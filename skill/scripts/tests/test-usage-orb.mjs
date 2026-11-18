#!/usr/bin/env node
// Exercise the renderer's actual quota adapter with native QueryClient/fiber
// fixtures. No application, browser, credentials, or network are required.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../../assets/renderer-inject.js', import.meta.url), 'utf8');
const quotaCode = source.slice(source.indexOf('  // Quota is account/session data'), source.indexOf('  const syncThemeMeta'));
const orbCode = source.slice(source.indexOf('  const formatResetTime'), source.indexOf('  const textNodesOutside'));
const updateCode = source.slice(source.indexOf('    const resolvedUsage ='), source.indexOf('    document.querySelectorAll(".dream-usage-orb")'));
const now = 1_800_000_000_000;
let clock = now;
const profile = {};
const main = {};
const sidebar = { querySelector: () => profile };
const fill = {};
const attributes = new Map();
const orb = {
  dataset: {}, style: { setProperty() {} },
  querySelector: () => fill,
  setAttribute: (key, value) => attributes.set(key, value),
  removeAttribute: key => attributes.delete(key),
};
const composer = { querySelector: () => orb };
const context = vm.createContext({
  Date: class extends Date { static now() { return clock; } },
  document: { querySelector: () => main },
  // Old cached values deliberately exist; they must never be consumed.
  previous: { usagePercent: 99, usageResetAt: now / 1000 - 10 },
  localStorage: { getItem() { throw new Error('quota must not read persistent storage'); } },
});
const api = vm.runInContext(`${quotaCode}\n${orbCode}\n({
  readWeeklyUsage, findUsageQueryClients, resolveUsageData,
  update(sidePanel, composer) { ${updateCode} syncUsageOrb(composer); },
  get values() { return [usagePercent, usageResetAt]; }
})`, context);
const plain = value => JSON.parse(JSON.stringify(value));
const status = (used = 24, reset = clock / 1000 + 86400) => ({ rate_limit: {
  primary_window: { used_percent: 5, limit_window_seconds: 18000, reset_at: clock / 1000 + 3600 },
  secondary_window: { used_percent: used, limit_window_seconds: 604800, reset_at: reset },
} });
let data = status();
let updatedAt = now;
let refreshCount = 0;
const client = {
  getQueryData(key) { assert.deepEqual(plain(key), ['rate-limit-status']); return data; },
  getQueryState() { return { dataUpdatedAt: updatedAt }; },
  refetchQueries(options) {
    assert.deepEqual(plain(options), { queryKey: ['rate-limit-status'], exact: true });
    refreshCount++;
    return Promise.reject(new Error('simulated offline refresh'));
  },
};
function attach(value, target = profile) { target.__reactFiber$test = value; }
function update() { api.update(sidebar, composer); return plain(api.values); }

assert.deepEqual(update(), [null, null], 'legacy injection/cache cannot seed current usage');
assert.equal(orb.dataset.tooltip, 'Weekly usage unavailable');
assert.equal(attributes.has('aria-valuenow'), false);

for (const fixture of [
  { memoizedState: { memoizedState: client } },
  { memoizedState: { memoizedState: { current: client } } },
  { memoizedState: { memoizedState: [client, []] } },
  { memoizedState: { memoizedState: { deps: [{ queryClient: client }] } } },
  { dependencies: { firstContext: { memoizedValue: client } } },
  { memoizedProps: { value: client } },
  { alternate: { dependencies: { firstContext: { memoizedValue: client } } } },
]) {
  attach(fixture);
  assert.deepEqual(update(), [76, now / 1000 + 86400], 'read current weekly cache through native fiber');
}
assert.equal(refreshCount, 0, 'fresh native quota needs no extra request');
assert.match(orb.dataset.tooltip, /^Weekly · 76% remaining\nResets /);
assert.equal(attributes.get('aria-valuenow'), '76');

// Cache data changes while the DOM still points at the same fiber.
data = status(41, now / 1000 + 172800);
assert.deepEqual(update(), [59, now / 1000 + 172800]);
data = status(42, null);
assert.deepEqual(update(), [58, null], 'missing reset must clear the previous reset');
assert.doesNotMatch(orb.dataset.tooltip, /Resets/);

for (const reset of [now / 1000 - 1, now / 1000, now + 86400000, 'tomorrow', NaN, Infinity]) {
  data = status(30, reset);
  assert.deepEqual(update(), [null, null], 'expired or malformed reset must clear both fields');
}
assert.equal(refreshCount, 1, 'failed refresh retries are throttled');
data = status();
clock += 61_000;
assert.deepEqual(update(), [76, now / 1000 + 86400]);
assert.equal(refreshCount, 2, 'refresh stale native query once a minute');
clock += 5 * 60_000;
assert.deepEqual(update(), [null, null], 'too-old cache is unavailable even before weekly reset');
updatedAt = clock;
data = status(50);
assert.deepEqual(update(), [50, clock / 1000 + 86400], 'fresh data recovers normally');

// Logout or removal of the weekly window must not preserve prior account data.
data = null;
assert.deepEqual(update(), [null, null]);
data = status();
delete data.rate_limit.secondary_window;
assert.deepEqual(update(), [null, null], 'five-hour usage must not masquerade as weekly usage');
for (const used of [-1, 101, NaN, Infinity, '24']) {
  data = status(used);
  assert.deepEqual(update(), [null, null], 'invalid used_percent is not clamped into a plausible value');
}
data = status(100);
assert.equal(update()[0], 0, 'zero remaining is available data');
data = status(0);
assert.equal(update()[0], 100);

// The profile button can be absent after a client update or sidebar collapse.
delete profile.__reactFiber$test;
attach({ dependencies: { firstContext: { memoizedValue: client } } }, main);
assert.equal(update()[0], 100, 'main renderer context provides the same native query');
delete main.__reactFiber$test;
attach({ memoizedProps: { remainingPercent: '88%' } });
assert.deepEqual(update(), [null, null], 'ambiguous remainingPercent must not override weekly data');
assert.equal(attributes.has('aria-valuenow'), false);

// Current clients scope query keys by account and keep inactive queries around.
const scopedKey = ['rate-limit-status', 'current-account', 'current-user'];
const current = { queryKey: scopedKey, isActive: () => true,
  state: { data: status(19), dataUpdatedAt: clock } };
const inactive = { queryKey: ['rate-limit-status', 'previous-account', 'previous-user'],
  isActive: () => false, state: { data: status(99), dataUpdatedAt: clock + 1 } };
const scopedClient = {
  getQueryData: () => undefined,
  getQueryCache: () => ({ getAll: () => [inactive, current] }),
  refetchQueries(options) { assert.deepEqual(plain(options.queryKey), scopedKey); return Promise.resolve(); },
};
attach({ memoizedProps: { value: scopedClient } });
assert.equal(update()[0], 81, 'active account-scoped query beats newer inactive data');
clock += 61_000;
assert.equal(update()[0], 81, 'refresh uses the complete observed native query key');
current.state.data = undefined;
assert.deepEqual(update(), [null, null], 'account loading must not reuse previous account data');
current.isActive = () => false;
assert.deepEqual(update(), [null, null], 'no active account is unavailable');
await new Promise(resolve => setImmediate(resolve));
console.log('PASS usage orb: current query discovery, weekly selection, atomic updates, expiry, refresh throttling and recovery');
