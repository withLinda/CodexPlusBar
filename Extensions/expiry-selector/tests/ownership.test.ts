import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { expect, test, vi } from 'vitest';
import { acquireOwnership, implementationVersion, type OwnershipOptions } from '../src/plugin/ownership.js';
import { initialState } from '../src/plugin/state-store.js';
import type { NativeAccess } from '../src/plugin/coordinator.js';
const adapter = (locationKey: string): NativeAccess => ({ locationKey, version: () => '2.2.6', pluginIDs: async () => [],
  connections: async () => [], activeID: async () => null, validateIdentity: async () => { throw new Error('unused'); }, activate: async () => { throw new Error('must not activate'); } });

async function options(): Promise<OwnershipOptions> {
  return { directory: await mkdtemp(join(process.env.TMPDIR!, 'expiry-owner-')), port: 0, key: Symbol(),
    dependencies: { now: Date.now, readSnapshot: async () => ({ ok: false, code: 'snapshot-missing' }),
      loadState: async () => initialState(), saveState: async () => {} } };
}
test('first and last location own exactly one listener and private epoch descriptor', async () => {
  const input = await options();
  const first = await acquireOwnership(adapter('/one'), input);
  const second = await acquireOwnership(adapter('/two'), input);
  try {
    expect(first.coordinator).toBe(second.coordinator);
    const runtime = JSON.parse(await readFile(join(input.directory!, 'runtime.json'), 'utf8'));
    expect(runtime).toMatchObject({ protocolVersion: 1, pid: process.pid });
    expect(runtime.bearer).toMatch(/^[0-9a-f]{64}$/);
    expect((await stat(join(input.directory!, 'runtime.json'))).mode & 0o777).toBe(0o600);
    expect(JSON.stringify(first.coordinator.status())).not.toContain(runtime.bearer);
    const headers = { authorization: `Bearer ${runtime.bearer}`, 'X-Selector-Epoch': runtime.epoch };
    expect((await fetch(`http://127.0.0.1:${runtime.port}/v1/status`, { headers })).status).toBe(200);
    await first.detach();
    expect((await fetch(`http://127.0.0.1:${runtime.port}/v1/status`, { headers })).status).toBe(200);
    await second.detach();
    await expect(readFile(join(input.directory!, 'runtime.json'))).rejects.toThrow();
    await expect(fetch(`http://127.0.0.1:${runtime.port}/v1/status`)).rejects.toThrow();
  } finally { await first.detach(); await second.detach(); await rm(input.directory!, { recursive: true, force: true }); }
});

test('occupied port blocks ownership without overwriting existing descriptor', async () => {
  const input = await options();
  const first = await acquireOwnership(adapter('/one'), input);
  try {
    const before = await readFile(join(input.directory!, 'runtime.json'), 'utf8');
    const runtime = JSON.parse(before);
    const other = await acquireOwnership(adapter('/other-process'), { ...input, key: Symbol(), port: runtime.port });
    try {
      expect((await other.coordinator.requestSelection('tick'))).toMatchObject({ action: 'blocked', code: 'ownership-unavailable' });
      expect(await readFile(join(input.directory!, 'runtime.json'), 'utf8')).toBe(before);
    } finally { await other.detach(); }
  } finally { await first.detach(); await rm(input.directory!, { recursive: true, force: true }); }
});

test('same-location reload releases its adapter when the original acquisition detached first', async () => {
  const input = await options();
  const first = await acquireOwnership(adapter('/one'), input);
  const duplicate = await acquireOwnership(adapter('/one'), input);
  const other = await acquireOwnership(adapter('/two'), input);
  try {
    await first.detach();
    await duplicate.detach();
    const replacement = await acquireOwnership(adapter('/one'), input);
    await replacement.detach();
  } finally { await first.detach(); await duplicate.detach(); await other.detach(); await rm(input.directory!, { recursive: true, force: true }); }
});

