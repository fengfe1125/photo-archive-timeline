#!/usr/bin/env node

import { createReadStream } from 'node:fs';
import { access, stat } from 'node:fs/promises';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { basename, extname, isAbsolute, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  MediaDatabase,
  type FileDetails,
  type TimelineQuery,
  type ActiveOverride
} from './database.js';
import { DerivativeService } from './derivatives.js';
import { exportArchive, type GpsPrivacy } from './exporter.js';
import { normalizeDateValue } from './metadata.js';

interface ServerOptions {
  dbPath: string;
  host: string;
  port: number;
}

const projectRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));
const publicRoot = resolve(projectRoot, 'public');
const exportRoot = resolve(projectRoot, 'data/exports');

function parseOptions(argv: string[]): ServerOptions {
  const options: Record<string, string> = {};
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (!value.startsWith('--')) continue;
    const name = value.slice(2);
    const next = argv[index + 1];
    if (next && !next.startsWith('--')) {
      options[name] = next;
      index += 1;
    }
  }

  const port = Number(options.port ?? 4310);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Invalid port: ${options.port}`);
  }

  return {
    dbPath: options.db ?? 'data/media.db',
    host: options.host ?? '127.0.0.1',
    port
  };
}

function sendJson(response: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body, null, 2);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store'
  });
  response.end(payload);
}

function sendText(response: ServerResponse, status: number, body: string): void {
  response.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' });
  response.end(body);
}

function mediaPath(location: { sourcePath: string; relativePath: string }): string {
  const sourceRoot = resolve(location.sourcePath);
  const filePath = resolve(sourceRoot, location.relativePath);
  const relativePath = relative(sourceRoot, filePath);
  if (isAbsolute(relativePath) || relativePath.startsWith('..')) {
    throw new Error(`Refusing to read a path outside source: ${location.relativePath}`);
  }
  return filePath;
}

function safeChildPath(root: string, childPath: string): string {
  const filePath = resolve(root, childPath);
  const relativePath = relative(root, filePath);
  if (isAbsolute(relativePath) || relativePath.startsWith('..')) {
    throw new Error('Refusing to read a path outside the export directory');
  }
  return filePath;
}

function contentTypeForStatic(pathname: string): string {
  switch (extname(pathname).toLowerCase()) {
    case '.html':
      return 'text/html; charset=utf-8';
    case '.js':
      return 'text/javascript; charset=utf-8';
    case '.css':
      return 'text/css; charset=utf-8';
    case '.json':
      return 'application/json; charset=utf-8';
    case '.txt':
      return 'text/plain; charset=utf-8';
    case '.svg':
      return 'image/svg+xml';
    case '.webp':
      return 'image/webp';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    default:
      return 'application/octet-stream';
  }
}

function contentTypeForDerivative(pathname: string): string {
  return extname(pathname).toLowerCase() === '.webp' ? 'image/webp' : 'image/jpeg';
}

async function serveFile(
  request: IncomingMessage,
  response: ServerResponse,
  filePath: string,
  contentType: string,
  cacheControl = 'private, max-age=3600'
): Promise<void> {
  const fileStat = await stat(filePath);
  const range = request.headers.range;
  let start = 0;
  let end = fileStat.size - 1;
  let status = 200;

  if (range) {
    const match = range.match(/^bytes=(\d*)-(\d*)$/);
    if (!match) {
      response.writeHead(416, { 'Content-Range': `bytes */${fileStat.size}` });
      response.end();
      return;
    }
    if (match[1]) start = Number(match[1]);
    if (match[2]) end = Number(match[2]);
    if (!match[1] && match[2]) {
      const suffixLength = Number(match[2]);
      start = Math.max(fileStat.size - suffixLength, 0);
      end = fileStat.size - 1;
    }
    end = Math.min(end, fileStat.size - 1);
    if (start < 0 || start > end || start >= fileStat.size) {
      response.writeHead(416, { 'Content-Range': `bytes */${fileStat.size}` });
      response.end();
      return;
    }
    status = 206;
  }

  const contentLength = end - start + 1;
  response.writeHead(status, {
    'Content-Type': contentType,
    'Content-Length': contentLength,
    'Accept-Ranges': 'bytes',
    'Cache-Control': cacheControl,
    ...(status === 206 ? { 'Content-Range': `bytes ${start}-${end}/${fileStat.size}` } : {})
  });

  if (request.method === 'HEAD') {
    response.end();
    return;
  }
  createReadStream(filePath, { start, end }).on('error', () => response.destroy()).pipe(response);
}

function publicDetails(details: FileDetails): Record<string, unknown> {
  const { sourcePath, ...safeDetails } = details;
  return { ...safeDetails, sourceName: basename(sourcePath) };
}

function parseInteger(value: string | null, fallback: number): number {
  if (!value) return fallback;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.floor(parsed) : fallback;
}

async function requestJson(request: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > 1024 * 1024) throw new Error('Request body is too large');
    chunks.push(buffer);
  }
  if (chunks.length === 0) return {};
  const parsed: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('JSON object required');
  return parsed as Record<string, unknown>;
}

function requiredString(value: unknown, name: string): string {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${name} is required`);
  return value.trim();
}

