import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Device, FileDto, Identity, IdentityJson, PrepareUploadResponseJson } from '../protocol/Dto';
import { ProtocolConstants } from '../common/Constants';
import { Logger } from '../common/Logger';

/** Error carrying the peer's HTTP status so senders can react (e.g. 401 PIN). */
export class PrepareUploadError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/**
 * HTTP client for the LocalSend v2 REST API, built on @ohos.net.http.
 *
 * M1 speaks plain HTTP, which the protocol allows. When TLS lands in M2
 * this class will be re-based on RemoteCommunicationKit (rcp), whose
 * security configuration can accept self-signed peer certificates —
 * @ohos.net.http cannot skip certificate validation.
 */
export class LocalSendClient {
  private static readonly logger: Logger = new Logger('Client');

  /**
   * POST /register to an explicit address. Used both for announce replies
   * and for the subnet-scan fallback discovery.
   * Returns null when the peer is unreachable or reports 412 (self).
   */
  async registerTo(ip: string, port: number, identity: Identity, timeoutMs: number): Promise<Device | null> {
    const client = http.createHttp();
    try {
      const url = `http://${ip}:${port}${ProtocolConstants.API_V2_BASE}/register`;
      const response = await client.request(url, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' } as Record<string, string>,
        extraData: JSON.stringify(identity.toRegisterRequestJson()),
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING,
        usingProtocol: http.HttpProtocol.HTTP1_1
      } as http.HttpRequestOptions);
      if (response.responseCode === 200 && typeof response.result === 'string') {
        const json = JSON.parse(response.result) as IdentityJson;
        if (typeof json.fingerprint === 'string' && json.fingerprint.length > 0) {
          return Device.fromIdentityJson(json, ip);
        }
      }
      // 412 = we found ourselves; anything else = not a LocalSend device.
      return null;
    } catch (e) {
      return null;
    } finally {
      client.destroy();
    }
  }

  /** Reply to a peer's announcement: introduces us and refreshes its info. */
  async register(device: Device, identity: Identity): Promise<Device | null> {
    return this.registerTo(device.ip, device.port, identity, 2500);
  }

  /**
   * Negotiate an upload: POST /prepare-upload with the sender identity and
   * the file list. On success returns { sessionId, files: { id -> token } }.
   * Throws PrepareUploadError with the peer's status on rejection.
   */
  async prepareUpload(device: Device, identity: Identity, files: FileDto[],
    pin: string | null): Promise<PrepareUploadResponseJson> {
    const filesJson: Record<string, Object> = {};
    for (let i = 0; i < files.length; i++) {
      const f = files[i];
      filesJson[f.id] = f.toJson();
    }
    const body: Record<string, Object> = {
      'info': identity.toRegisterRequestJson(),
      'files': filesJson
    };

    let url = `${device.baseUrl()}${ProtocolConstants.API_V2_BASE}/prepare-upload`;
    if (pin !== null && pin.length > 0) {
      url = `${url}?pin=${encodeURIComponent(pin)}`;
    }

    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' } as Record<string, string>,
        extraData: JSON.stringify(body),
        connectTimeout: 5000,
        readTimeout: 30000,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING,
        usingProtocol: http.HttpProtocol.HTTP1_1
      } as http.HttpRequestOptions);
      const status = response.responseCode;
      if (status === 200 && typeof response.result === 'string') {
        return JSON.parse(response.result) as PrepareUploadResponseJson;
      }
      const message = `prepare-upload rejected with ${status}`;
      LocalSendClient.logger.warn(message);
      throw new PrepareUploadError(status, message);
    } catch (e) {
      if (e instanceof PrepareUploadError) {
        throw e;
      }
      const err = e as BusinessError;
      LocalSendClient.logger.error(`prepare-upload failed: ${err.message ?? 'unknown'}`);
      throw new PrepareUploadError(0, 'network error');
    } finally {
      client.destroy();
    }
  }

  /** Upload one file: POST /upload with the raw bytes as the request body. */
  async uploadFile(device: Device, sessionId: string, fileId: string, token: string,
    data: ArrayBuffer): Promise<boolean> {
    const url = `${device.baseUrl()}${ProtocolConstants.API_V2_BASE}/upload`
      + `?sessionId=${encodeURIComponent(sessionId)}`
      + `&fileId=${encodeURIComponent(fileId)}`
      + `&token=${encodeURIComponent(token)}`;

    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/octet-stream' } as Record<string, string>,
        extraData: data,
        connectTimeout: 5000,
        // Whole-body upload of up to 64 MB over Wi-Fi needs headroom.
        readTimeout: 300000,
        usingCache: false,
        usingProtocol: http.HttpProtocol.HTTP1_1
      } as http.HttpRequestOptions);
      return response.responseCode === 200;
    } catch (e) {
      const err = e as BusinessError;
      LocalSendClient.logger.error(`upload ${fileId} failed: ${err.message ?? 'unknown'}`);
      return false;
    } finally {
      client.destroy();
    }
  }

  /** Abort a session: POST /cancel. Best effort, errors ignored. */
  async cancel(device: Device, sessionId: string): Promise<void> {
    const url = `${device.baseUrl()}${ProtocolConstants.API_V2_BASE}/cancel`
      + `?sessionId=${encodeURIComponent(sessionId)}`;
    const client = http.createHttp();
    try {
      await client.request(url, {
        method: http.RequestMethod.POST,
        connectTimeout: 3000,
        readTimeout: 3000,
        usingCache: false,
        usingProtocol: http.HttpProtocol.HTTP1_1
      } as http.HttpRequestOptions);
    } catch (e) {
      // ignore
    } finally {
      client.destroy();
    }
  }
}
