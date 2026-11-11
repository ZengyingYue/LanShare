import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { FileDto, IdentityJson } from '../protocol/Dto';
import { AppContext } from '../common/AppContext';
import { AppStorageKeys, ProtocolConstants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { IncomingFile, ReceivePhases, ReceiveSnapshot } from './ReceiveModels';

/** Result of the user-decision prompt handed back to the server route. */
export class PromptOutcome {
  readonly accepted: boolean;
  readonly sessionId: string;
  readonly tokens: Map<string, string>; // fileId -> token

  constructor(accepted: boolean, sessionId: string, tokens: Map<string, string>) {
    this.accepted = accepted;
    this.sessionId = sessionId;
    this.tokens = tokens;
  }
}

class ReceiveSession {
  readonly sessionId: string;
  readonly senderIp: string;
  readonly files: Map<string, IncomingFile>;
  readonly created: number;

  constructor(sessionId: string, senderIp: string, files: Map<string, IncomingFile>) {
    this.sessionId = sessionId;
    this.senderIp = senderIp;
    this.files = files;
    this.created = Date.now();
  }

  allDone(): boolean {
    let done = true;
    this.files.forEach((f: IncomingFile) => {
      if (!f.done && !f.skipped) {
        done = false;
      }
    });
    return done;
  }
}

/**
 * Owns the single active receive session (the protocol allows one at a
 * time — extra requests get 409). The server routes upload traffic here;
 * the UI drives accept/decline and target-folder selection.
 */
export class ReceiveController {
  private static instance: ReceiveController | null = null;

  private readonly logger: Logger = new Logger('Receive');
  private session: ReceiveSession | null = null;
  private pendingResolve: ((accepted: boolean) => void) | null = null;
  private promptTimer: number = -1;
  private staleTimer: number = -1;
  private snapshot: ReceiveSnapshot = ReceiveSnapshot.idle();

  static getInstance(): ReceiveController {
    if (ReceiveController.instance === null) {
      ReceiveController.instance = new ReceiveController();
    }
    return ReceiveController.instance;
  }

  isBusy(): boolean {
    return this.session !== null || this.pendingResolve !== null;
  }

  /**
   * Show the prompt in the UI and wait for the user (or the timeout).
   * Resolves with the session id and per-file tokens on acceptance.
   */
  async promptAndStart(sender: IdentityJson, senderIp: string, files: FileDto[]): Promise<PromptOutcome> {
    if (this.isBusy()) {
      return new PromptOutcome(false, '', new Map());
    }

    const incomingFiles: IncomingFile[] = files.map((f: FileDto) => {
      const incoming = new IncomingFile(f.id, f.fileName, f.size, f.fileType, '');
      incoming.skipped = f.size > ProtocolConstants.MAX_FILE_SIZE_BYTES;
      return incoming;
    });
    let acceptable = 0;
    incomingFiles.forEach((f: IncomingFile) => {
      if (!f.skipped) {
        acceptable++;
      }
    });
    if (acceptable === 0) {
      this.logger.info(`request from ${senderIp} has only oversized files, declining`);
      return new PromptOutcome(false, '', new Map());
    }
    let alias = senderIp;
    if (typeof sender.alias === 'string' && sender.alias.length > 0) {
      alias = sender.alias;
    }
    this.publish(ReceivePhases.PROMPTING, alias, sender.deviceModel ?? '', senderIp, '', incomingFiles, '');

    const accepted = await this.waitForDecision();
    if (!accepted) {
      this.logger.info(`request from ${senderIp} declined`);
      this.publish(ReceivePhases.DECLINED, alias, '', senderIp, '', incomingFiles, '');
      this.resetAfter(3000);
      return new PromptOutcome(false, '', new Map());
    }

    const sessionId = util.generateRandomUUID(false);
    const fileMap = new Map<string, IncomingFile>();
    const tokens = new Map<string, string>();
    const cacheDir = AppContext.getContext().cacheDir;
    incomingFiles.forEach((f: IncomingFile) => {
      fileMap.set(f.id, f);
      if (f.skipped) {
        return; // no token: the sender will not upload it
      }
      const token = util.generateRandomUUID(false);
      f.token = token;
      f.tempPath = `${cacheDir}/lanshare_${sessionId}_${ReceiveController.sanitize(f.fileName)}`;
      tokens.set(f.id, token);
    });
    this.session = new ReceiveSession(sessionId, senderIp, fileMap);
    this.logger.info(`session ${sessionId} started: ${fileMap.size} file(s) from ${senderIp}`);

    this.staleTimer = setTimeout(() => {
      this.abort('session timed out');
    }, 300000);

    this.publish(ReceivePhases.WAITING, alias, sender.deviceModel ?? '', senderIp, sessionId,
      this.snapshotFiles(), '');
    return new PromptOutcome(true, sessionId, tokens);
  }

  /**
   * A LocalSend text message: one text file whose full content travels in
   * `preview` (Windows/macOS "Paste"/"Text" send). Like the official client
   * we show it without a prompt and the server answers 204, so the sender
   * never uploads a .txt file. The text also goes to the system clipboard.
   */
  receiveMessage(sender: IdentityJson, senderIp: string, text: string): void {
    let alias = senderIp;
    if (typeof sender.alias === 'string' && sender.alias.length > 0) {
      alias = sender.alias;
    }
    const model = sender.deviceModel ?? '';
    this.logger.info(`text message from ${senderIp} (${text.length} chars)`);
    this.publish(ReceivePhases.MESSAGE, alias, model, senderIp, '', [], '', text, false);
    this.copyMessage();
  }

  /** Copy the displayed message to the system clipboard (also the Copy button). */
  async copyMessage(): Promise<void> {
    const snap = this.snapshot;
    if (snap.phase !== ReceivePhases.MESSAGE) {
      return;
    }
    let error = '';
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, snap.message);
      await pasteboard.getSystemPasteboard().setData(data);
    } catch (e) {
      const err = e as BusinessError;
      error = err.message ?? 'copy failed';
      this.logger.warn(`clipboard write failed: ${error}`);
    }
    // A newer request may have replaced the snapshot while we awaited.
    if (this.snapshot === snap) {
      this.publish(ReceivePhases.MESSAGE, snap.senderAlias, snap.senderModel, snap.senderIp, '', [],
        error, snap.message, error === '');
    }
  }

  /** Close button on the message card. */
  dismissMessage(): void {
    if (this.snapshot.phase === ReceivePhases.MESSAGE) {
      this.publish(ReceivePhases.IDLE, '', '', '', '', [], '');
    }
  }

  /** Called by the Accept button. */
  acceptFromUi(): void {
    if (this.pendingResolve !== null) {
      const resolve = this.pendingResolve;
      this.pendingResolve = null;
      clearTimeout(this.promptTimer);
      resolve(true);
    }
  }

  /** Called by the Decline button (or the prompt timeout). */
  declineFromUi(): void {
    if (this.pendingResolve !== null) {
      const resolve = this.pendingResolve;
      this.pendingResolve = null;
      clearTimeout(this.promptTimer);
      resolve(false);
    }
  }

  /** Store one uploaded file; returns the HTTP status to reply with. */
  handleUpload(sessionId: string, fileId: string, token: string, remoteIp: string,
    body: ArrayBuffer): number {
    const session = this.session;
    if (session === null) {
      return 409; // no session
    }
    if (remoteIp !== session.senderIp) {
      return 403; // session bound to the prepare-upload sender
    }
    if (sessionId !== session.sessionId) {
      return 403;
    }
    const file = session.files.get(fileId);
    if (file === undefined) {
      return 403; // unknown file
    }
    if (file.skipped || file.token !== token) {
      return 403; // token mismatch
    }
    if (file.done) {
      return 409;
    }
    try {
      const fd = fs.openSync(file.tempPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(fd.fd, body);
      fs.closeSync(fd);
    } catch (e) {
      const err = e as BusinessError;
      this.logger.error(`failed to write ${file.fileName}: ${err.message ?? 'unknown'}`);
      return 500;
    }
    file.bytesReceived = body.byteLength;
    file.done = true;
    this.logger.info(`received ${file.fileName} (${file.bytesReceived} bytes)`);

    if (session.allDone()) {
      clearTimeout(this.staleTimer);
      this.publish(ReceivePhases.READY_TO_SAVE, this.snapshot.senderAlias,
        this.snapshot.senderModel, this.snapshot.senderIp, session.sessionId,
        this.snapshotFiles(), '');
      // Try the save dialog immediately; if the app is backgrounded the UI
      // button lets the user retry.
      this.saveToUser();
    } else {
      this.publish(ReceivePhases.RECEIVING, this.snapshot.senderAlias,
        this.snapshot.senderModel, this.snapshot.senderIp, session.sessionId,
        this.snapshotFiles(), '');
    }
    return 200;
  }

  /** Sender aborts: POST /cancel. */
  cancelFromPeer(sessionId: string, remoteIp: string): boolean {
    const session = this.session;
    if (session === null || sessionId !== session.sessionId || remoteIp !== session.senderIp) {
      return false;
    }
    this.abort('cancelled by sender');
    return true;
  }

  /** Save received files via the system picker (user picks the folder). */
  async saveToUser(): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    if (this.snapshot.phase !== ReceivePhases.READY_TO_SAVE
      && this.snapshot.phase !== ReceivePhases.FAILED) {
      return;
    }
    this.publish(ReceivePhases.SAVING, this.snapshot.senderAlias, this.snapshot.senderModel,
      this.snapshot.senderIp, session.sessionId, this.snapshotFiles(), '');
    try {
      const ordered = Array.from(session.files.values()).filter((f: IncomingFile) => f.done);
      const names: string[] = ordered.map((f: IncomingFile) => ReceiveController.sanitize(f.fileName));
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = names;
      const docPicker = new picker.DocumentViewPicker(AppContext.getContext());
      const uris = await docPicker.save(options);
      if (uris === undefined || uris === null || uris.length < names.length) {
        throw new Error('save cancelled');
      }
      for (let i = 0; i < ordered.length; i++) {
        // Picker results are document URIs, not paths: copy through an fd.
        const target = fs.openSync(uris[i], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try {
          fs.copyFileSync(ordered[i].tempPath, target.fd);
        } finally {
          fs.closeSync(target);
        }
        ReceiveController.deleteQuietly(ordered[i].tempPath);
      }
      this.logger.info(`saved ${ordered.length} file(s)`);
      this.publish(ReceivePhases.SAVED, this.snapshot.senderAlias, this.snapshot.senderModel,
        this.snapshot.senderIp, session.sessionId, this.snapshotFiles(), '');
      this.session = null;
      this.resetAfter(10000);
    } catch (e) {
      const err = e as BusinessError;
      this.logger.error(`save failed: ${err.message ?? 'unknown'}`);
      // Stay ready so the user can retry from the Receive tab.
      this.publish(ReceivePhases.READY_TO_SAVE, this.snapshot.senderAlias,
        this.snapshot.senderModel, this.snapshot.senderIp, session.sessionId,
        this.snapshotFiles(), err.message ?? 'save failed');
    }
  }

  private waitForDecision(): Promise<boolean> {
    return new Promise<boolean>((resolve: (accepted: boolean) => void) => {
      this.pendingResolve = resolve;
      this.promptTimer = setTimeout(() => {
        this.logger.info('decision timeout, declining');
        this.declineFromUi();
      }, ProtocolConstants.RECEIVE_DECISION_TIMEOUT_MS);
    });
  }

  private abort(reason: string): void {
    const session = this.session;
    clearTimeout(this.staleTimer);
    if (session !== null) {
      session.files.forEach((f: IncomingFile) => {
        if (!f.done) {
          ReceiveController.deleteQuietly(f.tempPath);
        }
      });
      this.logger.info(`session ${session.sessionId} aborted: ${reason}`);
    }
    this.session = null;
    if (this.snapshot.phase === ReceivePhases.PROMPTING) {
      this.publish(ReceivePhases.IDLE, '', '', '', '', [], '');
      this.declineFromUi();
    } else {
      this.publish(ReceivePhases.FAILED, this.snapshot.senderAlias, this.snapshot.senderModel,
        this.snapshot.senderIp, '', this.snapshotFiles(), reason);
      this.resetAfter(10000);
    }
  }

  private snapshotFiles(): IncomingFile[] {
    const session = this.session;
    if (session === null) {
      return [];
    }
    return Array.from(session.files.values());
  }

  private publish(phase: string, alias: string, model: string, ip: string, sessionId: string,
    files: IncomingFile[], error: string, message: string = '', copied: boolean = false): void {
    this.snapshot = new ReceiveSnapshot(phase, alias, model, ip, sessionId, files, error, message, copied);
    AppStorage.setOrCreate(AppStorageKeys.RECEIVE_STATE, this.snapshot);
  }

  private resetAfter(ms: number): void {
    setTimeout(() => {
      if (this.session === null && this.pendingResolve === null
        && this.snapshot.phase !== ReceivePhases.PROMPTING
        && this.snapshot.phase !== ReceivePhases.MESSAGE) {
        this.publish(ReceivePhases.IDLE, '', '', '', '', [], '');
      }
    }, ms);
  }

  private static sanitize(name: string): string {
    return name.replace(/\//g, '_').replace(/\\/g, '_');
  }

  private static deleteQuietly(path: string): void {
    try {
      fs.unlinkSync(path);
    } catch (e) {
      // best effort
    }
  }
}