function optionalString(value: unknown): string | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  if (typeof value !== 'string') throw new Error('Expected a string or null');
  return value.trim();
}

function parseMediaId(value: string): number {
  const id = Number(value);
  if (!Number.isInteger(id) || id < 1) throw new Error('Invalid media id');
  return id;
}

function parseEventId(value: string): number {
  const id = Number(value);
  if (!Number.isInteger(id) || id < 1) throw new Error('Invalid event id');
  return id;
}

function parseTimeOverride(value: unknown): { value: string; precision: string } {
  const raw = typeof value === 'object' && value !== null && 'value' in value
    ? (value as { value?: unknown }).value
    : value;
  const normalized = normalizeDateValue(raw);
  if (!normalized) throw new Error('Invalid date; use YYYY-MM-DD or YYYY-MM-DDTHH:mm:ss');
  return normalized;
}

function parseGeoOverride(value: unknown): { latitude: number; longitude: number } {
  if (!value || typeof value !== 'object') throw new Error('GPS value must be an object');
  const object = value as { latitude?: unknown; longitude?: unknown };
  const latitude = Number(object.latitude);
  const longitude = Number(object.longitude);
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90) throw new Error('Latitude must be between -90 and 90');
  if (!Number.isFinite(longitude) || longitude < -180 || longitude > 180) throw new Error('Longitude must be between -180 and 180');
  return { latitude, longitude };
}

function parseOverrideField(body: Record<string, unknown>): {
  field: ActiveOverride['field'];
  value: unknown;
  reason: string;
} {
  const field = body.field;
  if (field !== 'time' && field !== 'geo' && field !== 'title' && field !== 'caption') {
    throw new Error('field must be time, geo, title, or caption');
  }
  const reason = typeof body.reason === 'string' && body.reason.trim() ? body.reason.trim() : 'manual';
  if (field === 'time') return { field, value: parseTimeOverride(body.value), reason };
  if (field === 'geo') return { field, value: parseGeoOverride(body.value), reason };
  return { field, value: optionalString(body.value) ?? '', reason };
}

function parsePrivacy(value: unknown): GpsPrivacy {
  if (value === undefined || value === 'omit') return 'omit';
  if (value === 'city' || value === 'precise') return value;
  throw new Error('gpsPrivacy must be omit, city, or precise');
}

function exportUrl(outputDir: string): string {
  const relativeDir = relative(exportRoot, outputDir);
  if (isAbsolute(relativeDir) || relativeDir.startsWith('..')) throw new Error('Invalid export path');
  return `/exports/${relativeDir.split(/[\\/]/).map(encodeURIComponent).join('/')}/index.html`;
}

