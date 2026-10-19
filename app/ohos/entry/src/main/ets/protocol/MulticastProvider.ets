import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Device, Identity, IdentityJson } from './Dto';
import { ProtocolConstants } from '../common/Constants';
import { AppContext } from '../common/AppContext';
import { Logger } from '../common/Logger';

/** Called for every valid announcement datagram from another device. */
export type AnnounceHandler = (device: Device, announceRequested: boolean) => void;

/**
 * Primary device discovery of the LocalSend protocol: join the UDP
 * multicast group and exchange identity announcements.
 *
 * The announcement burst timing (100/500/2000 ms) mirrors the official
 * clients so peers running them register us the same way.
 */
export class MulticastProvider {
  private static readonly CRLF: Uint8Array = new Uint8Array([13, 10]);

  private readonly logger: Logger = new Logger('Multicast');
  private readonly handler: AnnounceHandler;
  private readonly group: string;
  private readonly port: number;
  private readonly decoder: util.TextDecoder = new util.TextDecoder('utf-8');
  private readonly encoder: util.TextEncoder = new util.TextEncoder();

  private udp: socket.MulticastSocket | null = null;
  private running: boolean = false;

  constructor(handler: AnnounceHandler, group: string, port: number) {
    this.handler = handler;
    this.group = group;
    this.port = port;
  }

  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    const udp = socket.constructMulticastSocketInstance();
    udp.on('message', (info: socket.SocketMessageInfo) => {
      this.onMessage(info);
    });
    udp.on('error', (error: BusinessError) => {
      this.logger.error(`socket error ${error.code}: ${error.message}`);
    });
    await udp.bind({ address: '0.0.0.0', port: this.port } as socket.NetAddress);
    try {
      // We also filter by fingerprint; disabling loopback cuts the noise.
      await udp.setLoopbackMode(false);
    } catch (e) {
      this.logger.warn('setLoopbackMode not supported, continuing');
    }
    await udp.addMembership({ address: this.group, port: this.port } as socket.NetAddress);
    this.udp = udp;
    this.running = true;
    this.logger.info(`joined ${this.group}:${this.port}`);
  }

  async stop(): Promise<void> {
    if (!this.running || this.udp === null) {
      return;
    }
    this.running = false;
    try {
      this.udp.off('message');
      await this.udp.dropMembership({ address: this.group, port: this.port } as socket.NetAddress);
      await this.udp.close();
    } catch (e) {
      this.logger.warn('error during stop, ignoring');
    }
    this.udp = null;
  }

  isRunning(): boolean {
    return this.running;
  }

  /** Send the three-announcement burst (100/500/2000 ms delays). */
  async announceBurst(identity: Identity): Promise<void> {
    for (let i = 0; i < ProtocolConstants.ANNOUNCE_DELAYS_MS.length; i++) {
      await this.sleep(ProtocolConstants.ANNOUNCE_DELAYS_MS[i]);
      if (!this.running) {
        return;
      }
      try {
        await this.announceOnce(identity);
      } catch (e) {
        this.logger.warn(`announcement ${i} failed`);
      }
    }
  }

  private async announceOnce(identity: Identity): Promise<void> {
    if (this.udp === null) {
      throw new Error('not started');
    }
    const payload = JSON.stringify(identity.toAnnounceJson());
    const bytes = this.encoder.encodeInto(payload);
    await this.udp.send({
      data: bytes.buffer,
      address: { address: this.group, port: this.port } as socket.NetAddress
    } as socket.UDPSendOptions);
  }

  private onMessage(info: socket.SocketMessageInfo): void {
    try {
      const text = this.decoder.decodeToString(new Uint8Array(info.message));
      const json = JSON.parse(text) as IdentityJson;
      if (typeof json.fingerprint !== 'string' || json.fingerprint.length === 0) {
        return;
      }
      if (AppContext.isFingerprintSelf(json.fingerprint)) {
        return;
      }
      const device = Device.fromIdentityJson(json, info.remoteInfo.address);
      // v1 peers say "announcement", v2 peers say "announce".
      const announceRequested = json.announce === true || json.announcement === true;
      this.handler(device, announceRequested);
    } catch (e) {
      this.logger.warn('dropping malformed datagram');
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }
}
