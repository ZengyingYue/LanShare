/** Lifecycle phases of an incoming transfer, as shown in the Receive tab. */
export class ReceivePhases {
  static readonly IDLE: string = 'idle';
  static readonly PROMPTING: string = 'prompting';
  static readonly DECLINED: string = 'declined';
  static readonly WAITING: string = 'waiting';
  static readonly RECEIVING: string = 'receiving';
  static readonly READY_TO_SAVE: string = 'readyToSave';
  static readonly SAVING: string = 'saving';
  static readonly SAVED: string = 'saved';
  static readonly FAILED: string = 'failed';
}

/** One file of an incoming session. */
export class IncomingFile {
  readonly id: string;
  readonly fileName: string;
  readonly size: number;
  readonly fileType: string;
  token: string;
  bytesReceived: number = 0;
  done: boolean = false;
  /** Not accepted because it exceeds the in-memory size cap of this build. */
  skipped: boolean = false;
  tempPath: string = '';

  constructor(id: string, fileName: string, size: number, fileType: string, token: string) {
    this.id = id;
    this.fileName = fileName;
    this.size = size;
    this.fileType = fileType;
    this.token = token;
  }
}

/** Immutable snapshot published to the UI through AppStorage. */
export class ReceiveSnapshot {
  readonly phase: string;
  readonly senderAlias: string;
  readonly senderModel: string;
  readonly senderIp: string;
  readonly sessionId: string;
  readonly files: IncomingFile[];
  readonly error: string;

  constructor(phase: string, senderAlias: string, senderModel: string, senderIp: string,
    sessionId: string, files: IncomingFile[], error: string) {
    this.phase = phase;
    this.senderAlias = senderAlias;
    this.senderModel = senderModel;
    this.senderIp = senderIp;
    this.sessionId = sessionId;
    this.files = files;
    this.error = error;
  }

  static idle(): ReceiveSnapshot {
    return new ReceiveSnapshot(ReceivePhases.IDLE, '', '', '', '', [], '');
  }
}
