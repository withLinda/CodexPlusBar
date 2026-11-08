import { afterAll, afterEach, beforeAll, expect, test } from 'vitest';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';
import { startHarness } from './harness.js';
import { fakeProvider } from './fake-provider.js';
import { accounts, credential } from './fixtures.js';
import type { SelectorExportV1 } from '../../src/shared/contracts.js';

let runtime: Awaited<ReturnType<typeof startHarness>>, provider: Awaited<ReturnType<typeof fakeProvider>>;
beforeAll(async () => { provider = await fakeProvider(); runtime = await startHarness(provider.origin, undefined, true, false, true); });
afterAll(async () => { await runtime?.close(); await provider?.close(); });
afterEach(() => { provider?.refresh.gate?.resolve(); });
const descriptorPath = () => join(runtime.root, 'home/.codexplusbar-selector/runtime.json');
async function control(route = 'status', body?: object) {
  const d = JSON.parse(await readFile(descriptorPath(), 'utf8'));
  // Never contact a preexisting live owner on the fixed port.
  expect(d.pid).toBe((await runtime.api('/api/info')).pid);
  const response = await fetch(`http://127.0.0.1:53971/v1/${route}`, { method: body ? 'POST' : 'GET',
    headers: { authorization: `Bearer ${d.bearer}`, 'x-selector-epoch': d.epoch, 'content-type': 'application/json' },
    ...(body ? { body: JSON.stringify({ operationID: crypto.randomUUID(), ...body }) } : {}), signal: AbortSignal.timeout(30_000) });
  const value = await response.json(); if (!response.ok) throw new Error(`Control ${response.status}: ${JSON.stringify(value)}`); return value;
}
async function snapshot(change: (value: SelectorExportV1) => void) {
  const value = JSON.parse(await readFile(runtime.snapshotPath, 'utf8')) as SelectorExportV1;
  value.sequence++; value.generatedAtMs = Date.now(); change(value);
  await writeFile(runtime.snapshotPath, JSON.stringify(value), { mode: 0o600 });
}
async function active() { return (await runtime.api('/api/credential')).data.find((row: any) => row.integrationID === 'openai' && row.active)?.id; }
async function prompt(title: string | undefined = 'Built package fixture', location = runtime.locations[0]) {
  const { data: s } = await runtime.api('/api/session', { title, model: { providerID: 'openai', id: 'gpt-5.7' }, location: { directory: location } });
  await runtime.api(`/api/session/${s.id}/prompt`, { text: 'Fixture.' });
  return s.id as string;
}
async function wait(id: string) { await runtime.api(`/api/experimental/session/${id}/wait`, {}); }
async function reloadLocations() {
  for (const location of runtime.locations) await runtime.api('/api/location/reload', {}, location);
  // Reload invalidates locations; plugin inventory waits for lazy location startup.
  for (const location of runtime.locations) { await runtime.api('/api/plugin', undefined, location); await runtime.api('/api/integration', undefined, location); }
}

test('built extension installs in two locations and prefers 17-day subscription over 30-day subscription', async () => {
  for (const location of runtime.locations) expect((await runtime.api('/api/plugin', undefined, location)).data.some((p: any) => p.id === 'codexplusbar-expiry-selector' && p.state.status === 'active')).toBe(true);
  expect((await control()).mode).toBe('paused');
  await runtime.api(`/api/credential/${accounts.B.id}/activate`, {});
  await control('mode', { mode: 'auto' }); await wait(await prompt());
  expect(await active()).toBe(accounts.A.id);
  expect(provider.requests.at(-1)).toMatchObject({ accountID: accounts.A.accountID, header: accounts.A.accountID });
});

test('built selector excludes five-hour/weekly exhaustion and recovers on fresh positive evidence', async () => {
  await snapshot(s => { s.accounts[0]!.usage!.fiveHour.remainingPercent = 0; });
  await control('recheck', {}); expect(await active()).toBe(accounts.B.id);
  await snapshot(s => { const u = s.accounts[0]!.usage!; u.fiveHour.remainingPercent = 60; u.sevenDay = { state: 'available', remainingPercent: 0, resetAtMs: Date.now() + 3600000 }; });
  await control('recheck', {}); expect(await active()).toBe(accounts.B.id);
  await snapshot(s => { const u = s.accounts[0]!.usage!; u.observedAtMs = Date.now(); u.sevenDay = { state: 'available', remainingPercent: 50, resetAtMs: Date.now() + 3600000 }; });
  await control('recheck', {}); expect(await active()).toBe(accounts.A.id);
});

