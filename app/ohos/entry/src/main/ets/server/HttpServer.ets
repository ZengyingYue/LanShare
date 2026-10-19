import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteUtils } from '../common/ByteUtils';
import { Logger } from '../common/Logger';

/** A fully buffered request handed to the router. */
export interface HttpRequest {
  method: string;
  path: string;
  query: Map<string, string>;
  headers: Map<string, string>;
  body: ArrayBuffer;
  remoteAddress: string;
}

export class HttpResponse {
  readonly status: number;
  readonly contentType: string;
  readonly body: string | ArrayBuffer | null;

  constructor(status: number, contentType: string, body: string | ArrayBuffer | null) {
    this.status = status;
    this.contentType = contentType;
    this.body = body;
  }

  static json(status: number, payload: Record<string, Object>): HttpResponse {
    return new HttpResponse(status, 'application/json; charset=utf-8', JSON.stringify(payload));
  }

  static empty(status: number): HttpResponse {
    return new HttpResponse(status, 'application/json; charset=utf-8', '');
  }

  static text(status: number, message: string): HttpResponse {
    return new HttpResponse(status, 'text/plain; charset=utf-8', message);
  }
}

export type RequestHandler = (req: HttpRequest) => Promise<HttpResponse>;

/** Incremental decoder for `Transfer-Encoding: chunked` bodies. */
class ChunkedDecoder {
  private pending: Uint8Array = new Uint8Array(0);
  private state: number = 0; // 0: size line, 1: chunk data, 2: trailer
  private expected: number = 0;
  collected: ArrayBuffer[] = [];
  done: boolean = false;

  feed(data: Uint8Array): void {
    this.pending = ChunkedDecoder.concat(this.pending, data);
    let progressed = true;
    while (!this.done && progressed) {
      progressed = false;
      if (this.state === 0) {
        const idx = ByteUtils.indexOf(this.pending, HttpServer.CRLF, 0);
        if (idx >= 0) {
          const line = ByteUtils.utf8Decode(this.pending.subarray(0, idx));
          const size = ChunkedDecoder.parseHexSize(line);
          this.pending = this.pending.slice(idx + 2);
          if (size === 0) {
            this.state = 2;
          } else {
            this.expected = size;
            this.state = 1;
          }
          progressed = true;
        }
      } else if (this.state === 1) {
        if (this.pending.length >= this.expected + 2) {
          this.collected.push(this.pending.slice(0, this.expected).buffer);
          // Skip the CRLF that follows every chunk; peers conform in practice.
          this.pending = this.pending.slice(this.expected + 2);
          this.state = 0;
          progressed = true;
        }
      } else {
        const idx = ByteUtils.indexOf(this.pending, HttpServer.CRLF, 0);
        if (idx === 0) {
          this.done = true;
        } else if (idx > 0) {
          this.pending = this.pending.slice(idx + 2);
          progressed = true;
        }
      }
    }
  }

  private static concat(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  private static parseHexSize(line: string): number {
    const cleaned = line.split(';')[0].trim().toLowerCase();
    if (cleaned.length === 0) {
      throw new Error('empty chunk size');
    }
    let value = 0;
    for (let i = 0; i < cleaned.length; i++) {
      const c = cleaned.charCodeAt(i);
      let digit: number;
      if (c >= 48 && c <= 57) {
        digit = c - 48;
      } else if (c >= 97 && c <= 102) {
        digit = c - 97 + 10;
      } else {
        throw new Error('invalid chunk size');
      }
      value = value * 16 + digit;
    }
    return value;
  }
}

/** Per-connection accumulation state; one request per connection (we send `Connection: close`). */
class ConnectionState {
  private headParts: Array<ArrayBuffer> = [];
  private headerEndFound: boolean = false;
  private bodyParts: Array<ArrayBuffer> = [];
  private bodyReceived: number = 0;
  private contentLength: number = -1;
  private chunked: boolean = false;
  private chunkDecoder: ChunkedDecoder | null = null;
  private method: string = '';
  private path: string = '';
  private query: Map<string, string> = new Map();
  private headers: Map<string, string> = new Map();
  private remoteAddress: string = '';

