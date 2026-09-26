const state = {
  items: [],
  total: 0,
  events: [],
  map: null,
  markers: []
};

const $ = (selector) => document.querySelector(selector);
const timeline = $('#timeline');
const stats = $('#stats');
const resultSummary = $('#resultSummary');
const yearFilter = $('#yearFilter');
const monthFilter = $('#monthFilter');
const detailModal = $('#detailModal');
const detailContent = $('#detailContent');
const mapElement = $('#map');

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`;
}

function formatDate(value) {
  if (!value) return '时间未知';
  return value.replace('T', ' ').replace(/([+-]\d{2}:?\d{2}|Z)$/, '');
}

function dateKey(value) {
  return value ? value.slice(0, 10) : 'unknown';
}

function formatDay(value) {
  if (value === 'unknown') return '待确认时间';
  const [year, month, day] = value.split('-');
  return `${year} 年 ${Number(month)} 月 ${Number(day)} 日`;
}

function sourceLabel(source) {
  const labels = {
    exif: 'EXIF',
    xmp: 'XMP',
    quicktime: 'QuickTime',
    ffprobe: 'FFprobe',
    filename: '文件名',
    file_mtime: '文件修改时间',
    exif_modify_date: 'EXIF 修改时间',
    manual: '人工修正'
  };
  return labels[source] ?? source ?? '未知来源';
}

async function fetchJson(url, options) {
  const response = await fetch(url, options);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || `请求失败：${response.status}`);
  return body;
}

function renderStats(data) {
  const gpsPercent = data.indexed === 0 ? 0 : Math.round((data.withGps / data.indexed) * 100);
  stats.innerHTML = `
    <div class="stat-card"><span>已索引媒体</span><strong>${data.indexed}</strong></div>
    <div class="stat-card"><span>照片</span><strong>${data.photos}</strong></div>
    <div class="stat-card"><span>视频</span><strong>${data.videos}</strong></div>
    <div class="stat-card"><span>GPS 覆盖</span><strong>${gpsPercent}%</strong><small>${data.withGps} 个文件</small></div>
  `;
}

function updateYearOptions(items) {
  const selected = yearFilter.value;
  const years = [...new Set(items.map((item) => item.capturedAt?.slice(0, 4)).filter(Boolean))]
    .sort((a, b) => b.localeCompare(a));
  yearFilter.innerHTML = '<option value="">全部年份</option>' + years
    .map((year) => `<option value="${escapeHtml(year)}">${escapeHtml(year)}</option>`)
    .join('');
  if (years.includes(selected)) yearFilter.value = selected;
}

function renderMap(items) {
  const gpsItems = items.filter((item) => item.latitude !== null && item.longitude !== null);
  $('#mapSummary').textContent = `${gpsItems.length} 个媒体包含位置数据`;

  if (!window.L) {
    mapElement.innerHTML = gpsItems.length
      ? `<div class="map-fallback">地图增强不可用（可能是当前没有网络），共有 ${gpsItems.length} 个 GPS 点。<br /><span>时间轴和坐标数据仍然可用。</span></div>`
      : '<div class="map-fallback">当前筛选结果没有 GPS 数据。</div>';
    return;
  }

  if (!state.map) {
    mapElement.innerHTML = '';
    state.map = window.L.map(mapElement, { scrollWheelZoom: false });
    window.L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; OpenStreetMap contributors'
    }).addTo(state.map);
  }

  state.markers.forEach((marker) => marker.remove());
  state.markers = [];
  if (gpsItems.length === 0) {
    state.map.setView([35, 105], 3);
    return;
  }

  const bounds = [];
  for (const item of gpsItems) {
    const point = [item.latitude, item.longitude];
    bounds.push(point);
    const marker = window.L.marker(point)
      .addTo(state.map)
      .bindPopup(`<strong>${escapeHtml(item.relativePath)}</strong><br />${escapeHtml(formatDate(item.capturedAt))}`);
    state.markers.push(marker);
  }
  state.map.fitBounds(bounds, { padding: [24, 24], maxZoom: 12 });
  window.setTimeout(() => state.map?.invalidateSize(), 50);
}

function renderTimeline(items, total) {
  resultSummary.textContent = `显示 ${items.length} / ${total} 个媒体 · 按拍摄时间排序`;
  renderMap(items);
  if (items.length === 0) {
    timeline.innerHTML = '<div class="empty-state"><strong>没有找到媒体</strong><span>尝试清除筛选条件，或先运行扫描命令。</span></div>';
    return;
  }

  const groups = new Map();
  for (const item of items) {
    const key = dateKey(item.capturedAt);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(item);
  }

  timeline.innerHTML = [...groups.entries()].map(([day, dayItems]) => `
    <section class="day-group">
      <div class="day-heading">
        <span class="day-dot"></span>
        <h3>${escapeHtml(formatDay(day))}</h3>
        <span class="day-count">${dayItems.length} 个媒体</span>
      </div>
      <div class="media-grid">
        ${dayItems.map((item) => `
          <button class="media-card" type="button" data-id="${item.id}" aria-label="查看 ${escapeHtml(item.relativePath)}">
            <div class="media-preview">
              <img src="/api/media/${item.id}/thumbnail" alt="${escapeHtml(item.relativePath)}" loading="lazy" />
              ${item.mediaType === 'video' ? '<span class="media-type-badge">视频</span>' : ''}
              ${item.latitude !== null ? '<span class="gps-badge" title="包含 GPS">⌖</span>' : ''}
            </div>
            <div class="media-caption">
              <span class="media-time">${escapeHtml(formatDate(item.capturedAt))}</span>
              <span class="media-source ${item.capturedAtSource === 'manual' ? 'manual-source' : ''}">${escapeHtml(sourceLabel(item.capturedAtSource))}</span>
            </div>
          </button>
        `).join('')}
      </div>
    </section>
  `).join('');

  timeline.querySelectorAll('.media-card').forEach((card) => {
    card.addEventListener('click', () => openMediaDetails(Number(card.dataset.id)));
  });
  timeline.querySelectorAll('img').forEach((image) => {
    image.addEventListener('error', () => {
      image.classList.add('image-error');
      image.alt = '缩略图生成失败';
    });
  });
}

async function loadTimeline() {
  const params = new URLSearchParams({ limit: '200' });
  if (yearFilter.value) params.set('year', yearFilter.value);
  if (monthFilter.value) {
    const [year, month] = monthFilter.value.split('-');
    params.set('year', year);
    params.set('month', month);
  }

  timeline.innerHTML = '<div class="loading-state">正在读取时间轴……</div>';
  try {
    const data = await fetchJson(`/api/timeline?${params}`);
    state.items = data.items;
    state.total = data.total;
    if (!yearFilter.value && !monthFilter.value) updateYearOptions(data.items);
    renderTimeline(data.items, data.total);
  } catch (error) {
    timeline.innerHTML = `<div class="error-state"><strong>无法读取时间轴</strong><span>${escapeHtml(error.message)}</span></div>`;
  }
}

async function loadEvents() {
  const data = await fetchJson('/api/events');
  state.events = data.events;
  renderEvents();
}

function eventDate(event) {
  if (!event.startDate && !event.endDate) return '日期待补充';
  if (event.startDate === event.endDate || !event.endDate) return event.startDate || event.endDate;
  return `${event.startDate || '未知'} — ${event.endDate || '未知'}`;
}

function renderEvents() {
  const container = $('#eventsList');
  if (state.events.length === 0) {
    container.innerHTML = '<p class="muted">还没有事件。可以从时间轴详情中把媒体加入事件。</p>';
    return;
  }
  container.innerHTML = state.events.map((event) => `
    <article class="event-card">
      <button class="event-open" type="button" data-event-id="${event.id}">
        <span class="event-title">${escapeHtml(event.title)}</span>
        <span class="event-meta">${escapeHtml(eventDate(event))}${event.place ? ` · ${escapeHtml(event.place)}` : ''}</span>
        <span class="event-count">${event.assetCount} 个媒体</span>
      </button>
      <button class="event-export" type="button" data-export-event="${event.id}">导出</button>
    </article>
  `).join('');
  container.querySelectorAll('.event-open').forEach((button) => {
    button.addEventListener('click', () => openEventDetails(Number(button.dataset.eventId)));
  });
  container.querySelectorAll('.event-export').forEach((button) => {
    button.addEventListener('click', () => exportArchive(Number(button.dataset.exportEvent)));
  });
}

function openModal() {
  detailModal.classList.remove('hidden');
}

function closeDetails() {
  detailModal.classList.add('hidden');
}

function renderCandidateList(candidates, type) {
  if (!candidates?.length) return '<p class="muted">没有记录</p>';
  return `<ul class="candidate-list">${candidates.map((candidate) => {
    const value = type === 'time'
      ? `${formatDate(candidate.value)} · ${candidate.precision}`
      : `${Number(candidate.latitude).toFixed(5)}, ${Number(candidate.longitude).toFixed(5)}`;
    return `<li><span>${escapeHtml(value)}</span><em>${escapeHtml(sourceLabel(candidate.source))} · ${Math.round(candidate.confidence * 100)}%</em></li>`;
  }).join('')}</ul>`;
}

function toDateTimeInput(value) {
  if (!value) return '';
  const match = value.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})/);
  return match ? match[1] : '';
}

function activeOverride(item, field) {
  return item.overrides?.find((override) => override.field === field)?.value;
}

function eventOptions() {
  if (state.events.length === 0) return '<option value="">先创建一个事件</option>';
  return '<option value="">选择事件</option>' + state.events
    .map((event) => `<option value="${event.id}">${escapeHtml(event.title)}</option>`)
    .join('');
}

async function openMediaDetails(id) {
  openModal();
  detailContent.innerHTML = '<div class="loading-state">正在读取媒体详情……</div>';
  try {
    const item = await fetchJson(`/api/media/${id}`);
    const timeOverride = activeOverride(item, 'time');
    const geoOverride = activeOverride(item, 'geo');
    const currentGeo = geoOverride || item.geos?.[0];
    const preview = item.mediaType === 'video'
      ? `<video src="/api/media/${item.id}/file" controls preload="metadata"></video>`
      : `<img src="/api/media/${item.id}/file" alt="${escapeHtml(item.relativePath)}" />`;
    detailContent.innerHTML = `
      <div class="detail-preview">${preview}</div>
      <div class="detail-info">
        <p class="eyebrow">${escapeHtml(item.sourceName)} · ${escapeHtml(item.mediaType)}</p>
        <h2 id="detailTitle">${escapeHtml(item.relativePath)}</h2>
        <p class="detail-meta">${formatBytes(item.size)} · SHA-256 ${escapeHtml(item.sha256?.slice(0, 16) ?? '未生成')}…</p>
        <div class="detail-columns">
          <div><h3>时间候选</h3>${renderCandidateList(item.times, 'time')}</div>
          <div><h3>GPS 候选</h3>${renderCandidateList(item.geos, 'geo')}</div>
        </div>
        <div class="override-panel">
          <div class="panel-heading"><h3>人工修正</h3><span class="muted">只写入索引，不改原文件</span></div>
          <div class="override-grid">
            <label>拍摄时间<input id="overrideTime" type="datetime-local" value="${escapeHtml(toDateTimeInput(timeOverride?.value || item.times?.[0]?.value))}" /></label>
            <button class="accent-button" id="saveTime" type="button">保存时间</button>
            <label>纬度<input id="overrideLatitude" type="number" step="any" min="-90" max="90" value="${currentGeo ? escapeHtml(currentGeo.latitude) : ''}" /></label>
            <label>经度<input id="overrideLongitude" type="number" step="any" min="-180" max="180" value="${currentGeo ? escapeHtml(currentGeo.longitude) : ''}" /></label>
            <button class="accent-button" id="saveGeo" type="button">保存 GPS</button>
          </div>
          <label class="reason-field">修改原因<input id="overrideReason" placeholder="例如：相机时区设置错误" /></label>
          <div class="override-actions">
            <button class="clear-button" id="undoOverride" type="button" ${item.overrides?.length ? '' : 'disabled'}>撤销最近修正</button>
            ${item.overrides?.length ? `<span class="manual-note">当前有 ${item.overrides.length} 项人工修正</span>` : '<span class="muted">当前使用自动解析结果</span>'}
          </div>
        </div>
        <div class="event-add-panel">
          <h3>加入事件</h3>
          <div class="event-add-row">
            <select id="eventSelect">${eventOptions()}</select>
            <input id="assetCaption" placeholder="这张照片的说明（可选）" />
            <button class="accent-button" id="addToEvent" type="button" ${state.events.length ? '' : 'disabled'}>加入</button>
          </div>
        </div>
        <p class="muted">扫描器保留了原始元数据和来源；人工修正可以撤销。审计记录已保存。</p>
      </div>
    `;
    $('#saveTime').addEventListener('click', () => saveOverride(id, 'time'));
    $('#saveGeo').addEventListener('click', () => saveOverride(id, 'geo'));
    $('#undoOverride').addEventListener('click', () => undoOverride(id));
    $('#addToEvent').addEventListener('click', () => addToEvent(id));
  } catch (error) {
    detailContent.innerHTML = `<div class="error-state"><strong>无法读取详情</strong><span>${escapeHtml(error.message)}</span></div>`;
  }
}

async function saveOverride(id, field) {
  const reason = $('#overrideReason').value.trim() || 'manual';
  const value = field === 'time'
    ? $('#overrideTime').value
    : { latitude: Number($('#overrideLatitude').value), longitude: Number($('#overrideLongitude').value) };
  if (field === 'time' && !value) {
    alert('请选择时间');
    return;
  }
  try {
    await fetchJson(`/api/media/${id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ field, value, reason })
    });
    await loadAll();
    await openMediaDetails(id);
  } catch (error) {
    alert(error.message);
  }
}

