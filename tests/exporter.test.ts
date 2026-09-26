import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import sharp from 'sharp';
import { describe, expect, it } from 'vitest';
import { MediaDatabase } from '../src/database.js';
import { DerivativeService } from '../src/derivatives.js';
import { exportArchive } from '../src/exporter.js';

describe('exportArchive', () => {
  it('exports an event without absolute paths or precise GPS by default', async () => {
    const root = await mkdtemp(join(tmpdir(), 'photo-export-'));
    const database = new MediaDatabase(':memory:');
    try {
      const sourceId = database.getOrCreateSource(root);
      const image = await sharp({
        create: { width: 2, height: 2, channels: 3, background: { r: 200, g: 120, b: 80 } }
      }).jpeg().toBuffer();
      const mediaPath = join(root, 'IMG_0001.jpg');
      await writeFile(mediaPath, image);
      const fileId = database.upsertDiscoveredFile({
        sourceId,
        relativePath: 'IMG_0001.jpg',
        size: image.length,
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
        geoCandidates: [{
          extractor: 'exiftool',
          latitude: 31.23,
          longitude: 121.47,
          source: 'exif',
          rawValue: '{}',
          confidence: 1
        }],
        warnings: []
      });
      database.markIndexed(fileId, 'sha256-test');
      const eventId = database.createEvent({ title: 'Test export' });
      database.addEventAsset(eventId, fileId, { caption: 'A caption' });

      const derivatives = new DerivativeService(database, { rootDir: join(root, 'derivatives') });
      const result = await exportArchive(database, derivatives, {
        eventId,
        outputDir: join(root, 'exports'),
        gpsPrivacy: 'omit'
      });
      expect(result).toMatchObject({ assetCount: 1, skipped: 0, errors: [] });

      const manifestText = await readFile(join(result.outputDir, 'manifest.json'), 'utf8');
      const manifest = JSON.parse(manifestText) as { assets: Array<Record<string, unknown>> };
      expect(manifest.assets[0]).toMatchObject({
        sha256: 'sha256-test',
        latitude: null,
        longitude: null,
        caption: 'A caption'
      });
      expect(manifestText).not.toContain(root);
      expect((await readFile(join(result.outputDir, 'index.html'), 'utf8'))).not.toContain(root);
    } finally {
      database.close();
      await rm(root, { recursive: true, force: true });
    }
  });
});