  push(chunk: ArrayBuffer, remoteAddress: string): HttpRequest | null {
    this.remoteAddress = remoteAddress;
    if (!this.headerEndFound) {
      const parts = this.headParts.slice(0);
      parts.push(chunk);
      const merged = new Uint8Array(ByteUtils.concat(parts));
      const idx = ByteUtils.indexOf(merged, HttpServer.CRLFCRLF, 0);
      if (idx < 0) {
        if (merged.length > HttpServer.MAX_HEADER_BYTES) {
          throw new Error('header too large');
        }
        this.headParts = [merged.buffer];
        return null;
      }
      this.parseHead(ByteUtils.utf8Decode(merged.subarray(0, idx)));
      this.headerEndFound = true;
      const rest = merged.slice(idx + 4);
      if (rest.length > 0) {
        return this.pushBody(rest.buffer);
      }
      return this.tryComplete();
    }
    return this.pushBody(chunk);
  }

  private pushBody(chunk: ArrayBuffer): HttpRequest | null {
    if (this.chunked) {
      if (this.chunkDecoder === null) {
        this.chunkDecoder = new ChunkedDecoder();
      }
      this.chunkDecoder.feed(new Uint8Array(chunk));
      return this.tryComplete();
    }
    this.bodyParts.push(chunk);
    this.bodyReceived += chunk.byteLength;
    return this.tryComplete();
  }

  private tryComplete(): HttpRequest | null {
    let body: ArrayBuffer;
    if (this.chunked) {
      const decoder = this.chunkDecoder as ChunkedDecoder;
      if (!decoder.done) {
        return null;
      }
      body = ByteUtils.concat(decoder.collected);
    } else if (this.contentLength < 0) {
      body = new ArrayBuffer(0);
    } else if (this.bodyReceived < this.contentLength) {
      return null;
    } else {
      const merged = new Uint8Array(ByteUtils.concat(this.bodyParts));
      body = merged.slice(0, this.contentLength).buffer;
    }
    return {
      method: this.method,
      path: this.path,
      query: this.query,
      headers: this.headers,
      body: body,
      remoteAddress: this.remoteAddress
    };
  }

  private parseHead(headText: string): void {
    const lines = headText.split('\r\n');
    const requestLine = lines[0].split(' ');
    if (requestLine.length < 2) {
      throw new Error('malformed request line');
    }
    this.method = requestLine[0].toUpperCase();
    const target = requestLine[1];
    const qIdx = target.indexOf('?');
    if (qIdx >= 0) {
      this.path = target.substring(0, qIdx);
      this.query = ConnectionState.parseQuery(target.substring(qIdx + 1));
    } else {
      this.path = target;
      this.query = new Map();
    }
    for (let i = 1; i < lines.length; i++) {
      const colon = lines[i].indexOf(':');
      if (colon <= 0) {
        continue;
      }
      const key = lines[i].substring(0, colon).trim().toLowerCase();
      const value = lines[i].substring(colon + 1).trim();
      this.headers.set(key, value);
    }
    const transferEncoding = this.headers.get('transfer-encoding');
    this.chunked = transferEncoding !== undefined && transferEncoding.toLowerCase().indexOf('chunked') >= 0;
    if (this.chunked) {
      this.chunkDecoder = new ChunkedDecoder();
    } else {
      const contentLengthHeader = this.headers.get('content-length');
      if (contentLengthHeader !== undefined) {
        const parsed = parseInt(contentLengthHeader, 10);
        if (isNaN(parsed) || parsed < 0) {
          throw new Error('invalid content-length');
        }
        this.contentLength = parsed;
      }
    }
  }

  private static parseQuery(queryText: string): Map<string, string> {
    const map = new Map<string, string>();
    if (queryText.length === 0) {
      return map;
    }
    const pairs = queryText.split('&');
    for (let i = 0; i < pairs.length; i++) {
      const eq = pairs[i].indexOf('=');
      let key = pairs[i];
      let value = '';
      if (eq >= 0) {
        key = pairs[i].substring(0, eq);
        value = pairs[i].substring(eq + 1);
      }
      try {
        map.set(decodeURIComponent(key), decodeURIComponent(value));
      } catch (e) {
        map.set(key, value);
      }
    }
    return map;
  }
}

/**
 * Minimal HTTP/1.1 server over @ohos.net.socket TCPSocketServer.
 *
 * One request per connection: every response carries `Connection: close`
 * and the connection is closed right after. The official clients (and
 * browsers) handle this fine and it keeps the parser simple.
 *
 * M2 note: for HTTPS, swap the TCPSocketServer for a TLSSocketServer
 * configured with a per-install self-signed certificate; everything above
 * this class stays unchanged.
 */
export class HttpServer {
  static readonly CRLF: Uint8Array = new Uint8Array([13, 10]);
  static readonly CRLFCRLF: Uint8Array = new Uint8Array([13, 10, 13, 10]);
  static readonly MAX_HEADER_BYTES: number = 65536;

