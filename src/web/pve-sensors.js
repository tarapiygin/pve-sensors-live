/* SPDX-License-Identifier: MIT */
'use strict';

const byId = (id) => document.getElementById(id);
const numberFormat = new Intl.NumberFormat('en', { maximumFractionDigits: 1 });
const fmt = (value) => numberFormat.format(value);
const MAX_POINTS = 16000;
const node = new URLSearchParams(window.location.search).get('node') || 'localhost';
const snapshotUrl = '/api2/json/nodes/' + encodeURIComponent(node) + '/sensors';
let refreshMs = 500;
let fetchTimer = null;
let activeController = null;
let loading = false;
let latestPayload = null;
let latestToken = null;
let latestArrival = null;
let serverAgeMs = 0;
let errorMessage = null;
let cpuId = null;
let sourceSignature = '';
let sampleCount = 0;
let compressed = false;
let sessionStarted = performance.now();
let history = [];
let minimum = Infinity;
let maximum = -Infinity;
let breakNext = false;
let chartFrame = null;

const stateNames = { normal: 'Below thresholds', warning: 'Above max', critical: 'Critical threshold', neutral: 'No thresholds' };

function classify(metric) {
  if (!metric || metric.unit !== '°C') return 'neutral';
  if (Number.isFinite(metric.critical) && metric.value >= metric.critical) return 'critical';
  if (Number.isFinite(metric.max) && metric.value >= metric.max) return 'warning';
  return Number.isFinite(metric.max) || Number.isFinite(metric.critical) ? 'normal' : 'neutral';
}

function validatePayload(payload) {
  if (!payload || typeof payload !== 'object' || !Array.isArray(payload.metrics)
      || payload.metrics.length > 512 || !Number.isFinite(Date.parse(payload.updated_at))
      || typeof payload.session !== 'string' || !/^[a-f0-9]{16}$/.test(payload.session)
      || !Number.isSafeInteger(payload.sequence) || payload.sequence < 1) {
    throw new Error('Invalid sensor snapshot');
  }
  const ids = new Set();
  const metrics = payload.metrics.filter((m) => {
    if (!m || typeof m.id !== 'string' || m.id.length > 80 || ids.has(m.id)
        || typeof m.name !== 'string' || m.name.length > 120
        || !['cpu', 'storage', 'system', 'fans', 'gpu'].includes(m.category)
        || !['°C', 'RPM'].includes(m.unit) || !Number.isFinite(m.value)) return false;
    ids.add(m.id);
    return true;
  });
  if (!metrics.length) throw new Error('No valid sensor readings');
  return { ...payload, metrics };
}

function updateHero(prefix, metric) {
  const state = classify(metric);
  byId(prefix + 'State').className = 'state ' + state;
  byId(prefix + 'State').textContent = metric ? stateNames[state] : 'No data';
  byId(prefix + 'Value').textContent = metric ? `${fmt(metric.value)} °C` : '—';
  byId(prefix + 'Name').textContent = metric ? metric.name : 'Sensor not available';
  const ceiling = metric && (Number.isFinite(metric.critical) ? metric.critical : metric.max);
  byId(prefix + 'Meter').className = 'meter-fill ' + state;
  byId(prefix + 'Meter').style.width = metric && Number.isFinite(ceiling) && ceiling > 0
    ? Math.max(0, Math.min(100, metric.value / ceiling * 100)) + '%' : '0%';
  const limits = [];
  if (metric && Number.isFinite(metric.max)) limits.push(`Max ${fmt(metric.max)} °C`);
  if (metric && Number.isFinite(metric.critical)) limits.push(`Critical ${fmt(metric.critical)} °C`);
  byId(prefix + 'Limits').textContent = limits.join(' · ') || 'No thresholds reported by this sensor';
}

function makeCard(metric) {
  const card = document.createElement('article');
  card.className = 'sensor-card';
  card.dataset.state = classify(metric);
  const title = document.createElement('div');
  title.className = 'sensor-name';
  title.textContent = metric.name;
  const value = document.createElement('div');
  value.className = 'sensor-value';
  value.append(document.createTextNode(fmt(metric.value)));
  const unit = document.createElement('small');
  unit.textContent = metric.unit;
  value.append(unit);
  const note = document.createElement('div');
  note.className = 'sensor-meta';
  note.textContent = metric.unit === 'RPM'
    ? (metric.value === 0 ? 'Zero reported; verify fan telemetry' : 'Reported fan speed')
    : stateNames[classify(metric)];
  card.append(title, value, note);
  return card;
}

