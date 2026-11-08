import { afterAll, beforeAll, expect, test } from 'vitest';
import { fakeProvider } from './fake-provider.js';
import { startHarness } from './harness.js';
import { accounts, credential } from './fixtures.js';

let provider: Awaited<ReturnType<typeof fakeProvider>>;
let runtime: Awaited<ReturnType<typeof startHarness>>;
beforeAll(async () => {
  provider = await fakeProvider();
  runtime = await startHarness(provider.origin);
  console.log(JSON.stringify({ version: runtime.version, sha256: runtime.checksum }));
});
afterAll(async () => {
  if (provider) console.log(JSON.stringify({ httpRequests: provider.requests.length, websocketConnections: provider.websockets.length,
    websocketExchanges: provider.websockets.reduce((count, socket) => count + socket.frames.length, 0) }));
  await runtime?.close(); await provider?.close();
});

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

// Break caught: resolving the same expired native connection in two locations must
// not independently consume a rotating refresh token or leave the old pair saved.
test('native refresh is single-flight across two locations and saves the rotated pair', async () => {
  const id = 'cred_expiry_refresh';
  await runtime.api('/api/credential', { id, integrationID: 'openai', label: 'Fixture refresh', activate: false,
    value: { ...credential('A'), methodID: 'expiry-fixture-refresh', access: 'fixture-expired-access',
      refresh: 'fixture-refresh-old', expires: 1 } });
  const pending = runtime.locations.map(location => runtime.rpc('resolve', { credentialID: id }, location));
  try {
    await expect.poll(async () => (await runtime.rpc('status')).resolvesStarted).toBe(2);
    await expect.poll(async () => (await runtime.rpc('status')).refreshCalls).toBe(1);
  } finally {
    await runtime.rpc('control', { releaseRefresh: true });
  }
  expect(await Promise.all(pending)).toEqual([{ rotated: true }, { rotated: true }]);
  const { data: inventory } = await runtime.api('/api/credential');
  const saved = inventory.find((entry: { id: string }) => entry.id === id);
  expect(saved.value.refresh === 'fixture-refresh-new').toBe(true);
  expect(saved.value.access === credential('A').access).toBe(true);
  expect((await runtime.rpc('status')).refreshCalls).toBe(1);
});

test('tool continuation and retry preserve one effect, one prompt, and the same model', async () => {
  await runtime.rpc('control', { promptTarget: accounts.A.id, retryTarget: accounts.B.id, httpOnly: true, racedHeader: null });
  const initial = await runtime.rpc('status');
  const before = provider.requests.length;
  provider.behaviors.push(async () => 'tool', async () => 'quota');
  const { data: session } = await runtime.api('/api/session', { title: 'Fixture', location: { directory: runtime.locations[0] } });
  await runtime.api(`/api/session/${session.id}/prompt`, { text: 'Fixture tool exercise.' });
  await runtime.api(`/api/experimental/session/${session.id}/wait`, {});
  expect(provider.requests.slice(before).map(row => row.accountID)).toEqual([accounts.A.accountID, accounts.A.accountID, accounts.B.accountID]);
  expect(provider.requests.slice(before).map(row => row.model)).toEqual(['gpt-5.7', 'gpt-5.7', 'gpt-5.7']);
  expect(provider.requests.slice(before).map(row => row.toolResults)).toEqual([0, 1, 1]);
  const final = await runtime.rpc('status');
  expect(final.toolEffects - initial.toolEffects, JSON.stringify(final.fixtureTools)).toBe(1);
  expect(final.promptCalls - initial.promptCalls).toBe(1);
});

test('synthetic wake observes global selection without running the prompt selection hook', async () => {
  await runtime.rpc('control', { promptTarget: accounts.B.id, retryTarget: null, activate: accounts.A.id, httpOnly: true });
  const initial = await runtime.rpc('status');
  const before = provider.requests.length;
  const { data: session } = await runtime.api('/api/session', { title: 'Fixture', location: { directory: runtime.locations[0] } });
  await runtime.api(`/api/session/${session.id}/synthetic`, { text: 'Fixture wake.' });
  await runtime.api(`/api/experimental/session/${session.id}/wait`, {});
  expect(provider.requests.slice(before).map(row => row.accountID)).toEqual([accounts.A.accountID]);
  expect((await runtime.rpc('status')).promptCalls).toBe(initial.promptCalls);
});

