import { readFile } from 'node:fs/promises';
import { expect, test } from 'vitest';
import { SelectorCoordinator, type CoordinatorDependencies, type NativeAccess } from '../src/plugin/coordinator.js';
import { initialState } from '../src/plugin/state-store.js';
import type { SelectorExportV1 } from '../src/shared/contracts.js';
const fixture = JSON.parse(await readFile(new URL('./fixtures/selector-v1.json', import.meta.url), 'utf8')) as SelectorExportV1;
const now = 1_800_000_000_000;
const gate = () => Promise.withResolvers<void>();
async function harness() {
  let snapshot = structuredClone(fixture), active = 'credential-b', owns = true, competitor = false, failSave = false, failActivate = false, missing = false;
  let resolveGate: ReturnType<typeof gate> | null = null, activateGate: ReturnType<typeof gate> | null = null;
  const resolveStarted = gate(), activateStarted = gate(), activations: string[] = [], saved: any[] = [];
  const adapter: NativeAccess = {
    locationKey: '/one', version: () => '2.2.6',
    async pluginIDs() { return competitor ? ['openchamber-limit-failover'] : []; },
    async connections() { return snapshot.accounts.map(row => ({ id: row.credentialID, label: row.label, method: 'oauth' })); },
    async activeID() { return active; },
    async validateIdentity(id) { resolveStarted.resolve(); await resolveGate?.promise;
      const row = snapshot.accounts.find(row => row.credentialID === id)!;
      return { identityKey: row.identityKey, accountID: row.accountID, methodID: 'chatgpt-browser' }; },
    async activate(id) { activateStarted.resolve(); await activateGate?.promise; if (failActivate) throw new Error('fixture activation');
      activations.push(id); if (!missing) active = id; },
  };
  const dependencies: CoordinatorDependencies = {
    now: () => now, owns: () => owns,
    readSnapshot: async () => ({ ok: true, snapshot: structuredClone(snapshot), exclusions: [] }),
    loadState: async () => initialState(), saveState: async value => { if (failSave) throw new Error('fixture persistence'); saved.push(structuredClone(value)); },
  };
  const coordinator = new SelectorCoordinator(dependencies);
  await coordinator.initialize(); const detach = coordinator.attach(adapter);
  return { coordinator, adapter, dependencies, activations, saved, resolveStarted, activateStarted, detach,
    setResolveGate(value: ReturnType<typeof gate>) { resolveGate = value; }, setActivateGate(value: ReturnType<typeof gate>) { activateGate = value; },
    setCompetitor() { competitor = true; }, setFailSave() { failSave = true; }, setFailActivate(value: boolean) { failActivate = value; },
    setMissing() { missing = true; }, setOwner(value: boolean) { owns = value; },
    setActive(value: string) { active = value; }, update(value: SelectorExportV1) { snapshot = value; },
  };
}

