import { describe, expect, it } from 'vitest';
import { normalizeDateValue } from '../src/metadata.js';

 describe('normalizeDateValue', () => {
  it('normalizes EXIF dates without a timezone', () => {
    expect(normalizeDateValue('2024:05:01 10:02:03')).toEqual({
      value: '2024-05-01T10:02:03',
      precision: 'exact'
    });
  });

  it('preserves an explicit timezone offset', () => {
    expect(normalizeDateValue('2024-05-01T10:02:03+0800')).toEqual({
      value: '2024-05-01T10:02:03+08:00',
      precision: 'exact'
    });
  });

  it('keeps date-only precision', () => {
    expect(normalizeDateValue('2024:05:01')).toEqual({
      value: '2024-05-01',
      precision: 'day'
    });
  });

  it('rejects malformed values', () => {
    expect(normalizeDateValue('not a date')).toBeNull();
    expect(normalizeDateValue('2024:99:99 40:80:80')).toBeNull();
  });
});