  private static readonly REASONS: Record<string, string> = {
    '200': 'OK',
    '204': 'No Content',
    '400': 'Bad Request',
    '401': 'Unauthorized',
    '403': 'Forbidden',
    '404': 'Not Found',
    '405': 'Method Not Allowed',
    '409': 'Conflict',
    '412': 'Precondition Failed',
    '413': 'Payload Too Large',
    '422': 'Unprocessable Entity',
    '429': 'Too Many Requests',
    '500': 'Internal Server Error'
  };

  private readonly logger: Logger = new Logger('HttpServer');
  private readonly handler: RequestHandler;
  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;

  constructor(handler: RequestHandler) {
    this.handler = handler;
  }

  get listeningPort(): number {
    return this.port;
  }

  async start(port: number): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    server.on('connect', (connection: socket.TCPSocketConnection) => {
      this.onConnect(connection);
    });
    server.on('error', (error: BusinessError) => {
      this.logger.error(`server error ${error.code}: ${error.message}`);
    });
    await server.listen({ address: '0.0.0.0', port: port } as socket.NetAddress);
    this.server = server;
    this.port = port;
    this.logger.info(`listening on 0.0.0.0:${port}`);
  }

  async stop(): Promise<void> {
    if (this.server !== null) {
      try {
        this.server.off('connect');
        this.server.off('error');
      } catch (e) {
        // ignore
      }
      this.server = null;
      this.port = 0;
    }
  }

  private onConnect(connection: socket.TCPSocketConnection): void {
    const state = new ConnectionState();
    connection.on('message', (info: socket.SocketMessageInfo) => {
      let request: HttpRequest | null = null;
      try {
        request = state.push(info.message, info.remoteInfo.address);
      } catch (e) {
        this.logger.warn(`bad request from ${info.remoteInfo.address}`);
        this.sendAndClose(connection, HttpResponse.text(400, 'Bad Request'));
        return;
      }
      if (request !== null) {
        this.dispatch(connection, request);
      }
    });
    connection.on('close', () => {
    });
    connection.on('error', (error: BusinessError) => {
      this.logger.warn(`connection error: ${error.message}`);
    });
  }

  private async dispatch(connection: socket.TCPSocketConnection, request: HttpRequest): Promise<void> {
    const startedAt = Date.now();
    let response: HttpResponse;
    try {
      response = await this.handler(request);
    } catch (e) {
      const err = e as BusinessError;
      this.logger.error(`handler crashed: ${err.message ?? 'unknown'}`);
      response = HttpResponse.text(500, 'Internal Server Error');
    }
    const elapsed = Date.now() - startedAt;
    this.logger.info(`${request.remoteAddress} "${request.method} ${request.path}" -> ${response.status} (${elapsed}ms)`);
    this.sendAndClose(connection, response);
  }

  private sendAndClose(connection: socket.TCPSocketConnection, response: HttpResponse): void {
    (async () => {
      try {
        await this.sendResponse(connection, response);
      } catch (e) {
        this.logger.warn('failed to send response');
      }
      try {
        await connection.close();
      } catch (e) {
        // peer may already be gone
      }
    })();
  }

  private async sendResponse(connection: socket.TCPSocketConnection,
    response: HttpResponse): Promise<void> {
    let bodyBytes = new Uint8Array(0);
    if (typeof response.body === 'string') {
      bodyBytes = ByteUtils.utf8Encode(response.body);
    } else if (response.body !== null) {
      bodyBytes = new Uint8Array(response.body as ArrayBuffer);
    }
    const reason = HttpServer.REASONS[`${response.status}`] ?? 'Unknown';
    const head = 'HTTP/1.1 ' + `${response.status}` + ' ' + reason + '\r\n'
      + 'Content-Type: ' + response.contentType + '\r\n'
      + 'Content-Length: ' + `${bodyBytes.length}` + '\r\n'
      + 'Connection: close\r\n'
      + '\r\n';
    const headBytes = ByteUtils.utf8Encode(head);
    const payload = ByteUtils.concat([
      HttpServer.exactBuffer(headBytes),
      HttpServer.exactBuffer(bodyBytes)
    ]);
    await connection.send({ data: payload } as socket.TCPSendOptions);
  }

  /** Uint8Array.buffer can be larger than the view; trim to exact bytes. */
  private static exactBuffer(bytes: Uint8Array): ArrayBuffer {
    if (bytes.byteLength === bytes.buffer.byteLength) {
      return bytes.buffer;
    }
    return bytes.slice().buffer;
  }
}
