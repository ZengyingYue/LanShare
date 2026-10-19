import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Device, Identity } from './Dto';
import { LocalSendClient } from '../client/LocalSendClient';
import { Logger } from '../common/Logger';

/**
 * Fallback discovery when multicast does not work on a network: enumerate
 * the /24 of every local interface and POST /register to each candidate.
 *
 * This mirrors the protocol's HTTP discovery mode; LocalSend devices
 * answer /register with their identity, non-LocalSend hosts time out.
 */
export class FallbackProber {
  private static readonly logger: Logger = new Logger('Prober');
  private static readonly CONCURRENCY: number = 50;
  private static readonly TIMEOUT_MS: number = 400;

  /**
   * Probe the whole /24 of each local IPv4 address.
   * Returns the number of devices found.
   */
  static async probeSubnets(client: LocalSendClient, identity: Identity,
    onDevice: (device: Device) => void): Promise<number> {
    let found = 0;
    const candidates = await FallbackProber.collectCandidates();
    if (candidates.length === 0) {
      FallbackProber.logger.warn('no local IPv4 addresses found');
      return 0;
    }
    FallbackProber.logger.info(`probing ${candidates.length} addresses`);
    for (let i = 0; i < candidates.length; i += FallbackProber.CONCURRENCY) {
      const batch = candidates.slice(i, i + FallbackProber.CONCURRENCY);
      const results = await Promise.all(batch.map((ip: string) => {
        return client.registerTo(ip, identity.port, identity, FallbackProber.TIMEOUT_MS);
      }));
      for (let j = 0; j < results.length; j++) {
        const device = results[j];
        if (device !== null) {
          found++;
          onDevice(device);
        }
      }
    }
    FallbackProber.logger.info(`probe finished, ${found} device(s)`);
    return found;
  }

  private static async collectCandidates(): Promise<string[]> {
    const candidates: string[] = [];
    try {
      const net = await connection.getDefaultNet();
      if (net === null || net === undefined) {
        return candidates;
      }
      const props = await connection.getConnectionProperties(net);
      if (props.linkAddrs === undefined || props.linkAddrs === null) {
        return candidates;
      }
      const ownIps: string[] = [];
      for (const linkAddr of props.linkAddrs) {
        const addr = linkAddr.address.address;
        if (typeof addr !== 'string' || addr.indexOf('.') < 0) {
          continue; // IPv6 or missing
        }
        ownIps.push(addr);
        const parts = addr.split('.');
        if (parts.length !== 4) {
          continue;
        }
        const prefix = `${parts[0]}.${parts[1]}.${parts[2]}`;
        for (let host = 1; host <= 254; host++) {
          candidates.push(`${prefix}.${host}`);
        }
      }
      // Never probe ourselves (same IP as an interface).
      return candidates.filter((ip: string) => ownIps.indexOf(ip) < 0);
    } catch (e) {
      const err = e as BusinessError;
      FallbackProber.logger.error(`getConnectionProperties failed: ${err.message ?? 'unknown'}`);
      return candidates;
    }
  }
}