test('50 simultaneous triggers coalesce into one verified native activation', async () => {
  const h = await harness(); await h.coordinator.setMode('auto', 'enable');
  const decisions = await Promise.all(Array.from({ length: 50 }, () => h.coordinator.requestSelection('prompt', '/one')));
  expect(h.activations).toEqual(['credential-a']);
  expect(decisions.every(value => value.action === 'activate' || value.action === 'keep')).toBe(true);
});
test('weekly priority drives paused preview and prompt selection, then falls back after observed use', async () => {
  const h = await harness(), snapshot = structuredClone(fixture);
  snapshot.accounts[1]!.usage!.sevenDay = { state: 'available', remainingPercent: 100, resetAtMs: now + 604_800_000 };
  h.update(snapshot); h.setActive('credential-a');
  expect(await h.coordinator.recheck('weekly-preview')).toMatchObject({ mode: 'paused', nextCredentialID: 'credential-b' });
  expect(h.activations).toEqual([]);
  await h.coordinator.setMode('auto', 'enable');
  expect(await h.coordinator.requestSelection('prompt', '/one')).toMatchObject({ action: 'activate', credentialID: 'credential-b' });
  snapshot.accounts[1]!.usage!.sevenDay.remainingPercent = 99;
  snapshot.accounts[1]!.usage!.observedAtMs = now;
  snapshot.sequence++;
  h.update(snapshot);
  expect(await h.coordinator.requestSelection('snapshot', '/one')).toMatchObject({ action: 'activate', credentialID: 'credential-a' });
  expect(h.activations).toEqual(['credential-b', 'credential-a']);
});
test('late A failure while healthy B active persists A exhaustion and retries B without activation', async () => {
  const h = await harness(); await h.coordinator.setMode('auto', 'enable');
  const row = fixture.accounts[0]!;
  const result = await h.coordinator.handleRetry({ locationKey: '/one', sessionID: 's', modelID: 'm', attempt: 2,
    identityKey: row.identityKey, errorType: 'provider.quota', proposedDelayMs: 0 });
  expect(result).toEqual({ retry: true, delay: 0 });
  expect(h.activations).toEqual([]);
  expect(h.saved.at(-1).cooldowns[row.identityKey]).toMatchObject({ failedAtMs: now });
});
test('pause during resolve prevents stale activation and acknowledgement drains queued work', async () => {
  const h = await harness(); await h.coordinator.setMode('auto', 'enable');
  const resolve = gate(); h.setResolveGate(resolve);
  const selection = h.coordinator.requestSelection('prompt'); await h.resolveStarted.promise;
  let acknowledged = false;
  const pause = h.coordinator.setMode('paused', 'pause').then(() => { acknowledged = true; });
  expect(acknowledged).toBe(false); resolve.resolve();
  await selection; await pause;
  expect(h.activations).toEqual([]);
  expect(h.coordinator.status().mode).toBe('paused');
});

test('pause invalidates selection even before the queued job starts', async () => {
  const h = await harness(); await h.coordinator.setMode('auto', 'enable');
  const selection = h.coordinator.requestSelection('prompt');
  const pause = h.coordinator.setMode('paused', 'pause');
  await selection; await pause;
  expect(h.activations).toEqual([]);
});

test('paused recheck computes the candidate and active status without activating, idempotently', async () => {
  const h = await harness();
  const status = await h.coordinator.recheck('recheck');
  expect(status).toMatchObject({ mode: 'paused', activeCredentialID: 'credential-b', nextCredentialID: 'credential-a' });
  h.setActive('credential-c');
  expect(await h.coordinator.recheck('recheck')).toEqual(status);
  expect(h.activations).toEqual([]);
});

