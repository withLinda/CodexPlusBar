import { readFile, writeFile, mkdtemp, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { expect, test } from 'vitest';
import { StateStore, initialState } from '../src/plugin/state-store.js';

test('private atomic state survives restart; failed write preserves exhaustion', async () => {
  const directory = await mkdtemp(join(process.env.TMPDIR!, 'expiry-state-'));
  try {
    const store = new StateStore(directory), state = initialState();
    expect(await store.loadState()).toEqual(state);
    const key = 'a'.repeat(64);
    state.desiredMode = 'auto';
    state.cooldowns[key] = { identityKey: key, failedAtMs: 1_800_000_000_000, resetAtMs: 1_800_003_600_000, reason: 'quota', source: 'fallback' };
    state.recentHistory = Array.from({ length: 105 }, (_, index) => ({ atMs: 1_800_000_000_000 + index, code: 'cooldown', credentialID: 'fixture-a' }));
    await store.saveState(state);
    const restored = await new StateStore(directory).loadState();
    expect(restored.desiredMode).toBe('auto');
    expect(restored.cooldowns).toEqual(state.cooldowns);
    expect(restored.recentHistory).toHaveLength(100);
    const before = await readFile(join(directory, 'state.json'), 'utf8');
    const failing = new StateStore(directory, async () => { throw new Error('fixture write failure'); });
    await expect(failing.saveState(initialState())).rejects.toThrow();
    expect(await readFile(join(directory, 'state.json'), 'utf8')).toBe(before);
    expect((await stat(join(directory, 'state.json'))).mode & 0o777).toBe(0o600);
    expect((await stat(directory)).mode & 0o777).toBe(0o700);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test.each(['{invalid', '{"schemaVersion":2}', '{"access":"not-a-state"}'])('corrupt state %s pauses without silently overwriting it', async content => {
  const directory = await mkdtemp(join(process.env.TMPDIR!, 'expiry-state-'));
  try {
    await writeFile(join(directory, 'state.json'), content);
    const restored = await new StateStore(directory).loadState();
    expect(restored.desiredMode).toBe('paused');
    expect(restored.diagnostic).toBe('persistence-unavailable');
    expect(await readFile(join(directory, 'state.json'), 'utf8')).toBe(content);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('maintenance recovery is paused even when saved desired mode is auto', async () => {
  const directory = await mkdtemp(join(process.env.TMPDIR!, 'expiry-state-'));
  try {
    const store = new StateStore(directory), state = initialState();
    state.desiredMode = 'auto'; state.maintenanceRecovery = true;
    await store.saveState(state);
    expect(await store.loadState()).toMatchObject({ desiredMode: 'paused', maintenanceRecovery: true });
    await expect(store.saveState({ ...state, accessToken: 'fixture' } as typeof state)).rejects.toThrow();
  } finally { await rm(directory, { recursive: true, force: true }); }
});
