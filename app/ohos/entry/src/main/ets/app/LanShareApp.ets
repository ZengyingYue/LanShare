import { common } from '@kit.AbilityKit';
import { Settings } from '../common/Settings';
import { AppContext } from '../common/AppContext';
import { AppStorageKeys, ProtocolConstants } from '../common/Constants';
import { DeviceStore } from '../common/DeviceStore';
import { Logger } from '../common/Logger';
import { MulticastProvider } from '../protocol/MulticastProvider';
import { FallbackProber } from '../protocol/FallbackProber';
import { LocalSendClient } from '../client/LocalSendClient';
import { HttpServer } from '../server/HttpServer';
import { LanShareServer } from '../server/LanShareServer';
import { ReceiveSnapshot } from '../receive/ReceiveModels';
import { Device } from '../protocol/Dto';

/**
 * Composition root: loads settings, publishes initial UI state, starts the
 * HTTP server and multicast discovery, and wires announce handling.
 *
 * Everything degrades independently: if the TCP port is taken the app still
 * sends; if multicast is blocked by the network the fallback prober (and
 * the Refresh button) still finds peers.
 */
export class LanShareApp {
  private static instance: LanShareApp | null = null;

  private readonly logger: Logger = new Logger('App');
  private readonly client: LocalSendClient = new LocalSendClient();
  private server: HttpServer | null = null;
  private multicast: MulticastProvider | null = null;
  private bootstrapped: boolean = false;
  private probing: boolean = false;

  static getInstance(): LanShareApp {
    if (LanShareApp.instance === null) {
      LanShareApp.instance = new LanShareApp();
    }
    return LanShareApp.instance;
  }

  /** Called once from EntryAbility.onCreate; safe to fire and forget. */
  static async bootstrap(context: common.UIAbilityContext): Promise<void> {
    const settings = await Settings.load(context);
    AppContext.init(context, settings);

    // Initial UI state so the page can render before the network is up.
    AppStorage.setOrCreate(AppStorageKeys.DEVICES, new Array<Device>());
    AppStorage.setOrCreate(AppStorageKeys.RECEIVE_STATE, ReceiveSnapshot.idle());
    AppStorage.setOrCreate(AppStorageKeys.SERVER_PORT, 0);
    AppStorage.setOrCreate(AppStorageKeys.FINGERPRINT, settings.fingerprint);
    AppStorage.setOrCreate(AppStorageKeys.PROTOCOL, 'http');
    AppStorage.setOrCreate(AppStorageKeys.ALIAS, settings.alias);

    LanShareApp.getInstance().start();
  }

  private async start(): Promise<void> {
    if (this.bootstrapped) {
      return;
    }
    this.bootstrapped = true;
    const settings = AppContext.getSettings();
    const identity = AppContext.getIdentity();

    // 1. HTTP server (receiving + discovery responses).
    const server = new HttpServer(new LanShareServer().handler);
    try {
      await server.start(settings.port);
      this.server = server;
      AppStorage.setOrCreate(AppStorageKeys.SERVER_PORT, settings.port);
    } catch (e) {
      this.logger.error(`HTTP server failed to start on port ${settings.port} — receiving disabled`);
    }

    // 2. Multicast discovery.
    const multicast = new MulticastProvider((device: Device, announceRequested: boolean) => {
      this.onAnnounce(device, announceRequested);
    }, ProtocolConstants.MULTICAST_GROUP, settings.port);
    try {
      await multicast.start();
      this.multicast = multicast;
      await multicast.announceBurst(identity);
    } catch (e) {
      this.logger.warn('multicast unavailable, relying on HTTP fallback discovery');
    }

    // 3. Background fallback sweep so the list is not empty on hard networks.
    this.refresh();
  }

  private onAnnounce(device: Device, announceRequested: boolean): void {
    DeviceStore.getInstance().upsert(device);
    if (announceRequested) {
      const identity = AppContext.getIdentity();
      this.client.register(device, identity).then((fresh: Device | null) => {
        if (fresh !== null) {
          DeviceStore.getInstance().upsert(fresh);
        }
      });
    }
  }

  /** Refresh button: re-announce and sweep the subnet over HTTP. */
  async refresh(): Promise<void> {
    const identity = AppContext.getIdentity();
    if (this.multicast !== null && this.multicast.isRunning()) {
      this.multicast.announceBurst(identity);
    }
    if (this.probing) {
      return;
    }
    this.probing = true;
    try {
      await FallbackProber.probeSubnets(this.client, identity, (device: Device) => {
        DeviceStore.getInstance().upsert(device);
      });
    } finally {
      this.probing = false;
    }
  }
}