test('status exposes bounded account evidence without identities, and recheck observes selection during maintenance', async () => {
  const h = await harness();
  await h.coordinator.recheck('inspect');
  const status = h.coordinator.status();
  expect(status.accounts[0]).toMatchObject({ credentialID: 'credential-a', expiresAtMs: fixture.accounts[0]!.entitlement!.expiresAtMs,
    fiveHourRemaining: fixture.accounts[0]!.usage!.fiveHour.remainingPercent });
  expect(JSON.stringify(status)).not.toContain(fixture.accounts[0]!.identityKey);
  expect(JSON.stringify(status)).not.toContain(fixture.accounts[0]!.accountID);
  await h.coordinator.beginMaintenance('hold', 'manual-account-change');
  h.setActive('credential-c'); await h.coordinator.recheck('after-use');
  expect(h.coordinator.status()).toMatchObject({ activeCredentialID: 'credential-c', blockedReason: 'maintenance', nextCredentialID: null });
  expect(h.activations).toEqual([]);
});
test('pause and last detach wait for activation already dispatched', async () => {
  const h = await harness(); await h.coordinator.setMode('auto', 'enable');
  const activation = gate(); h.setActivateGate(activation);
  const selection = h.coordinator.requestSelection('prompt'); await h.activateStarted.promise;
  let paused = false, detached = false;
  const pause = h.coordinator.setMode('paused', 'pause').then(() => { paused = true; });
  const unload = h.detach().then(() => { detached = true; });
  expect(paused || detached).toBe(false);
  activation.resolve(); await selection; await pause; await unload;
  expect(h.activations).toEqual(['credential-a']);
  expect(h.coordinator.status().mode).toBe('paused');
});
test('unloading during identity resolution prevents activation', async () => {
  const h = await harness(); await h.coordinator.setMode('auto', 'enable');
  const resolve = gate(); h.setResolveGate(resolve);
  const selection = h.coordinator.requestSelection('tick'); await h.resolveStarted.promise;
  const unload = h.detach(); resolve.resolve(); await selection; await unload;
  expect(h.activations).toEqual([]);
});
test('missing activation readback and thrown activation never announce success or poison the queue', async () => {
  const h = await harness(); await h.coordinator.setMode('auto', 'enable');
  h.setFailActivate(true);
  expect((await h.coordinator.requestSelection('prompt')).action).toBe('blocked');
  h.setFailActivate(false); h.setMissing();
  expect(await h.coordinator.requestSelection('prompt')).toMatchObject({ action: 'blocked', code: 'activation-unconfirmed' });
  await expect(h.coordinator.setMode('paused', 'pause')).resolves.toMatchObject({ mode: 'paused' });
});
test('competitor or failed persistence prevents activation and retry override', async () => {
  for (const reason of ['competitor', 'save']) {
    const h = await harness(); await h.coordinator.setMode('auto', 'enable');
    if (reason === 'competitor') h.setCompetitor(); else h.setFailSave();
    expect(await h.coordinator.handleRetry({ locationKey: '/one', sessionID: 's', modelID: 'm', attempt: 2,
      identityKey: fixture.accounts[1]!.identityKey, errorType: 'provider.quota' })).toBeNull();
    expect(h.activations).toEqual([]);
  }
});
test('maintenance operations are idempotent, prevent resume, and release leaves paused', async () => {
  const h = await harness(); await h.coordinator.setMode('auto', 'enable');
  const hold = await h.coordinator.beginMaintenance('operation', 'manual-account-change');
  expect(await h.coordinator.beginMaintenance('operation', 'manual-account-change')).toEqual(hold);
  await expect(h.coordinator.setMode('auto', 'resume')).rejects.toThrow();
  await h.coordinator.endMaintenance('end', hold.holdToken);
  expect(h.coordinator.status()).toMatchObject({ mode: 'paused', holdsCount: 0 });
  expect(h.saved.at(-1)).toMatchObject({ desiredMode: 'paused', maintenanceRecovery: false });
});
test('corrupt persisted state cannot enable automatic selection', async () => {
  const h = await harness();
  const coordinator = new SelectorCoordinator({ ...h.dependencies, loadState: async () => ({ ...initialState(), diagnostic: 'persistence-unavailable' }) });
  await coordinator.initialize(); coordinator.attach(h.adapter);
  await expect(coordinator.setMode('auto', 'enable')).rejects.toThrow();
  expect((await coordinator.requestSelection('tick')).action).toBe('blocked');
});
test('native budget, unrecognized failures and ownership loss preserve native retry', async () => {
  const h = await harness(); await h.coordinator.setMode('auto', 'enable');
  const base = { locationKey: '/one', sessionID: 's', modelID: 'm', identityKey: fixture.accounts[0]!.identityKey };
  expect(await h.coordinator.handleRetry({ ...base, attempt: 11, errorType: 'provider.quota' })).toBeNull();
  expect(await h.coordinator.handleRetry({ ...base, attempt: 2, errorType: 'provider.auth' })).toBeNull();
  h.setOwner(false);
  expect(await h.coordinator.handleRetry({ ...base, attempt: 2, errorType: 'provider.quota' })).toBeNull();
  expect(h.activations).toEqual([]);
});

test('snapshot changes during resolution recompute, and repeated churn stops after two recomputations', async () => {
  const h = await harness(); await h.coordinator.setMode('auto', 'enable');
  const resolve = gate(); h.setResolveGate(resolve);
  const pending = h.coordinator.requestSelection('prompt'); await h.resolveStarted.promise;
  const next = structuredClone(fixture); next.sequence++; next.accounts[0]!.usage!.fiveHour.remainingPercent = 0;
  h.update(next); resolve.resolve();
  expect(await pending).toMatchObject({ action: 'keep', credentialID: 'credential-b' });
  expect(h.activations).toEqual([]);
  let reads = 0;
  const coordinator = new SelectorCoordinator({ ...h.dependencies, readSnapshot: async () => ({ ok: true,
    snapshot: { ...fixture, sequence: ++reads }, exclusions: [] }) });
  await coordinator.initialize(); coordinator.attach(h.adapter); await coordinator.setMode('auto', 'enable');
  expect(await coordinator.requestSelection('tick')).toMatchObject({ action: 'blocked', code: 'snapshot-changed' });
  expect(reads).toBeLessThanOrEqual(8);
});

