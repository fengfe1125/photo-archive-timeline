import { createClient } from '@supabase/supabase-js';
import { zipSync, strToU8 } from 'fflate';

const supabase = createClient(__SUPABASE_URL__, __SUPABASE_KEY__);
const $ = selector => document.querySelector(selector);
const esc = value => String(value ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#039;');
const state = { owner: null, media: [], stories: [], corrections: new Map(), captions: [], map: null, markers: [], loadedAt: 0 };
const mediaByID = () => new Map(state.media.map(item => [item.id, item]));
function fail(error) { alert(error?.message ?? String(error)); }
function authMessage(text) { $('#authMessage').textContent = text; }
async function rows(table, query = q => q) {
  const result = [];
  for (let start = 0; ; start += 500) {
    const response = await query(supabase.from(table).select('*')).range(start, start + 499);
    if (response.error) throw response.error;
    result.push(...response.data);
    if (response.data.length < 500) break;
  }
  return result;
}
async function signedURLs(bucket, paths) {
  const map = new Map();
  for (let i = 0; i < paths.length; i += 100) {
    const batch = paths.slice(i, i + 100);
    if (!batch.length) continue;
    const response = await supabase.storage.from(bucket).createSignedUrls(batch, 900);
    if (response.error) throw response.error;
    for (const item of response.data) if (item.signedUrl) map.set(item.path, item.signedUrl);
  }
  return map;
}
function bestDate(item) { return item.asset?.time_sources?.[0]?.value ?? item.asset?.captured_at ?? null; }
function dateLabel(value) { return value ? String(value).replace('T', ' ').replace(/(Z|[+-]\d{2}:?\d{2})$/, '') : '时间未知'; }
function dayLabel(value) { if (!value) return '待确认时间'; const [y,m,d] = value.split('-'); return `${y} 年 ${Number(m)} 月 ${Number(d)} 日`; }
function bytesLabel(n) { return n == null ? '原片未上传' : n < 1048576 ? `${(n / 1024).toFixed(1)} KB` : `${(n / 1048576).toFixed(1)} MB`; }
function storyFromRow(row, extras) {
  return { id: row.id, version: row.version, title: row.payload.title,
    description: row.payload.description ?? '', mediaIDs: row.payload.mediaIDs ?? [],
    coverID: row.payload.coverID ?? null, startDate: extras?.start_day ?? '',
    endDate: extras?.end_day ?? '', place: extras?.place ?? '', extrasVersion: extras?.version ?? 0 };
}
async function load() {
  if (!state.owner) return;
  $('#timeline').innerHTML = '<div class="loading-state">正在读取云端档案……</div>';
  const [mediaRows, assets, storyRows, extras, captions, corrections] = await Promise.all([
    rows('archive_media'), rows('archive_media_assets'), rows('archive_stories', q => q.eq('deleted', false)),
    rows('archive_story_extras'), rows('archive_story_captions'), rows('archive_corrections', q => q.eq('deleted', false))
  ]);
  if (!state.owner) return;
  const assetsByID = new Map(assets.map(asset => [asset.media_id, asset]));
  const previewURLs = await signedURLs('archive-previews', assets.filter(a => a.status === 'ready' && a.preview_path).map(a => a.preview_path));
  const originalURLs = await signedURLs('archive-originals', assets.filter(a => a.status === 'ready').map(a => a.object_path));
  state.media = mediaRows.map(media => {
    const asset = assetsByID.get(media.id) ?? null;
    return { id: media.id, kind: media.kind, asset,
      preview: asset?.preview_path ? previewURLs.get(asset.preview_path) : media.kind === 'photo' ? originalURLs.get(asset?.object_path) : null,
      original: originalURLs.get(asset?.object_path) ?? null,
      name: asset?.display_name ?? '原片尚未上传' };
  }).sort((a,b) => String(bestDate(b) ?? '').localeCompare(String(bestDate(a) ?? '')));
  const extrasByID = new Map(extras.map(item => [item.story_id, item]));
  state.stories = storyRows.map(row => storyFromRow(row, extrasByID.get(row.id)));
  state.captions = captions;
  state.corrections = new Map(corrections.map(row => [row.id, row]));
  state.loadedAt = Date.now();
  renderStats(); renderTimeline(); renderStories();
}
function renderStats() {
  const ready = state.media.filter(m => m.asset?.status === 'ready');
  const gps = ready.filter(m => m.asset.latitude != null);
  $('#stats').innerHTML = `<div class="stat-card"><span>云端媒体</span><strong>${ready.length}</strong></div>
    <div class="stat-card"><span>照片</span><strong>${ready.filter(m => m.kind === 'photo').length}</strong></div>
    <div class="stat-card"><span>视频</span><strong>${ready.filter(m => m.kind === 'video').length}</strong></div>
    <div class="stat-card"><span>GPS 覆盖</span><strong>${gps.length}</strong></div>`;
}
function renderMap(items) {
  const points = items.filter(m => m.asset?.latitude != null && m.asset?.longitude != null);
  $('#mapSummary').textContent = `${points.length} 个媒体包含位置数据`;
  if (!window.L) { $('#map').textContent = points.length ? '地图暂不可用，时间轴仍可使用。' : '当前没有地点数据。'; return; }
  if (!state.map) {
    $('#map').innerHTML = '';
    state.map = window.L.map('map', { scrollWheelZoom: false });
    window.L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '&copy; OpenStreetMap contributors' }).addTo(state.map);
  }
  state.markers.forEach(marker => marker.remove()); state.markers = [];
  if (!points.length) { state.map.setView([35,105],3); return; }
  for (const item of points) state.markers.push(window.L.marker([item.asset.latitude,item.asset.longitude]).addTo(state.map).bindPopup(esc(item.name)));
  state.map.fitBounds(points.map(m => [m.asset.latitude,m.asset.longitude]), { padding:[24,24], maxZoom:12 });
  setTimeout(() => state.map.invalidateSize(), 50);
}
function renderTimeline() {
  const year = $('#yearFilter').value;
  const month = $('#monthFilter').value;
  const dated = state.media.map(item => ({ item, day: bestDate(item)?.slice(0,10) ?? '' }));
  const years = [...new Set(dated.map(x => x.day.slice(0,4)).filter(Boolean))].sort().reverse();
  $('#yearFilter').innerHTML = `<option value="">全部年份</option>${years.map(y => `<option value="${esc(y)}">${esc(y)}</option>`).join('')}`;
  $('#yearFilter').value = years.includes(year) ? year : '';
  const filtered = dated.filter(x => (!year || x.day.startsWith(year)) && (!month || x.day.startsWith(month)));
  $('#resultSummary').textContent = `显示 ${filtered.length} / ${state.media.length} 个媒体`;
  renderMap(filtered.map(x => x.item));
  const groups = new Map();
  for (const entry of filtered) { const day = entry.day || 'unknown'; if (!groups.has(day)) groups.set(day, []); groups.get(day).push(entry.item); }
  $('#timeline').innerHTML = groups.size ? [...groups].map(([day, items]) => `<section class="day-group"><div class="day-heading"><h3>${esc(dayLabel(day === 'unknown' ? '' : day))}</h3><span>${items.length} 个媒体</span></div><div class="media-grid">${items.map(item => `<button class="media-card" data-id="${item.id}" type="button"><div class="media-preview">${item.preview ? `<img src="${esc(item.preview)}" alt="${esc(item.name)}" loading="lazy" />` : '<div class="media-missing">原片未上传</div>'}${item.kind === 'video' ? '<span class="media-type-badge">视频</span>' : ''}</div><div class="media-caption"><span>${esc(item.name)}</span><span class="media-time">${esc(dateLabel(bestDate(item)))}</span></div></button>`).join('')}</div></section>`).join('') : '<div class="empty-state">还没有媒体。可从电脑手动导入，或在 iPhone 开启原片同步。</div>';
  $('#timeline').querySelectorAll('[data-id]').forEach(button => button.onclick = () => openMedia(button.dataset.id));
  $('#timeline').querySelectorAll('.media-preview img').forEach(image => { image.onerror = () => { image.parentElement.innerHTML = '<div class="media-missing">云端预览缺失</div>'; }; });
}
function renderStories() {
  $('#eventsList').innerHTML = state.stories.length ? state.stories.map(story => `<article class="event-card"><button class="event-open" data-story="${story.id}" type="button"><span class="event-title">${esc(story.title)}</span><span class="event-meta">${esc(story.startDate || '日期待补充')}${story.place ? ` · ${esc(story.place)}` : ''}</span><span class="event-count">${story.mediaIDs.length} 个媒体</span></button><button class="event-export" data-export="${story.id}" type="button">导出</button></article>`).join('') : '<p class="muted">还没有故事。</p>';
  $('#eventsList').querySelectorAll('[data-story]').forEach(button => button.onclick = () => openStory(button.dataset.story));
  $('#eventsList').querySelectorAll('[data-export]').forEach(button => button.onclick = () => exportArchive(button.dataset.export));
}
function openModal(html) { $('#detailContent').innerHTML = html; $('#detailModal').classList.remove('hidden'); }
function closeModal() { $('#detailModal').classList.add('hidden'); }
function correctionPayload(id, day, place, description) {
  const old = state.corrections.get(id)?.payload ?? {};
  const payload = { description: description ?? old.description ?? '', dayMode: day ? 'value' : 'original', placeMode: place ? 'value' : 'original' };
  if (day) { const [year,month,date] = day.split('-').map(Number); payload.day = { year, month, day: date }; }
  if (place) payload.place = place;
  return payload;
}
async function push(entity, id, payload, deleted = false, version = 0) {
  const response = await supabase.rpc('archive_push', { p_operation: {
    id: crypto.randomUUID(), entity, entityID: id, baseVersion: version,
    deleted, payload, resolving: null
  }});
  if (response.error) throw response.error;
  if (response.data.status !== 'accepted') throw new Error('云端内容已变化，请刷新并检查冲突');
  return response.data;
}
function candidateList(list, type) {
  return list?.length ? `<ul class="candidate-list">${list.map(c => `<li><span>${esc(type === 'time' ? dateLabel(c.value) : `${c.latitude}, ${c.longitude}`)}</span><em>${esc(c.source)} · ${Math.round(c.confidence * 100)}%</em></li>`).join('')}</ul>` : '<p class="muted">没有记录</p>';
}
async function openMedia(id) {
  const item = mediaByID().get(id); if (!item) return;
  const correction = state.corrections.get(id);
  const payload = correction?.payload ?? {};
  const day = payload.dayMode === 'value' ? `${payload.day.year}-${String(payload.day.month).padStart(2,'0')}-${String(payload.day.day).padStart(2,'0')}` : '';
  const place = payload.placeMode === 'value' ? payload.place : null;
  const media = item.original ? item.kind === 'video' ? `<video src="${esc(item.original)}" controls preload="metadata"></video>` : `<img src="${esc(item.original)}" alt="${esc(item.name)}" />` : '<div class="media-missing">原片尚未上传；故事与整理信息仍可查看。</div>';
  openModal(`<div class="detail-preview">${media}</div><div class="detail-info"><h2 id="detailTitle">${esc(item.name)}</h2><p>${esc(bytesLabel(item.asset?.bytes))} · ${esc(item.asset?.sha256?.slice(0,16) ?? '')}</p>${item.original ? '<button id="downloadOriginal" class="quiet-button">下载原片</button>' : ''}<div class="detail-columns"><div><h3>时间来源</h3>${candidateList(item.asset?.time_sources,'time')}</div><div><h3>地点来源</h3>${candidateList(item.asset?.geo_sources,'geo')}</div></div><div class="story-edit"><h3>整理修正</h3><label>日期<input id="editDay" type="date" value="${esc(day)}" /></label><label>地点名称<input id="editPlace" value="${esc(place?.name ?? '')}" /></label><label>纬度<input id="editLat" type="number" step="any" value="${esc(place?.latitude ?? '')}" /></label><label>经度<input id="editLon" type="number" step="any" value="${esc(place?.longitude ?? '')}" /></label><label>描述<textarea id="editDescription">${esc(payload.description ?? '')}</textarea></label><button id="saveCorrection" class="accent-button">保存修正</button><button id="undoCorrection" class="quiet-button" ${correction ? '' : 'disabled'}>恢复原始信息</button></div><div class="event-add-panel"><h3>加入故事</h3><select id="chooseStory"><option value="">选择故事</option>${state.stories.map(s => `<option value="${s.id}">${esc(s.title)}</option>`).join('')}</select><input id="caption" placeholder="单张说明（可选）" /><button id="addStory" class="accent-button">加入</button></div></div>`);
  const downloadButton = $('#downloadOriginal');
  if (downloadButton) downloadButton.onclick = async () => { try {
    const signed = await supabase.storage.from('archive-originals').createSignedUrl(item.asset.object_path, 300);
    if (signed.error) throw signed.error;
    const response = await fetch(signed.data.signedUrl);
    if (!response.ok) throw new Error('云端原片不可读取，请在原设备重试上传');
    const href = URL.createObjectURL(await response.blob());
    const link = document.createElement('a'); link.href = href; link.download = item.name;
    link.click(); setTimeout(() => URL.revokeObjectURL(href), 60000);
  } catch (error) { fail(error); } };
  const shownMedia = $('#detailContent .detail-preview img, #detailContent .detail-preview video');
  if (shownMedia) shownMedia.onerror = () => { shownMedia.parentElement.innerHTML = '<div class="media-missing">云端原片缺失，请在原设备重试上传。</div>'; };
  $('#saveCorrection').onclick = async () => { try {
    const dayValue = $('#editDay').value;
    const placeName = $('#editPlace').value.trim();
    const lat = $('#editLat').value, lon = $('#editLon').value;
    if (Boolean(lat) !== Boolean(lon)) throw new Error('经纬度需要同时填写');
    const placeValue = placeName || lat ? { name: placeName || '手动坐标' } : null;
    if (placeValue && lat) { placeValue.latitude = Number(lat); placeValue.longitude = Number(lon); }
    await push('correction', id, correctionPayload(id, dayValue, placeValue, $('#editDescription').value), false, correction?.version ?? 0);
    await load(); openMedia(id);
  } catch(error) { fail(error); } };
  $('#undoCorrection').onclick = async () => { try { await push('correction',id,{},true,correction.version); await load(); openMedia(id); } catch(error) { fail(error); } };
  $('#addStory').onclick = async () => { try {
    const story = state.stories.find(s => s.id === $('#chooseStory').value);
    if (!story) throw new Error('先选择故事');
    const ids = story.mediaIDs.includes(id) ? story.mediaIDs : [...story.mediaIDs,id];
    await saveStory({ ...story, mediaIDs: ids, coverID: story.coverID ?? id });
    const caption = $('#caption').value.trim();
    if (caption) await saveCaption(story.id, id, caption, state.captions.find(c => c.story_id === story.id && c.media_id === id));
    await load(); openMedia(id);
  } catch(error) { fail(error); } };
}
async function saveStory(story) {
  const payload = { title: story.title.trim(), description: story.description ?? '', mediaIDs: story.mediaIDs, coverID: story.coverID };
  if (!payload.title) throw new Error('故事标题不能为空');
  await push('story', story.id, payload, false, story.version ?? 0);
  const extras = { user_id: state.owner, story_id: story.id, start_day: story.startDate || null, end_day: story.endDate || null, place: story.place || null };
  const result = story.extrasVersion ? await supabase.from('archive_story_extras')
    .update({ ...extras, version: story.extrasVersion + 1 }).eq('story_id', story.id).eq('version', story.extrasVersion).select('version')
    : await supabase.from('archive_story_extras').insert(extras).select('version');
  if (result.error) throw result.error;
  if (result.data.length !== 1) throw new Error('故事日期或地点已由另一台设备修改，请刷新后核对');
}
async function saveCaption(storyID, mediaID, caption, old) {
  const table = supabase.from('archive_story_captions');
  let result;
  if (!caption) {
    if (!old) return;
    result = await table.delete().eq('story_id', storyID).eq('media_id', mediaID).eq('version', old.version).select('version');
  } else if (old) {
    result = await table.update({ caption, version: old.version + 1 })
      .eq('story_id', storyID).eq('media_id', mediaID).eq('version', old.version).select('version');
  } else {
    result = await table.insert({ user_id: state.owner, story_id: storyID, media_id: mediaID, caption }).select('version');
  }
  if (result.error) throw result.error;
  if (result.data.length !== 1) throw new Error('单张说明已由另一台设备修改，请刷新后核对');
}
function openStory(id) {
  const story = state.stories.find(item => item.id === id); if (!story) return;
  const byID = mediaByID();
  openModal(`<div class="detail-info"><h2 id="detailTitle">${esc(story.title)}</h2><div class="story-edit"><label>标题<input id="storyTitle" value="${esc(story.title)}" /></label><label>开始日期<input id="storyStart" type="date" value="${esc(story.startDate)}" /></label><label>结束日期<input id="storyEnd" type="date" value="${esc(story.endDate)}" /></label><label>地点<input id="storyPlace" value="${esc(story.place)}" /></label><label>说明<textarea id="storyDescription">${esc(story.description)}</textarea></label><button id="saveStory" class="accent-button">保存故事</button><button id="deleteStory" class="quiet-button">删除故事</button><button id="exportStory" class="quiet-button">导出静态故事</button></div><div class="event-assets">${story.mediaIDs.map((mediaID, index) => { const item = byID.get(mediaID); const caption = state.captions.find(c => c.story_id === id && c.media_id === mediaID)?.caption ?? ''; return `<article class="event-asset-row">${item?.preview ? `<img src="${esc(item.preview)}" alt="" />` : '<span>无云端原片</span>'}<div><strong>${esc(item?.name ?? '未关联媒体')}</strong><input data-caption="${mediaID}" value="${esc(caption)}" placeholder="单张说明" /></div><div class="asset-actions"><button data-move="up" data-index="${index}" ${index===0?'disabled':''}>↑</button><button data-move="down" data-index="${index}" ${index===story.mediaIDs.length-1?'disabled':''}>↓</button><button data-cover="${mediaID}">${story.coverID===mediaID?'封面':'设为封面'}</button><button data-remove="${mediaID}">移出</button></div></article>`; }).join('')}</div></div>`);
  $('#saveStory').onclick = async () => { try {
    const next = { ...story, title: $('#storyTitle').value, startDate: $('#storyStart').value, endDate: $('#storyEnd').value, place: $('#storyPlace').value, description: $('#storyDescription').value };
    await saveStory(next);
    for (const field of $('#detailContent').querySelectorAll('[data-caption]')) {
      const old = state.captions.find(c => c.story_id === id && c.media_id === field.dataset.caption);
      if (field.value === (old?.caption ?? '')) continue;
      await saveCaption(id, field.dataset.caption, field.value, old);
    }
    await load(); openStory(id);
  } catch(error) { fail(error); } };
  $('#deleteStory').onclick = async () => { if (!confirm('删除这个故事？原片仍保留。')) return; try { await push('story',id,{},true,story.version); await load(); closeModal(); } catch(error) { fail(error); } };
  $('#exportStory').onclick = () => exportArchive(id);
  $('#detailContent').querySelectorAll('[data-move]').forEach(button => button.onclick = async () => { try { const from = Number(button.dataset.index); const to = from + (button.dataset.move === 'up' ? -1 : 1); const ids = [...story.mediaIDs]; [ids[from],ids[to]]=[ids[to],ids[from]]; await saveStory({ ...story, mediaIDs: ids }); await load(); openStory(id); } catch(error) { fail(error); } });
  $('#detailContent').querySelectorAll('[data-cover]').forEach(button => button.onclick = async () => { try { await saveStory({ ...story, coverID: button.dataset.cover }); await load(); openStory(id); } catch(error) { fail(error); } });
  $('#detailContent').querySelectorAll('[data-remove]').forEach(button => button.onclick = async () => { try { const ids = story.mediaIDs.filter(value => value !== button.dataset.remove); await saveStory({ ...story, mediaIDs: ids, coverID: story.coverID === button.dataset.remove ? ids[0] ?? null : story.coverID }); await load(); openStory(id); } catch(error) { fail(error); } });
}
async function exportArchive(storyID) {
  try {
    const story = state.stories.find(s => s.id === storyID);
    const items = story ? story.mediaIDs.map(id => mediaByID().get(id)).filter(Boolean) : state.media;
    const files = {};
    const cards = [];
    for (const item of items) {
      if (!item.preview) continue;
      const response = await fetch(item.preview); if (!response.ok) continue;
      const ext = item.asset?.preview_path?.endsWith('.jpg') ? 'jpg' : 'webp';
      const name = `previews/${item.id}.${ext}`;
      files[name] = new Uint8Array(await response.arrayBuffer());
      cards.push(`<figure><img src="${name}" alt=""><figcaption>${esc(item.name)} · ${esc(dateLabel(bestDate(item)))}</figcaption></figure>`);
    }
    files['index.html'] = strToU8(`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>${esc(story?.title ?? '摄影档案')}</title><style>body{font-family:system-ui;max-width:900px;margin:auto;padding:2rem}img{max-width:100%}figure{margin:2rem 0}</style><h1>${esc(story?.title ?? '摄影档案')}</h1>${cards.join('')}</html>`);
    files['manifest.json'] = strToU8(JSON.stringify({ title: story?.title ?? '摄影档案', items: items.map(item => ({ id: item.id, name: item.name, sha256: item.asset?.sha256, capturedAt: bestDate(item) })) }, null, 2));
    const blob = new Blob([zipSync(files)], { type: 'application/zip' });
    const href = URL.createObjectURL(blob); const anchor = document.createElement('a');
    anchor.href = href; anchor.download = `${story?.title ?? '摄影档案'}.zip`; anchor.click(); setTimeout(() => URL.revokeObjectURL(href), 60000);
  } catch(error) { fail(error); }
}
async function signedIn() {
  const result = await supabase.auth.getUser();
  if (result.error || !result.data.user) return;
  state.owner = result.data.user.id;
  $('#accountStatus').textContent = result.data.user.email ?? '';
  $('#signOutButton').hidden = false; $('#authPanel').hidden = true; $('#archiveContent').hidden = false;
  await load();
}
$('#emailForm').onsubmit = async event => { event.preventDefault(); try {
  const email = $('#emailInput').value.trim(); const response = await supabase.auth.signInWithOtp({ email });
  if (response.error) throw response.error; $('#codeForm').hidden = false; authMessage('验证码已发送，请检查邮箱。');
} catch(error) { authMessage(error.message); } };
$('#codeForm').onsubmit = async event => { event.preventDefault(); try {
  const response = await supabase.auth.verifyOtp({ email: $('#emailInput').value.trim(), token: $('#codeInput').value.trim(), type: 'email' });
  if (response.error) throw response.error; await signedIn();
} catch(error) { authMessage(error.message); } };
$('#signOutButton').onclick = async () => { await supabase.auth.signOut(); state.owner = null; state.media = []; state.stories = []; $('#authPanel').hidden = false; $('#archiveContent').hidden = true; $('#signOutButton').hidden = true; $('#accountStatus').textContent = ''; };
$('#refreshButton').onclick = () => load().catch(fail);
$('#yearFilter').onchange = renderTimeline; $('#monthFilter').onchange = renderTimeline;
$('#clearFilters').onclick = () => { $('#yearFilter').value=''; $('#monthFilter').value=''; renderTimeline(); };
$('#newEventButton').onclick = () => $('#eventForm').classList.toggle('hidden');
$('#cancelEvent').onclick = () => $('#eventForm').classList.add('hidden');
$('#eventForm').onsubmit = async event => { event.preventDefault(); try {
  const fields = Object.fromEntries(new FormData(event.currentTarget).entries());
  await saveStory({ id: crypto.randomUUID(), version: 0, title: fields.title, description: fields.description, mediaIDs: [], coverID: null, startDate: fields.startDate, endDate: fields.endDate, place: fields.place });
  event.currentTarget.reset(); event.currentTarget.classList.add('hidden'); await load();
} catch(error) { fail(error); } };
$('#exportTimeline').onclick = () => exportArchive();
$('#closeModal').onclick = closeModal;
$('#detailModal').onclick = event => { if (event.target === $('#detailModal')) closeModal(); };
document.onkeydown = event => { if (event.key === 'Escape') closeModal(); };
signedIn().catch(error => authMessage(error.message));

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && state.owner && Date.now() - state.loadedAt > 10 * 60 * 1000) load().catch(fail);
});
setInterval(() => {
  if (document.visibilityState === 'visible' && state.owner) load().catch(fail);
}, 12 * 60 * 1000);
