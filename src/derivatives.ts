import { mkdir, stat } from 'node:fs/promises';
import { isAbsolute, relative, resolve } from 'node:path';
import sharp from 'sharp';
import { MediaDatabase } from './database.js';
import { runCommand } from './process.js';
import type {
  DerivativeKind,
  DerivativeRecord,
  IndexedFileLocation,
  PendingJob
} from './database.js';

export interface DerivativeServiceOptions {
  rootDir?: string;
  ffmpegPath?: string;
}

export interface PrepareSummary {
  queued: number;
  processed: number;
  failed: number;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function sourceFilePath(location: IndexedFileLocation): string {
  const sourceRoot = resolve(location.sourcePath);
  const filePath = resolve(sourceRoot, location.relativePath);
  const relativePath = relative(sourceRoot, filePath);
  if (isAbsolute(relativePath) || relativePath.startsWith(`..`)) {
    throw new Error(`Refusing to read a file outside its source: ${location.relativePath}`);
  }
  return filePath;
}

export class DerivativeService {
  private readonly rootDir: string;
  private readonly ffmpegPath: string;

  constructor(
    private readonly database: MediaDatabase,
    options: DerivativeServiceOptions = {}
  ) {
    this.rootDir = resolve(options.rootDir ?? 'data/derivatives');
    this.ffmpegPath = options.ffmpegPath ?? process.env.FFMPEG_BIN ?? 'ffmpeg';
  }

  async enqueueMissing(): Promise<number> {
    let queued = 0;
    for (const location of this.database.listIndexedFileLocations()) {
      const kind: DerivativeKind = location.mediaType === 'video' ? 'poster' : 'thumbnail';
      const existing = this.database.getDerivative(location.id, kind);
      if (existing && await this.fileExists(this.outputPath(existing))) continue;
      this.database.enqueueDerivativeJob(location.id, kind);
      queued += 1;
    }
    return queued;
  }

  async ensure(fileId: number, kind: DerivativeKind): Promise<DerivativeRecord> {
    const existing = this.database.getDerivative(fileId, kind);
    if (existing && await this.fileExists(this.outputPath(existing))) return existing;

    this.database.enqueueDerivativeJob(fileId, kind);
    const job = this.database
      .pendingDerivativeJobs(100)
      .find((candidate) => candidate.mediaFileId === fileId && candidate.type === kind);
    if (!job) throw new Error(`No pending ${kind} job for media file ${fileId}`);

    await this.processJob(job);
    const saved = this.database.getDerivative(fileId, kind);
    if (!saved) throw new Error(`Derivative was not created for media file ${fileId}`);
    return saved;
  }

  async processPending(limit = 100): Promise<PrepareSummary> {
    const jobs = this.database.pendingDerivativeJobs(limit);
    const summary: PrepareSummary = { queued: jobs.length, processed: 0, failed: 0 };
    for (const job of jobs) {
      try {
        await this.processJob(job);
        summary.processed += 1;
      } catch {
        summary.failed += 1;
      }
    }
    return summary;
  }

  outputPath(derivative: DerivativeRecord): string {
    return resolve(this.rootDir, derivative.relativePath);
  }

  async processAll(): Promise<PrepareSummary> {
    const queued = await this.enqueueMissing();
    const result = await this.processPending(1000);
    return { queued, processed: result.processed, failed: result.failed };
  }

  private async processJob(job: PendingJob): Promise<void> {
    const location = this.database.getIndexedFileLocation(job.mediaFileId);
    if (!location) throw new Error(`Indexed media file not found: ${job.mediaFileId}`);

    const inputPath = sourceFilePath(location);
    await stat(inputPath);
    this.database.markJobRunning(job.id);

    const relativePath = `${job.mediaFileId}/${job.type}.${job.type === 'thumbnail' ? 'webp' : 'jpg'}`;
    const outputPath = resolve(this.rootDir, relativePath);
    await mkdir(resolve(this.rootDir, String(job.mediaFileId)), { recursive: true });

    try {
      const info = job.type === 'thumbnail'
        ? await this.generateImage(inputPath, outputPath)
        : await this.generateVideoPoster(inputPath, outputPath);
      const outputStat = await stat(outputPath);
      this.database.saveDerivative({
        mediaFileId: job.mediaFileId,
        kind: job.type,
        relativePath,
        width: info.width,
        height: info.height,
        size: outputStat.size
      });
      this.database.markJobCompleted(job.id);
    } catch (error) {
      const message = errorMessage(error);
      this.database.markJobFailed(job.id, message);
      throw error;
    }
  }

  private async generateImage(inputPath: string, outputPath: string): Promise<{ width: number; height: number }> {
    const info = await sharp(inputPath)
      .rotate()
      .resize({ width: 640, height: 640, fit: 'inside', withoutEnlargement: true })
      .webp({ quality: 82 })
      .toFile(outputPath);
    return { width: info.width, height: info.height };
  }

  private async generateVideoPoster(inputPath: string, outputPath: string): Promise<{ width: number; height: number }> {
    await runCommand(this.ffmpegPath, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-ss',
      '00:00:00',
      '-i',
      inputPath,
      '-frames:v',
      '1',
      '-vf',
      'scale=640:-2:force_original_aspect_ratio=decrease',
      '-q:v',
      '4',
      outputPath
    ]);
    const info = await sharp(outputPath).metadata();
    return { width: info.width ?? 0, height: info.height ?? 0 };
  }

  private async fileExists(filePath: string): Promise<boolean> {
    try {
      await stat(filePath);
      return true;
    } catch {
      return false;
    }
  }
}
