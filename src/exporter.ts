import { copyFile, mkdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { MediaDatabase, type EventDetails, type TimelineItem } from './database.js';
import { DerivativeService } from './derivatives.js';

export type GpsPrivacy = 'omit' | 'city' | 'precise';

export interface ExportOptions {
  eventId?: number;
  outputDir?: string;
  gpsPrivacy?: GpsPrivacy;
}

export interface ExportAsset {
  id: number;
  fileName: string | null;
  mediaType: string;
  relativePath: string;
  size: number;
  sha256: string | null;
  capturedAt: string | null;
  capturedAtSource: string | null;
  caption: string | null;
  latitude: number | null;
  longitude: number | null;
  geoSource: string | null;
}

export interface ExportResult {
  outputDir: string;
  scope: 'event' | 'timeline';
  eventId?: number;
  assetCount: number;
  skipped: number;
  errors: string[];
}

interface ExportDocument {
  title: string;
  startDate: string | null;
  endDate: string | null;
  place: string | null;
  description: string | null;
  assets: ExportAsset[];
}

function escapeHtml(value: unknown): string {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function escapeCsv(value: unknown): string {
  const text = String(value ?? '');
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function slugify(value: string): string {
  const slug = value
    .normalize('NFKD')
    .replace(/[^\p{Letter}\p{Number}]+/gu, '-')
    .replace(/^-+|-+$/g, '')
    .toLowerCase();
  return slug || 'archive';
}

function privacyCoordinate(value: number | null, privacy: GpsPrivacy): number | null {
  if (value === null || privacy === 'omit') return null;
  if (privacy === 'city') return Math.round(value * 100) / 100;
  return value;
}

function formatDate(value: string | null): string {
  return value ? value.replace('T', ' ').replace(/([+-]\d{2}:?\d{2}|Z)$/, '') : '时间未知';
}

function documentFromEvent(event: EventDetails): ExportDocument {
  return {
    title: event.title,
    startDate: event.startDate,
    endDate: event.endDate,
    place: event.place,
    description: event.description,
    assets: event.assets
      .filter((asset): asset is typeof asset & { item: TimelineItem } => asset.item !== null)
      .map((asset) => ({
        id: asset.item.id,
        fileName: null,
        mediaType: asset.item.mediaType,
        relativePath: asset.item.relativePath,
        size: asset.item.size,
        sha256: asset.item.sha256,
        capturedAt: asset.item.capturedAt,
        capturedAtSource: asset.item.capturedAtSource,
        caption: asset.caption,
        latitude: asset.item.latitude,
        longitude: asset.item.longitude,
        geoSource: asset.item.geoSource
      }))
  };
}

async function documentFromTimeline(database: MediaDatabase): Promise<ExportDocument> {
  const items: TimelineItem[] = [];
  let offset = 0;
  while (true) {
    const page = database.listTimeline({ limit: 200, offset });
    items.push(...page.items);
    offset += page.items.length;
    if (items.length >= page.total || page.items.length === 0) break;
  }
  return {
    title: '摄影档案时间线',
    startDate: items[0]?.capturedAt ?? null,
    endDate: items.at(-1)?.capturedAt ?? null,
    place: null,
    description: '由摄影档案时间线生成的静态媒体归档。',
    assets: items.map((item) => ({
      id: item.id,
      fileName: null,
      mediaType: item.mediaType,
      relativePath: item.relativePath,
      size: item.size,
      sha256: item.sha256,
      capturedAt: item.capturedAt,
      capturedAtSource: item.capturedAtSource,
      caption: null,
      latitude: item.latitude,
      longitude: item.longitude,
      geoSource: item.geoSource
    }))
  };
}

function renderHtml(document: ExportDocument, privacy: GpsPrivacy): string {
  const assetMarkup = document.assets.map((asset) => {
    if (!asset.fileName) return '';
    const media = asset.mediaType === 'video'
      ? `<div class="video-poster"><img src="${escapeHtml(asset.fileName)}" alt="视频封面" /><span>视频</span></div>`
      : `<img src="${escapeHtml(asset.fileName)}" alt="${escapeHtml(asset.relativePath)}" loading="lazy" />`;
    const location = asset.latitude === null || privacy === 'omit'
      ? ''
      : `<span>${privacy === 'city' ? '约略位置' : 'GPS'} · ${asset.latitude.toFixed(2)}, ${asset.longitude?.toFixed(2) ?? ''}</span>`;
    return `<figure>
      ${media}
      <figcaption>
        <strong>${escapeHtml(formatDate(asset.capturedAt))}</strong>
        <span>${escapeHtml(asset.caption || asset.relativePath)}</span>
        ${location}
      </figcaption>
    </figure>`;
  }).join('\n');

  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${escapeHtml(document.title)}</title>
<style>
:root { color-scheme: light; --ink:#27231f; --muted:#82766b; --paper:#f5f0e9; --card:#fffdf9; --line:#ded5ca; --accent:#bf5b3e; font-family:system-ui,-apple-system,"Segoe UI",sans-serif; }
* { box-sizing:border-box; } body { margin:0; color:var(--ink); background:var(--paper); }
header { padding:clamp(42px,8vw,100px) max(22px,calc((100vw - 1100px)/2)) 50px; background:#e8ded2; border-bottom:1px solid var(--line); }
.eyebrow { margin:0 0 12px; color:var(--accent); font-size:11px; letter-spacing:.16em; text-transform:uppercase; }
h1 { max-width:800px; margin:0; font:500 clamp(36px,7vw,76px)/1.05 Georgia,serif; letter-spacing:-.05em; }
.meta { margin:18px 0 0; color:var(--muted); } .description { max-width:620px; margin:18px 0 0; line-height:1.7; }
main { width:min(1100px,calc(100% - 44px)); margin:0 auto; padding:42px 0 80px; }
.grid { columns:3 260px; column-gap:16px; } figure { break-inside:avoid; margin:0 0 16px; background:var(--card); border:1px solid var(--line); }
figure img { display:block; width:100%; height:auto; } figcaption { display:grid; gap:4px; padding:12px; color:var(--muted); font-size:12px; } figcaption strong { color:var(--ink); font-size:13px; } figcaption span { overflow-wrap:anywhere; }
.video-poster { position:relative; } .video-poster span { position:absolute; top:10px; left:10px; padding:4px 7px; color:white; background:#27231fcc; font-size:11px; }
.empty { padding:70px 20px; color:var(--muted); text-align:center; } footer { margin-top:40px; color:var(--muted); font-size:11px; }
</style>
</head>
<body>
<header><p class="eyebrow">PHOTO ARCHIVE · STATIC EXPORT</p><h1>${escapeHtml(document.title)}</h1>
<p class="meta">${escapeHtml(document.startDate ? formatDate(document.startDate) : '')}${document.endDate ? ` — ${escapeHtml(formatDate(document.endDate))}` : ''}${document.place ? ` · ${escapeHtml(document.place)}` : ''}</p>
${document.description ? `<p class="description">${escapeHtml(document.description)}</p>` : ''}</header>
<main><section class="grid">${assetMarkup || '<div class="empty">这个归档中没有可展示的派生文件。</div>'}</section>
<footer>由摄影档案时间线 v0.4 导出 · GPS 隐私策略：${escapeHtml(privacy)}</footer></main>
</body></html>`;
}

function renderCsv(assets: ExportAsset[]): string {
  const header = ['id', 'relative_path', 'media_type', 'size', 'sha256', 'captured_at', 'captured_at_source', 'caption', 'latitude', 'longitude', 'geo_source'];
  const rows = assets.map((asset) => [
    asset.id,
    asset.relativePath,
    asset.mediaType,
    asset.size,
    asset.sha256,
    asset.capturedAt,
    asset.capturedAtSource,
    asset.caption,
    asset.latitude,
    asset.longitude,
    asset.geoSource
  ]);
  return [header, ...rows].map((row) => row.map(escapeCsv).join(',')).join('\n') + '\n';
}

export async function exportArchive(
  database: MediaDatabase,
  derivatives: DerivativeService,
  options: ExportOptions = {}
): Promise<ExportResult> {
  const privacy = options.gpsPrivacy ?? 'omit';
  if (options.eventId === undefined && privacy === 'precise') {
    // Precise GPS is an explicit option. It remains available for local export,
    // but callers must opt in rather than inherit it from an event.
  }

  const event = options.eventId === undefined ? undefined : database.getEvent(options.eventId);
  if (options.eventId !== undefined && !event) throw new Error(`Event not found: ${options.eventId}`);
  const document = event ? documentFromEvent(event) : await documentFromTimeline(database);
  const scope = event ? 'event' : 'timeline';
  const scopeId = event ? `${event.id}-` : '';
  const outputParent = resolve(options.outputDir ?? 'data/exports');
  const outputDir = resolve(outputParent, `${scope}-${scopeId}${slugify(document.title)}`);
  const temporaryDir = `${outputDir}.tmp-${process.pid}`;
  const assetsDir = join(temporaryDir, 'assets');
  await rm(temporaryDir, { recursive: true, force: true });
  await mkdir(assetsDir, { recursive: true });

  const exportedAssets: ExportAsset[] = [];
  const errors: string[] = [];
  let skipped = 0;

  for (const asset of document.assets) {
    const safeAsset: ExportAsset = {
      ...asset,
      latitude: privacyCoordinate(asset.latitude, privacy),
      longitude: privacyCoordinate(asset.longitude, privacy)
    };
    const kind = asset.mediaType === 'video' ? 'poster' : 'thumbnail';
    try {
      const derivative = await derivatives.ensure(asset.id, kind);
      const sourceDerivativePath = derivatives.outputPath(derivative);
      await stat(sourceDerivativePath);
      const extension = kind === 'poster' ? 'jpg' : 'webp';
      safeAsset.fileName = `assets/${String(exportedAssets.length + 1).padStart(4, '0')}-${asset.id}.${extension}`;
      await copyFile(sourceDerivativePath, join(temporaryDir, safeAsset.fileName));
      exportedAssets.push(safeAsset);
    } catch (error) {
      skipped += 1;
      const message = error instanceof Error ? error.message : String(error);
      errors.push(`${asset.relativePath}: ${message}`);
    }
  }

  const manifest = {
    exportVersion: '0.4',
    generatedAt: new Date().toISOString(),
    scope,
    eventId: options.eventId ?? null,
    privacy: { gps: privacy, absolutePaths: 'omitted', originalMedia: 'not-copied' },
    title: document.title,
    startDate: document.startDate,
    endDate: document.endDate,
    place: document.place,
    description: document.description,
    assets: exportedAssets
  };
  await writeFile(join(temporaryDir, 'index.html'), renderHtml({ ...document, assets: exportedAssets }, privacy));
  await writeFile(join(temporaryDir, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  await writeFile(join(temporaryDir, 'media.csv'), renderCsv(exportedAssets));
  await writeFile(
    join(temporaryDir, 'README.txt'),
    `摄影档案时间线静态导出\n\n标题：${document.title}\n导出版本：0.4\nGPS 策略：${privacy}\n原始媒体：未复制，仅导出缩略图/视频封面\n\n打开 index.html，或运行 python3 -m http.server 8000。\n${errors.length ? `\n未能生成的媒体：\n${errors.map((error) => `- ${error}`).join('\n')}\n` : ''}`
  );

  await rm(outputDir, { recursive: true, force: true });
  await rename(temporaryDir, outputDir);
  return {
    outputDir,
    scope,
    eventId: options.eventId,
    assetCount: exportedAssets.length,
    skipped,
    errors
  };
}