function renderGroup(id, metrics) {
  const box = byId(id);
  if (metrics.length) {
    box.replaceChildren(...metrics.map(makeCard));
  } else {
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = 'No sensors reported for this group.';
    box.replaceChildren(empty);
  }
}

function pickDefaultCpu(metrics) {
  return metrics.find((m) => /\/ Package$/.test(m.name))
    || metrics.find((m) => /\/ Tdie$/.test(m.name))
    || metrics.find((m) => m.role === 'package') || metrics[0];
}

function resetHistory() {
  history = [];
  sampleCount = 0;
  minimum = Infinity;
  maximum = -Infinity;
  compressed = false;
  sessionStarted = performance.now();
  breakNext = true;
  for (const id of ['chartCurrent', 'chartMin', 'chartMax']) byId(id).textContent = '—';
  byId('chartSamples').textContent = '0';
  byId('historyNote').textContent = 'Reloading or changing the source resets history. Hidden tabs pause polling.';
  requestChart();
}

function updateSources(cpus) {
  const signature = cpus.map((m) => m.id + ':' + m.name).join('|');
  if (signature === sourceSignature) return;
  sourceSignature = signature;
  const previous = cpuId;
  if (!cpus.some((m) => m.id === cpuId)) cpuId = pickDefaultCpu(cpus)?.id || null;
  const select = byId('cpuSource');
  const options = cpus.map((m) => {
    const option = document.createElement('option');
    option.value = m.id;
    option.textContent = m.name;
    return option;
  });
  if (!options.length) {
    const option = document.createElement('option');
    option.value = '';
    option.textContent = 'CPU sensor unavailable';
    options.push(option);
  }
  select.replaceChildren(...options);
  select.value = cpuId || '';
  if (previous !== null && previous !== cpuId) resetHistory();
}

function render(payload, addSample) {
  const metrics = payload.metrics;
  const cpus = metrics.filter((m) => m.category === 'cpu')
    .sort((a, b) => a.name.localeCompare(b.name, 'en', { numeric: true }));
  updateSources(cpus);
  const cpu = cpus.find((m) => m.id === cpuId);
  const storage = metrics.find((m) => m.category === 'storage' && m.role === 'composite')
    || metrics.find((m) => m.category === 'storage');
  updateHero('cpu', cpu);
  updateHero('nvme', storage);
  renderGroup('cores', cpus.filter((m) => m.id !== cpuId));
  renderGroup('other', metrics.filter((m) => m.category !== 'cpu' && m.id !== storage?.id));
  if (addSample && cpu) addChartSample(cpu);
  byId('chartTitle').textContent = cpu ? `${cpu.name} history` : 'CPU temperature history';
}

function addChartSample(metric) {
  const elapsed = performance.now() - sessionStarted;
  const previous = history[history.length - 1];
  history.push({ time: elapsed, value: metric.value,
    gap: breakNext || !!(previous && elapsed - previous.time > Math.max(2500, refreshMs * 5)) });
  breakNext = false;
  sampleCount++;
  minimum = Math.min(minimum, metric.value);
  maximum = Math.max(maximum, metric.value);
  if (history.length > MAX_POINTS) compressHistory();
  byId('chartCurrent').textContent = fmt(metric.value) + ' °C';
  byId('chartMin').textContent = fmt(minimum) + ' °C';
  byId('chartMax').textContent = fmt(maximum) + ' °C';
  byId('chartSamples').textContent = sampleCount.toLocaleString('en');
  requestChart();
}

function compressHistory() {
  // Retain first, minimum, maximum and last per 8-snapshot block. The entire
  // time span and extrema survive; resolution decreases in long-lived tabs.
  const next = [];
  for (let start = 0; start < history.length; start += 8) {
    const block = history.slice(start, start + 8);
    let low = 0, high = 0;
    for (let i = 1; i < block.length; i++) {
      if (block[i].value < block[low].value) low = i;
      if (block[i].value > block[high].value) high = i;
    }
    const chosen = [...new Set([0, low, high, block.length - 1])].sort((a, b) => a - b);
    let previous = -1;
    for (const i of chosen) {
      const gap = block.slice(previous + 1, i + 1).some((p) => p.gap);
      next.push({ ...block[i], gap });
      previous = i;
    }
  }
  history = next;
  compressed = true;
  byId('historyNote').textContent = 'Long session: history is downsampled to bound memory. Time span and temperature extrema are retained.';
}

