/**
 * Constants of the LocalSend v2 wire protocol as implemented by LanShare.
 * Reference: https://github.com/localsend/protocol (v2.2)
 */
export class ProtocolConstants {
  /** Default UDP multicast + HTTP(S) server port. Configurable in settings. */
  static readonly DEFAULT_PORT: number = 53317;

  /**
   * Multicast group. The spec restricts the group to 224.0.0.0/24 because
   * some Android devices only accept that range.
   */
  static readonly MULTICAST_GROUP: string = '224.0.0.167';

  /** Protocol version announced by this app. */
  static readonly PROTOCOL_VERSION: string = '2.2';

  /** Announcement burst delays, matching the official clients. */
  static readonly ANNOUNCE_DELAYS_MS: number[] = [100, 500, 2000];

  static readonly API_V2_BASE: string = '/api/localsend/v2';
  static readonly API_V1_BASE: string = '/api/localsend/v1';

  /** Seconds to wait for the user to accept/decline an incoming request. */
  static readonly RECEIVE_DECISION_TIMEOUT_MS: number = 60000;

  /** Failed PIN attempts allowed per sender IP before 429. */
  static readonly MAX_PIN_ATTEMPTS: number = 3;

  /** Preview-build cap for a single uploaded file (whole-body buffering). */
  static readonly MAX_FILE_SIZE_BYTES: number = 64 * 1024 * 1024;
}

export class DeviceTypes {
  static readonly MOBILE: string = 'mobile';
  static readonly DESKTOP: string = 'desktop';
  static readonly WEB: string = 'web';
  static readonly HEADLESS: string = 'headless';
  static readonly SERVER: string = 'server';
}

export class AppStorageKeys {
  static readonly DEVICES: string = 'lanshare_devices';
  static readonly RECEIVE_STATE: string = 'lanshare_receive_state';
  static readonly SERVER_PORT: string = 'lanshare_server_port';
  static readonly FINGERPRINT: string = 'lanshare_fingerprint';
  static readonly PROTOCOL: string = 'lanshare_protocol';
  static readonly ALIAS: string = 'lanshare_alias';
}