test('built quota retry keeps tools and model, persists cooldown across OS process restart', async () => {
  const before = provider.requests.length, initial = await runtime.rpc('status');
  provider.behaviors.push(async () => 'tool', async () => 'quota');
  await wait(await prompt());
  expect(provider.requests.slice(before).map(row => row.accountID)).toEqual([accounts.A.accountID, accounts.A.accountID, accounts.B.accountID]);
  expect(provider.requests.slice(before).every(row => row.model === 'gpt-5.7')).toBe(true);
  expect(provider.requests.slice(before).map(row => row.toolResults)).toEqual([0, 1, 1]);
  expect((await runtime.rpc('status')).effects - initial.effects).toBe(1);
  expect((await runtime.rpc('status')).prompts - initial.prompts).toBe(1);
  const oldEpoch = (await control()).epoch;
  await runtime.restart();
  expect((await control()).epoch).not.toBe(oldEpoch);
  await control('recheck', {}); expect(await active()).toBe(accounts.B.id);
  const state = JSON.parse(await readFile(join(runtime.root, 'home/.codexplusbar-selector/state.json'), 'utf8'));
  expect(Object.keys(state.cooldowns)).toHaveLength(1);
  expect(JSON.stringify(state)).not.toContain('fixture-refresh');
});

test('stale publisher preserves native requests and recreated credential ID needs verified rebind', async () => {
  await snapshot(s => { s.generatedAtMs = Date.now() - 100_000; });
  expect((await control('recheck', {})).blockedReason).toBe('publisher-stale');
  const before = provider.requests.length; await wait(await prompt());
  expect(provider.requests.slice(before).map(row => row.accountID)).toEqual([accounts.B.accountID]);
  await control('mode', { mode: 'paused' });
  await runtime.api(`/api/credential/${accounts.A.id}`, undefined, runtime.locations[0], 'DELETE');
  await runtime.api('/api/credential', { id: 'cred_recreated_a', integrationID: 'openai', label: 'Recreated A', value: credential('A'), activate: false });
  await snapshot(() => {});
  // Credential changes broadcast config.updated asynchronously; wait for a new
  // completed inspection after the cancellation generation has settled.
  await expect.poll(async () => (await control('recheck', {})).exclusions).toContainEqual({ credentialID: accounts.A.id, code: 'binding-missing' });
  await snapshot(s => { s.accounts[0]!.credentialID = 'cred_recreated_a'; });
  await expect.poll(async () => (await control('recheck', {})).exclusions).toContainEqual({ credentialID: 'cred_recreated_a', code: 'cooldown' });
  // Deterministically advance the persisted reset while unloaded; retain failure evidence.
  runtime.hostAction('disable'); await reloadLocations();
  const path = join(runtime.root, 'home/.codexplusbar-selector/state.json'), state = JSON.parse(await readFile(path, 'utf8'));
  for (const row of Object.values(state.cooldowns) as any[]) row.resetAtMs = Date.now() - 1;
  await writeFile(path, JSON.stringify(state), { mode: 0o600 });
  await snapshot(s => { s.accounts[0]!.usage!.observedAtMs = Date.now(); });
  runtime.hostAction('enable'); await reloadLocations();
  await control('mode', { mode: 'auto' }); await control('recheck', {});
  expect(await active()).toBe('cred_recreated_a');
});

test('built HTTP and WS account pairs remain coherent across native switches', async () => {
  await runtime.rpc('control', { websocket: true });
  await control('mode', { mode: 'paused' });
  const before = provider.websockets.length;
  const id = await prompt(); await wait(id);
  await runtime.api(`/api/credential/${accounts.B.id}/activate`, {});
  await runtime.api(`/api/session/${id}/prompt`, { text: 'Fixture continuation.' }); await wait(id);
  expect(provider.websockets.slice(before).map(s => [s.accountID, s.header])).toEqual([[accounts.A.accountID, accounts.A.accountID], [accounts.B.accountID, accounts.B.accountID]]);
  expect(provider.websockets[before + 1]!.frames[0]!.previous).toBe(false);
  expect(provider.websockets[before + 1]!.frames[0]!.inputs).toBeGreaterThan(provider.websockets[before]!.frames[0]!.inputs);
  await runtime.rpc('control', { websocket: false });
});

