import { afterAll, beforeAll, expect, test } from 'vitest';
import { fakeProvider } from './fake-provider.js';
import { startHarness } from './harness.js';
import { accounts } from './fixtures.js';

let provider: Awaited<ReturnType<typeof fakeProvider>>;
let runtime: Awaited<ReturnType<typeof startHarness>>;
beforeAll(async () => {
  provider = await fakeProvider();
  runtime = await startHarness(provider.origin);
  console.log(JSON.stringify({ version: runtime.version, sha256: runtime.checksum }));
});
afterAll(async () => { await runtime?.close(); await provider?.close(); });

test('promptSwitch.firstRequest.identity == B', async () => {
  const { data: session } = await runtime.api('/api/session', { title: 'Fixture', location: { directory: runtime.locations[0] } });
  await runtime.api(`/api/session/${session.id}/prompt`, { text: 'Fixture prompt.' });
  await runtime.api(`/api/experimental/session/${session.id}/wait`, {});
  expect(provider.requests.length, runtime.diagnostic()).toBeGreaterThan(0);
  expect(provider.requests[0]?.accountID).toBe(accounts.B.accountID);
  expect(provider.requests[0]?.header).toBe(accounts.B.accountID);
});

test('two locations share one process-global owner', async () => {
  const one = await runtime.rpc('status');
  const two = await runtime.rpc('status', {}, runtime.locations[1]);
  expect(one.epoch).toBe(two.epoch);
  expect(one.locations).toBe(2);
});

test('missing-ID activation is detected by unchanged native readback', async () => {
  await runtime.rpc('control', { activate: accounts.A.id });
  const result = await runtime.rpc('control', { activate: 'cred_expiry_missing' });
  expect(result.activeID).toBe(accounts.A.id);
});

test('raced token B/header A remains coherent on HTTP and WS fallback', async () => {
  await runtime.rpc('control', { racedHeader: accounts.A.accountID });
  const before = provider.requests.length;
  const { data: session } = await runtime.api('/api/session', { title: 'Fixture', location: { directory: runtime.locations[0] } });
  await runtime.api(`/api/session/${session.id}/prompt`, { text: 'Fixture prompt.' });
  await runtime.api(`/api/experimental/session/${session.id}/wait`, {});
  expect(provider.requests.length).toBe(before + 1);
  expect(provider.requests[before]?.accountID).toBe(accounts.B.accountID);
  expect(provider.requests[before]?.header).toBe(accounts.B.accountID);
  const { observed } = await runtime.rpc('status');
  expect(observed.filter((row: any) => row.accountID === accounts.B.accountID).every((row: any) => row.header === accounts.B.accountID)).toBe(true);
});

test('retrySwitch.nextRequest.identity == B; late A failure exhausts only A', async () => {
  await runtime.rpc('control', { promptTarget: null, retryTarget: accounts.B.id, activate: accounts.A.id, racedHeader: null });
  const arrived = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  provider.behaviors.push(async () => { arrived.resolve(); await release.promise; return 'quota'; });
  const before = provider.requests.length;
  const { data: session } = await runtime.api('/api/session', { title: 'Fixture', location: { directory: runtime.locations[0] } });
  await runtime.api(`/api/session/${session.id}/prompt`, { text: 'Fixture prompt.' });
  await arrived.promise;
  // Another location selects B before A's failure arrives.
  await runtime.rpc('control', { activate: accounts.B.id }, runtime.locations[1]);
  release.resolve();
  await runtime.api(`/api/experimental/session/${session.id}/wait`, {});
  expect(provider.requests.slice(before).map(row => row.accountID)).toEqual([accounts.A.accountID, accounts.B.accountID]);
  expect((await runtime.rpc('status')).exhausted).toEqual([accounts.A.accountID]);
});

test('changed WS account opens a new connection with full context and coherent headers', async () => {
  await runtime.rpc('control', { promptTarget: null, retryTarget: null, activate: accounts.A.id, httpOnly: false, racedHeader: accounts.B.accountID });
  const before = provider.websockets.length;
  const { data: session } = await runtime.api('/api/session', { title: 'Fixture', location: { directory: runtime.locations[0] } });
  await runtime.api(`/api/session/${session.id}/prompt`, { text: 'Fixture first.' });
  await runtime.api(`/api/experimental/session/${session.id}/wait`, {});
  await runtime.rpc('control', { activate: accounts.B.id, racedHeader: accounts.A.accountID });
  await runtime.api(`/api/session/${session.id}/prompt`, { text: 'Fixture second.' });
  await runtime.api(`/api/experimental/session/${session.id}/wait`, {});
  const sockets = provider.websockets.slice(before);
  expect(sockets.map(row => [row.accountID, row.header])).toEqual([
    [accounts.A.accountID, accounts.A.accountID], [accounts.B.accountID, accounts.B.accountID],
  ]);
  expect(sockets[1]?.frames[0]?.previous).toBe(false);
  expect(sockets[1]?.frames[0]?.inputs).toBeGreaterThan(sockets[0]?.frames[0]?.inputs ?? 0);
});
