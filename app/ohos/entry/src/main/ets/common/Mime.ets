/**
 * Extension -> MIME type mapping used when describing outgoing files.
 * Anything unknown is sent as application/octet-stream, which is what the
 * protocol expects for opaque files.
 */
export class Mime {
  private static readonly MAP: Record<string, string> = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
    'bmp': 'image/bmp',
    'heic': 'image/heic',
    'svg': 'image/svg+xml',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'mkv': 'video/x-matroska',
    'avi': 'video/x-msvideo',
    'webm': 'video/webm',
    '3gp': 'video/3gpp',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'flac': 'audio/flac',
    'wav': 'audio/wav',
    'ogg': 'audio/ogg',
    'txt': 'text/plain',
    'md': 'text/markdown',
    'csv': 'text/csv',
    'html': 'text/html',
    'htm': 'text/html',
    'xml': 'application/xml',
    'json': 'application/json',
    'pdf': 'application/pdf',
    'zip': 'application/zip',
    'rar': 'application/vnd.rar',
    '7z': 'application/x-7z-compressed',
    'tar': 'application/x-tar',
    'gz': 'application/gzip',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'apk': 'application/vnd.android.package-archive',
    'hap': 'application/octet-stream'
  };

  static forFileName(fileName: string): string {
    const idx = fileName.lastIndexOf('.');
    if (idx < 0 || idx === fileName.length - 1) {
      return 'application/octet-stream';
    }
    const ext = fileName.substring(idx + 1).toLowerCase();
    const mime = Mime.MAP[ext];
    if (typeof mime === 'string' && mime.length > 0) {
      return mime;
    }
    return 'application/octet-stream';
  }
}
