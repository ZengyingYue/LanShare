import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Settings } from './Settings';
import { Identity } from '../protocol/Dto';
import { DeviceTypes, ProtocolConstants } from './Constants';

/**
 * Process-wide app state assembled during ability startup.
 * Everything here is initialized in EntryAbility.onCreate before the UI
 * or the network stack touches it.
 */
export class AppContext {
  private static abilityContext: common.UIAbilityContext | null = null;
  private static appSettings: Settings | null = null;
  private static appIdentity: Identity | null = null;

  static init(context: common.UIAbilityContext, settings: Settings): void {
    AppContext.abilityContext = context;
    AppContext.appSettings = settings;
    AppContext.appIdentity = AppContext.buildIdentity(settings);
  }

  static getContext(): common.UIAbilityContext {
    if (AppContext.abilityContext === null) {
      throw new Error('AppContext not initialized');
    }
    return AppContext.abilityContext;
  }

  static getSettings(): Settings {
    if (AppContext.appSettings === null) {
      throw new Error('AppContext not initialized');
    }
    return AppContext.appSettings;
  }

  static getIdentity(): Identity {
    if (AppContext.appIdentity === null) {
      throw new Error('AppContext not initialized');
    }
    return AppContext.appIdentity;
  }

  /** Rebuild the announced identity after settings changed. */
  static refreshIdentity(): void {
    const next = AppContext.buildIdentity(AppContext.getSettings());
    // The server keeps listening on the old port until the app restarts.
    next.port = AppContext.getIdentity().port;
    AppContext.appIdentity = next;
  }

  static isFingerprintSelf(fingerprint: string): boolean {
    const own = AppContext.getIdentity().fingerprint;
    return own.toUpperCase() === fingerprint.toUpperCase();
  }

  static deviceModel(): string {
    let name = '';
    if (typeof deviceInfo.brand === 'string') {
      name = deviceInfo.brand;
    }
    if (typeof deviceInfo.productModel === 'string' && deviceInfo.productModel.length > 0) {
      name = name.length > 0 ? `${name} ${deviceInfo.productModel}` : deviceInfo.productModel;
    }
    return name.length > 0 ? name : 'HarmonyOS';
  }

  static deviceType(): string {
    // deviceInfo.deviceType: phone | tablet | 2in1 | ...
    if (deviceInfo.deviceType === 'phone' || deviceInfo.deviceType === 'tablet') {
      return DeviceTypes.MOBILE;
    }
    return DeviceTypes.DESKTOP;
  }

  private static buildIdentity(settings: Settings): Identity {
    return new Identity(
      settings.alias,
      ProtocolConstants.PROTOCOL_VERSION,
      AppContext.deviceModel(),
      AppContext.deviceType(),
      settings.fingerprint,
      settings.port,
      'http',
      false
    );
  }
}
