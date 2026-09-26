import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import BetterSqlite3 from 'better-sqlite3';
import type {
  DiscoveredFile,
  ExtractionResult,
  GeoCandidate,
  MediaType,
  TimeCandidate
} from './types.js';

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS sources (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    label TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS media_files (
    id INTEGER PRIMARY KEY,
    source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    relative_path TEXT NOT NULL,
    size INTEGER NOT NULL,
    mtime_ms INTEGER NOT NULL,
    mime_type TEXT NOT NULL,
    media_type TEXT NOT NULL CHECK (media_type IN ('photo', 'video')),
    sha256 TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'indexed', 'error', 'missing')),
    error_message TEXT,
    last_seen_at TEXT,
    indexed_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(source_id, relative_path)
  );

  CREATE TABLE IF NOT EXISTS metadata_snapshots (
    id INTEGER PRIMARY KEY,
    media_file_id INTEGER NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
    extractor TEXT NOT NULL,
    extractor_version TEXT,
    raw_json TEXT NOT NULL,
    created_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS time_candidates (
    id INTEGER PRIMARY KEY,
    media_file_id INTEGER NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
    snapshot_id INTEGER REFERENCES metadata_snapshots(id) ON DELETE SET NULL,
    value TEXT NOT NULL,
    source TEXT NOT NULL,
    raw_value TEXT NOT NULL,
    precision TEXT NOT NULL CHECK (precision IN ('exact', 'minute', 'day', 'unknown')),
    confidence REAL NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    created_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS geo_candidates (
    id INTEGER PRIMARY KEY,
    media_file_id INTEGER NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
    snapshot_id INTEGER REFERENCES metadata_snapshots(id) ON DELETE SET NULL,
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    source TEXT NOT NULL,
    raw_value TEXT NOT NULL,
    confidence REAL NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    accuracy_m REAL,
    created_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS scan_errors (
    id INTEGER PRIMARY KEY,
    source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    media_file_id INTEGER REFERENCES media_files(id) ON DELETE SET NULL,
    relative_path TEXT NOT NULL,
    stage TEXT NOT NULL,
    message TEXT NOT NULL,
    created_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS manual_overrides (
    id INTEGER PRIMARY KEY,
    media_file_id INTEGER NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
    field TEXT NOT NULL CHECK (field IN ('time', 'geo', 'title', 'caption')),
    value_json TEXT NOT NULL,
    reason TEXT,
    active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY,
    media_file_id INTEGER NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
    action TEXT NOT NULL,
    field TEXT NOT NULL,
    old_value_json TEXT,
    new_value_json TEXT,
    reason TEXT,
    created_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    start_date TEXT,
    end_date TEXT,
    place TEXT,
    description TEXT,
    cover_media_file_id INTEGER REFERENCES media_files(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS event_assets (
    event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    media_file_id INTEGER NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
    sort_order INTEGER NOT NULL DEFAULT 0,
    caption TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (event_id, media_file_id)
  );

  CREATE TABLE IF NOT EXISTS derivatives (
    id INTEGER PRIMARY KEY,
    media_file_id INTEGER NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('thumbnail', 'poster')),
    relative_path TEXT NOT NULL,
    width INTEGER,
    height INTEGER,
    size INTEGER,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(media_file_id, kind)
  );

  CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY,
    media_file_id INTEGER NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('thumbnail', 'poster')),
    status TEXT NOT NULL DEFAULT 'pending'
      CHECK (status IN ('pending', 'running', 'completed', 'failed')),
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(media_file_id, type)
  );

  CREATE INDEX IF NOT EXISTS idx_media_files_source_status
    ON media_files(source_id, status);
  CREATE INDEX IF NOT EXISTS idx_media_files_mtime
    ON media_files(mtime_ms);
  CREATE INDEX IF NOT EXISTS idx_time_candidates_file
    ON time_candidates(media_file_id, value);
  CREATE INDEX IF NOT EXISTS idx_geo_candidates_file
    ON geo_candidates(media_file_id);
  CREATE INDEX IF NOT EXISTS idx_scan_errors_source
    ON scan_errors(source_id, created_at);
  CREATE INDEX IF NOT EXISTS idx_manual_overrides_active
    ON manual_overrides(media_file_id, field, active);
  CREATE INDEX IF NOT EXISTS idx_audit_log_media
    ON audit_log(media_file_id, created_at);
  CREATE INDEX IF NOT EXISTS idx_event_assets_order
    ON event_assets(event_id, sort_order);
  CREATE INDEX IF NOT EXISTS idx_derivatives_file_kind
    ON derivatives(media_file_id, kind);
  CREATE INDEX IF NOT EXISTS idx_jobs_status
    ON jobs(status, updated_at);
`;

export interface ExistingFile {
  id: number;
  size: number;
  mtimeMs: number;
  status: 'pending' | 'indexed' | 'error' | 'missing';
}

export interface ActiveOverride {
  id: number;
  field: 'time' | 'geo' | 'title' | 'caption';
  value: unknown;
  reason: string | null;
  createdAt: string;
}

export interface AuditEntry {
  id: number;
  action: string;
  field: string;
  oldValue: unknown;
  newValue: unknown;
  reason: string | null;
  createdAt: string;
}

export interface FileDetails {
  id: number;
  sourcePath: string;
  relativePath: string;
  size: number;
  mtimeMs: number;
  mimeType: string;
  mediaType: MediaType;
  sha256: string | null;
  status: string;
  errorMessage: string | null;
  times: Array<TimeCandidate & { id: number }>;
  geos: Array<GeoCandidate & { id: number }>;
  snapshots: Array<{
    id: number;
    extractor: string;
    extractorVersion: string | null;
    createdAt: string;
  }>;
  overrides: ActiveOverride[];
  auditLog: AuditEntry[];
}

export interface DatabaseStats {
  sources: number;
  total: number;
  indexed: number;
  pending: number;
  errors: number;
  missing: number;
  photos: number;
  videos: number;
  withTime: number;
  withGps: number;
}

export interface TimelineQuery {
  limit?: number;
  offset?: number;
  year?: string;
  month?: string;
}

export interface TimelineItem {
  id: number;
  relativePath: string;
  size: number;
  mimeType: string;
  mediaType: MediaType;
  sha256: string | null;
  capturedAt: string | null;
  capturedAtSource: string | null;
  capturedAtPrecision: string | null;
  capturedAtConfidence: number | null;
  timeCandidateCount: number;
  latitude: number | null;
  longitude: number | null;
  geoSource: string | null;
  thumbnailReady: boolean;
  durationSeconds: number | null;
}

export interface TimelineResult {
  items: TimelineItem[];
  total: number;
}

export type DerivativeKind = 'thumbnail' | 'poster';

export interface DerivativeRecord {
  id: number;
  mediaFileId: number;
  kind: DerivativeKind;
  relativePath: string;
  width: number | null;
  height: number | null;
  size: number | null;
}

export interface IndexedFileLocation {
  id: number;
  sourcePath: string;
  relativePath: string;
  mediaType: MediaType;
  mimeType: string;
}

export interface PendingJob {
  id: number;
  mediaFileId: number;
  type: DerivativeKind;
  attempts: number;
}

export interface EventSummary {
  id: number;
  title: string;
  startDate: string | null;
  endDate: string | null;
  place: string | null;
  description: string | null;
  coverMediaFileId: number | null;
  assetCount: number;
  createdAt: string;
  updatedAt: string;
}

export interface EventAsset {
  mediaFileId: number;
  sortOrder: number;
  caption: string | null;
  item: TimelineItem | null;
}

export interface EventDetails extends EventSummary {
  assets: EventAsset[];
}

function now(): string {
  return new Date().toISOString();
}

function ensureParentDirectory(filename: string): void {
  if (filename !== ':memory:') {
    mkdirSync(dirname(resolve(filename)), { recursive: true });
  }
}

function durationFromFfprobe(rawJson: string | null): number | null {
  if (!rawJson) return null;
  try {
    const parsed = JSON.parse(rawJson) as { format?: { duration?: string | number } };
    const value = parsed.format?.duration;
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (typeof value === 'string' && Number.isFinite(Number(value))) return Number(value);
  } catch {
    // Optional FFprobe snapshots must not break timeline queries.
  }
  return null;
}

function parseJson(value: string | null): unknown {
  if (value === null) return null;
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

export class MediaDatabase {
  private readonly db: BetterSqlite3.Database;

  constructor(filename: string) {
    ensureParentDirectory(filename);
    this.db = new BetterSqlite3(filename);
    this.db.pragma('foreign_keys = ON');
    this.db.pragma('journal_mode = WAL');
    this.db.exec(SCHEMA);
  }

  close(): void {
    this.db.close();
  }

  getOrCreateSource(sourcePath: string, label?: string): number {
    const canonicalPath = resolve(sourcePath);
    const existing = this.db
      .prepare('SELECT id FROM sources WHERE path = ?')
      .get(canonicalPath) as { id: number } | undefined;

    if (existing) {
      this.db
        .prepare('UPDATE sources SET label = COALESCE(?, label), updated_at = ? WHERE id = ?')
        .run(label ?? null, now(), existing.id);
      return existing.id;
    }

    const timestamp = now();
    const result = this.db
      .prepare(
        'INSERT INTO sources (path, label, created_at, updated_at) VALUES (?, ?, ?, ?)'
      )
      .run(canonicalPath, label ?? null, timestamp, timestamp);
    return Number(result.lastInsertRowid);
  }

  findFile(sourceId: number, relativePath: string): ExistingFile | undefined {
    return this.db
      .prepare(
        `SELECT id, size, mtime_ms AS mtimeMs, status
         FROM media_files WHERE source_id = ? AND relative_path = ?`
      )
      .get(sourceId, relativePath) as ExistingFile | undefined;
  }

  upsertDiscoveredFile(file: DiscoveredFile): number {
    const timestamp = now();
    const existing = this.findFile(file.sourceId, file.relativePath);

    if (existing) {
      this.db
        .prepare(
          `UPDATE media_files
           SET size = ?, mtime_ms = ?, mime_type = ?, media_type = ?,
               status = 'pending', error_message = NULL, last_seen_at = ?, updated_at = ?
           WHERE id = ?`
        )
        .run(
          file.size,
          file.mtimeMs,
          file.mimeType,
          file.mediaType,
          timestamp,
          timestamp,
          existing.id
        );
      this.db.prepare('DELETE FROM derivatives WHERE media_file_id = ?').run(existing.id);
      this.db
        .prepare(
          `UPDATE jobs SET status = 'pending', last_error = NULL, updated_at = ?
           WHERE media_file_id = ?`
        )
        .run(timestamp, existing.id);
      return existing.id;
    }

    const result = this.db
      .prepare(
        `INSERT INTO media_files
          (source_id, relative_path, size, mtime_ms, mime_type, media_type,
           status, last_seen_at, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)`
      )
      .run(
        file.sourceId,
        file.relativePath,
        file.size,
        file.mtimeMs,
        file.mimeType,
        file.mediaType,
        timestamp,
        timestamp,
        timestamp
      );
    return Number(result.lastInsertRowid);
  }

  touchFile(fileId: number): void {
    const timestamp = now();
    this.db
      .prepare('UPDATE media_files SET last_seen_at = ?, updated_at = ? WHERE id = ?')
      .run(timestamp, timestamp, fileId);
  }

  replaceObservations(fileId: number, extraction: ExtractionResult): void {
    const timestamp = now();
    const transaction = this.db.transaction(() => {
      this.db.prepare('DELETE FROM time_candidates WHERE media_file_id = ?').run(fileId);
      this.db.prepare('DELETE FROM geo_candidates WHERE media_file_id = ?').run(fileId);

      const snapshotIds = new Map<string, number>();
      const insertSnapshot = this.db.prepare(
        `INSERT INTO metadata_snapshots
          (media_file_id, extractor, extractor_version, raw_json, created_at)
         VALUES (?, ?, ?, ?, ?)`
      );

      for (const snapshot of extraction.snapshots) {
        const result = insertSnapshot.run(
          fileId,
          snapshot.extractor,
          snapshot.extractorVersion ?? null,
          JSON.stringify(snapshot.raw),
          timestamp
        );
        snapshotIds.set(snapshot.extractor, Number(result.lastInsertRowid));
      }

      const insertTime = this.db.prepare(
        `INSERT INTO time_candidates
          (media_file_id, snapshot_id, value, source, raw_value, precision, confidence, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
      );
      for (const candidate of extraction.timeCandidates) {
        insertTime.run(
          fileId,
          snapshotIds.get(candidate.extractor) ?? null,
          candidate.value,
          candidate.source,
          candidate.rawValue,
          candidate.precision,
          candidate.confidence,
          timestamp
        );
      }

      const insertGeo = this.db.prepare(
        `INSERT INTO geo_candidates
          (media_file_id, snapshot_id, latitude, longitude, source, raw_value,
           confidence, accuracy_m, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
      );
      for (const candidate of extraction.geoCandidates) {
        insertGeo.run(
          fileId,
          snapshotIds.get(candidate.extractor) ?? null,
          candidate.latitude,
          candidate.longitude,
          candidate.source,
          candidate.rawValue,
          candidate.confidence,
          candidate.accuracyMeters ?? null,
          timestamp
        );
      }
    });

    transaction();
  }

  markIndexed(fileId: number, sha256: string): void {
    const timestamp = now();
    this.db
      .prepare(
        `UPDATE media_files
         SET sha256 = ?, status = 'indexed', error_message = NULL,
             indexed_at = ?, last_seen_at = ?, updated_at = ?
         WHERE id = ?`
      )
      .run(sha256, timestamp, timestamp, timestamp, fileId);
  }

  markError(fileId: number, message: string, sha256?: string): void {
    const timestamp = now();
    this.db
      .prepare(
        `UPDATE media_files
         SET sha256 = COALESCE(?, sha256), status = 'error', error_message = ?,
             last_seen_at = ?, updated_at = ?
         WHERE id = ?`
      )
      .run(sha256 ?? null, message, timestamp, timestamp, fileId);
  }

  addScanError(
    sourceId: number,
    relativePath: string,
    stage: string,
    message: string,
    mediaFileId?: number
  ): void {
    this.db
      .prepare(
        `INSERT INTO scan_errors
          (source_id, media_file_id, relative_path, stage, message, created_at)
         VALUES (?, ?, ?, ?, ?, ?)`
      )
      .run(sourceId, mediaFileId ?? null, relativePath, stage, message, now());
  }

  markMissing(sourceId: number, seenPaths: Set<string>): number {
    const rows = this.db
      .prepare('SELECT id, relative_path FROM media_files WHERE source_id = ?')
      .all(sourceId) as Array<{ id: number; relative_path: string }>;
    let count = 0;
    const mark = this.db.prepare(
      `UPDATE media_files
       SET status = 'missing', last_seen_at = ?, updated_at = ?
       WHERE id = ? AND status != 'missing'`
    );

    const transaction = this.db.transaction(() => {
      for (const row of rows) {
        if (!seenPaths.has(row.relative_path)) {
          const result = mark.run(now(), now(), row.id);
          count += result.changes;
        }
      }
    });
    transaction();
    return count;
  }

  stats(): DatabaseStats {
    const sources = this.db.prepare('SELECT COUNT(*) AS count FROM sources').get() as {
      count: number;
    };
    const counts = this.db
      .prepare(
        `SELECT
          COUNT(*) AS total,
          SUM(status = 'indexed') AS indexed,
          SUM(status = 'pending') AS pending,
          SUM(status = 'error') AS errors,
          SUM(status = 'missing') AS missing,
          SUM(media_type = 'photo') AS photos,
          SUM(media_type = 'video') AS videos
         FROM media_files`
      )
      .get() as Record<string, number | null>;
    const withTime = this.db
      .prepare(
        `SELECT COUNT(DISTINCT media_file_id) AS count FROM time_candidates
         JOIN media_files ON media_files.id = time_candidates.media_file_id
         WHERE media_files.status != 'missing'`
      )
      .get() as { count: number };
    const withGps = this.db
      .prepare(
        `SELECT COUNT(DISTINCT media_file_id) AS count FROM geo_candidates
         JOIN media_files ON media_files.id = geo_candidates.media_file_id
         WHERE media_files.status != 'missing'`
      )
      .get() as { count: number };

    return {
      sources: sources.count,
      total: counts.total ?? 0,
      indexed: counts.indexed ?? 0,
      pending: counts.pending ?? 0,
      errors: counts.errors ?? 0,
      missing: counts.missing ?? 0,
      photos: counts.photos ?? 0,
      videos: counts.videos ?? 0,
      withTime: withTime.count,
      withGps: withGps.count
    };
  }

  listTimeline(query: TimelineQuery = {}): TimelineResult {
    const limit = Math.min(Math.max(Math.floor(query.limit ?? 60), 1), 200);
    const offset = Math.max(Math.floor(query.offset ?? 0), 0);
    const filters: string[] = [];
    const parameters: Array<string | number> = [];

    if (query.year) {
      filters.push('substr(timeline.capturedAt, 1, 4) = ?');
      parameters.push(query.year);
    }
    if (query.month) {
      filters.push('substr(timeline.capturedAt, 6, 2) = ?');
      parameters.push(query.month.padStart(2, '0'));
    }

    const where = filters.length > 0 ? `WHERE ${filters.join(' AND ')}` : '';
    const rows = this.db
      .prepare(
        `WITH ranked_times AS (
           SELECT tc.media_file_id, tc.value, tc.source, tc.precision, tc.confidence,
                  ROW_NUMBER() OVER (
                    PARTITION BY tc.media_file_id
                    ORDER BY tc.confidence DESC, tc.id
                  ) AS rn
           FROM time_candidates tc
         ), ranked_geos AS (
           SELECT gc.media_file_id, gc.latitude, gc.longitude, gc.source,
                  ROW_NUMBER() OVER (
                    PARTITION BY gc.media_file_id
                    ORDER BY gc.confidence DESC, gc.id
                  ) AS rn
           FROM geo_candidates gc
         )
         SELECT timeline.*, COUNT(*) OVER () AS totalCount
         FROM (
           SELECT mf.id, mf.relative_path AS relativePath, mf.size, mf.mime_type AS mimeType,
                  mf.media_type AS mediaType, mf.sha256,
                  CASE WHEN time_override.id IS NOT NULL
                    THEN CAST(json_extract(time_override.value_json, '$.value') AS TEXT)
                    ELSE rt.value END AS capturedAt,
                  CASE WHEN time_override.id IS NOT NULL THEN 'manual' ELSE rt.source END AS capturedAtSource,
                  CASE WHEN time_override.id IS NOT NULL
                    THEN COALESCE(CAST(json_extract(time_override.value_json, '$.precision') AS TEXT), 'exact')
                    ELSE rt.precision END AS capturedAtPrecision,
                  CASE WHEN time_override.id IS NOT NULL THEN 1 ELSE rt.confidence END AS capturedAtConfidence,
                  (SELECT COUNT(*) FROM time_candidates tc2
                   WHERE tc2.media_file_id = mf.id) AS timeCandidateCount,
                  CASE WHEN geo_override.id IS NOT NULL
                    THEN CAST(json_extract(geo_override.value_json, '$.latitude') AS REAL)
                    ELSE rg.latitude END AS latitude,
                  CASE WHEN geo_override.id IS NOT NULL
                    THEN CAST(json_extract(geo_override.value_json, '$.longitude') AS REAL)
                    ELSE rg.longitude END AS longitude,
                  CASE WHEN geo_override.id IS NOT NULL THEN 'manual' ELSE rg.source END AS geoSource,
                  EXISTS (
                    SELECT 1 FROM derivatives d
                    WHERE d.media_file_id = mf.id AND d.kind = 'thumbnail'
                  ) AS thumbnailReady,
                  (SELECT ms.raw_json FROM metadata_snapshots ms
                   WHERE ms.media_file_id = mf.id AND ms.extractor = 'ffprobe'
                   ORDER BY ms.id DESC LIMIT 1) AS ffprobeJson
           FROM media_files mf
           LEFT JOIN ranked_times rt ON rt.media_file_id = mf.id AND rt.rn = 1
           LEFT JOIN ranked_geos rg ON rg.media_file_id = mf.id AND rg.rn = 1
           LEFT JOIN manual_overrides time_override
             ON time_override.media_file_id = mf.id
            AND time_override.field = 'time' AND time_override.active = 1
           LEFT JOIN manual_overrides geo_override
             ON geo_override.media_file_id = mf.id
            AND geo_override.field = 'geo' AND geo_override.active = 1
           WHERE mf.status = 'indexed'
         ) AS timeline
         ${where}
         ORDER BY CASE WHEN timeline.capturedAt IS NULL THEN 1 ELSE 0 END,
                  timeline.capturedAt ASC, timeline.id ASC
         LIMIT ? OFFSET ?`
      )
      .all(...parameters, limit, offset) as Array<{
        id: number;
        relativePath: string;
        size: number;
        mimeType: string;
        mediaType: MediaType;
        sha256: string | null;
        capturedAt: string | null;
        capturedAtSource: string | null;
        capturedAtPrecision: string | null;
        capturedAtConfidence: number | null;
        timeCandidateCount: number;
        latitude: number | null;
        longitude: number | null;
        geoSource: string | null;
        thumbnailReady: number;
        ffprobeJson: string | null;
        totalCount: number;
      }>;

    const items = rows.map((row): TimelineItem => ({
      id: row.id,
      relativePath: row.relativePath,
      size: row.size,
      mimeType: row.mimeType,
      mediaType: row.mediaType,
      sha256: row.sha256,
      capturedAt: row.capturedAt,
      capturedAtSource: row.capturedAtSource,
      capturedAtPrecision: row.capturedAtPrecision,
      capturedAtConfidence: row.capturedAtConfidence,
      timeCandidateCount: row.timeCandidateCount,
      latitude: row.latitude,
      longitude: row.longitude,
      geoSource: row.geoSource,
      thumbnailReady: Boolean(row.thumbnailReady),
      durationSeconds: durationFromFfprobe(row.ffprobeJson)
    }));

    return { items, total: rows[0]?.totalCount ?? 0 };
  }

  getIndexedFileLocation(fileId: number): IndexedFileLocation | undefined {
    return this.db
      .prepare(
        `SELECT media_files.id, sources.path AS sourcePath,
                media_files.relative_path AS relativePath,
                media_files.media_type AS mediaType, media_files.mime_type AS mimeType
         FROM media_files JOIN sources ON sources.id = media_files.source_id
         WHERE media_files.id = ? AND media_files.status = 'indexed'`
      )
      .get(fileId) as IndexedFileLocation | undefined;
  }

  listIndexedFileLocations(): IndexedFileLocation[] {
    return this.db
      .prepare(
        `SELECT media_files.id, sources.path AS sourcePath,
                media_files.relative_path AS relativePath,
                media_files.media_type AS mediaType, media_files.mime_type AS mimeType
         FROM media_files JOIN sources ON sources.id = media_files.source_id
         WHERE media_files.status = 'indexed'
         ORDER BY media_files.id`
      )
      .all() as IndexedFileLocation[];
  }

  getDerivative(fileId: number, kind: DerivativeKind): DerivativeRecord | undefined {
    return this.db
      .prepare(
        `SELECT id, media_file_id AS mediaFileId, kind, relative_path AS relativePath,
                width, height, size
         FROM derivatives WHERE media_file_id = ? AND kind = ?`
      )
      .get(fileId, kind) as DerivativeRecord | undefined;
  }

  saveDerivative(input: Omit<DerivativeRecord, 'id'>): DerivativeRecord {
    const timestamp = now();
    this.db
      .prepare(
        `INSERT INTO derivatives
          (media_file_id, kind, relative_path, width, height, size, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(media_file_id, kind) DO UPDATE SET
           relative_path = excluded.relative_path,
           width = excluded.width,
           height = excluded.height,
           size = excluded.size,
           updated_at = excluded.updated_at`
      )
      .run(
        input.mediaFileId,
        input.kind,
        input.relativePath,
        input.width,
        input.height,
        input.size,
        timestamp,
        timestamp
      );
    const saved = this.getDerivative(input.mediaFileId, input.kind);
    if (!saved) throw new Error('Failed to save derivative record');
    return saved;
  }

  enqueueDerivativeJob(fileId: number, type: DerivativeKind): void {
    const timestamp = now();
    this.db
      .prepare(
        `INSERT INTO jobs
          (media_file_id, type, status, attempts, created_at, updated_at)
         VALUES (?, ?, 'pending', 0, ?, ?)
         ON CONFLICT(media_file_id, type) DO UPDATE SET
           status = 'pending', last_error = NULL, updated_at = excluded.updated_at`
      )
      .run(fileId, type, timestamp, timestamp);
  }

  pendingDerivativeJobs(limit = 10): PendingJob[] {
    return this.db
      .prepare(
        `SELECT id, media_file_id AS mediaFileId, type, attempts
         FROM jobs WHERE status = 'pending' ORDER BY id LIMIT ?`
      )
      .all(Math.min(Math.max(limit, 1), 100)) as PendingJob[];
  }

  markJobRunning(jobId: number): void {
    this.db
      .prepare(
        `UPDATE jobs SET status = 'running', attempts = attempts + 1,
                updated_at = ? WHERE id = ?`
      )
      .run(now(), jobId);
  }

  markJobCompleted(jobId: number): void {
    this.db
      .prepare(
        `UPDATE jobs SET status = 'completed', last_error = NULL, updated_at = ?
         WHERE id = ?`
      )
      .run(now(), jobId);
  }

  markJobFailed(jobId: number, message: string): void {
    this.db
      .prepare(
        `UPDATE jobs SET status = 'failed', last_error = ?, updated_at = ?
         WHERE id = ?`
      )
      .run(message, now(), jobId);
  }

  setOverride(
    fileId: number,
    field: ActiveOverride['field'],
    value: unknown,
    reason = 'manual'
  ): ActiveOverride {
    const timestamp = now();
    const valueJson = JSON.stringify(value);
    const transaction = this.db.transaction(() => {
      const current = this.db
        .prepare(
          `SELECT value_json AS valueJson FROM manual_overrides
           WHERE media_file_id = ? AND field = ? AND active = 1
           ORDER BY id DESC LIMIT 1`
        )
        .get(fileId, field) as { valueJson: string } | undefined;
      this.db
        .prepare(
          `UPDATE manual_overrides SET active = 0
           WHERE media_file_id = ? AND field = ? AND active = 1`
        )
        .run(fileId, field);
      const result = this.db
        .prepare(
          `INSERT INTO manual_overrides
            (media_file_id, field, value_json, reason, active, created_at)
           VALUES (?, ?, ?, ?, 1, ?)`
        )
        .run(fileId, field, valueJson, reason, timestamp);
      this.db
        .prepare(
          `INSERT INTO audit_log
            (media_file_id, action, field, old_value_json, new_value_json, reason, created_at)
           VALUES (?, 'set', ?, ?, ?, ?, ?)`
        )
        .run(fileId, field, current?.valueJson ?? null, valueJson, reason, timestamp);
      return Number(result.lastInsertRowid);
    });

    const id = transaction();
    const saved = this.db
      .prepare(
        `SELECT id, field, value_json AS valueJson, reason, created_at AS createdAt
         FROM manual_overrides WHERE id = ?`
      )
      .get(id) as {
      id: number;
      field: ActiveOverride['field'];
      valueJson: string;
      reason: string | null;
      createdAt: string;
    };
    return {
      id: saved.id,
      field: saved.field,
      value: parseJson(saved.valueJson),
      reason: saved.reason,
      createdAt: saved.createdAt
    };
  }

  undoLastOverride(fileId: number): { field: ActiveOverride['field']; restored: unknown } | null {
    const transaction = this.db.transaction(() => {
      const current = this.db
        .prepare(
          `SELECT id, field, value_json AS valueJson, reason FROM manual_overrides
           WHERE media_file_id = ? AND active = 1 ORDER BY id DESC LIMIT 1`
        )
        .get(fileId) as {
        id: number;
        field: ActiveOverride['field'];
        valueJson: string;
        reason: string | null;
      } | undefined;
      if (!current) return null;

      this.db.prepare('UPDATE manual_overrides SET active = 0 WHERE id = ?').run(current.id);
      const previous = this.db
        .prepare(
          `SELECT id, value_json AS valueJson FROM manual_overrides
           WHERE media_file_id = ? AND field = ? AND id < ? AND active = 0
           ORDER BY id DESC LIMIT 1`
        )
        .get(fileId, current.field, current.id) as { id: number; valueJson: string } | undefined;
      if (previous) this.db.prepare('UPDATE manual_overrides SET active = 1 WHERE id = ?').run(previous.id);

      this.db
        .prepare(
          `INSERT INTO audit_log
            (media_file_id, action, field, old_value_json, new_value_json, reason, created_at)
           VALUES (?, 'undo', ?, ?, ?, ?, ?)`
        )
        .run(
          fileId,
          current.field,
          current.valueJson,
          previous?.valueJson ?? null,
          'undo last override',
          now()
        );
      return { field: current.field, restored: parseJson(previous?.valueJson ?? null) };
    });
    return transaction();
  }

  activeOverrides(fileId: number): ActiveOverride[] {
    const rows = this.db
      .prepare(
        `SELECT id, field, value_json AS valueJson, reason, created_at AS createdAt
         FROM manual_overrides WHERE media_file_id = ? AND active = 1 ORDER BY id`
      )
      .all(fileId) as Array<{
      id: number;
      field: ActiveOverride['field'];
      valueJson: string;
      reason: string | null;
      createdAt: string;
    }>;
    return rows.map((row) => ({
      id: row.id,
      field: row.field,
      value: parseJson(row.valueJson),
      reason: row.reason,
      createdAt: row.createdAt
    }));
  }

  auditEntries(fileId: number): AuditEntry[] {
    const rows = this.db
      .prepare(
        `SELECT id, action, field, old_value_json AS oldValue,
                new_value_json AS newValue, reason, created_at AS createdAt
         FROM audit_log WHERE media_file_id = ? ORDER BY id DESC`
      )
      .all(fileId) as Array<{
      id: number;
      action: string;
      field: string;
      oldValue: string | null;
      newValue: string | null;
      reason: string | null;
      createdAt: string;
    }>;
    return rows.map((row) => ({
      id: row.id,
      action: row.action,
      field: row.field,
      oldValue: parseJson(row.oldValue),
      newValue: parseJson(row.newValue),
      reason: row.reason,
      createdAt: row.createdAt
    }));
  }

  createEvent(input: {
    title: string;
    startDate?: string | null;
    endDate?: string | null;
    place?: string | null;
    description?: string | null;
    coverMediaFileId?: number | null;
  }): number {
    const title = input.title.trim();
    if (!title) throw new Error('Event title is required');
    const timestamp = now();
    const result = this.db
      .prepare(
        `INSERT INTO events
          (title, start_date, end_date, place, description, cover_media_file_id, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        title,
        input.startDate ?? null,
        input.endDate ?? null,
        input.place ?? null,
        input.description ?? null,
        input.coverMediaFileId ?? null,
        timestamp,
        timestamp
      );
    return Number(result.lastInsertRowid);
  }

  updateEvent(
    eventId: number,
    input: Partial<{
      title: string;
      startDate: string | null;
      endDate: string | null;
      place: string | null;
      description: string | null;
      coverMediaFileId: number | null;
    }>
  ): void {
    if (input.title !== undefined && !input.title.trim()) throw new Error('Event title is required');
    const fields: string[] = [];
    const values: Array<string | number | null> = [];
    const mapping: Array<[keyof typeof input, string]> = [
      ['title', 'title'],
      ['startDate', 'start_date'],
      ['endDate', 'end_date'],
      ['place', 'place'],
      ['description', 'description'],
      ['coverMediaFileId', 'cover_media_file_id']
    ];
    for (const [key, column] of mapping) {
      if (input[key] !== undefined) {
        fields.push(`${column} = ?`);
        values.push(key === 'title' ? String(input[key]).trim() : (input[key] as string | number | null));
      }
    }
    if (fields.length === 0) return;
    fields.push('updated_at = ?');
    values.push(now(), eventId);
    const result = this.db
      .prepare(`UPDATE events SET ${fields.join(', ')} WHERE id = ?`)
      .run(...values);
    if (result.changes === 0) throw new Error(`Event not found: ${eventId}`);
  }

  deleteEvent(eventId: number): void {
    this.db.prepare('DELETE FROM events WHERE id = ?').run(eventId);
  }

  listEvents(): EventSummary[] {
    return this.db
      .prepare(
        `SELECT e.id, e.title, e.start_date AS startDate, e.end_date AS endDate,
                e.place, e.description, e.cover_media_file_id AS coverMediaFileId,
                COUNT(ea.media_file_id) AS assetCount,
                e.created_at AS createdAt, e.updated_at AS updatedAt
         FROM events e LEFT JOIN event_assets ea ON ea.event_id = e.id
         GROUP BY e.id ORDER BY COALESCE(e.start_date, e.created_at) DESC, e.id DESC`
      )
      .all() as EventSummary[];
  }

  getEvent(eventId: number): EventDetails | undefined {
    const event = this.db
      .prepare(
        `SELECT e.id, e.title, e.start_date AS startDate, e.end_date AS endDate,
                e.place, e.description, e.cover_media_file_id AS coverMediaFileId,
                (SELECT COUNT(*) FROM event_assets ea WHERE ea.event_id = e.id) AS assetCount,
                e.created_at AS createdAt, e.updated_at AS updatedAt
         FROM events e WHERE e.id = ?`
      )
      .get(eventId) as EventSummary | undefined;
    if (!event) return undefined;

    const items = new Map<number, TimelineItem>();
    let timelineOffset = 0;
    while (true) {
      const page = this.listTimeline({ limit: 200, offset: timelineOffset });
      for (const item of page.items) items.set(item.id, item);
      timelineOffset += page.items.length;
      if (page.items.length === 0 || items.size >= page.total) break;
    }
    const assets = this.db
      .prepare(
        `SELECT media_file_id AS mediaFileId, sort_order AS sortOrder, caption
         FROM event_assets WHERE event_id = ? ORDER BY sort_order, media_file_id`
      )
      .all(eventId) as Array<{ mediaFileId: number; sortOrder: number; caption: string | null }>;
    return {
      ...event,
      assets: assets.map((asset) => ({ ...asset, item: items.get(asset.mediaFileId) ?? null }))
    };
  }

  addEventAsset(
    eventId: number,
    mediaFileId: number,
    input: { sortOrder?: number; caption?: string | null } = {}
  ): void {
    if (!this.getIndexedFileLocation(mediaFileId)) throw new Error(`Media file not found: ${mediaFileId}`);
    const eventExists = this.db.prepare('SELECT 1 FROM events WHERE id = ?').get(eventId);
    if (!eventExists) throw new Error(`Event not found: ${eventId}`);
    const order = input.sortOrder ?? ((this.db
      .prepare('SELECT COALESCE(MAX(sort_order), -1) + 1 AS next FROM event_assets WHERE event_id = ?')
      .get(eventId) as { next: number }).next);
    const timestamp = now();
    this.db
      .prepare(
        `INSERT INTO event_assets
          (event_id, media_file_id, sort_order, caption, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(event_id, media_file_id) DO UPDATE SET
           sort_order = excluded.sort_order,
           caption = COALESCE(excluded.caption, event_assets.caption),
           updated_at = excluded.updated_at`
      )
      .run(eventId, mediaFileId, order, input.caption ?? null, timestamp, timestamp);
  }

  updateEventAsset(
    eventId: number,
    mediaFileId: number,
    input: { sortOrder?: number; caption?: string | null }
  ): void {
    const fields: string[] = [];
    const values: Array<string | number | null> = [];
    if (input.sortOrder !== undefined) {
      fields.push('sort_order = ?');
      values.push(input.sortOrder);
    }
    if (input.caption !== undefined) {
      fields.push('caption = ?');
      values.push(input.caption);
    }
    if (fields.length === 0) return;
    fields.push('updated_at = ?');
    values.push(now(), eventId, mediaFileId);
    const result = this.db
      .prepare(`UPDATE event_assets SET ${fields.join(', ')} WHERE event_id = ? AND media_file_id = ?`)
      .run(...values);
    if (result.changes === 0) throw new Error('Event asset not found');
  }

  removeEventAsset(eventId: number, mediaFileId: number): void {
    this.db.prepare('DELETE FROM event_assets WHERE event_id = ? AND media_file_id = ?').run(eventId, mediaFileId);
  }

  findFileDetails(query: string): FileDetails | undefined {
    const numericId = /^\d+$/.test(query) ? Number(query) : null;
    const row = numericId !== null
      ? this.db
          .prepare(
            `SELECT media_files.id, sources.path AS sourcePath, media_files.relative_path AS relativePath,
                    media_files.size, media_files.mtime_ms AS mtimeMs, media_files.mime_type AS mimeType,
                    media_files.media_type AS mediaType, media_files.sha256, media_files.status,
                    media_files.error_message AS errorMessage
             FROM media_files JOIN sources ON sources.id = media_files.source_id
             WHERE media_files.id = ?`
          )
          .get(numericId)
      : this.db
          .prepare(
            `SELECT media_files.id, sources.path AS sourcePath, media_files.relative_path AS relativePath,
                    media_files.size, media_files.mtime_ms AS mtimeMs, media_files.mime_type AS mimeType,
                    media_files.media_type AS mediaType, media_files.sha256, media_files.status,
                    media_files.error_message AS errorMessage
             FROM media_files JOIN sources ON sources.id = media_files.source_id
             WHERE media_files.relative_path = ?
             ORDER BY media_files.id LIMIT 1`
          )
          .get(query);

    if (!row) return undefined;
    const file = row as Omit<FileDetails, 'times' | 'geos' | 'snapshots' | 'overrides' | 'auditLog'>;
    const times = this.db
      .prepare(
        `SELECT time_candidates.id, value, source, raw_value AS rawValue, precision, confidence,
                COALESCE(metadata_snapshots.extractor, 'scanner') AS extractor
         FROM time_candidates
         LEFT JOIN metadata_snapshots ON metadata_snapshots.id = time_candidates.snapshot_id
         WHERE time_candidates.media_file_id = ?
         ORDER BY confidence DESC, time_candidates.id`
      )
      .all(file.id) as Array<TimeCandidate & { id: number }>;
    const geos = this.db
      .prepare(
        `SELECT geo_candidates.id, latitude, longitude, source, raw_value AS rawValue, confidence,
                accuracy_m AS accuracyMeters, COALESCE(metadata_snapshots.extractor, 'scanner') AS extractor
         FROM geo_candidates
         LEFT JOIN metadata_snapshots ON metadata_snapshots.id = geo_candidates.snapshot_id
         WHERE geo_candidates.media_file_id = ?
         ORDER BY confidence DESC, geo_candidates.id`
      )
      .all(file.id) as Array<GeoCandidate & { id: number }>;
    const snapshots = this.db
      .prepare(
        `SELECT id, extractor, extractor_version AS extractorVersion, created_at AS createdAt
         FROM metadata_snapshots WHERE media_file_id = ? ORDER BY id`
      )
      .all(file.id) as FileDetails['snapshots'];

    return {
      ...file,
      times,
      geos,
      snapshots,
      overrides: this.activeOverrides(file.id),
      auditLog: this.auditEntries(file.id)
    };
  }
}