test('built maintenance barrier rejects resume, then paused manual Use and resume work', async () => {
  const hold = await control('maintenance/begin', { reason: 'manual-account-change' });
  await expect(control('mode', { mode: 'auto' })).rejects.toThrow('409');
  await runtime.api(`/api/credential/${accounts.B.id}/activate`, {});
  expect((await control('recheck', {})).activeCredentialID).toBe(accounts.B.id);
  expect((await control('maintenance/end', { holdToken: hold.holdToken })).mode).toBe('paused');
  await control('mode', { mode: 'auto' }); await control('recheck', {}); expect(await active()).toBe('cred_recreated_a');
});

test.each([
  { websocket: false, headerCase: 'chatgpt-account-id' }, { websocket: false, headerCase: 'ChatGPT-Account-ID' },
  { websocket: true, headerCase: 'chatgpt-account-id' }, { websocket: true, headerCase: 'ChatGPT-Account-ID' },
])('built coherence guard repairs delayed native header publication: $headerCase WS=$websocket', async ({ websocket, headerCase }) => {
  await control('mode', { mode: 'paused' });
  await runtime.api('/api/credential/cred_recreated_a/activate', {});
  await runtime.rpc('control', { holdHeader: false, websocket });
  const before = websocket ? provider.websockets.length : provider.requests.length;
  const reloads = (await runtime.rpc('status')).delayedReloads;
  await runtime.rpc('control', { holdHeader: true, headerCase });
  try {
    await runtime.api(`/api/credential/${accounts.B.id}/activate`, {});
    await expect.poll(async () => (await runtime.rpc('status')).delayedReloads).toBeGreaterThan(reloads);
    await wait(await prompt());
    const rows = (websocket ? provider.websockets : provider.requests).slice(before);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ accountID: accounts.B.accountID, header: accounts.B.accountID });
  } finally { await runtime.rpc('control', { holdHeader: false, websocket: false }); }
});

test('built synthetic wake uses native selection without injecting a user prompt', async () => {
  const initial = await runtime.rpc('status'), before = provider.requests.length;
  const { data: s } = await runtime.api('/api/session', { title: 'Wake fixture', location: { directory: runtime.locations[0] } });
  await runtime.api(`/api/session/${s.id}/synthetic`, { text: 'Fixture wake.' }); await wait(s.id);
  expect(provider.requests.slice(before).map(row => row.accountID)).toEqual([accounts.B.accountID]);
  expect((await runtime.rpc('status')).prompts).toBe(initial.prompts);
});

test('50 concurrent built-package prompts across locations converge with one activation', async () => {
  await control('mode', { mode: 'paused' });
  await runtime.api(`/api/credential/${accounts.B.id}/activate`, {});
  const before = provider.requests.length, switches = (await control()).recentHistory.filter((row: any) => row.code === 'activated').length;
  await control('mode', { mode: 'auto' });
  const ids = await Promise.all(Array.from({ length: 50 }, (_, i) => prompt('Concurrent fixture', runtime.locations[i % 2])));
  await Promise.all(ids.map(wait));
  expect(provider.requests.slice(before)).toHaveLength(50);
  expect(provider.requests.slice(before).every(row => row.accountID === accounts.A.accountID && row.header === accounts.A.accountID)).toBe(true);
  expect((await control()).recentHistory.filter((row: any) => row.code === 'activated').length - switches).toBe(1);
});

