import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { expect, test } from 'vitest';
import type { Plugin } from '@opencode/plugin';
import { installSelector } from '../src/plugin/index.js';
import { initialState } from '../src/plugin/state-store.js';
import type { OwnershipOptions } from '../src/plugin/ownership.js';
import type { SelectorExportV1 } from '../src/shared/contracts.js';

const snapshot = JSON.parse(await readFile(new URL('./fixtures/selector-v1.json', import.meta.url), 'utf8')) as SelectorExportV1;
const now = 1_800_000_000_000;
async function fixture(version = '2.3.0') {
  const directory = await mkdtemp(join(process.env.TMPDIR!, 'expiry-compatibility-'));
  const hooks = new Set<string>();
  const endEvents = Promise.withResolvers<void>();
  let activations = 0, rejectHook = '', malformedHook = '', waitHook = '';
  const enteredHook = Promise.withResolvers<void>(), releaseHook = Promise.withResolvers<void>();
  const ctx: any = {
    app: { version }, location: { directory },
    plugin: { list: async () => ({ data: [] }) },
    session: { get: async () => ({ model: { providerID: 'openai' } }),
      hook: async (name: string) => {
        if (name === waitHook) { enteredHook.resolve(); await releaseHook.promise; }
        if (name === rejectHook) throw new Error('fixture: hook removed');
        if (name === malformedHook) return {};
        hooks.add(name);
        return { dispose: async () => { hooks.delete(name); } };
      } },
    event: { subscribe: ({ signal }: { signal: AbortSignal }) => (async function* () {
      signal.addEventListener('abort', () => endEvents.resolve(), { once: true });
      await endEvents.promise;
    })() },
    integration: { get: async () => ({ data: { id: 'openai', connections: snapshot.accounts.map(row =>
      ({ type: 'credential', id: row.credentialID, label: row.label, method: 'oauth' })) } }),
      connection: { active: async () => ({ type: 'credential', id: 'credential-b' }),
        resolve: async () => { throw new Error('must not resolve in compatibility tests'); } } },
    credential: { activate: async () => { activations++; } },
  };
  const options: OwnershipOptions = { directory, snapshotPath: join(directory, 'absent-export'), port: 0, key: Symbol(),
    dependencies: { now: () => now, readSnapshot: async () => ({ ok: true, snapshot, exclusions: [] }),
      loadState: async () => initialState(), saveState: async () => {} } };
  return { ctx, options, hooks, endEvents, enteredHook, releaseHook, activations: () => activations,
    install: () => installSelector(ctx as Plugin.Context, options),
    reject(name: string) { rejectHook = name; }, malformed(name: string) { malformedHook = name; },
    wait(name: string) { waitHook = name; },
    cleanup: () => rm(directory, { recursive: true, force: true }) };
}

test.each(['2.3.0', '2.99.0', '3.0.0', 'future-build'])
('installed plugin permits Auto on %s after required hooks register', async version => {
  const h = await fixture(version);
  const owner = await h.install();
  try {
    expect(await owner.coordinator.setMode('auto', 'enable')).toMatchObject({ mode: 'auto', blockedReason: null });
    expect(h.hooks.size).toBe(5);
  } finally { await owner.detach(); await h.cleanup(); }
  expect(h.hooks.size).toBe(0);
});

test.each([
  ['plugin', 'list', 'native-api-unavailable'],
  ['session', 'get', 'native-api-unavailable'],
  ['integration', 'get', 'native-api-unavailable'],
  ['integration.connection', 'active', 'native-api-unavailable'],
  ['integration.connection', 'resolve', 'native-api-unavailable'],
  ['credential', 'activate', 'native-api-unavailable'],
  ['session', 'hook', 'hooks-unavailable'],
  ['event', 'subscribe', 'lifecycle-unavailable'],
])('missing %s.%s blocks Auto with a useful diagnostic', async (parent, method, issue) => {
  const h = await fixture('2.2.6');
  const target = parent.split('.').reduce((value, key) => value[key], h.ctx);
  delete target[method];
  let owner: Awaited<ReturnType<typeof h.install>> | undefined;
  try {
    owner = await h.install();
    await expect(owner.coordinator.setMode('auto', 'enable')).rejects.toThrow(issue);
    expect(await owner.coordinator.recheck('inspect')).toMatchObject({ blockedReason: issue });
    expect(h.activations()).toBe(0);
  } finally { await owner?.detach(); await h.cleanup(); }
});

test('a partially registered location blocks Auto until setup finishes', async () => {
  const h = await fixture('2.2.6');
  h.wait('retry');
  const installing = h.install();
  await h.enteredHook.promise;
  const runtime = JSON.parse(await readFile(join(h.options.directory!, 'runtime.json'), 'utf8'));
  try {
    const result = await fetch(`http://127.0.0.1:${runtime.port}/v1/mode`, { method: 'POST',
      headers: { authorization: `Bearer ${runtime.bearer}`, 'X-Selector-Epoch': runtime.epoch, 'content-type': 'application/json' },
      body: JSON.stringify({ mode: 'auto', operationID: crypto.randomUUID() }) });
    expect(result.ok).toBe(false);
    expect(h.activations()).toBe(0);
  } finally {
    h.releaseHook.resolve();
    const owner = await installing;
    try { expect(await owner.coordinator.setMode('auto', 'ready')).toMatchObject({ mode: 'auto' }); }
    finally { await owner.detach(); await h.cleanup(); }
  }
});

test.each(['reject', 'malformed'] as const)('%s required hook blocks Auto and cleans partial registrations', async kind => {
  const h = await fixture('2.2.6');
  h[kind]('retry');
  let owner: Awaited<ReturnType<typeof h.install>> | undefined;
  try {
    owner = await h.install();
    await expect(owner.coordinator.setMode('auto', 'enable')).rejects.toThrow('hooks-unavailable');
    expect(h.hooks.size).toBe(0);
    expect(h.activations()).toBe(0);
  } finally { await owner?.detach(); await h.cleanup(); }
});

test.each(['invalid', 'ended'] as const)('%s lifecycle subscription blocks Auto', async kind => {
  const h = await fixture('2.2.6');
  if (kind === 'invalid') h.ctx.event.subscribe = () => ({});
  const owner = await h.install();
  try {
    if (kind === 'ended') {
      await owner.coordinator.setMode('auto', 'enable');
      h.endEvents.resolve();
    }
    await expect.poll(async () => (await owner.coordinator.recheck(crypto.randomUUID())).blockedReason).toBe('lifecycle-unavailable');
    await expect(owner.coordinator.setMode('auto', 'resume')).rejects.toThrow('lifecycle-unavailable');
    expect(h.activations()).toBe(0);
  } finally { await owner.detach(); await h.cleanup(); }
  expect(h.hooks.size).toBe(0);
});
