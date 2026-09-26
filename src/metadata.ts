import { basename } from 'node:path';
import { runCommand } from './process.js';
import type {
  CandidatePrecision,
  ExtractionResult,
  GeoCandidate,
  MediaType,
  MetadataSnapshotInput,
  TimeCandidate
} from './types.js';

export interface MetadataExtractionOptions {
  mediaType: MediaType;
  mtimeMs: number;
  exiftoolPath?: string;
  exiftoolVersion?: string;
  ffprobePath?: string;
  ffprobeVersion?: string;
}

interface MetadataRecord {
  [key: string]: unknown;
}

export interface NormalizedDate {
  value: string;
  precision: CandidatePrecision;
}

const DATE_FIELDS = [
  'DateTimeOriginal',
  'CreateDate',
  'DateCreated',
  'DateTimeCreated',
  'CreationDate',
  'ModifyDate'
];

function keyTail(key: string): string {
  return key.split(':').at(-1)?.toLowerCase() ?? key.toLowerCase();
}

function keyGroup(key: string): string {
  return key.split(':').at(0)?.toLowerCase() ?? '';
}

function stringValue(value: unknown): string | null {
  if (typeof value === 'string') return value.trim() || null;
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  return null;
}

function valuesMatching(record: MetadataRecord, names: string[]): Array<{ key: string; value: unknown }> {
  const wanted = new Set(names.map((name) => name.toLowerCase()));
  return Object.entries(record)
    .filter(([key, value]) => wanted.has(keyTail(key)) && value !== undefined && value !== null)
    .map(([key, value]) => ({ key, value }));
}

function sourceForDateKey(key: string): string {
  const group = keyGroup(key);
  if (group.includes('xmp')) return 'xmp';
  if (group.includes('quicktime') || group.includes('matroska') || group.includes('mpeg')) return 'quicktime';
  if (keyTail(key) === 'modifydate') return 'exif_modify_date';
  return 'exif';
}

function confidenceForDateSource(source: string): number {
  switch (source) {
    case 'exif':
      return 1;
    case 'xmp':
      return 0.95;
    case 'quicktime':
      return 0.9;
    case 'exif_modify_date':
      return 0.7;
    case 'ffprobe':
      return 0.85;
    case 'filename':
      return 0.45;
    case 'file_mtime':
      return 0.2;
    default:
      return 0.3;
  }
}

/**
 * Normalize common EXIF, XMP and QuickTime date forms without silently
 * converting a timezone-less camera date into the machine's timezone.
 */
export function normalizeDateValue(raw: unknown): NormalizedDate | null {
  const input = stringValue(raw);
  if (!input) return null;

  const match = input.match(
    /^(\d{4})[:\-](\d{2})[:\-](\d{2})(?:[ T](\d{2})(?::(\d{2}))?(?::(\d{2})(?:\.(\d+))?)?\s*(Z|[+\-]\d{2}:?\d{2})?)?/
  );
  if (!match) return null;

  const [, year, month, day, hour, minute, second, fraction, timezone] = match;
  const yearNumber = Number(year);
  const monthNumber = Number(month);
  const dayNumber = Number(day);
  if (monthNumber < 1 || monthNumber > 12 || dayNumber < 1 || dayNumber > 31) return null;

  const datePart = `${year}-${month}-${day}`;
  if (!hour) return { value: datePart, precision: 'day' };

  const hourNumber = Number(hour);
  const minuteNumber = Number(minute ?? 0);
  const secondNumber = Number(second ?? 0);
  if (hourNumber > 23 || minuteNumber > 59 || secondNumber > 59) return null;

  const timePart = `${hour.padStart(2, '0')}:${String(minuteNumber).padStart(2, '0')}:${String(secondNumber).padStart(2, '0')}`;
  const normalizedTimezone = timezone
    ? timezone === 'Z'
      ? 'Z'
      : timezone.replace(/([+\-]\d{2})(\d{2})$/, '$1:$2')
    : '';
  const normalizedFraction = fraction ? `.${fraction}` : '';
  const precision: CandidatePrecision = second || fraction ? 'exact' : 'minute';
  return {
    value: `${datePart}T${timePart}${normalizedFraction}${normalizedTimezone}`,
    precision
  };
}

