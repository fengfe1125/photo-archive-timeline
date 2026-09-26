#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { readFile, readdir, stat, mkdir, chmod } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { basename, join, relative, resolve, sep } from 'node:path';
import { tmpdir } from 'node:os';
import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import Database from 'better-sqlite3';
import sharp from 'sharp';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import * as tus from 'tus-js-client';
import { identifyMediaFile } from './file-types.js';
import { sha256File } from './hash.js';
import { extractMetadata } from './metadata.js';
import type { GeoCandidate, TimeCandidate } from './types.js';

const MAX_ORIGINAL = 50 * 1024 * 1024;
const BUCKET = 'archive-originals';
const PREVIEWS = 'archive-previews';
interface SourceItem {
  path: string;
  displayName: string;
  kind: 'photo' | 'video';
  mime: string;
  size: number;
  sha256: string;
  times: Array<Pick<TimeCandidate, 'value' | 'source' | 'precision' | 'confidence'>>;
  geos: Array<Pick<GeoCandidate, 'latitude' | 'longitude' | 'source' | 'confidence'>>;
}
interface Prepared { mediaID: string; objectPath: string; previewPath: string | null; status: 'pending' | 'ready'; duplicate: boolean }

function check<T>(value: { data: T; error: Error | null }): T {
  if (value.error) throw value.error;
  return value.data;
}
function uuidFor(owner: string, sha: string): string {
  const bytes = createHash('sha256').update(`${owner}:${sha}`).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const h = bytes.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
function config(): { url: string; key: string } {
  let url = process.env.SUPABASE_URL;
  let key = process.env.SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) {
    const text = requireLocalConfig();
    url ??= text.match(/^SUPABASE_URL\s*=\s*(.+)$/m)?.[1].trim().replace('https:/$()/', 'https://');
    key ??= text.match(/^SUPABASE_PUBLISHABLE_KEY\s*=\s*(.+)$/m)?.[1].trim();
  }
  if (!url?.startsWith('https://') || !key?.startsWith('sb_publishable_')) throw new Error('需要线上 SUPABASE_URL 和 publishable key');
  return { url, key };
}
function requireLocalConfig(): string {
  const file = resolve('ios/Local.xcconfig');
  try { return readFileSync(file, 'utf8'); }
  catch { return ''; }
}
async function login(client: SupabaseClient): Promise<string> {
  const rl = createInterface({ input: stdin, output: stdout });
  try {
    const email = (await rl.question('用于导入的 Supabase 账号邮箱：')).trim();
    if (!email) throw new Error('邮箱不能为空');
    check(await client.auth.signInWithOtp({ email }));
    const token = (await rl.question('请输入收到的 6 位验证码：')).trim();
    const result = check(await client.auth.verifyOtp({ email, token, type: 'email' }));
    if (!result.user || !result.session) throw new Error('未建立登录会话');
    return result.user.id;
  } finally { rl.close(); }
}
async function fromDatabase(filename: string): Promise<SourceItem[]> {
  const db = new Database(filename, { readonly: true, fileMustExist: true });
  try {
    const rows = db.prepare(`select mf.id, s.path source_path, mf.relative_path, mf.media_type,
      mf.mime_type, mf.size, mf.sha256 from media_files mf join sources s on s.id=mf.source_id
      where mf.status='indexed' order by mf.id`).all() as Array<Record<string, any>>;
    const timeQuery = db.prepare(`select value,source,precision,confidence from time_candidates
      where media_file_id=? order by confidence desc,id`);
    const geoQuery = db.prepare(`select latitude,longitude,source,confidence from geo_candidates
      where media_file_id=? order by confidence desc,id`);
    const result: SourceItem[] = [];
    for (const row of rows) {
      const root = resolve(row.source_path);
      const path = resolve(root, row.relative_path);
      const rel = relative(root, path);
      if (rel.startsWith('..') || rel.startsWith(sep)) throw new Error('源文件越过扫描目录');
      const info = await stat(path);
      if (info.size !== row.size || await sha256File(path) !== row.sha256) throw new Error(`源文件已改变：${row.id}`);
      result.push({ path, displayName: basename(path), kind: row.media_type,
        mime: row.mime_type, size: info.size, sha256: row.sha256,
        times: timeQuery.all(row.id) as SourceItem['times'], geos: geoQuery.all(row.id) as SourceItem['geos'] });
    }
    return result;
  } finally { db.close(); }
}
async function walk(root: string): Promise<string[]> {
  const items: string[] = [];
  for (const entry of await readdir(root, { withFileTypes: true })) {
    if (entry.isSymbolicLink()) continue;
    const path = join(root, entry.name);
    if (entry.isDirectory()) items.push(...await walk(path));
    else if (entry.isFile() && identifyMediaFile(path)) items.push(path);
  }
  return items;
}
async function fromDirectory(root: string): Promise<SourceItem[]> {
  const result: SourceItem[] = [];
  for (const path of await walk(resolve(root))) {
    const media = identifyMediaFile(path)!;
    const info = await stat(path);
    const sha256 = await sha256File(path);
    const extraction = await extractMetadata(path, { mediaType: media.mediaType, mtimeMs: info.mtimeMs });
    result.push({ path, displayName: basename(path), kind: media.mediaType, mime: media.mimeType,
      size: info.size, sha256,
      times: extraction.timeCandidates.map(({ value, source, precision, confidence }) => ({ value, source, precision, confidence })),
      geos: extraction.geoCandidates.map(({ latitude, longitude, source, confidence }) => ({ latitude, longitude, source, confidence })) });
  }
  return result;
}
function capturedAt(times: SourceItem['times']): string | null {
  const value = times[0]?.value;
  if (!value) return null;
  // Preserve the camera's wall-clock candidate separately; this is only a sortable approximation.
  return /^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T12:00:00Z` :
    /(?:Z|[+-]\d{2}:?\d{2})$/.test(value) ? value : `${value}Z`;
}
async function preview(item: SourceItem): Promise<Buffer | null> {
  try {
    if (item.kind === 'photo') return await sharp(item.path).rotate().resize(640, 640, { fit: 'inside', withoutEnlargement: true }).webp({ quality: 82 }).toBuffer();
    return null;
  } catch { return null; }
}
async function tusUpload(item: SourceItem, objectPath: string, accessToken: string, url: string, key: string, storage: any): Promise<void> {
  const project = new URL(url).hostname.split('.')[0];
  const input = await readFile(item.path);
  await new Promise<void>(async (resolveUpload, rejectUpload) => {
    const upload = new tus.Upload(input, {
      endpoint: `https://${project}.storage.supabase.co/storage/v1/upload/resumable`,
      headers: { authorization: `Bearer ${accessToken}`, apikey: key },
      uploadSize: input.byteLength,
      metadata: { bucketName: BUCKET, objectName: objectPath, contentType: item.mime, cacheControl: '3600' },
      chunkSize: 6 * 1024 * 1024, retryDelays: [0, 1000, 3000, 5000],
      fingerprint: async () => `${project}:${objectPath}:${item.sha256}`,
      urlStorage: storage,
      onError: rejectUpload,
      onSuccess: () => resolveUpload()
    });
    try {
      const previous = await upload.findPreviousUploads();
      if (previous[0]) upload.resumeFromPreviousUpload(previous[0]);
      upload.start();
    } catch (error) { rejectUpload(error); }
  });
}
async function importOne(client: SupabaseClient, owner: string, item: SourceItem, url: string, key: string, storage: any): Promise<string> {
  if (item.size > MAX_ORIGINAL) return '超过 50 MB，原片暂留本机';
  const { data: sameHash, error: lookupError } = await client.from('archive_media_assets')
    .select('media_id,status').eq('sha256', item.sha256).maybeSingle();
  if (lookupError) throw lookupError;
  if (sameHash?.status === 'ready') return '已存在相同原片';
  const mediaID = sameHash?.media_id ?? uuidFor(owner, item.sha256);
  if (!sameHash) {
    const pushed = check(await client.rpc('archive_push', { p_operation: {
      id: uuidFor(owner, `${item.sha256}:push`), entity: 'media', entityID: mediaID,
      baseVersion: 0, deleted: false, payload: { kind: item.kind }, resolving: null
    }}));
    if (pushed.status !== 'accepted' && pushed.status !== 'conflict') throw new Error(`媒体引用失败：${pushed.status}`);
  }
  const prepared = check(await client.rpc('archive_prepare_asset', {
    p_media_id: mediaID, p_sha256: item.sha256, p_bytes: item.size,
    p_mime_type: item.mime, p_display_name: item.displayName,
    p_captured_at: capturedAt(item.times), p_latitude: item.geos[0]?.latitude ?? null,
    p_longitude: item.geos[0]?.longitude ?? null, p_time_sources: item.times,
    p_geo_sources: item.geos
  })) as Prepared;
  if (prepared.status === 'ready') return '已完成';
  const sessionResult = await client.auth.getSession();
  if (sessionResult.error) throw sessionResult.error;
  const session = sessionResult.data.session;
  if (!session) throw new Error('登录会话已失效');
  try { await tusUpload(item, prepared.objectPath, session.access_token, url, key, storage); }
  catch (error) {
    const { data } = await client.storage.from(BUCKET).info(prepared.objectPath);
    if (!data) throw error;
  }
  const thumbnail = await preview(item);
  if (thumbnail) {
    const path = `${owner}/${prepared.mediaID}/preview.webp`;
    const uploaded = await client.storage.from(PREVIEWS).upload(path, thumbnail, { contentType: 'image/webp', upsert: false });
    if (uploaded.error && !/already exists/i.test(uploaded.error.message)) throw uploaded.error;
  }
  const downloaded = check(await client.storage.from(BUCKET).download(prepared.objectPath));
  if (!downloaded) throw new Error('云端下载失败');
  const remoteHash = createHash('sha256').update(Buffer.from(await downloaded.arrayBuffer())).digest('hex');
  if (remoteHash !== item.sha256) throw new Error('云端下载校验和不一致');
  check(await client.rpc('archive_complete_asset', { p_media_id: prepared.mediaID, p_preview: Boolean(thumbnail) }));
  return '已上传并校验';
}
async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const dryRun = args.includes('--dry-run');
  const dirAt = args.indexOf('--dir');
  const dbAt = args.indexOf('--db');
  if ((dirAt >= 0) === (dbAt >= 0)) throw new Error('用法：cloud-import --dir <目录> 或 --db <旧 SQLite> [--dry-run]');
  const source = args[(dirAt >= 0 ? dirAt : dbAt) + 1];
  if (!source) throw new Error('缺少目录或 SQLite 路径');
  const items = dirAt >= 0 ? await fromDirectory(source) : await fromDatabase(source);
  const bytes = items.reduce((sum, item) => sum + item.size, 0);
  console.log(JSON.stringify({ count: items.length, bytes, oversized: items.filter(item => item.size > MAX_ORIGINAL).length }));
  if (dryRun) return;
  const { url, key } = config();
  const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: true } });
  const owner = await login(client);
  const stateDir = join(tmpdir(), `photoarchive-upload-${createHash('sha256').update(owner).digest('hex').slice(0, 16)}`);
  await mkdir(stateDir, { recursive: true, mode: 0o700 });
  await chmod(stateDir, 0o700);
  // tus-js-client's Node FileUrlStorage stores only resumable upload URLs, not credentials.
  const FileUrlStorage = (tus as unknown as { FileUrlStorage: new(path: string) => any }).FileUrlStorage;
  const storage = new FileUrlStorage(join(stateDir, 'urls.json'));
  let completed = 0;
  for (const item of items) {
    const result = await importOne(client, owner, item, url, key, storage);
    completed++;
    console.log(`${completed}/${items.length} ${item.displayName}: ${result}`);
  }
  await client.auth.signOut();
}
main().catch(error => { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1; });
