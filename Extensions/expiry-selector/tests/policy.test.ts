import { readFile } from 'node:fs/promises';
import { expect, test } from 'vitest';
import { selectAccount, type SelectionInput } from '../src/policy/eligibility.js';
import type { SelectorExportV1 } from '../src/shared/contracts.js';
const now = 1_800_000_000_000;
const fixture = JSON.parse(await readFile(new URL('./fixtures/selector-v1.json', import.meta.url), 'utf8')) as SelectorExportV1;
function input(): SelectionInput {
  const snapshot = structuredClone(fixture);
  snapshot.accounts[0]!.usage!.fiveHour.remainingPercent = 1;
  snapshot.accounts[1]!.usage!.fiveHour.remainingPercent = 90;
  return { snapshot, connections: snapshot.accounts.map(row => ({ id: row.credentialID, label: row.label, method: 'chatgpt-browser' })),
    activeCredentialID: null, cooldowns: {}, failedIdentityKeys: new Set(), nowMs: now };
}

test('earliest verified expiry wins even at 1% against a later 90% account', () => {
  expect(selectAccount(input())).toMatchObject({ action: 'activate', credentialID: 'credential-a' });
});

test.each([
  ['5H empty', (v: SelectionInput) => { v.snapshot.accounts[0]!.usage!.fiveHour.remainingPercent = 0; }, 'five-hour-empty'],
  ['7D empty', (v: SelectionInput) => { v.snapshot.accounts[0]!.usage!.sevenDay = { state: 'available', remainingPercent: 0, resetAtMs: now + 1000 }; }, 'seven-day-empty'],
  ['expired', (v: SelectionInput) => { v.snapshot.accounts[0]!.entitlement!.expiresAtMs = now; }, 'expired'],
  ['unknown expiry', (v: SelectionInput) => { v.snapshot.accounts[0]!.entitlement!.expiresAtMs = null; }, 'expiry-unknown'],
  ['denied', (v: SelectionInput) => { v.snapshot.accounts[0]!.usage!.allowed = false; }, 'usage-denied'],
  ['reached', (v: SelectionInput) => { v.snapshot.accounts[0]!.usage!.limitReached = true; }, 'usage-denied'],
  ['reset needs observation', (v: SelectionInput) => { v.snapshot.accounts[0]!.usage!.fiveHour.resetAtMs = now; }, 'reset-unconfirmed'],
  ['inactive', (v: SelectionInput) => { v.snapshot.accounts[0]!.entitlement!.active = false; }, 'inactive'],
  ['deactivated', (v: SelectionInput) => { v.snapshot.accounts[0]!.entitlement!.deactivated = true; }, 'unusable'],
  ['missing credential', (v: SelectionInput) => { v.connections.shift(); }, 'binding-missing'],
  ['unsupported method', (v: SelectionInput) => { v.connections[0]!.method = 'api-key'; }, 'native-unavailable'],
  ['failed in this chain', (v: SelectionInput) => { v.failedIdentityKeys.add(v.snapshot.accounts[0]!.identityKey); }, 'cooldown'],
])('%s excludes A and selects B', (_name, mutate, code) => {
  const value = input(); mutate(value);
  expect(selectAccount(value)).toMatchObject({ action: 'activate', credentialID: 'credential-b',
    exclusions: expect.arrayContaining([{ credentialID: 'credential-a', code }]) });
});

test('equal expiry retains eligible current, otherwise stable identity order', () => {
  const value = input(); value.snapshot.accounts[1]!.entitlement!.expiresAtMs = value.snapshot.accounts[0]!.entitlement!.expiresAtMs;
  value.activeCredentialID = 'credential-a';
  expect(selectAccount(value)).toMatchObject({ action: 'keep', credentialID: 'credential-a' });
  value.activeCredentialID = 'credential-b';
  expect(selectAccount(value)).toMatchObject({ action: 'keep', credentialID: 'credential-b' });
  value.activeCredentialID = null;
  expect(selectAccount(value)).toMatchObject({ action: 'activate', credentialID: 'credential-b' });
  value.snapshot.accounts.reverse();
  expect(selectAccount(value)).toMatchObject({ action: 'activate', credentialID: 'credential-b' });
});

test.each([
  ['heartbeat', 90_000], ['usage', 900_000], ['entitlement', 86_400_000],
] as const)('%s maximum age is inclusive', (kind, age) => {
  const value = input(); value.snapshot.accounts = [value.snapshot.accounts[0]!];
  const set = (time: number) => {
    if (kind === 'heartbeat') value.snapshot.generatedAtMs = time;
    else value.snapshot.accounts[0]![kind]!.observedAtMs = time;
  };
  set(now - age);
  expect(selectAccount(value).action).toBe('activate');
  set(now - age - 1);
  expect(selectAccount(value).action).toBe('blocked');
  set(now + 30_000);
  expect(selectAccount(value).action).toBe('activate');
  set(now + 30_001);
  expect(selectAccount(value).action).toBe('blocked');
  set(Number.NaN);
  expect(selectAccount(value).action).toBe('blocked');
  set(Number.MAX_SAFE_INTEGER + 1);
  expect(selectAccount(value).action).toBe('blocked');
});

test('cooldown follows identity across credential recreation and needs positive post-reset evidence', () => {
  const value = input(), row = value.snapshot.accounts[0]!;
  value.cooldowns[row.identityKey] = { identityKey: row.identityKey, failedAtMs: now - 2000, resetAtMs: now - 1000, reason: 'quota', source: 'provider' };
  row.credentialID = 'recreated'; value.connections[0]!.id = 'recreated';
  expect(selectAccount(value)).toMatchObject({ credentialID: 'credential-b' });
  row.usage!.observedAtMs = now - 1000;
  expect(selectAccount(value)).toMatchObject({ credentialID: 'recreated' });
  row.usage!.fiveHour.remainingPercent = 0;
  expect(selectAccount(value)).toMatchObject({ credentialID: 'credential-b' });
});

test('no eligible candidate returns blocked without a mutation target', () => {
  const value = input(); value.snapshot.accounts.forEach(row => { row.usage = null; });
  expect(selectAccount(value)).toMatchObject({ action: 'blocked' });
  expect(selectAccount(value)).not.toHaveProperty('credentialID');
});
