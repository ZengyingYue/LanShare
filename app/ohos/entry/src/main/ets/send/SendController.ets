import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Device, FileDto, PrepareUploadResponseJson } from '../protocol/Dto';
import { LocalSendClient, PrepareUploadError } from '../client/LocalSendClient';
import { AppContext } from '../common/AppContext';
import { Mime } from '../common/Mime';
import { ProtocolConstants } from '../common/Constants';
import { Logger } from '../common/Logger';

export class OutgoingFileStates {
  static readonly READY: string = 'ready';
  static readonly TOO_LARGE: string = 'tooLarge';
  static readonly UPLOADING: string = 'uploading';
  static readonly DONE: string = 'done';
  static readonly FAILED: string = 'failed';
}

export class OutgoingFile {
  readonly id: string;
  readonly uri: string;
  readonly fileName: string;
  readonly size: number;
  readonly fileType: string;
  state: string;

  constructor(id: string, uri: string, fileName: string, size: number, fileType: string,
    state: string) {
    this.id = id;
    this.uri = uri;
    this.fileName = fileName;
    this.size = size;
    this.fileType = fileType;
    this.state = state;
  }
}

export class SendResult {
  static readonly OK: string = 'ok';
  static readonly EMPTY: string = 'empty';
  static readonly PIN_REQUIRED: string = 'pinRequired';
  static readonly DECLINED: string = 'declined';
  static readonly BUSY: string = 'busy';
  static readonly PIN_LOCKED: string = 'pinLocked';
  static readonly FAILED: string = 'failed';

  readonly outcome: string;
  readonly failedCount: number;

  constructor(outcome: string, failedCount: number) {
    this.outcome = outcome;
    this.failedCount = failedCount;
  }
}

/**
 * Outgoing transfer flow: pick files -> prepare-upload -> parallel raw
 * uploads (3 at a time). M1 buffers whole files in memory, so files above
 * MAX_FILE_SIZE_BYTES are rejected up front.
 */
export class SendController {
  private static instance: SendController | null = null;

  private readonly logger: Logger = new Logger('Send');
  private readonly client: LocalSendClient = new LocalSendClient();
  private files: OutgoingFile[] = [];
  private onChange: (() => void) | null = null;

  static getInstance(): SendController {
    if (SendController.instance === null) {
      SendController.instance = new SendController();
    }
    return SendController.instance;
  }

  /** UI registers to re-render when file states change. */
  setChangeListener(listener: () => void): void {
    this.onChange = listener;
  }

  getFiles(): OutgoingFile[] {
    return this.files;
  }

  /** Add picker results; sizes are checked against the M1 cap. */
  addUris(uris: string[]): void {
    for (let i = 0; i < uris.length; i++) {
      const uri = uris[i];
      try {
        const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        const stat = fs.statSync(file.fd);
        fs.closeSync(file);
        const fileName = SendController.fileNameFromUri(uri);
        const state = stat.size > ProtocolConstants.MAX_FILE_SIZE_BYTES
          ? OutgoingFileStates.TOO_LARGE : OutgoingFileStates.READY;
        this.files.push(new OutgoingFile(util.generateRandomUUID(false), uri, fileName,
          stat.size, Mime.forFileName(fileName), state));
      } catch (e) {
        const err = e as BusinessError;
        this.logger.warn(`cannot open ${uri}: ${err.message ?? 'unknown'}`);
      }
    }
    this.notify();
  }

  clear(): void {
    this.files = [];
    this.notify();
  }

  hasReadyFiles(): boolean {
    let ready = false;
    for (let i = 0; i < this.files.length; i++) {
      if (this.files[i].state === OutgoingFileStates.READY
        || this.files[i].state === OutgoingFileStates.DONE
        || this.files[i].state === OutgoingFileStates.FAILED) {
        ready = true;
      }
    }
    return ready;
  }

