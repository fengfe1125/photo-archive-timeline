import { readdir, stat } from 'node:fs/promises';
import { basename, relative, resolve, sep } from 'node:path';
import { MediaDatabase } from './database.js';
import { identifyMediaFile } from './file-types.js';
import { sha256File } from './hash.js';
import { extractMetadata } from './metadata.js';
import { commandVersion } from './process.js';
import type { DiscoveredFile, ScanSummary } from './types.js';

interface ScanOptions {
  exiftoolPath?: string;
  ffprobePath?: string;
  onProgress?: (message: string) => void;
}

async function walkFiles(root: string): Promise<string[]> {
  const results: string[] = [];
  const entries = await readdir(root, { withFileTypes: true });

  for (const entry of entries) {
    // Symlinks are intentionally skipped in v0.1 so a source cannot escape
    // its configured directory or recurse through a symlink cycle.
    if (entry.isSymbolicLink()) continue;
    const child = resolve(root, entry.name);
    if (entry.isDirectory()) {
      results.push(...(await walkFiles(child)));
    } else if (entry.isFile()) {
      results.push(child);
    }
  }

  return results;
}

function toRelativePath(root: string, filePath: string): string {
  return relative(root, filePath).split(sep).join('/');
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export async function scanSource(
  database: MediaDatabase,
  sourcePath: string,
  options: ScanOptions = {}
): Promise<ScanSummary> {
  const root = resolve(sourcePath);
  const rootStat = await stat(root);
  if (!rootStat.isDirectory()) {
    throw new Error(`Source is not a directory: ${root}`);
  }

  const sourceId = database.getOrCreateSource(root, basename(root));
  const exiftoolPath = options.exiftoolPath ?? process.env.EXIFTOOL_BIN ?? 'exiftool';
  const ffprobePath = options.ffprobePath ?? process.env.FFPROBE_BIN ?? 'ffprobe';
  let exiftoolVersion: string | undefined;
  let ffprobeVersion: string | undefined;

  try {
    exiftoolVersion = await commandVersion(exiftoolPath, ['-ver']);
  } catch (error) {
    throw new Error(`ExifTool is required for scanning: ${errorMessage(error)}`);
  }

  try {
    ffprobeVersion = await commandVersion(ffprobePath, ['-version']);
  } catch (error) {
    options.onProgress?.(`Warning: FFprobe unavailable; video metadata may be incomplete: ${errorMessage(error)}`);
  }

  const files = await walkFiles(root);
  const seenPaths = new Set<string>();
  const summary: ScanSummary = {
    sourcePath: root,
    discovered: 0,
    indexed: 0,
    skipped: 0,
    errors: 0,
    warnings: 0,
    missing: 0
  };

  for (const filePath of files) {
    const media = identifyMediaFile(filePath);
    if (!media) continue;

    const relativePath = toRelativePath(root, filePath);
    seenPaths.add(relativePath);
    summary.discovered += 1;

    let fileStat;
    try {
      fileStat = await stat(filePath);
    } catch (error) {
      summary.errors += 1;
      database.addScanError(sourceId, relativePath, 'stat', errorMessage(error));
      continue;
    }

    const existing = database.findFile(sourceId, relativePath);
    if (
      existing &&
      existing.status === 'indexed' &&
      existing.size === fileStat.size &&
      existing.mtimeMs === fileStat.mtimeMs
    ) {
      database.touchFile(existing.id);
      summary.skipped += 1;
      continue;
    }

    const discoveredFile: DiscoveredFile = {
      sourceId,
      relativePath,
      size: fileStat.size,
      mtimeMs: fileStat.mtimeMs,
      mimeType: media.mimeType,
      mediaType: media.mediaType
    };
    const mediaFileId = database.upsertDiscoveredFile(discoveredFile);

    options.onProgress?.(`Indexing ${relativePath}`);
    let sha256: string | undefined;
    try {
      sha256 = await sha256File(filePath);
      const extraction = await extractMetadata(filePath, {
        mediaType: media.mediaType,
        mtimeMs: fileStat.mtimeMs,
        exiftoolPath,
        exiftoolVersion,
        ffprobePath,
        ffprobeVersion
      });
      database.replaceObservations(mediaFileId, extraction);
      database.markIndexed(mediaFileId, sha256);

      for (const warning of extraction.warnings) {
        summary.warnings += 1;
        database.addScanError(sourceId, relativePath, warning.stage, warning.message, mediaFileId);
      }
      summary.indexed += 1;
    } catch (error) {
      summary.errors += 1;
      const message = errorMessage(error);
      database.markError(mediaFileId, message, sha256);
      database.addScanError(sourceId, relativePath, 'index', message, mediaFileId);
    }
  }

  summary.missing = database.markMissing(sourceId, seenPaths);
  return summary;
}
