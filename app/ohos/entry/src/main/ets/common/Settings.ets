import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { ProtocolConstants } from './Constants';
import { Logger } from './Logger';

/**
 * Persisted app settings backed by @ohos.data.preferences.
 *
 * The fingerprint is a random UUID in M1 (plain-HTTP identity, used for
 * self-discovery filtering and peer deduplication). In M2, when TLS lands,
 * it becomes the SHA-256 of the device's self-signed certificate, exactly
 * like the official clients.
 */
export class Settings {
  private static readonly STORE_NAME = 'lanshare_settings';
  private static readonly KEY_ALIAS = 'alias';
  private static readonly KEY_PORT = 'port';
  private static readonly KEY_PIN = 'pin';
  private static readonly KEY_FINGERPRINT = 'fingerprint';

  private static readonly logger: Logger = new Logger('Settings');

  private store: preferences.Preferences | null = null;

  alias: string;
  port: number;
  pin: string;
  fingerprint: string;

  private constructor(alias: string, port: number, pin: string, fingerprint: string) {
    this.alias = alias;
    this.port = port;
    this.pin = pin;
    this.fingerprint = fingerprint;
  }

  static async load(context: common.UIAbilityContext): Promise<Settings> {
    const store = await preferences.getPreferences(context, Settings.STORE_NAME);

    let alias = store.getSync(Settings.KEY_ALIAS, '') as string;
    if (typeof alias !== 'string' || alias.length === 0) {
      alias = Settings.defaultAlias();
      await store.put(Settings.KEY_ALIAS, alias);
    }

    const port = store.getSync(Settings.KEY_PORT, ProtocolConstants.DEFAULT_PORT) as number;

    const pin = store.getSync(Settings.KEY_PIN, '') as string;

    let fingerprint = store.getSync(Settings.KEY_FINGERPRINT, '') as string;
    if (typeof fingerprint !== 'string' || fingerprint.length === 0) {
      fingerprint = util.generateRandomUUID(false);
      await store.put(Settings.KEY_FINGERPRINT, fingerprint);
    }

    await store.flush();
    const settings = new Settings(alias, port, pin, fingerprint);
    settings.store = store;
    Settings.logger.info(`loaded: alias=${alias} port=${port} fingerprint=${fingerprint}`);
    return settings;
  }

  private static defaultAlias(): string {
    const brand = deviceInfo.brand;
    const model = deviceInfo.productModel;
    let name = '';
    if (typeof brand === 'string' && brand.length > 0) {
      name = brand;
    }
    if (typeof model === 'string' && model.length > 0) {
      name = name.length > 0 ? `${name} ${model}` : model;
    }
    if (name.length === 0) {
      name = 'HarmonyOS';
    }
    const suffix = Math.floor(Math.random() * 900 + 100);
    return `${name}-${suffix}`;
  }

  async save(): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.put(Settings.KEY_ALIAS, this.alias);
    await this.store.put(Settings.KEY_PORT, this.port);
    await this.store.put(Settings.KEY_PIN, this.pin);
    await this.store.flush();
    Settings.logger.info('settings saved');
  }
}