function parseFilenameDate(filePath: string): NormalizedDate | null {
  const name = basename(filePath);
  const match = name.match(/(?:^|[^\d])(20\d{2})[-_]?([01]\d)[-_]?([0-3]\d)(?:[_-]?([0-2]\d)([0-5]\d)([0-5]\d))?(?:[^\d]|$)/);
  if (!match) return null;
  const [, year, month, day, hour, minute, second] = match;
  return normalizeDateValue(
    hour ? `${year}-${month}-${day} ${hour}:${minute}:${second}` : `${year}-${month}-${day}`
  );
}

function numberValue(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value !== 'string') return null;
  const normalized = value.trim().replace(',', '.');
  const parsed = Number(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

function coordinateWithReference(value: unknown, reference: unknown): number | null {
  const number = numberValue(value);
  if (number === null) return null;
  const ref = stringValue(reference)?.toUpperCase();
  if ((ref === 'S' || ref === 'W') && number > 0) return -number;
  return number;
}

function sanitizeExifRecord(record: MetadataRecord): MetadataRecord {
  return Object.fromEntries(
    Object.entries(record).filter(([key]) => keyTail(key) !== 'sourcefile')
  );
}

function addTimeCandidate(
  candidates: TimeCandidate[],
  candidate: Omit<TimeCandidate, 'confidence'> & { confidence?: number }
): void {
  if (candidates.some((item) => item.source === candidate.source && item.value === candidate.value)) return;
  candidates.push({
    ...candidate,
    confidence: candidate.confidence ?? confidenceForDateSource(candidate.source)
  });
}

function addExifCandidates(
  record: MetadataRecord,
  candidates: TimeCandidate[],
  geos: GeoCandidate[],
  versionedExtractor: string
): void {
  for (const { key, value } of valuesMatching(record, DATE_FIELDS)) {
    const normalized = normalizeDateValue(value);
    if (!normalized) continue;
    const source = sourceForDateKey(key);
    addTimeCandidate(candidates, {
      extractor: versionedExtractor,
      value: normalized.value,
      source,
      rawValue: String(value),
      precision: normalized.precision
    });
  }

  const latitudeEntry = valuesMatching(record, ['GPSLatitude'])[0];
  const longitudeEntry = valuesMatching(record, ['GPSLongitude'])[0];
  if (!latitudeEntry || !longitudeEntry) return;

  const latitude = coordinateWithReference(
    latitudeEntry.value,
    valuesMatching(record, ['GPSLatitudeRef'])[0]?.value
  );
  const longitude = coordinateWithReference(
    longitudeEntry.value,
    valuesMatching(record, ['GPSLongitudeRef'])[0]?.value
  );
  if (latitude === null || longitude === null || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) return;

  const source = keyGroup(latitudeEntry.key).includes('xmp') ? 'xmp' : 'exif';
  geos.push({
    extractor: versionedExtractor,
    latitude,
    longitude,
    source,
    rawValue: JSON.stringify({
      latitude: latitudeEntry.value,
      longitude: longitudeEntry.value,
      latitudeRef: valuesMatching(record, ['GPSLatitudeRef'])[0]?.value,
      longitudeRef: valuesMatching(record, ['GPSLongitudeRef'])[0]?.value
    }),
    confidence: source === 'exif' ? 1 : 0.85
  });
}

function addFfprobeDateCandidates(
  ffprobe: Record<string, unknown>,
  candidates: TimeCandidate[],
  extractor: string
): void {
  const values: unknown[] = [];
  const format = ffprobe.format;
  if (format && typeof format === 'object') {
    const tags = (format as { tags?: unknown }).tags;
    if (tags && typeof tags === 'object') {
      for (const [key, value] of Object.entries(tags)) {
        if (key.toLowerCase() === 'creation_time') values.push(value);
      }
    }
  }

  const streams = ffprobe.streams;
  if (Array.isArray(streams)) {
    for (const stream of streams) {
      if (!stream || typeof stream !== 'object') continue;
      const tags = (stream as { tags?: unknown }).tags;
      if (!tags || typeof tags !== 'object') continue;
      for (const [key, value] of Object.entries(tags)) {
        if (key.toLowerCase() === 'creation_time') values.push(value);
      }
    }
  }

  for (const value of values) {
    const normalized = normalizeDateValue(value);
    if (!normalized) continue;
    addTimeCandidate(candidates, {
      extractor,
      value: normalized.value,
      source: 'ffprobe',
      rawValue: String(value),
      precision: normalized.precision,
      confidence: confidenceForDateSource('ffprobe')
    });
  }
}

function getJsonRecord(stdout: string): MetadataRecord {
  const parsed: unknown = JSON.parse(stdout);
  if (!Array.isArray(parsed) || !parsed[0] || typeof parsed[0] !== 'object') return {};
  return parsed[0] as MetadataRecord;
}

export async function extractMetadata(
  filePath: string,
  options: MetadataExtractionOptions
): Promise<ExtractionResult> {
  const exiftoolPath = options.exiftoolPath ?? process.env.EXIFTOOL_BIN ?? 'exiftool';
  const ffprobePath = options.ffprobePath ?? process.env.FFPROBE_BIN ?? 'ffprobe';
  const snapshots: MetadataSnapshotInput[] = [];
  const timeCandidates: TimeCandidate[] = [];
  const geoCandidates: GeoCandidate[] = [];
  const warnings: Array<{ stage: string; message: string }> = [];

  const exifResult = await runCommand(exiftoolPath, [
    '-j',
    '-G1',
    '-s',
    '-n',
    '-api',
    'LargeFileSupport=1',
    filePath
  ]);
  const exifRecord = getJsonRecord(exifResult.stdout);
  const exifExtractor = 'exiftool';
  snapshots.push({
    extractor: exifExtractor,
    extractorVersion: options.exiftoolVersion,
    raw: sanitizeExifRecord(exifRecord)
  });
  addExifCandidates(exifRecord, timeCandidates, geoCandidates, exifExtractor);

  const filenameDate = parseFilenameDate(filePath);
  if (filenameDate) {
    addTimeCandidate(timeCandidates, {
      extractor: 'scanner',
      value: filenameDate.value,
      source: 'filename',
      rawValue: basename(filePath),
      precision: filenameDate.precision,
      confidence: confidenceForDateSource('filename')
    });
  }

  const fileMtime = new Date(options.mtimeMs).toISOString();
  addTimeCandidate(timeCandidates, {
    extractor: 'scanner',
    value: fileMtime,
    source: 'file_mtime',
    rawValue: String(options.mtimeMs),
    precision: 'exact',
    confidence: confidenceForDateSource('file_mtime')
  });

  if (options.mediaType === 'video') {
    try {
      const ffprobeResult = await runCommand(ffprobePath, [
        '-v',
        'error',
        '-print_format',
        'json',
        '-show_format',
        '-show_streams',
        filePath
      ]);
      const ffprobeRecord = JSON.parse(ffprobeResult.stdout) as Record<string, unknown>;
      const ffprobeExtractor = 'ffprobe';
      snapshots.push({
        extractor: ffprobeExtractor,
        extractorVersion: options.ffprobeVersion,
        raw: ffprobeRecord
      });
      addFfprobeDateCandidates(ffprobeRecord, timeCandidates, ffprobeExtractor);
    } catch (error) {
      warnings.push({
        stage: 'ffprobe',
        message: error instanceof Error ? error.message : String(error)
      });
    }
  }

  return { snapshots, timeCandidates, geoCandidates, warnings };
}
