/**
 * Minimal leveled logger. All modules log under a single [LanShare] prefix
 * so `hdc shell hilog | grep LanShare` shows the full picture on device.
 */
export class Logger {
  private tag: string;

  constructor(tag: string) {
    this.tag = tag;
  }

  info(message: string): void {
    console.info(`[LanShare][${this.tag}] ${message}`);
  }

  warn(message: string): void {
    console.warn(`[LanShare][${this.tag}] ${message}`);
  }

  error(message: string): void {
    console.error(`[LanShare][${this.tag}] ${message}`);
  }
}