async function handleRequest(
  request: IncomingMessage,
  response: ServerResponse,
  database: MediaDatabase,
  derivatives: DerivativeService
): Promise<void> {
  if (request.method !== 'GET' && request.method !== 'HEAD' && request.method !== 'POST' && request.method !== 'PATCH' && request.method !== 'DELETE') {
    sendJson(response, 405, { error: 'Unsupported method' });
    return;
  }

  const requestUrl = new URL(request.url ?? '/', 'http://localhost');
  const pathname = decodeURIComponent(requestUrl.pathname);

  if (request.method === 'GET' && pathname === '/api/stats') {
    sendJson(response, 200, database.stats());
    return;
  }

  if (request.method === 'GET' && pathname === '/api/timeline') {
    const query: TimelineQuery = {
      limit: parseInteger(requestUrl.searchParams.get('limit'), 60),
      offset: parseInteger(requestUrl.searchParams.get('offset'), 0),
      year: requestUrl.searchParams.get('year') ?? undefined,
      month: requestUrl.searchParams.get('month') ?? undefined
    };
    sendJson(response, 200, database.listTimeline(query));
    return;
  }

  if (pathname === '/api/events' && request.method === 'GET') {
    sendJson(response, 200, { events: database.listEvents() });
    return;
  }

  if (pathname === '/api/events' && request.method === 'POST') {
    const body = await requestJson(request);
    const eventId = database.createEvent({
      title: requiredString(body.title, 'title'),
      startDate: optionalString(body.startDate),
      endDate: optionalString(body.endDate),
      place: optionalString(body.place),
      description: optionalString(body.description)
    });
    sendJson(response, 201, database.getEvent(eventId));
    return;
  }

  const eventMatch = pathname.match(/^\/api\/events\/(\d+)(?:\/(assets|export)(?:\/(\d+))?)?$/);
  if (eventMatch) {
    const eventId = parseEventId(eventMatch[1]);
    const subresource = eventMatch[2];
    const assetId = eventMatch[3] ? parseMediaId(eventMatch[3]) : undefined;

    if (!subresource && request.method === 'GET') {
      const event = database.getEvent(eventId);
      if (!event) {
        sendJson(response, 404, { error: 'Event not found' });
        return;
      }
      sendJson(response, 200, event);
      return;
    }

    if (!subresource && request.method === 'PATCH') {
      const body = await requestJson(request);
      database.updateEvent(eventId, {
        title: body.title === undefined ? undefined : requiredString(body.title, 'title'),
        startDate: optionalString(body.startDate),
        endDate: optionalString(body.endDate),
        place: optionalString(body.place),
        description: optionalString(body.description),
        coverMediaFileId: body.coverMediaFileId === undefined ? undefined : (body.coverMediaFileId === null ? null : parseMediaId(String(body.coverMediaFileId)))
      });
      sendJson(response, 200, database.getEvent(eventId));
      return;
    }

    if (!subresource && request.method === 'DELETE') {
      database.deleteEvent(eventId);
      response.writeHead(204);
      response.end();
      return;
    }

    if (subresource === 'assets' && request.method === 'POST' && assetId === undefined) {
      const body = await requestJson(request);
      const mediaFileId = parseMediaId(String(body.mediaFileId));
      database.addEventAsset(eventId, mediaFileId, {
        sortOrder: body.sortOrder === undefined ? undefined : parseInteger(String(body.sortOrder), 0),
        caption: optionalString(body.caption)
      });
      sendJson(response, 201, database.getEvent(eventId));
      return;
    }

    if (subresource === 'assets' && assetId !== undefined && request.method === 'PATCH') {
      const body = await requestJson(request);
      database.updateEventAsset(eventId, assetId, {
        sortOrder: body.sortOrder === undefined ? undefined : parseInteger(String(body.sortOrder), 0),
        caption: body.caption === undefined ? undefined : optionalString(body.caption) ?? ''
      });
      sendJson(response, 200, database.getEvent(eventId));
      return;
    }

    if (subresource === 'assets' && assetId !== undefined && request.method === 'DELETE') {
      database.removeEventAsset(eventId, assetId);
      response.writeHead(204);
      response.end();
      return;
    }

    if (subresource === 'export' && request.method === 'POST') {
      const body = await requestJson(request);
      const result = await exportArchive(database, derivatives, {
        eventId,
        gpsPrivacy: parsePrivacy(body.gpsPrivacy)
      });
      sendJson(response, 201, { ...result, outputDir: undefined, url: exportUrl(result.outputDir) });
      return;
    }

    sendJson(response, 404, { error: 'Event route not found' });
    return;
  }

  if (pathname === '/api/export' && request.method === 'POST') {
    const body = await requestJson(request);
    const result = await exportArchive(database, derivatives, {
      gpsPrivacy: parsePrivacy(body.gpsPrivacy)
    });
    sendJson(response, 201, { ...result, outputDir: undefined, url: exportUrl(result.outputDir) });
    return;
  }

  const mediaMatch = pathname.match(/^\/api\/media\/(\d+)(?:\/(thumbnail|file|overrides\/undo))?$/);
  if (mediaMatch) {
    const fileId = parseMediaId(mediaMatch[1]);
    const action = mediaMatch[2];
    const location = database.getIndexedFileLocation(fileId);
    if (!location) {
      sendJson(response, 404, { error: 'Indexed media file not found' });
      return;
    }

    if (!action && request.method === 'GET') {
      const details = database.findFileDetails(String(fileId));
      if (!details) {
        sendJson(response, 404, { error: 'Media file not found' });
        return;
      }
      sendJson(response, 200, publicDetails(details));
      return;
    }

    if (!action && request.method === 'PATCH') {
      const body = await requestJson(request);
      const override = parseOverrideField(body);
      const saved = database.setOverride(fileId, override.field, override.value, override.reason);
      sendJson(response, 200, { override, saved, details: publicDetails(database.findFileDetails(String(fileId))!) });
      return;
    }

    if (action === 'overrides/undo' && request.method === 'POST') {
      const result = database.undoLastOverride(fileId);
      if (!result) {
        sendJson(response, 404, { error: 'No active override to undo' });
        return;
      }
      sendJson(response, 200, { ...result, details: publicDetails(database.findFileDetails(String(fileId))!) });
      return;
    }

    if (action === 'thumbnail' && request.method === 'GET') {
      const kind = location.mediaType === 'video' ? 'poster' : 'thumbnail';
      const derivative = await derivatives.ensure(fileId, kind);
      await serveFile(request, response, derivatives.outputPath(derivative), contentTypeForDerivative(derivative.relativePath));
      return;
    }

    if (action === 'file' && (request.method === 'GET' || request.method === 'HEAD')) {
      await serveFile(request, response, mediaPath(location), location.mimeType, 'private, max-age=3600');
      return;
    }

    sendJson(response, 405, { error: 'Unsupported media operation' });
    return;
  }

  if (pathname.startsWith('/exports/')) {
    const exportRelativePath = pathname.slice('/exports/'.length);
    try {
      const filePath = safeChildPath(exportRoot, exportRelativePath);
      await access(filePath);
      await serveFile(request, response, filePath, contentTypeForStatic(filePath), 'no-cache');
    } catch {
      sendText(response, 404, 'Export not found');
    }
    return;
  }

  if (request.method !== 'GET' && request.method !== 'HEAD') {
    sendJson(response, 404, { error: 'Not found' });
    return;
  }

  const relativePublicPath = pathname === '/' ? 'index.html' : pathname.replace(/^\//, '');
  try {
    const filePath = safeChildPath(publicRoot, relativePublicPath);
    await access(filePath);
    await serveFile(request, response, filePath, contentTypeForStatic(filePath), 'no-cache');
  } catch {
    sendText(response, 404, 'Not found');
  }
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  const database = new MediaDatabase(options.dbPath);
  const derivatives = new DerivativeService(database);
  const server = createServer((request, response) => {
    void handleRequest(request, response, database, derivatives).catch((error: unknown) => {
      console.error(error);
      if (!response.headersSent) sendJson(response, 400, { error: error instanceof Error ? error.message : String(error) });
      else response.destroy();
    });
  });

  server.listen(options.port, options.host, () => {
    console.log(`Photo archive timeline: http://${options.host}:${options.port}`);
    console.log(`Database: ${resolve(options.dbPath)}`);
  });

  void derivatives.processAll().then((summary) => {
    if (summary.queued > 0) console.log(`Derivatives: ${summary.processed} processed, ${summary.failed} failed`);
  }).catch((error: unknown) => console.error('Derivative preparation failed:', error));

  const shutdown = (): void => {
    server.close(() => {
      database.close();
      process.exit(0);
    });
  };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