test('concurrent generate on B cannot replace primary A retry attribution', async () => {
  await runtime.rpc('control', { promptTarget: null, retryTarget: accounts.B.id, activate: accounts.A.id, httpOnly: true });
  const initial = await runtime.rpc('status');
  const arrived = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  provider.behaviors.push(async () => { arrived.resolve(); await release.promise; return 'quota'; });
  const before = provider.requests.length;
  const { data: session } = await runtime.api('/api/session', { title: 'Fixture', location: { directory: runtime.locations[0] } });
  await runtime.api(`/api/session/${session.id}/prompt`, { text: 'Fixture primary.' });
  await arrived.promise;
  try {
    await runtime.rpc('control', { activate: accounts.B.id }, runtime.locations[1]);
    await runtime.api(`/api/session/${session.id}/generate`, { prompt: 'Fixture auxiliary.' });
    const during = await runtime.rpc('status');
    expect(during.observed.some((row: any) => row.kind === 'generate' && row.accountID === accounts.B.accountID)).toBe(true);
  } finally { release.resolve(); }
  await runtime.api(`/api/experimental/session/${session.id}/wait`, {});
  expect(provider.requests.slice(before).map(row => row.accountID)).toEqual([accounts.A.accountID, accounts.B.accountID, accounts.B.accountID]);
  expect((await runtime.rpc('status')).exhausted.slice(initial.exhausted.length)).toEqual([accounts.A.accountID]);
});

test('a delayed title on A cannot overwrite a newer primary retry on B', async () => {
  await runtime.rpc('control', { promptTarget: null, retryTarget: accounts.B.id, activate: accounts.A.id, httpOnly: true, skipTitle: false, holdTitle: true });
  const initial = await runtime.rpc('status');
  const firstArrived = Promise.withResolvers<void>();
  const firstRelease = Promise.withResolvers<void>();
  const secondArrived = Promise.withResolvers<void>();
  const secondRelease = Promise.withResolvers<void>();
  provider.behaviors.push(
    async () => { firstArrived.resolve(); await firstRelease.promise; return 'quota'; },
    async () => { secondArrived.resolve(); await secondRelease.promise; return 'quota'; },
  );
  const before = provider.requests.length;
  const { data: session } = await runtime.api('/api/session', { location: { directory: runtime.locations[0] } });
  try {
    await runtime.api(`/api/session/${session.id}/prompt`, { text: 'Fixture title concurrency.' });
    await firstArrived.promise;
    await expect.poll(async () => (await runtime.rpc('status')).titleWaiting).toBe(true);
    firstRelease.resolve();
    await secondArrived.promise;
    await runtime.rpc('control', { releaseTitle: true });
    await expect.poll(() => provider.requests.slice(before).some(row => row.kind === 'title')).toBe(true);
    secondRelease.resolve();
    await runtime.api(`/api/experimental/session/${session.id}/wait`, {});
    expect(provider.requests.slice(before).map(row => [row.kind, row.accountID])).toEqual([
      ['primary', accounts.A.accountID], ['primary', accounts.B.accountID], ['title', accounts.A.accountID], ['primary', accounts.B.accountID],
    ]);
    expect((await runtime.rpc('status')).exhausted.slice(initial.exhausted.length)).toEqual([accounts.A.accountID, accounts.B.accountID]);
  } finally {
    firstRelease.resolve(); secondRelease.resolve();
    await runtime.rpc('control', { skipTitle: true, releaseTitle: true });
  }
});

