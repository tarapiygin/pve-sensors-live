/* SPDX-License-Identifier: MIT */
// Portable transport tests; no browser, server or npm packages required.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('src/web/pve-sensors.js', 'utf8')
  .split("byId('cpuSource').addEventListener")[0];
const payload = {
  session: 'abcdef0123456789', sequence: 1,
  updated_at: new Date().toISOString(), sample_interval_ms: 500,
  metrics: [{id: 'cpu-1', name: 'CPU 1', category: 'cpu', unit: '°C', value: 42}],
};
(async () => {
  for (const status of [200, 401, 403, 503]) {
    const calls = [];
    const context = vm.createContext({
      document: {hidden: false, getElementById: () => ({})},
      window: {location: {search: '?node=test-node'}},
      Intl, performance, URLSearchParams, AbortController,
      setTimeout: () => 1, clearTimeout: () => {},
      fetch: async (url, options) => {
        calls.push({url, options});
        return {ok: status === 200, status, text: async () => JSON.stringify({data: payload}),
          headers: {get: () => new Date().toUTCString()}};
      },
    });
    vm.runInContext(source + '\nrender = () => {}; updateConnection = () => {}; requestChart = () => {};', context);
    await vm.runInContext('refresh()', context);
    assert.equal(calls.length, 1, 'no fallback request');
    assert.equal(calls[0].url, '/api2/json/nodes/test-node/sensors');
    assert.equal(calls[0].options.credentials, 'same-origin');
    assert.equal(calls[0].options.cache, 'no-store');
    if (status === 200) {
      assert.equal(vm.runInContext('latestPayload.metrics[0].value', context), 42);
      assert.equal(vm.runInContext('refreshMs', context), 500);
    } else {
      assert.equal(vm.runInContext('latestPayload', context), null);
      const message = vm.runInContext('errorMessage', context);
      assert.match(message, status === 401 ? /Log in/ : status === 403 ? /Sys.Audit/ : /Cannot read/);
    }
  }
  console.log('Transport checks passed: authenticated API envelope, 401, 403, 503; no fallback.');
})().catch(error => { console.error(error); process.exitCode = 1; });