async function undoOverride(id) {
  try {
    await fetchJson(`/api/media/${id}/overrides/undo`, { method: 'POST' });
    await loadAll();
    await openMediaDetails(id);
  } catch (error) {
    alert(error.message);
  }
}

async function addToEvent(mediaFileId) {
  const eventId = Number($('#eventSelect').value);
  if (!eventId) {
    alert('请先选择事件');
    return;
  }
  try {
    await fetchJson(`/api/events/${eventId}/assets`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mediaFileId, caption: $('#assetCaption').value.trim() || null })
    });
    await loadEvents();
    alert('已加入事件');
  } catch (error) {
    alert(error.message);
  }
}

async function openEventDetails(id) {
  openModal();
  detailContent.innerHTML = '<div class="loading-state">正在读取事件……</div>';
  try {
    const event = await fetchJson(`/api/events/${id}`);
    detailContent.innerHTML = `
      <div class="detail-info event-detail">
        <p class="eyebrow">STORY / EVENT</p>
        <h2 id="detailTitle">${escapeHtml(event.title)}</h2>
        <p class="detail-meta">${escapeHtml(eventDate(event))}${event.place ? ` · ${escapeHtml(event.place)}` : ''}</p>
        ${event.description ? `<p class="event-description">${escapeHtml(event.description)}</p>` : ''}
        <div class="event-detail-actions"><button class="accent-button" id="exportCurrentEvent" type="button">导出静态故事</button></div>
        <div class="event-assets">
          ${event.assets.length ? event.assets.map((asset, index) => asset.item ? `
            <article class="event-asset-row">
              <img src="/api/media/${asset.item.id}/thumbnail" alt="" />
              <div><strong>${escapeHtml(formatDate(asset.item.capturedAt))}</strong><span>${escapeHtml(asset.caption || asset.item.relativePath)}</span></div>
              <div class="asset-actions">
                <button type="button" data-move="up" data-index="${index}" ${index === 0 ? 'disabled' : ''}>↑</button>
                <button type="button" data-move="down" data-index="${index}" ${index === event.assets.length - 1 ? 'disabled' : ''}>↓</button>
                <button type="button" data-cover="${asset.item.id}">${event.coverMediaFileId === asset.item.id ? '已是封面' : '设为封面'}</button>
              </div>
            </article>
          ` : '').join('') : '<p class="muted">事件中还没有可用媒体。</p>'}
        </div>
      </div>
    `;
    $('#exportCurrentEvent').addEventListener('click', () => exportArchive(id));
    detailContent.querySelectorAll('[data-move]').forEach((button) => {
      button.addEventListener('click', () => moveEventAsset(id, event.assets, Number(button.dataset.index), button.dataset.move));
    });
    detailContent.querySelectorAll('[data-cover]').forEach((button) => {
      button.addEventListener('click', () => setEventCover(id, Number(button.dataset.cover)));
    });
  } catch (error) {
    detailContent.innerHTML = `<div class="error-state"><strong>无法读取事件</strong><span>${escapeHtml(error.message)}</span></div>`;
  }
}