test('incompatible global implementation never shares or replaces owner', async () => {
  const input = await options();
  const first = await acquireOwnership(adapter('/one'), input);
  try {
    await expect(acquireOwnership(adapter('/two'), { ...input, version: implementationVersion + '-other' })).rejects.toThrow('implementation');
    expect((await stat(join(input.directory!, 'runtime.json'))).isFile()).toBe(true);
  } finally { await first.detach(); await rm(input.directory!, { recursive: true, force: true }); }
});

test('location resources install once, dispose on final release, and timers stop on shutdown', async () => {
  vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval', 'setTimeout', 'clearTimeout'] });
  const input = await options(); let setups = 0, cleanups = 0;
  input.setupLocation = async () => { setups++; return async () => { cleanups++; }; };
  const one = await acquireOwnership(adapter('/one'), input);
  const again = await acquireOwnership(adapter('/one'), input);
  const two = await acquireOwnership(adapter('/two'), input);
  try {
    expect(setups).toBe(2); expect(vi.getTimerCount()).toBe(1);
    await one.detach(); expect(cleanups).toBe(0);
    await again.detach(); expect(cleanups).toBe(1);
    await two.detach(); expect(cleanups).toBe(2); expect(vi.getTimerCount()).toBe(0);
  } finally { await one.detach(); await again.detach(); await two.detach(); vi.useRealTimers(); await rm(input.directory!, { recursive: true, force: true }); }
});

test('reload waits for last-owner cleanup before publishing a new epoch', async () => {
  const input = await options(), release = Promise.withResolvers<void>(), started = Promise.withResolvers<void>();
  input.setupLocation = async () => async () => { started.resolve(); await release.promise; };
  const first = await acquireOwnership(adapter('/one'), input);
  const old = JSON.parse(await readFile(join(input.directory!, 'runtime.json'), 'utf8'));
  const closing = first.detach(); await started.promise;
  let acquired = false;
  const next = acquireOwnership(adapter('/two'), input).then(value => { acquired = true; return value; });
  expect(acquired).toBe(false);
  release.resolve(); await closing;
  const second = await next;
  try {
    const current = JSON.parse(await readFile(join(input.directory!, 'runtime.json'), 'utf8'));
    expect(current.epoch).not.toBe(old.epoch);
  } finally { await second.detach(); await rm(input.directory!, { recursive: true, force: true }); }
});

test('all controls require bearer and epoch, reject browser origins and bounded invalid JSON', async () => {
  const input = await options(); const owner = await acquireOwnership(adapter('/one'), input);
  try {
    const runtime = JSON.parse(await readFile(join(input.directory!, 'runtime.json'), 'utf8'));
    const origin = `http://127.0.0.1:${runtime.port}`;
    const headers = { authorization: `Bearer ${runtime.bearer}`, 'x-selector-epoch': runtime.epoch, 'content-type': 'application/json' };
    expect((await fetch(origin + '/v1/status')).status).toBe(401);
    expect((await fetch(origin + '/v1/status', { headers: { ...headers, 'x-selector-epoch': 'stale' } })).status).toBe(409);
    expect((await fetch(origin + '/v1/status', { headers: { ...headers, origin: 'https://evil.test' } })).status).toBe(403);
    expect((await fetch(origin + '/v1/mode', { method: 'POST', headers, body: '{broken' })).status).toBe(400);
    expect((await fetch(origin + '/v1/mode', { method: 'POST', headers, body: ' '.repeat(65_537) })).status).toBe(413);
    const operationID = crypto.randomUUID();
    const begin = () => fetch(origin + '/v1/maintenance/begin', { method: 'POST', headers, body: JSON.stringify({ operationID, reason: 'manual-account-change' }) });
    const held = await (await begin()).json();
    expect(await (await begin()).json()).toEqual(held);
    expect(held).toMatchObject({ protocolVersion: 1, epoch: runtime.epoch, holdToken: expect.any(String) });
    expect(JSON.stringify(await (await fetch(origin + '/v1/status', { headers })).json())).not.toContain(held.holdToken);
  } finally { await owner.detach(); await rm(input.directory!, { recursive: true, force: true }); }
});