test('failed native identity excludes that candidate and uses the next healthy identity', async () => {
  const h = await harness();
  const validate = h.adapter.validateIdentity;
  h.adapter.validateIdentity = async id => { if (id === 'credential-a') throw new Error('identity-mismatch'); return validate(id); };
  await h.coordinator.setMode('auto', 'enable');
  expect(await h.coordinator.requestSelection('prompt')).toMatchObject({ action: 'keep', credentialID: 'credential-b',
    exclusions: expect.arrayContaining([{ credentialID: 'credential-a', code: 'native-unavailable' }]) });
});

test('retry cooldown is committed before any activation and survives all identities failing', async () => {
  const h = await harness();
  const saved = gate(), started = gate();
  const coordinator = new SelectorCoordinator({ ...h.dependencies, saveState: async state => {
    if (Object.keys(state.cooldowns).length) { started.resolve(); await saved.promise; }
    await h.dependencies.saveState(state);
  } });
  await coordinator.initialize(); coordinator.attach(h.adapter); await coordinator.setMode('auto', 'enable');
  const base = { locationKey: '/one', sessionID: 's', modelID: 'm', errorType: 'provider.quota' };
  const retry = coordinator.handleRetry({ ...base, attempt: 2, identityKey: fixture.accounts[1]!.identityKey });
  await started.promise; expect(h.activations).toEqual([]); saved.resolve();
  expect(await retry).toEqual({ retry: true, delay: 0 });
  expect(await coordinator.handleRetry({ ...base, attempt: 3, identityKey: fixture.accounts[0]!.identityKey })).toBeNull();
  expect(h.activations).toEqual(['credential-a']);
});

test('an enable interrupted during its snapshot read cannot restore auto', async () => {
  const h = await harness(), started = gate(), release = gate();
  const coordinator = new SelectorCoordinator({ ...h.dependencies, readSnapshot: async now => {
    started.resolve(); await release.promise; return h.dependencies.readSnapshot(now);
  } });
  await coordinator.initialize(); coordinator.attach(h.adapter);
  const enable = coordinator.setMode('auto', 'enable');
  await started.promise;
  const pause = coordinator.setMode('paused', 'pause');
  release.resolve();
  await expect(enable).rejects.toThrow(); await pause;
  expect(h.saved.every(state => state.desiredMode === 'paused')).toBe(true);
});

test('a competitor in any live location blocks all locations', async () => {
  const h = await harness();
  h.coordinator.attach({ ...h.adapter, locationKey: '/two', pluginIDs: async () => ['openchamber-limit-failover'] });
  await expect(h.coordinator.setMode('auto', 'enable')).rejects.toThrow('competing-switcher');
  expect(h.activations).toEqual([]);
});

test('active maintenance receipts survive the bounded control cache', async () => {
  const h = await harness();
  const held = await h.coordinator.beginMaintenance('hold', 'manual-account-change');
  for (let index = 0; index < 300; index++) await h.coordinator.recheck(`recheck-${index}`);
  expect(await h.coordinator.beginMaintenance('hold', 'manual-account-change')).toEqual(held);
  expect(h.coordinator.status().holdsCount).toBe(1);
});

test('a late failure keeps any healthy replacement already active rather than optimizing expiry again', async () => {
  const h = await harness();
  const snapshot = structuredClone(fixture), row = snapshot.accounts[2]!;
  row.usage = { ...structuredClone(snapshot.accounts[1]!.usage!), identityKey: row.identityKey };
  row.entitlement = { ...snapshot.accounts[1]!.entitlement!, accountID: row.accountID, expiresAtMs: now + 10 * 86400000 };
  h.update(snapshot); h.setActive('credential-c'); await h.coordinator.setMode('auto', 'enable');
  expect(await h.coordinator.handleRetry({ locationKey: '/one', sessionID: 's', modelID: 'm', attempt: 2,
    identityKey: snapshot.accounts[0]!.identityKey, errorType: 'provider.quota' })).toEqual({ retry: true, delay: 0 });
  expect(h.activations).toEqual([]);
  expect(h.coordinator.status().activeCredentialID).toBe('credential-c');
});