async function moveEventAsset(eventId, assets, index, direction) {
  const otherIndex = direction === 'up' ? index - 1 : index + 1;
  if (!assets[otherIndex]?.item) return;
  try {
    await fetchJson(`/api/events/${eventId}/assets/${assets[index].item.id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sortOrder: assets[otherIndex].sortOrder })
    });
    await fetchJson(`/api/events/${eventId}/assets/${assets[otherIndex].item.id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sortOrder: assets[index].sortOrder })
    });
    await openEventDetails(eventId);
    await loadEvents();
  } catch (error) {
    alert(error.message);
  }
}

async function setEventCover(eventId, mediaFileId) {
  try {
    await fetchJson(`/api/events/${eventId}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ coverMediaFileId: mediaFileId })
    });
    await openEventDetails(eventId);
    await loadEvents();
  } catch (error) {
    alert(error.message);
  }
}

async function createEvent(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const formData = new FormData(form);
  try {
    await fetchJson('/api/events', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(Object.fromEntries(formData.entries()))
    });
    form.reset();
    form.classList.add('hidden');
    await loadEvents();
  } catch (error) {
    alert(error.message);
  }
}

async function exportArchive(eventId) {
  const url = eventId ? `/api/events/${eventId}/export` : '/api/export';
  try {
    const result = await fetchJson(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ gpsPrivacy: 'omit' })
    });
    window.open(result.url, '_blank');
  } catch (error) {
    alert(`导出失败：${error.message}`);
  }
}

async function loadAll() {
  try {
    const [statsData, timelineData, eventsData] = await Promise.all([
      fetchJson('/api/stats'),
      fetchJson('/api/timeline?limit=200'),
      fetchJson('/api/events')
    ]);
    renderStats(statsData);
    state.items = timelineData.items;
    state.total = timelineData.total;
    updateYearOptions(timelineData.items);
    state.events = eventsData.events;
    renderEvents();
    renderTimeline(timelineData.items, timelineData.total);
  } catch (error) {
    stats.innerHTML = `<div class="error-state"><strong>无法连接本地服务</strong><span>${escapeHtml(error.message)}</span></div>`;
    timeline.innerHTML = '<div class="error-state"><strong>请确认服务正在运行</strong><span>npm run web -- --db data/media.db</span></div>';
  }
}

yearFilter.addEventListener('change', loadTimeline);
monthFilter.addEventListener('change', loadTimeline);
$('#clearFilters').addEventListener('click', () => {
  yearFilter.value = '';
  monthFilter.value = '';
  loadTimeline();
});
$('#refreshButton').addEventListener('click', loadAll);
$('#exportTimeline').addEventListener('click', () => exportArchive());
$('#newEventButton').addEventListener('click', () => $('#eventForm').classList.toggle('hidden'));
$('#cancelEvent').addEventListener('click', () => $('#eventForm').classList.add('hidden'));
$('#eventForm').addEventListener('submit', createEvent);
$('#closeModal').addEventListener('click', closeDetails);
detailModal.addEventListener('click', (event) => {
  if (event.target === detailModal) closeDetails();
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') closeDetails();
});

loadAll();