test('two late failing sessions and a simultaneous title keep only A in cooldown', async () => {
  await runtime.rpc('control', { skipTitle: false, holdTitle: true });
  const arrivals = [Promise.withResolvers<void>(), Promise.withResolvers<void>()], release = Promise.withResolvers<void>();
  const before = provider.requests.length;
  provider.behaviors.push(...arrivals.map(arrival => async () => { arrival.resolve(); await release.promise; return 'quota' as const; }));
  const ids: string[] = [];
  try {
    // No title supplied: native title generation overlaps the two primary requests.
    const { data: s } = await runtime.api('/api/session', { location: { directory: runtime.locations[0] } });
    ids.push(s.id); await runtime.api(`/api/session/${s.id}/prompt`, { text: 'Fixture title.' });
    await arrivals[0]!.promise; ids.push(await prompt()); await arrivals[1]!.promise;
    await expect.poll(async () => (await runtime.rpc('status')).titleWaiting).toBe(true);
    await runtime.api(`/api/credential/${accounts.B.id}/activate`, {}, runtime.locations[1]);
    await runtime.rpc('control', { releaseTitle: true });
    await expect.poll(() => provider.requests.slice(before).some(row => row.kind === 'title')).toBe(true);
  } finally { release.resolve(); await runtime.rpc('control', { skipTitle: true, releaseTitle: true }); }
  await Promise.all(ids.map(wait));
  const requests = provider.requests.slice(before);
  expect(requests.filter(row => row.kind === 'primary').map(row => row.accountID)).toEqual([accounts.A.accountID, accounts.A.accountID, accounts.B.accountID, accounts.B.accountID]);
  expect(requests.every(row => row.accountID === row.header)).toBe(true);
  const state = JSON.parse(await readFile(join(runtime.root, 'home/.codexplusbar-selector/state.json'), 'utf8'));
  expect(Object.keys(state.cooldowns)).toEqual([(JSON.parse(await readFile(runtime.snapshotPath, 'utf8'))).accounts[0].identityKey]);
  expect(await active()).toBe(accounts.B.id);
});

test('native user cancellation does not rotate or mark a healthy account exhausted', async () => {
  const arrived = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  const before = provider.requests.length, previous = await readFile(join(runtime.root, 'home/.codexplusbar-selector/state.json'), 'utf8');
  provider.behaviors.push(async () => { arrived.resolve(); await release.promise; return 'ok'; });
  const id = await prompt(); await arrived.promise;
  try { expect((await runtime.api(`/api/session/${id}/interrupt`, {})).interrupted).toBe(true); } finally { release.resolve(); }
  await wait(id);
  expect(provider.requests.slice(before)).toHaveLength(1);
  expect(await active()).toBe(accounts.B.id);
  expect(await readFile(join(runtime.root, 'home/.codexplusbar-selector/state.json'), 'utf8')).toBe(previous);
});

test('built plugin delegates delayed refresh once and Pause drains it without stale activation', async () => {
  await control('mode', { mode: 'paused' });
  await runtime.api('/api/credential', { id: 'cred_refresh_a', integrationID: 'openai', label: 'Refresh A', activate: false,
    value: { ...credential('A'), refresh: 'fixture-refresh-old', expires: 1 } });
  await snapshot(s => { s.accounts[0]!.credentialID = 'cred_refresh_a'; });
  // Recover the already-tested cooldown with fresh positive evidence after its reset.
  runtime.hostAction('disable'); await reloadLocations();
  const path = join(runtime.root, 'home/.codexplusbar-selector/state.json'), state = JSON.parse(await readFile(path, 'utf8'));
  for (const row of Object.values(state.cooldowns) as any[]) row.resetAtMs = Date.now() - 1;
  await writeFile(path, JSON.stringify(state), { mode: 0o600 });
  await snapshot(s => { s.accounts[0]!.usage!.observedAtMs = Date.now(); });
  runtime.hostAction('enable'); await reloadLocations();
  provider.refresh.gate = Promise.withResolvers<void>();
  await control('mode', { mode: 'auto' });
  const selection = control('recheck', {});
  await expect.poll(() => provider.refresh.calls).toBe(1);
  const second = runtime.rpc('resolve', { credentialID: 'cred_refresh_a' }, runtime.locations[1]);
  let acknowledged = false;
  const pause = control('mode', { mode: 'paused' }).then(value => { acknowledged = true; return value; });
  try { expect((await control()).checking).toBe(true); expect(acknowledged).toBe(false); }
  finally { provider.refresh.gate.resolve(); }
  await selection; await pause;
  expect(await second).toEqual({ rotated: true }); expect(provider.refresh.calls).toBe(1);
  expect(await active()).toBe(accounts.B.id);
  const saved = (await runtime.api('/api/credential')).data.find((row: any) => row.id === 'cred_refresh_a');
  expect(saved.value.refresh === 'fixture-refresh-new').toBe(true);
  expect((await control()).mode).toBe('paused');
});