function duration(ms) {
  const seconds = Math.floor(Math.max(0, ms) / 1000);
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor(seconds / 60) % 60;
  const rest = seconds % 60;
  return (hours ? hours + ':' : '') + String(minutes).padStart(2, '0') + ':' + String(rest).padStart(2, '0');
}

function requestChart() {
  if (chartFrame !== null || document.hidden) return;
  chartFrame = requestAnimationFrame(() => { chartFrame = null; drawChart(); });
}

function displayPoints(width, xMax) {
  if (history.length <= width * 3) return history;
  const points = [];
  let i = 0;
  while (i < history.length) {
    const first = i;
    const column = Math.floor(history[i].time / xMax * width);
    let low = i, high = i;
    while (i < history.length && Math.floor(history[i].time / xMax * width) === column) {
      if (history[i].value < history[low].value) low = i;
      if (history[i].value > history[high].value) high = i;
      i++;
    }
    const chosen = [...new Set([first, low, high, i - 1])].sort((a, b) => a - b);
    let last = first - 1;
    for (const index of chosen) {
      let gap = false;
      for (let k = last + 1; k <= index; k++) gap ||= history[k].gap;
      points.push({ ...history[index], gap });
      last = index;
    }
  }
  return points;
}

function drawChart() {
  const canvas = byId('cpuChart');
  const width = Math.max(1, canvas.clientWidth);
  const height = Math.max(1, canvas.clientHeight);
  const scale = Math.min(window.devicePixelRatio || 1, 2);
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  if (canvas.width !== Math.round(width * scale) || canvas.height !== Math.round(height * scale)) {
    canvas.width = Math.round(width * scale);
    canvas.height = Math.round(height * scale);
  }
  ctx.setTransform(scale, 0, 0, scale, 0, 0);
  ctx.clearRect(0, 0, width, height);
  const css = getComputedStyle(document.documentElement);
  const grid = css.getPropertyValue('--chart-grid').trim();
  const text = css.getPropertyValue('--chart-text').trim();
  const line = css.getPropertyValue('--chart-line').trim();
  const left = width < 450 ? 37 : 48, right = 14, top = 18, bottom = 32;
  const plotWidth = Math.max(1, width - left - right);
  const plotHeight = Math.max(1, height - top - bottom);
  const xMax = Math.max(4000, performance.now() - sessionStarted);
  const min = history.length ? minimum : 35, max = history.length ? maximum : 50;
  const yMin = Math.floor((min - 3) / 5) * 5;
  const yMax = Math.max(yMin + 10, Math.ceil((max + 3) / 5) * 5);
  const px = (t) => left + Math.max(0, Math.min(xMax, t)) / xMax * plotWidth;
  const py = (v) => top + (yMax - v) / (yMax - yMin) * plotHeight;
  ctx.font = '11px system-ui, sans-serif';
  ctx.textBaseline = 'middle';
  ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = top + i * plotHeight / 4;
    ctx.strokeStyle = grid;
    ctx.beginPath(); ctx.moveTo(left, y); ctx.lineTo(left + plotWidth, y); ctx.stroke();
    ctx.textAlign = 'right'; ctx.fillStyle = text;
    ctx.fillText(fmt(yMax - i * (yMax - yMin) / 4) + '°', left - 8, y);
  }
  const ticks = width < 450 ? 3 : 5;
  for (let i = 0; i <= ticks; i++) {
    ctx.textAlign = i === 0 ? 'left' : i === ticks ? 'right' : 'center';
    ctx.fillStyle = text;
    ctx.fillText(duration(xMax * i / ticks), left + plotWidth * i / ticks, height - 12);
  }
  if (!history.length) {
    ctx.textAlign = 'center'; ctx.fillStyle = text;
    ctx.fillText('Waiting for CPU temperature samples', left + plotWidth / 2, top + plotHeight / 2);
  } else {
    const points = displayPoints(Math.floor(plotWidth), xMax);
    ctx.save(); ctx.beginPath(); ctx.rect(left, top, plotWidth, plotHeight); ctx.clip();
    ctx.strokeStyle = line; ctx.lineWidth = 2; ctx.lineJoin = 'round';
    ctx.beginPath();
    points.forEach((p, i) => {
      if (i === 0 || p.gap) ctx.moveTo(px(p.time), py(p.value));
      else ctx.lineTo(px(p.time), py(p.value));
    });
    ctx.stroke();
    const last = points[points.length - 1];
    ctx.fillStyle = line; ctx.beginPath(); ctx.arc(px(last.time), py(last.value), 3.5, 0, Math.PI * 2); ctx.fill();
    ctx.restore();
  }
  byId('chartDuration').textContent = duration(xMax === 4000 && !history.length ? 0 : performance.now() - sessionStarted);
}