  async sendTo(device: Device, pin: string): Promise<SendResult> {
    const ready: OutgoingFile[] = this.files.filter((f: OutgoingFile) => {
      return f.state === OutgoingFileStates.READY;
    });
    if (ready.length === 0) {
      return new SendResult(SendResult.EMPTY, 0);
    }

    const identity = AppContext.getIdentity();
    const dtos: FileDto[] = ready.map((f: OutgoingFile) => {
      return new FileDto(f.id, f.fileName, f.size, f.fileType, null, null);
    });

    let response: PrepareUploadResponseJson;
    try {
      response = await this.client.prepareUpload(device, identity, dtos, pin);
    } catch (e) {
      let outcome = SendResult.FAILED;
      if (e instanceof PrepareUploadError) {
        if (e.status === 401) {
          outcome = SendResult.PIN_REQUIRED;
        } else if (e.status === 403) {
          outcome = SendResult.DECLINED;
        } else if (e.status === 409) {
          outcome = SendResult.BUSY;
        } else if (e.status === 429) {
          outcome = SendResult.PIN_LOCKED;
        }
      }
      this.logger.warn(`prepare-upload failed: ${outcome}`);
      return new SendResult(outcome, ready.length);
    }

    const acceptedIds = Object.keys(response.files);
    if (acceptedIds.length === 0) {
      // 204-equivalent: receiver considered the transfer complete.
      ready.forEach((f: OutgoingFile) => {
        f.state = OutgoingFileStates.DONE;
      });
      this.notify();
      return new SendResult(SendResult.OK, 0);
    }

    let failed = 0;
    const CONCURRENCY = 3;
    for (let i = 0; i < acceptedIds.length; i += CONCURRENCY) {
      const batch = acceptedIds.slice(i, i + CONCURRENCY);
      const results = await Promise.all(batch.map((fileId: string) => {
        return this.uploadOne(device, response.sessionId, fileId, response.files[fileId], ready);
      }));
      for (let j = 0; j < results.length; j++) {
        if (!results[j]) {
          failed++;
        }
      }
    }

    if (failed > 0) {
      await this.client.cancel(device, response.sessionId);
      return new SendResult(SendResult.FAILED, failed);
    }
    return new SendResult(SendResult.OK, 0);
  }

  private async uploadOne(device: Device, sessionId: string, fileId: string, token: string,
    pool: OutgoingFile[]): Promise<boolean> {
    let file: OutgoingFile | null = null;
    for (let i = 0; i < pool.length; i++) {
      if (pool[i].id === fileId) {
        file = pool[i];
        break;
      }
    }
    if (file === null || token === undefined) {
      return false;
    }
    file.state = OutgoingFileStates.UPLOADING;
    this.notify();
    try {
      const data = await SendController.readAll(file.uri, file.size);
      const ok = await this.client.uploadFile(device, sessionId, fileId, token, data);
      file.state = ok ? OutgoingFileStates.DONE : OutgoingFileStates.FAILED;
      this.notify();
      return ok;
    } catch (e) {
      const err = e as BusinessError;
      this.logger.error(`upload ${file.fileName} failed: ${err.message ?? 'unknown'}`);
      file.state = OutgoingFileStates.FAILED;
      this.notify();
      return false;
    }
  }

  private notify(): void {
    if (this.onChange !== null) {
      this.onChange();
    }
  }

  /** Read the whole file (bounded by MAX_FILE_SIZE_BYTES by the caller). */
  private static readAll(uri: string, size: number): Promise<ArrayBuffer> {
    return new Promise<ArrayBuffer>((resolve: (buffer: ArrayBuffer) => void,
      reject: (e: Object) => void) => {
      try {
        const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        try {
          const buffer = new ArrayBuffer(size);
          const read = fs.readSync(file.fd, buffer);
          if (read !== size) {
            throw new Error(`short read: ${read}/${size}`);
          }
          resolve(buffer);
        } finally {
          fs.closeSync(file);
        }
      } catch (e) {
        reject(e as Object);
      }
    });
  }

  private static fileNameFromUri(uri: string): string {
    try {
      const noQuery = uri.split('?')[0];
      const segments = noQuery.split('/');
      const last = segments[segments.length - 1];
      const decoded = decodeURIComponent(last);
      if (decoded.length > 0) {
        return decoded;
      }
    } catch (e) {
      // fall through
    }
    return `file-${Date.now()}`;
  }
}
