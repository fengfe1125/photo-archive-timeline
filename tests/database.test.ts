import { describe, expect, it } from 'vitest';
import { MediaDatabase } from '../src/database.js';

function createDatabase(): MediaDatabase {
  return new MediaDatabase(':memory:');
}

describe('MediaDatabase', () => {
  it('creates an idempotent source and stores observations', () => {
    const database = createDatabase();
    try {
      const sourceId = database.getOrCreateSource('/tmp/photos');
      const sameSourceId = database.getOrCreateSource('/tmp/photos');
      expect(sameSourceId).toBe(sourceId);

      const fileId = database.upsertDiscoveredFile({
        sourceId,
        relativePath: 'IMG_0001.JPG',
        size: 12,
        mtimeMs: 1_700_000_000_000,
        mimeType: 'image/jpeg',
        mediaType: 'photo'
      });
      database.replaceObservations(fileId, {
        snapshots: [
          {
            extractor: 'exiftool',
            extractorVersion: '13.55',
            raw: { DateTimeOriginal: '2024:05:01 10:00:00' }
          }
        ],
        timeCandidates: [
          {
            extractor: 'exiftool',
            value: '2024-05-01T10:00:00',
            source: 'exif',
            rawValue: '2024:05:01 10:00:00',
            precision: 'exact',
            confidence: 1
          }
        ],
        geoCandidates: [
          {
            extractor: 'exiftool',
            latitude: 31.23,
            longitude: 121.47,
            source: 'exif',
            rawValue: '{"latitude":31.23,"longitude":121.47}',
            confidence: 1
          }
        ],
        warnings: []
      });
      database.markIndexed(fileId, 'abc123');

      expect(database.stats()).toMatchObject({
        sources: 1,
        total: 1,
        indexed: 1,
        photos: 1,
        videos: 0,
        withTime: 1,
        withGps: 1
      });
      expect(database.listTimeline({ year: '2024' })).toMatchObject({
        total: 1,
        items: [{ relativePath: 'IMG_0001.JPG', capturedAtSource: 'exif', thumbnailReady: false }]
      });
      expect(database.findFileDetails(String(fileId))).toMatchObject({
        relativePath: 'IMG_0001.JPG',
        sha256: 'abc123',
        times: [{ value: '2024-05-01T10:00:00', source: 'exif' }],
        geos: [{ latitude: 31.23, longitude: 121.47, source: 'exif' }]
      });
    } finally {
      database.close();
    }
  });

  it('applies reversible overrides and manages event assets', () => {
    const database = createDatabase();
    try {
      const sourceId = database.getOrCreateSource('/tmp/photos');
      const fileId = database.upsertDiscoveredFile({
        sourceId,
        relativePath: 'IMG_0002.JPG',
        size: 12,
        mtimeMs: 1_700_000_000_000,
        mimeType: 'image/jpeg',
        mediaType: 'photo'
      });
      database.replaceObservations(fileId, {
        snapshots: [{ extractor: 'exiftool', raw: {} }],
        timeCandidates: [{
          extractor: 'exiftool',
          value: '2024-05-01T10:00:00',
          source: 'exif',
          rawValue: '2024:05:01 10:00:00',
          precision: 'exact',
          confidence: 1
        }],
        geoCandidates: [],
        warnings: []
      });
      database.markIndexed(fileId, 'def456');

      database.setOverride(fileId, 'time', {
        value: '2024-06-02T11:00:00',
        precision: 'exact'
      }, 'camera clock correction');
      expect(database.listTimeline({ year: '2024' }).items[0]).toMatchObject({
        capturedAt: '2024-06-02T11:00:00',
        capturedAtSource: 'manual'
      });
      expect(database.undoLastOverride(fileId)).toMatchObject({
        field: 'time',
        restored: null
      });
      expect(database.listTimeline({ year: '2024' }).items[0]).toMatchObject({
        capturedAt: '2024-05-01T10:00:00',
        capturedAtSource: 'exif'
      });

      const eventId = database.createEvent({ title: 'Test trip', startDate: '2024-05-01' });
      database.addEventAsset(eventId, fileId, { caption: 'A caption' });
      expect(database.getEvent(eventId)).toMatchObject({
        title: 'Test trip',
        assetCount: 1,
        assets: [{ mediaFileId: fileId, caption: 'A caption' }]
      });
      database.updateEventAsset(eventId, fileId, { sortOrder: 2, caption: 'Updated caption' });
      expect(database.getEvent(eventId)?.assets[0]).toMatchObject({ sortOrder: 2, caption: 'Updated caption' });
    } finally {
      database.close();
    }
  });
});
