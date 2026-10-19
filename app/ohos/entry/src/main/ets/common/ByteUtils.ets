import { util } from '@kit.ArkTS';

/**
 * Byte-level helpers for hand-rolled HTTP parsing over raw sockets.
 */
export class ByteUtils {
  private static readonly DECODER: util.TextDecoder = new util.TextDecoder('utf-8');
  private static readonly ENCODER: util.TextEncoder = new util.TextEncoder();

  static utf8Decode(bytes: Uint8Array): string {
    return ByteUtils.DECODER.decodeToString(bytes);
  }

  static utf8Encode(text: string): Uint8Array {
    return ByteUtils.ENCODER.encodeInto(text);
  }

  static toUint8Array(buffer: ArrayBuffer): Uint8Array {
    return new Uint8Array(buffer);
  }

  /** Concatenate chunks into a single ArrayBuffer of exactly totalLength bytes. */
  static concat(chunks: Array<ArrayBuffer>): ArrayBuffer {
    let total = 0;
    for (let i = 0; i < chunks.length; i++) {
      total += chunks[i].byteLength;
    }
    const out = new Uint8Array(total);
    let offset = 0;
    for (let i = 0; i < chunks.length; i++) {
      out.set(new Uint8Array(chunks[i]), offset);
      offset += chunks[i].byteLength;
    }
    return out.buffer;
  }

  /**
   * Find the first occurrence of needle in haystack at or after `from`.
   * Returns -1 when not found. Needles used here are short ("\r\n", "\r\n\r\n").
   */
  static indexOf(haystack: Uint8Array, needle: Uint8Array, from: number): number {
    if (needle.length === 0 || haystack.length < needle.length) {
      return -1;
    }
    const lastStart = haystack.length - needle.length;
    for (let i = Math.max(0, from); i <= lastStart; i++) {
      let matched = true;
      for (let j = 0; j < needle.length; j++) {
        if (haystack[i + j] !== needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return i;
      }
    }
    return -1;
  }

  /** Parse an unsigned decimal integer from ASCII bytes, or -1 on failure. */
  static parseAsciiInt(bytes: Uint8Array): number {
    let value = 0;
    if (bytes.length === 0) {
      return -1;
    }
    for (let i = 0; i < bytes.length; i++) {
      const c = bytes[i];
      if (c < 48 || c > 57) {
        return -1;
      }
      value = value * 10 + (c - 48);
    }
    return value;
  }
}
