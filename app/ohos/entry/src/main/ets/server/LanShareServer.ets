import { HttpRequest, HttpResponse, RequestHandler } from './HttpServer';
import { ByteUtils } from '../common/ByteUtils';
import { Device, FileDto, IdentityJson, PrepareUploadRequestJson } from '../protocol/Dto';
import { DeviceStore } from '../common/DeviceStore';
import { AppContext } from '../common/AppContext';
import { ReceiveController } from '../receive/ReceiveController';
import { ProtocolConstants } from '../common/Constants';
import { Logger } from '../common/Logger';

/**
 * LocalSend v2 REST routes served by LanShare.
 *
 *  POST /api/localsend/v2/register        discovery handshake
 *  GET  /api/localsend/v2/info            legacy/debug discovery (also /v1)
 *  POST /api/localsend/v2/prepare-upload  negotiate an upload (PIN checked here)
 *  POST /api/localsend/v2/upload          raw file body upload
 *  POST /api/localsend/v2/cancel          abort a session
 *
 * Status codes follow the protocol: 412 self-discovered, 401 PIN,
 * 403 declined/mismatch, 409 busy/conflict, 429 PIN rate limit.
 */
export class LanShareServer {
  private static readonly logger: Logger = new Logger('Router');

  private readonly store: DeviceStore = DeviceStore.getInstance();
  private readonly receive: ReceiveController = ReceiveController.getInstance();
  private readonly pinAttempts: Map<string, number> = new Map();

  readonly handler: RequestHandler = async (req: HttpRequest): Promise<HttpResponse> => {
    return this.route(req);
  };

  private async route(req: HttpRequest): Promise<HttpResponse> {
    const path = req.path;
    const isPost = req.method === 'POST';
    const isGet = req.method === 'GET';

    if (isPost && path === `${ProtocolConstants.API_V2_BASE}/register`) {
      return this.handleRegister(req);
    }
    if (isGet && (path === `${ProtocolConstants.API_V2_BASE}/info`
      || path === `${ProtocolConstants.API_V1_BASE}/info`)) {
      return this.handleInfo(req);
    }
    if (isPost && path === `${ProtocolConstants.API_V2_BASE}/prepare-upload`) {
      return this.handlePrepareUpload(req);
    }
    if (isPost && path === `${ProtocolConstants.API_V2_BASE}/upload`) {
      return this.handleUpload(req);
    }
    if (isPost && path === `${ProtocolConstants.API_V2_BASE}/cancel`) {
      return this.handleCancel(req);
    }
    return HttpResponse.text(404, 'Not Found');
  }

  private handleRegister(req: HttpRequest): HttpResponse {
    const identity = this.parseJson(req.body) as IdentityJson | null;
    if (identity === null || typeof identity.fingerprint !== 'string'
      || identity.fingerprint.length === 0) {
      return HttpResponse.text(400, 'Invalid body');
    }
    if (AppContext.isFingerprintSelf(identity.fingerprint)) {
      return HttpResponse.text(412, 'Self-discovered');
    }
    this.store.upsert(Device.fromIdentityJson(identity, req.remoteAddress));
    return HttpResponse.json(200, AppContext.getIdentity().toRegisterResponseJson());
  }

  private handleInfo(req: HttpRequest): HttpResponse {
    const known = req.query.get('fingerprint');
    if (known !== undefined && AppContext.isFingerprintSelf(known)) {
      return HttpResponse.text(412, 'Self-discovered');
    }
    return HttpResponse.json(200, AppContext.getIdentity().toRegisterResponseJson());
  }

  private handlePrepareUpload(req: HttpRequest): Promise<HttpResponse> {
    return this.doPrepareUpload(req);
  }

  private async doPrepareUpload(req: HttpRequest): Promise<HttpResponse> {
    // PIN gate before anything else; 3 failures per IP then 429.
    const settings = AppContext.getSettings();
    if (settings.pin.length > 0) {
      const provided = req.query.get('pin');
      if (provided === undefined || provided !== settings.pin) {
        const attempts = (this.pinAttempts.get(req.remoteAddress) ?? 0) + 1;
        this.pinAttempts.set(req.remoteAddress, attempts);
        LanShareServer.logger.warn(`bad PIN attempt ${attempts} from ${req.remoteAddress}`);
        if (attempts >= ProtocolConstants.MAX_PIN_ATTEMPTS) {
          return HttpResponse.text(429, 'Too many PIN attempts');
        }
        return HttpResponse.text(401, 'PIN required or invalid');
      }
      this.pinAttempts.delete(req.remoteAddress);
    }

    const body = this.parseJson(req.body) as PrepareUploadRequestJson | null;
    if (body === null || body.info === undefined || body.info === null
      || typeof body.info.fingerprint !== 'string'
      || body.files === undefined || body.files === null) {
      return HttpResponse.text(400, 'Invalid body');
    }

    const files: FileDto[] = [];
    const keys = Object.keys(body.files);
    for (let i = 0; i < keys.length; i++) {
      const raw = body.files[keys[i]];
      if (raw === undefined || raw === null) {
        continue;
      }
      // The map key must equal the file id; fall back to the key if absent.
      if (typeof raw.id !== 'string' || raw.id.length === 0) {
        raw.id = keys[i];
      }
      files.push(FileDto.fromJson(raw));
    }
    if (files.length === 0) {
      return HttpResponse.text(400, 'Must contain at least one file');
    }

    if (this.receive.isBusy()) {
      return HttpResponse.text(409, 'Blocked by another session');
    }

    const outcome = await this.receive.promptAndStart(body.info, req.remoteAddress, files);
    if (!outcome.accepted) {
      return HttpResponse.text(403, 'Declined');
    }
    if (outcome.tokens.size === 0) {
      return HttpResponse.empty(204);
    }

    const accepted: Record<string, string> = {};
    outcome.tokens.forEach((token: string, fileId: string) => {
      accepted[fileId] = token;
    });
    const payload: Record<string, Object> = {
      'sessionId': outcome.sessionId,
      'files': accepted
    };
    return HttpResponse.json(200, payload);
  }

  private handleUpload(req: HttpRequest): HttpResponse {
    const sessionId = req.query.get('sessionId');
    const fileId = req.query.get('fileId');
    const token = req.query.get('token');
    if (sessionId === undefined || fileId === undefined || token === undefined) {
      return HttpResponse.text(400, 'Missing parameters');
    }
    const status = this.receive.handleUpload(sessionId, fileId, token, req.remoteAddress, req.body);
    if (status === 200) {
      return HttpResponse.empty(200);
    }
    return HttpResponse.text(status, `Upload rejected (${status})`);
  }

  private handleCancel(req: HttpRequest): HttpResponse {
    const sessionId = req.query.get('sessionId');
    if (sessionId === undefined) {
      return HttpResponse.text(400, 'Missing sessionId');
    }
    const cancelled = this.receive.cancelFromPeer(sessionId, req.remoteAddress);
    return cancelled ? HttpResponse.empty(200) : HttpResponse.text(409, 'No such session');
  }

  private parseJson(body: ArrayBuffer): Object | null {
    try {
      const text = ByteUtils.utf8Decode(new Uint8Array(body));
      if (text.length === 0) {
        return null;
      }
      return JSON.parse(text) as Object;
    } catch (e) {
      return null;
    }
  }
}