test.each([
  { httpOnly: true, headerCase: 'chatgpt-account-id' },
  { httpOnly: true, headerCase: 'ChatGPT-Account-ID' },
  { httpOnly: false, headerCase: 'chatgpt-account-id' },
  { httpOnly: false, headerCase: 'ChatGPT-Account-ID' },
])('delayed native provider header publication stays coherent: $headerCase, HTTP fallback=$httpOnly', async ({ httpOnly, headerCase }) => {
  await runtime.rpc('control', { promptTarget: null, retryTarget: null, activate: accounts.A.id, racedHeader: null, httpOnly });
  // A supported provider reload completes A's initial projection before arming.
  await runtime.rpc('control', { holdProviderHeader: false });
  const initial = await runtime.rpc('status');
  await runtime.rpc('control', { holdProviderHeader: true, providerHeaderCase: headerCase, holdTransport: true });
  try {
    await runtime.rpc('control', { activate: accounts.B.id });
    await expect.poll(async () => (await runtime.rpc('status')).delayedReloads).toBeGreaterThan(initial.delayedReloads);
    const { data: session } = await runtime.api('/api/session', { title: 'Fixture', location: { directory: runtime.locations[0] } });
    await runtime.api(`/api/session/${session.id}/prompt`, { text: 'Fixture reload race.' });
    await expect.poll(async () => (await runtime.rpc('status')).transportWaiting).toBe(true);
    await runtime.rpc('control', { releaseTransport: true });
    await runtime.api(`/api/experimental/session/${session.id}/wait`, {});
    const observed = (await runtime.rpc('status')).observed.slice(initial.observed.length);
    expect(observed.length).toBe(httpOnly ? 2 : 1);
    expect(observed.every((row: any) => row.before === accounts.A.accountID && row.accountID === accounts.B.accountID)).toBe(true);
    expect(observed.every((row: any) => row.header === accounts.B.accountID)).toBe(true);
  } finally { await runtime.rpc('control', { holdProviderHeader: false, releaseTransport: true }); }
});

test('cross-location FIFO and maintenance acknowledgement wait for dispatched activation', async () => {
  await runtime.rpc('control', { holdActivation: true, activate: accounts.A.id });
  const before = (await runtime.rpc('status')).events.length;
  const activation = runtime.rpc('queuedActivate', { id: accounts.B.id });
  await expect.poll(async () => (await runtime.ownerStatus()).activationWaiting).toBe(true);
  let acknowledged = false;
  const pause = runtime.rpc('maintenance', { action: 'begin' }, runtime.locations[1]).then(value => { acknowledged = true; return value; });
  expect((await runtime.ownerStatus()).paused).toBe(false);
  expect(acknowledged).toBe(false);
  await runtime.rpc('control', { releaseActivation: true });
  expect(await activation).toEqual({ activated: true });
  const held = await pause;
  expect(held.events.slice(before)).toEqual([`start:${accounts.B.id}`, `end:${accounts.B.id}`, 'pause']);
  expect((await runtime.rpc('status')).activeID).toBe(accounts.B.id);
  expect((await runtime.rpc('maintenance', { action: 'resume' })).paused).toBe(true);
  await runtime.rpc('maintenance', { action: 'end' });
  expect((await runtime.rpc('queuedActivate', { id: accounts.A.id })).activated).toBe(false);
  await runtime.rpc('maintenance', { action: 'resume' });
});

test('a second native process cannot own the listener or switch on prompt', async () => {
  const other = await startHarness(provider.origin, runtime.coordinatorPort);
  try {
    expect((await runtime.rpc('status')).ownsPort).toBe(true);
    expect((await other.rpc('status')).ownsPort).toBe(false);
    const before = provider.requests.length;
    const { data: session } = await other.api('/api/session', { title: 'Fixture', location: { directory: other.locations[0] } });
    await other.api(`/api/session/${session.id}/prompt`, { text: 'Fixture competing process.' });
    await other.api(`/api/experimental/session/${session.id}/wait`, {});
    expect(provider.requests.slice(before).map(row => row.accountID)).toEqual([accounts.A.accountID]);
    expect((await other.rpc('status')).activeID).toBe(accounts.A.id);
  } finally { await other.close(); }
});

