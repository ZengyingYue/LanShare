import { Device } from '../protocol/Dto';
import { AppContext } from './AppContext';
import { AppStorageKeys } from './Constants';
import { Logger } from './Logger';

/**
 * Registry of devices seen on the LAN, keyed by (case-insensitive)
 * fingerprint. Publishes a fresh array to AppStorage on every change so
 * the Nearby tab re-renders.
 */
export class DeviceStore {
  private static instance: DeviceStore | null = null;

  private devices: Map<string, Device> = new Map();
  private logger: Logger = new Logger('DeviceStore');

  static getInstance(): DeviceStore {
    if (DeviceStore.instance === null) {
      DeviceStore.instance = new DeviceStore();
    }
    return DeviceStore.instance;
  }

  upsert(device: Device): void {
    if (AppContext.isFingerprintSelf(device.fingerprint)) {
      return;
    }
    this.devices.set(device.fingerprint.toUpperCase(), device);
    this.logger.info(`upsert ${device.alias} (${device.ip}:${device.port})`);
    this.publish();
  }

  remove(fingerprint: string): void {
    this.devices.delete(fingerprint.toUpperCase());
    this.publish();
  }

  clear(): void {
    this.devices.clear();
    this.publish();
  }

  getAll(): Device[] {
    const list: Device[] = [];
    this.devices.forEach((device: Device) => {
      list.push(device);
    });
    list.sort((a: Device, b: Device) => b.lastSeen - a.lastSeen);
    return list;
  }

  private publish(): void {
    AppStorage.setOrCreate(AppStorageKeys.DEVICES, this.getAll());
  }
}
