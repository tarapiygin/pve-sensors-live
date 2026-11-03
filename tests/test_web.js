/* SPDX-License-Identifier: MIT */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('src/web/pve-sensors.js', 'utf8');

class Element {
  constructor() {
    this.listeners = new Map(); this.style = {}; this.dataset = {}; this.children = [];
    this.textContent = ''; this.className = ''; this.value = '';
    this.classList = { toggle() {} }; this.clientWidth = 800; this.clientHeight = 292;
  }
  addEventListener(name, callback) { this.listeners.set(name, callback); }
  removeEventListener(name, callback) { if (this.listeners.get(name) === callback) this.listeners.delete(name); }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  getContext() { return null; }
}
const payload = (sequence = 1) => ({
  session: 'abcdef0123456789', sequence,
  updated_at: new Date().toISOString(), sample_interval_ms: 500,
  metrics: [{id: 'cpu-1', name: 'CPU 1', category: 'cpu', unit: '°C', value: 42}],
});
const response = (status = 200, sequence = 1) => ({
  ok: status === 200, status, text: async () => JSON.stringify({data: payload(sequence)}),
  headers: {get: () => new Date().toUTCString()},
});
const settle = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };

function harness(fetchImpl = async () => response(), visible = true) {
  let definition;
  let timerId = 0;
  const timers = new Map();
  const frames = new Map();
  const requests = [];
  const elements = new Map();
  const root = {
    host: new Element(),
    getElementById(id) { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); },
    querySelector() { return this.getElementById('stylesheet'); },
  };
  const document = new Element();
  document.hidden = false;
  document.createElement = () => new Element();
  document.createTextNode = value => ({ textContent: value });
  const window = new Element();
  const theme = new Element();
  window.matchMedia = () => theme;
  const context = vm.createContext({
    Ext: { define(name, value) { assert.equal(name, 'PVE.node.Sensors'); definition = value; } },
    document, window, Intl, performance, AbortController,
    getComputedStyle: () => ({getPropertyValue: () => '#ffffff'}),
    setTimeout(callback, delay) { const id = ++timerId; timers.set(id, {callback, delay, kind: 'timeout'}); return id; },
    clearTimeout(id) { timers.delete(id); },
    setInterval(callback, delay) { const id = ++timerId; timers.set(id, {callback, delay, kind: 'interval'}); return id; },
    clearInterval(id) { timers.delete(id); },
    requestAnimationFrame(callback) { const id = ++timerId; frames.set(id, callback); return id; },
    cancelAnimationFrame(id) { frames.delete(id); },
    fetch(url, options) { requests.push({url, options}); return fetchImpl(url, options); },
  });
  vm.runInContext(source, context);
  assert.equal(definition.alias, 'widget.pveNodeSensors');
  const panel = { nodename: 'node-alpha', body: {dom: {attachShadow: () => root}}, isVisible: () => visible };
  const fire = name => definition.listeners[name].call(panel);
  fire('afterrender');
  return {panel, fire, root, elements, document, window, theme, timers, frames, requests,
    runTimeout() {
      const entry = [...timers].find(([, t]) => t.kind === 'timeout' && t.delay < 2000);
      assert.ok(entry, 'poll scheduled'); timers.delete(entry[0]); entry[1].callback();
    },
  };
}

(async () => {
  for (const status of [200, 401, 403, 503]) {
    const h = harness(async () => response(status));
    await settle();
    assert.equal(h.requests.length, 1, 'no public fallback');
    assert.equal(h.requests[0].url, '/api2/json/nodes/node-alpha/sensors');
    assert.equal(h.requests[0].options.credentials, 'same-origin');
    assert.equal(h.requests[0].options.cache, 'no-store');
    if (status === 200) {
      assert.equal(h.root.getElementById('cpuValue').textContent, '42 °C');
      assert.equal(h.root.getElementById('chartSamples').textContent, '1');
      const poll = [...h.timers.values()].find(t => t.kind === 'timeout');
      assert.ok(poll.delay <= 500 && poll.delay >= 50, '500 ms polling target retained');
    } else {
      assert.match(h.root.getElementById('updated').textContent,
        status === 401 ? /session expired/ : status === 403 ? /Sys.Audit/ : /Cannot read/);
    }
    h.fire('beforedestroy');
    assert.equal(h.timers.size, 0); assert.equal(h.frames.size, 0);
    assert.equal(h.document.listeners.size, 0); assert.equal(h.window.listeners.size, 0);
    assert.equal(h.theme.listeners.size, 0);
    assert.equal(h.root.getElementById('cpuSource').listeners.size, 0);
  }

  // A tab that has not been opened does not poll; activate starts it.
  const hidden = harness(undefined, false);
  assert.equal(hidden.requests.length, 0);
  hidden.fire('activate'); await settle();
  assert.equal(hidden.requests.length, 1);
  hidden.fire('deactivate');
  assert.equal(hidden.timers.size, 0); assert.equal(hidden.frames.size, 0);
  hidden.fire('activate'); await settle();
  assert.equal(hidden.requests.length, 2);
  hidden.document.hidden = true;
  hidden.document.listeners.get('visibilitychange')();
  assert.equal(hidden.timers.size, 0);
  hidden.document.hidden = false;
  hidden.document.listeners.get('visibilitychange')(); await settle();
  assert.equal(hidden.requests.length, 3);
  hidden.fire('beforedestroy');

  // Hide/show while an aborted request still settles: no overlap, stale render,
  // timeout message or lost future polling, even if transport ignores abort.
  let complete;
  const pending = harness(() => new Promise(resolve => { complete = resolve; }));
  pending.fire('deactivate');
  assert.equal(pending.requests[0].options.signal.aborted, true);
  pending.fire('activate');
  assert.equal(pending.requests.length, 1, 'only one request in flight');
  complete(response()); await settle();
  assert.equal(pending.root.getElementById('cpuValue').textContent, '', 'aborted response not rendered');
  assert.doesNotMatch(pending.root.getElementById('updated').textContent, /timed out/);
  pending.runTimeout();
  assert.equal(pending.requests.length, 2, 'polling resumes once old request settles');
  pending.fire('beforedestroy'); complete(response()); await settle();
  assert.equal(pending.timers.size, 0); assert.equal(pending.frames.size, 0);
  assert.equal(pending.root.getElementById('cpuValue').textContent, '', 'late response cannot mutate destroyed view');

  // Each newly created view starts an independent chart and DOM scope.
  const first = harness(); const second = harness(); await settle();
  assert.equal(first.root.getElementById('chartSamples').textContent, '1');
  assert.equal(second.root.getElementById('chartSamples').textContent, '1');
  first.fire('beforedestroy'); second.fire('beforedestroy');
  console.log('Native UI checks passed: rendering, auth errors, selected node, visibility, no overlap, abort races, destroy cleanup and isolated history.');
})().catch(error => { console.error(error); process.exitCode = 1; });
