import { spawnSync } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { MediaDatabase } from '../src/database.js';
import { scanSource } from '../src/scanner.js';

const hasExiftool = spawnSync(process.env.EXIFTOOL_BIN ?? 'exiftool', ['-ver']).status === 0;
const onePixelJpeg = Buffer.from(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAH/AP/EABQQAQAAAAAAAAAAAAAAAAAAABD/2gAIAQEAAT8Af//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQMBAT8Af//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8Af//Z',
  'base64'
);

describe.skipIf(!hasExiftool)('scanSource integration', () => {
  it('indexes supported files and skips unchanged files on a second scan', async () => {
    const root = await mkdtemp(join(tmpdir(), 'photo-archive-'));
    const database = new MediaDatabase(':memory:');
    try {
      await writeFile(join(root, 'IMG_20240501_100000.jpg'), onePixelJpeg);
      await writeFile(join(root, 'notes.txt'), 'not media');

      const first = await scanSource(database, root);
      expect(first).toMatchObject({ discovered: 1, indexed: 1, skipped: 0, errors: 0 });
      expect(database.stats()).toMatchObject({ total: 1, indexed: 1, photos: 1 });

      const second = await scanSource(database, root);
      expect(second).toMatchObject({ discovered: 1, indexed: 0, skipped: 1, errors: 0 });
    } finally {
      database.close();
      await rm(root, { recursive: true, force: true });
    }
  });
});