test('competitor presence blocks activation after configuration reload', async () => {
  await runtime.configure(true, true);
  for (const location of runtime.locations) {
    await expect.poll(async () => (await runtime.api('/api/plugin', undefined, location)).data.some((plugin: any) => plugin.id === 'openchamber-limit-failover')).toBe(true);
  }
  await runtime.rpc('control', { activate: accounts.A.id });
  expect((await runtime.rpc('queuedActivate', { id: accounts.B.id })).activated).toBe(false);
  expect((await runtime.rpc('status')).activeID).toBe(accounts.A.id);
  await runtime.configure(true, false);
  await expect.poll(async () => (await runtime.rpc('status')).locations).toBe(2);
  expect((await runtime.rpc('queuedActivate', { id: accounts.B.id })).activated).toBe(true);
});

test('configuration removal unloads both locations and releases the exclusive listener', async () => {
  const oldEpoch = (await runtime.rpc('status')).epoch;
  await runtime.configure(false);
  for (const location of runtime.locations) {
    await expect.poll(async () => (await runtime.api('/api/plugin', undefined, location)).data.some((plugin: any) => plugin.id === 'codexplusbar-expiry-selector-probe')).toBe(false);
  }
  await expect(runtime.ownerStatus()).rejects.toThrow();
  await runtime.configure(true);
  await expect.poll(async () => (await runtime.rpc('status')).locations).toBe(2);
  expect((await runtime.rpc('status')).epoch).not.toBe(oldEpoch);
  expect((await runtime.ownerStatus()).locations).toBe(2);
});

test('configuration unload waits for an outstanding activation result before releasing ownership', async () => {
  await runtime.rpc('control', { holdActivation: true });
  const oldEpoch = (await runtime.rpc('status')).epoch;
  const activation = runtime.rpc('queuedActivate', { id: accounts.A.id }).then(() => 'settled', () => 'interrupted');
  await expect.poll(async () => (await runtime.ownerStatus()).activationWaiting).toBe(true);
  let reloaded = false;
  const reload = runtime.configure(false).then(() => { reloaded = true; });
  try {
    await expect.poll(async () => (await runtime.ownerStatus()).locations).toBe(0);
    expect(reloaded).toBe(false);
    expect((await runtime.ownerStatus()).epoch).toBe(oldEpoch);
  } finally { await runtime.ownerStatus(true); }
  await reload;
  await activation;
  await expect(runtime.ownerStatus()).rejects.toThrow();
  await runtime.configure(true);
  await expect.poll(async () => (await runtime.rpc('status')).locations).toBe(2);
  expect((await runtime.ownerStatus()).epoch).not.toBe(oldEpoch);
});

test('installed host extension lifecycle delivers and unloads the packaged plugin in two locations', async () => {
  const host = await startHarness(provider.origin, undefined, true);
  try {
    const first = await host.rpc('status');
    expect(first.locations).toBeGreaterThanOrEqual(2);
    expect((await host.rpc('status', {}, host.locations[1])).epoch).toBe(first.epoch);
    expect(host.hostAction('disable')).toEqual({ action: 'disable', plugins: 0 });
    for (const location of host.locations) {
      await expect.poll(async () => (await host.api('/api/plugin', undefined, location)).data.some((plugin: any) => plugin.id === 'codexplusbar-expiry-selector-probe'), { timeout: 10_000 }).toBe(false);
    }
    await expect(host.ownerStatus()).rejects.toThrow();
    expect(host.hostAction('enable')).toEqual({ action: 'enable', plugins: 1 });
    await expect.poll(async () => (await host.rpc('status')).locations, { timeout: 10_000 }).toBeGreaterThanOrEqual(2);
    expect(host.hostAction('uninstall')).toEqual({ action: 'uninstall', plugins: 0 });
    for (const location of host.locations) {
      await expect.poll(async () => (await host.api('/api/plugin', undefined, location)).data.some((plugin: any) => plugin.id === 'codexplusbar-expiry-selector-probe'), { timeout: 10_000 }).toBe(false);
    }
    await expect(host.ownerStatus()).rejects.toThrow();
  } finally { await host.close(); }
});
