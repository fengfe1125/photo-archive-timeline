import { extname } from 'node:path';
import type { MediaType } from './types.js';

interface MediaDescription {
  mediaType: MediaType;
  mimeType: string;
}

const MEDIA_BY_EXTENSION: Record<string, MediaDescription> = {
  '.jpg': { mediaType: 'photo', mimeType: 'image/jpeg' },
  '.jpeg': { mediaType: 'photo', mimeType: 'image/jpeg' },
  '.png': { mediaType: 'photo', mimeType: 'image/png' },
  '.heic': { mediaType: 'photo', mimeType: 'image/heic' },
  '.heif': { mediaType: 'photo', mimeType: 'image/heif' },
  '.tif': { mediaType: 'photo', mimeType: 'image/tiff' },
  '.tiff': { mediaType: 'photo', mimeType: 'image/tiff' },
  '.dng': { mediaType: 'photo', mimeType: 'image/x-adobe-dng' },
  '.nef': { mediaType: 'photo', mimeType: 'image/x-nikon-nef' },
  '.cr2': { mediaType: 'photo', mimeType: 'image/x-canon-cr2' },
  '.cr3': { mediaType: 'photo', mimeType: 'image/x-canon-cr3' },
  '.arw': { mediaType: 'photo', mimeType: 'image/x-sony-arw' },
  '.raf': { mediaType: 'photo', mimeType: 'image/x-fuji-raf' },
  '.orf': { mediaType: 'photo', mimeType: 'image/x-olympus-orf' },
  '.rw2': { mediaType: 'photo', mimeType: 'image/x-panasonic-rw2' },
  '.raw': { mediaType: 'photo', mimeType: 'image/x-raw' },
  '.webp': { mediaType: 'photo', mimeType: 'image/webp' },
  '.avif': { mediaType: 'photo', mimeType: 'image/avif' },
  '.mov': { mediaType: 'video', mimeType: 'video/quicktime' },
  '.mp4': { mediaType: 'video', mimeType: 'video/mp4' },
  '.m4v': { mediaType: 'video', mimeType: 'video/x-m4v' },
  '.avi': { mediaType: 'video', mimeType: 'video/x-msvideo' },
  '.mkv': { mediaType: 'video', mimeType: 'video/x-matroska' },
  '.mts': { mediaType: 'video', mimeType: 'video/mp2t' },
  '.m2ts': { mediaType: 'video', mimeType: 'video/mp2t' },
  '.3gp': { mediaType: 'video', mimeType: 'video/3gpp' },
  '.webm': { mediaType: 'video', mimeType: 'video/webm' }
};

export function identifyMediaFile(filePath: string): MediaDescription | null {
  return MEDIA_BY_EXTENSION[extname(filePath).toLowerCase()] ?? null;
}

export function supportedExtensions(): string[] {
  return Object.keys(MEDIA_BY_EXTENSION).sort();
}