function updateConnection() {
  const badge = byId('connection');
  const stale = latestArrival !== null &&
    (performance.now() - latestArrival + serverAgeMs > Math.max(3000, refreshMs * 4));
  document.body.classList.toggle('data-stale', !!errorMessage || stale);
  if (document.hidden) {
    badge.className = 'connection pending'; badge.textContent = 'Paused in background';
  } else if (errorMessage) {
    badge.className = 'connection danger'; badge.textContent = 'Connection error';
    byId('updated').textContent = errorMessage;
  } else if (stale) {
    badge.className = 'connection warning'; badge.textContent = 'Snapshot is stale';
  } else if (latestArrival !== null) {
    badge.className = 'connection ok'; badge.textContent = 'Live readings';
  }
  if (!errorMessage && latestPayload) {
    const time = new Date(latestPayload.updated_at).toLocaleTimeString('en', { hour12: false });
    byId('updated').textContent = `Sampled ${time} · ${Math.round(refreshMs)} ms target`;
  }
}

async function refresh() {
  if (loading || document.hidden) return;
  loading = true;
  const started = performance.now();
  const controller = new AbortController();
  activeController = controller;
  const timeout = setTimeout(() => controller.abort(), 4000);
  try {
    const response = await fetch(snapshotUrl, {
      cache: 'no-store', credentials: 'same-origin', referrerPolicy: 'no-referrer', signal: controller.signal,
    });
    if (response.status === 401 || response.status === 403) {
      const error = new Error(response.status === 401
        ? 'Log in to Proxmox on this origin, then reload this page'
        : 'Sys.Audit permission is required on this node');
      error.name = 'AccessError';
      throw error;
    }
    if (!response.ok) throw new Error('HTTP ' + response.status);
    const raw = await response.text();
    if (raw.length > 262144) throw new Error('Sensor snapshot is too large');
    const payload = validatePayload(JSON.parse(raw).data);
    const interval = Number(payload.sample_interval_ms);
    refreshMs = Number.isFinite(interval) && interval >= 100 && interval <= 60000 ? interval : 500;
    byId('sampling').textContent = `${Math.round(refreshMs)} ms target interval`;
    const token = payload.session + ':' + payload.sequence;
    if (token !== latestToken) {
      const restarted = latestPayload && latestPayload.session !== payload.session;
      if (restarted) breakNext = true;
      // Compare two server times, not the browser clock. HTTP Date is optional.
      const serverDate = Date.parse(response.headers.get('Date'));
      serverAgeMs = Number.isFinite(serverDate) ? Math.max(0, serverDate - Date.parse(payload.updated_at)) : 0;
      latestArrival = performance.now();
      latestToken = token;
      latestPayload = payload;
      const isFresh = serverAgeMs <= Math.max(3000, refreshMs * 4);
      render(payload, isFresh);
      if (!isFresh) breakNext = true;
    }
    errorMessage = null;
  } catch (error) {
    if (!document.hidden) errorMessage = error.name === 'AccessError' ? error.message
      : error.name === 'AbortError' ? 'Request timed out' : 'Cannot read the sensor snapshot';
    breakNext = true;
  } finally {
    clearTimeout(timeout);
    activeController = null;
    loading = false;
    updateConnection();
    requestChart();
    if (!document.hidden) {
      const delay = errorMessage ? Math.max(2000, refreshMs) : Math.max(50, refreshMs - (performance.now() - started));
      fetchTimer = setTimeout(refresh, delay);
    }
  }
}

byId('cpuSource').addEventListener('change', (event) => {
  cpuId = event.target.value || null;
  resetHistory();
  const fresh = latestArrival !== null && !errorMessage &&
    performance.now() - latestArrival + serverAgeMs <= Math.max(3000, refreshMs * 4);
  if (latestPayload) render(latestPayload, fresh);
});
document.addEventListener('visibilitychange', () => {
  clearTimeout(fetchTimer);
  if (document.hidden) { activeController?.abort(); breakNext = true; }
  else if (!loading) refresh();
  updateConnection();
});
window.addEventListener('resize', requestChart);
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', requestChart);
window.addEventListener('pagehide', () => { clearTimeout(fetchTimer); activeController?.abort(); });
setInterval(() => { if (!document.hidden) { updateConnection(); requestChart(); } }, 1000);
requestChart();
refresh();
