export type MediaType = 'photo' | 'video';

export type CandidatePrecision = 'exact' | 'minute' | 'day' | 'unknown';

export interface TimeCandidate {
  extractor: string;
  value: string;
  source: string;
  rawValue: string;
  precision: CandidatePrecision;
  confidence: number;
}

export interface GeoCandidate {
  extractor: string;
  latitude: number;
  longitude: number;
  source: string;
  rawValue: string;
  confidence: number;
  accuracyMeters?: number;
}

export interface MetadataSnapshotInput {
  extractor: string;
  extractorVersion?: string;
  raw: unknown;
}

export interface ExtractionResult {
  snapshots: MetadataSnapshotInput[];
  timeCandidates: TimeCandidate[];
  geoCandidates: GeoCandidate[];
  warnings: Array<{ stage: string; message: string }>;
}

export interface DiscoveredFile {
  sourceId: number;
  relativePath: string;
  size: number;
  mtimeMs: number;
  mimeType: string;
  mediaType: MediaType;
}

export interface ScanSummary {
  sourcePath: string;
  discovered: number;
  indexed: number;
  skipped: number;
  errors: number;
  warnings: number;
  missing: number;
}