test('host disable during native refresh drains the built owner and prevents stale activation', async () => {
  await runtime.api('/api/credential', { id: 'cred_unload_refresh_a', integrationID: 'openai', label: 'Unload refresh A', activate: false,
    value: { ...credential('A'), refresh: 'fixture-refresh-old', expires: 1 } });
  await snapshot(s => { s.accounts[0]!.credentialID = 'cred_unload_refresh_a'; });
  // Read-only paused inventory must settle the native credential-change event.
  await expect.poll(async () => (await control('recheck', {})).nextCredentialID).toBe('cred_unload_refresh_a');
  provider.refresh.gate = Promise.withResolvers<void>();
  const calls = provider.refresh.calls;
  await control('mode', { mode: 'auto' });
  const selection = control('recheck', {}).catch(() => null);
  await expect.poll(() => provider.refresh.calls).toBe(calls + 1);
  runtime.hostAction('disable');
  let unloaded = false;
  const unload = reloadLocations().then(() => { unloaded = true; });
  try { expect((await control()).checking).toBe(true); expect(unloaded).toBe(false); }
  finally { provider.refresh.gate.resolve(); }
  await selection; await unload;
  expect(await active()).toBe(accounts.B.id);
  await expect(readFile(descriptorPath())).rejects.toThrow();
  runtime.hostAction('enable'); await reloadLocations(); await control('mode', { mode: 'paused' });
});

test('a second built-package OS process cannot acquire the fixed port or switch native selection', async () => {
  const before = await readFile(descriptorPath(), 'utf8');
  const other = await startHarness(provider.origin, undefined, true, false, true);
  try {
    await expect(readFile(join(other.root, 'home/.codexplusbar-selector/runtime.json'))).rejects.toThrow();
    await other.api(`/api/credential/${accounts.B.id}/activate`, {});
    const count = provider.requests.length;
    const { data: s } = await other.api('/api/session', { title: 'Collision fixture', location: { directory: other.locations[0] } });
    await other.api(`/api/session/${s.id}/prompt`, { text: 'Fixture collision.' });
    await other.api(`/api/experimental/session/${s.id}/wait`, {});
    expect(provider.requests.slice(count).map(row => row.accountID)).toEqual([accounts.B.accountID]);
    expect(await readFile(descriptorPath(), 'utf8')).toBe(before);
  } finally { await other.close(); }
});

test('built service health requires bearer, process crash does not stop plugin, host uninstall drains owner', async () => {
  const listener = createServer(); await new Promise<void>(r => listener.listen(0, '127.0.0.1', r));
  const port = (listener.address() as { port: number }).port; await new Promise<void>(r => listener.close(() => r()));
  const service = spawn('/usr/bin/sandbox-exec', ['-p', '(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))', process.execPath, join(runtime.root, 'extension/service/main.js')], { env: { HOME: join(runtime.root, 'home'), OPENCHAMBER_SERVICE_PORT: String(port), OPENCHAMBER_SERVICE_TOKEN: 'synthetic-host-token' }, stdio: 'ignore' });
  const exited = new Promise<void>(r => service.once('exit', () => r()));
  try {
    const headers = { authorization: 'Bearer synthetic-host-token' };
    for (let i = 0; i < 100; i++) { try { if ((await fetch(`http://127.0.0.1:${port}/health`, { headers })).ok) break; } catch {} await delay(20); }
    expect((await fetch(`http://127.0.0.1:${port}/health`)).status).toBe(401);
    const status = await fetch(`http://127.0.0.1:${port}/v1/status`, { headers }), text = await status.text();
    expect(status.status, text).toBe(200);
    expect(text).not.toContain((JSON.parse(await readFile(descriptorPath(), 'utf8'))).bearer);
  } finally { service.kill('SIGKILL'); await exited; }
  const epoch = (await control()).epoch; await control('recheck', {}); expect((await control()).epoch).toBe(epoch);
  await control('mode', { mode: 'paused' }); runtime.hostAction('uninstall'); await reloadLocations();
  await expect(readFile(descriptorPath())).rejects.toThrow();
  for (const location of runtime.locations) expect((await runtime.api('/api/plugin', undefined, location)).data.some((p: any) => p.id === 'codexplusbar-expiry-selector')).toBe(false);
  await runtime.api(`/api/credential/${accounts.B.id}/activate`, {}); await wait(await prompt());
  expect(provider.requests.at(-1)).toMatchObject({ accountID: accounts.B.accountID, header: accounts.B.accountID });
});
