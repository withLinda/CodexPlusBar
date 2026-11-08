import { afterAll, beforeAll, expect, test } from 'vitest';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { startHarness } from './harness.js';
import { fakeProvider } from './fake-provider.js';
import { accounts } from './fixtures.js';

let runtime: Awaited<ReturnType<typeof startHarness>>, provider: Awaited<ReturnType<typeof fakeProvider>>;
beforeAll(async () => { provider = await fakeProvider(); runtime = await startHarness(provider.origin, undefined, false, true); });
afterAll(async () => { await runtime?.close(); await provider?.close(); });
async function active() { return (await runtime.api('/api/credential')).data.find((row: any) => row.integrationID === 'openai' && row.active)?.id; }
async function session() {
  const { data: session } = await runtime.api('/api/session', { title: 'Production fixture', model: { providerID: 'openai', id: 'gpt-5.7' }, location: { directory: runtime.locations[0] } });
  return session.id as string;
}
test('production prompt selects earliest eligible native identity before first transport', async () => {
  await runtime.api(`/api/credential/${accounts.B.id}/activate`, {});
  expect((await runtime.rpc('status')).mode).toBe('paused');
  await runtime.rpc('mode', { mode: 'auto' });
  const id = await session();
  await runtime.api(`/api/session/${id}/prompt`, { text: 'Fixture.' });
  await runtime.api(`/api/experimental/session/${id}/wait`, {});
  expect(provider.requests.map(row => [row.accountID, row.header]), runtime.diagnostic()).toEqual([[accounts.A.accountID, accounts.A.accountID]]);
  expect(await active()).toBe(accounts.A.id);
});

test('production late quota attribution persists only A and retries already active B', async () => {
  const arrived = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  provider.behaviors.push(async () => { arrived.resolve(); await release.promise; return 'quota'; });
  const before = provider.requests.length;
  const switches = (await runtime.rpc('status')).recentHistory.filter((row: any) => row.code === 'activated').length;
  const id = await session(); await runtime.api(`/api/session/${id}/prompt`, { text: 'Fixture quota.' });
  await arrived.promise;
  await runtime.api(`/api/credential/${accounts.B.id}/activate`, {}, runtime.locations[1]);
  release.resolve(); await runtime.api(`/api/experimental/session/${id}/wait`, {});
  expect(provider.requests.slice(before).map(row => row.accountID)).toEqual([accounts.A.accountID, accounts.B.accountID]);
  const status = await runtime.rpc('status');
  expect(status.recentHistory.filter((row: any) => row.code === 'activated')).toHaveLength(switches);
  const state = JSON.parse(await readFile(join(runtime.root, 'home/.codexplusbar-selector/state.json'), 'utf8'));
  expect(Object.keys(state.cooldowns)).toHaveLength(1);
});

test('production reload detects competitor in either location and unload releases private descriptor', async () => {
  await runtime.configure(true, true);
  await expect(runtime.rpc('mode', { mode: 'auto' })).rejects.toThrow();
  expect(await active()).toBe(accounts.B.id);
  await runtime.rpc('mode', { mode: 'paused' });
  await runtime.configure(false);
  await expect(readFile(join(runtime.root, 'home/.codexplusbar-selector/runtime.json'))).rejects.toThrow();
  await runtime.configure(true);
  expect((await runtime.rpc('status')).mode).toBe('paused');
});

test('production ownership refuses a second OS process on the occupied port', async () => {
  const before = await readFile(join(runtime.root, 'home/.codexplusbar-selector/runtime.json'), 'utf8');
  const other = await startHarness(provider.origin, runtime.coordinatorPort, false, true);
  try {
    await expect(other.rpc('mode', { mode: 'auto' })).rejects.toThrow();
    expect((await other.rpc('status')).blockedReason).toBe('ownership-unavailable');
    await expect(readFile(join(other.root, 'home/.codexplusbar-selector/runtime.json'))).rejects.toThrow();
    expect(await readFile(join(runtime.root, 'home/.codexplusbar-selector/runtime.json'), 'utf8')).toBe(before);
  } finally { await other.close(); }
});
