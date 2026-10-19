import { DeviceTypes, ProtocolConstants } from '../common/Constants';

/**
 * Wire-format types and domain objects for the LocalSend v2 protocol.
 *
 * JSON interfaces describe the exact wire shape (camelCase). Domain classes
 * add the compatibility quirks documented in the protocol:
 *  - the checksum may arrive as `sha256` or legacy `hash`
 *  - an announcement may use `announce` (v2) or `announcement` (v1)
 *  - v1 peers may omit `version`/`port`/`protocol`
 *  - fingerprints are compared case-insensitively
 */

export interface IdentityJson {
  alias: string;
  version?: string;
  deviceModel?: string;
  deviceType?: string;
  fingerprint: string;
  port?: number;
  protocol?: string;
  download?: boolean;
  announce?: boolean;
  announcement?: boolean;
}

export interface FileMetadataJson {
  modified?: string;
  accessed?: string;
}

export interface FileDtoJson {
  id: string;
  fileName: string;
  size: number;
  fileType?: string;
  sha256?: string;
  hash?: string;
  preview?: string;
  metadata?: FileMetadataJson;
}

export interface PrepareUploadRequestJson {
  info: IdentityJson;
  files: Record<string, FileDtoJson>;
}

export interface PrepareUploadResponseJson {
  sessionId: string;
  files: Record<string, string>;
}

/** A file offered by a sender (outgoing) or accepted by us (incoming). */
export class FileDto {
  id: string;
  fileName: string;
  size: number;
  fileType: string;
  sha256: string | null;
  preview: string | null;

  constructor(id: string, fileName: string, size: number, fileType: string,
    sha256: string | null, preview: string | null) {
    this.id = id;
    this.fileName = fileName;
    this.size = size;
    this.fileType = fileType;
    this.sha256 = sha256;
    this.preview = preview;
  }

  static fromJson(json: FileDtoJson): FileDto {
    // Official Dart clients (<=1.15.x) serialized the checksum as "hash".
    let checksum: string | null = null;
    if (typeof json.sha256 === 'string' && json.sha256.length > 0) {
      checksum = json.sha256;
    } else if (typeof json.hash === 'string' && json.hash.length > 0) {
      checksum = json.hash;
    }
    let fileType = 'application/octet-stream';
    if (typeof json.fileType === 'string' && json.fileType.length > 0) {
      fileType = json.fileType;
    }
    let preview: string | null = null;
    if (typeof json.preview === 'string' && json.preview.length > 0) {
      preview = json.preview;
    }
    return new FileDto(json.id, json.fileName, json.size, fileType, checksum, preview);
  }

  toJson(): FileDtoJson {
    const json: FileDtoJson = {
      id: this.id,
      fileName: this.fileName,
      size: this.size,
      fileType: this.fileType
    };
    if (this.sha256 !== null) {
      json.sha256 = this.sha256;
    }
    if (this.preview !== null) {
      json.preview = this.preview;
    }
    return json;
  }
}

/** This device's identity, announced to and exchanged with peers. */
export class Identity {
  alias: string;
  version: string;
  deviceModel: string;
  deviceType: string;
  fingerprint: string;
  port: number;
  protocol: string;
  download: boolean;

  constructor(alias: string, version: string, deviceModel: string, deviceType: string,
    fingerprint: string, port: number, protocol: string, download: boolean) {
    this.alias = alias;
    this.version = version;
    this.deviceModel = deviceModel;
    this.deviceType = deviceType;
    this.fingerprint = fingerprint;
    this.port = port;
    this.protocol = protocol;
    this.download = download;
  }

  /** Full form used in the multicast announcement and /register requests. */
  toAnnounceJson(): Record<string, Object> {
    const json: Record<string, Object> = {
      'alias': this.alias,
      'version': this.version,
      'deviceModel': this.deviceModel,
      'deviceType': this.deviceType,
      'fingerprint': this.fingerprint,
      'port': this.port,
      'protocol': this.protocol,
      'download': this.download,
      'announce': true,
      'announcement': true
    };
    return json;
  }

  /** Body sent to peers via POST /register. */
  toRegisterRequestJson(): Record<string, Object> {
    const json: Record<string, Object> = {
      'alias': this.alias,
      'version': this.version,
      'deviceModel': this.deviceModel,
      'deviceType': this.deviceType,
      'fingerprint': this.fingerprint,
      'port': this.port,
      'protocol': this.protocol,
      'download': this.download
    };
    return json;
  }

  /** Response of /register and /info. The spec omits port/protocol here. */
  toRegisterResponseJson(): Record<string, Object> {
    const json: Record<string, Object> = {
      'alias': this.alias,
      'version': this.version,
      'deviceModel': this.deviceModel,
      'deviceType': this.deviceType,
      'fingerprint': this.fingerprint,
      'download': this.download
    };
    return json;
  }
}

/** A remote device discovered on the LAN. */
export class Device {
  alias: string;
  deviceModel: string;
  deviceType: string;
  fingerprint: string;
  ip: string;
  port: number;
  protocol: string;
  download: boolean;
  lastSeen: number;

  constructor(alias: string, deviceModel: string, deviceType: string, fingerprint: string,
    ip: string, port: number, protocol: string, download: boolean, lastSeen: number) {
    this.alias = alias;
    this.deviceModel = deviceModel;
    this.deviceType = deviceType;
    this.fingerprint = fingerprint;
    this.ip = ip;
    this.port = port;
    this.protocol = protocol;
    this.download = download;
    this.lastSeen = lastSeen;
  }

  /**
   * Build from an announcement datagram or /register payload. Tolerates v1
   * peers that omit port/protocol and devices with unknown types.
   */
  static fromIdentityJson(json: IdentityJson, ip: string): Device {
    let port = ProtocolConstants.DEFAULT_PORT;
    if (typeof json.port === 'number' && json.port > 0 && json.port < 65536) {
      port = json.port;
    }
    let protocol = 'http';
    if (json.protocol === 'https') {
      protocol = 'https';
    }
    let deviceModel = '';
    if (typeof json.deviceModel === 'string') {
      deviceModel = json.deviceModel;
    }
    let deviceType = DeviceTypes.DESKTOP;
    if (typeof json.deviceType === 'string' && json.deviceType.length > 0) {
      deviceType = json.deviceType;
    }
    let alias = json.fingerprint;
    if (typeof json.alias === 'string' && json.alias.length > 0) {
      alias = json.alias;
    }
    let download = false;
    if (json.download === true) {
      download = true;
    }
    return new Device(alias, deviceModel, deviceType, json.fingerprint, ip, port, protocol,
      download, Date.now());
  }

  baseUrl(): string {
    return `${this.protocol}://${this.ip}:${this.port}`;
  }
}
