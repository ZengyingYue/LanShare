import { rcp } from '@kit.RemoteCommunicationKit';
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
 * HTTP(S) client for the LocalSend v2 REST API, built on
 * RemoteCommunicationKit (rcp).
 *
 * The official desktop/mobile clients enable encryption by default and serve
 * HTTPS with a per-install self-signed certificate. rcp lets us skip CA
 * validation (@ohos.net.http cannot), so M1 can talk to peers in either
 * mode. M2 replaces 'skip' with fingerprint pinning (TOFU).
 *
 * LAN traffic must never go through a system/VPN proxy, hence 'no-proxy'.
 */
export class LocalSendClient {
  private static readonly logger: Logger = new Logger('Client');

  private session: rcp.Session | null = null;

  private getSession(): rcp.Session {
    if (this.session === null) {
      this.session = rcp.createSession({
        requestConfiguration: {
          security: { remoteValidation: 'skip' },
          proxy: 'no-proxy'
        }
      } as rcp.SessionConfiguration);
    }
    return this.session;
  }

  private async post(url: string, contentType: string | null, body: string | ArrayBuffer | null,
    connectMs: number, transferMs: number): Promise<rcp.Response> {
    const headers: rcp.RequestHeaders = {};
    if (contentType !== null) {
      headers['content-type'] = contentType;
    }
    const request = new rcp.Request(url, 'POST', headers, body === null ? undefined : body);
    request.configuration = {
      transfer: { timeout: { connectMs: connectMs, transferMs: transferMs } }
    } as rcp.Configuration;
    return this.getSession().fetch(request);
  }

  /**
   * POST /register to an explicit address. Used both for announce replies
   * and for the subnet-scan fallback discovery.
   * Returns null when the peer is unreachable or reports 412 (self).
   */
  async registerTo(ip: string, port: number, protocol: string, identity: Identity,
    timeoutMs: number): Promise<Device | null> {
    try {
      const url = `${protocol}://${ip}:${port}${ProtocolConstants.API_V2_BASE}/register`;
      const response = await this.post(url, 'application/json',
        JSON.stringify(identity.toRegisterRequestJson()), timeoutMs, timeoutMs);
      if (response.statusCode === 200) {
        const json = JSON.parse(response.toString() ?? '') as IdentityJson;
        if (typeof json.fingerprint === 'string' && json.fingerprint.length > 0) {
          // The /register response omits port/protocol; we know both.
          json.port = port;
          json.protocol = protocol;
          return Device.fromIdentityJson(json, ip);
        }
      }
      // 412 = we found ourselves; anything else = not a LocalSend device.
      return null;
    } catch (e) {
      return null;
    }
  }

  /** Reply to a peer's announcement: introduces us and refreshes its info. */
  async register(device: Device, identity: Identity): Promise<Device | null> {
    return this.registerTo(device.ip, device.port, device.protocol, identity, 2500);
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

    let response: rcp.Response;
    try {
      // The receiver holds this request open until its user decides
      // (LocalSend waits up to a few minutes), so the transfer timeout is long.
      response = await this.post(url, 'application/json', JSON.stringify(body), 5000, 180000);
    } catch (e) {
      const err = e as BusinessError;
      LocalSendClient.logger.error(`prepare-upload failed: ${err.message ?? 'unknown'}`);
      throw new PrepareUploadError(0, 'network error');
    }
    const status = response.statusCode;
    if (status === 200) {
      return JSON.parse(response.toString() ?? '') as PrepareUploadResponseJson;
    }
    if (status === 204) {
      // Receiver already has everything; nothing to upload.
      const empty: PrepareUploadResponseJson = { sessionId: '', files: {} };
      return empty;
    }
    const message = `prepare-upload rejected with ${status}`;
    LocalSendClient.logger.warn(message);
    throw new PrepareUploadError(status, message);
  }

  /** Upload one file: POST /upload with the raw bytes as the request body. */
  async uploadFile(device: Device, sessionId: string, fileId: string, token: string,
    data: ArrayBuffer): Promise<boolean> {
    const url = `${device.baseUrl()}${ProtocolConstants.API_V2_BASE}/upload`
      + `?sessionId=${encodeURIComponent(sessionId)}`
      + `&fileId=${encodeURIComponent(fileId)}`
      + `&token=${encodeURIComponent(token)}`;
    try {
      // Whole-body upload of up to 64 MB over Wi-Fi needs headroom.
      const response = await this.post(url, 'application/octet-stream', data, 5000, 300000);
      if (response.statusCode !== 200) {
        LocalSendClient.logger.warn(`upload ${fileId} rejected with ${response.statusCode}`);
      }
      return response.statusCode === 200;
    } catch (e) {
      const err = e as BusinessError;
      LocalSendClient.logger.error(`upload ${fileId} failed: ${err.message ?? 'unknown'}`);
      return false;
    }
  }

  /** Abort a session: POST /cancel. Best effort, errors ignored. */
  async cancel(device: Device, sessionId: string): Promise<void> {
    const url = `${device.baseUrl()}${ProtocolConstants.API_V2_BASE}/cancel`
      + `?sessionId=${encodeURIComponent(sessionId)}`;
    try {
      await this.post(url, null, null, 3000, 3000);
    } catch (e) {
      // ignore
    }
  }
}
