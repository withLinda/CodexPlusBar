import { expect, test } from 'vitest';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { validateSnapshot, SnapshotReader } from '../src/shared/snapshot-reader.js';

const now = 1_800_000_000_000;
const fixture = JSON.parse(await readFile(new URL('./fixtures/selector-v1.json', import.meta.url), 'utf8'));
const fresh = () => structuredClone(fixture);

test('supported wire shape keeps separate observation clocks and explicit nulls', () => {
  const result = validateSnapshot(fresh(), now);
  expect(result.ok).toBe(true);
  if (!result.ok) return;
  expect(result.snapshot.accounts).toEqual(fixture.accounts);
  expect(result.exclusions).toEqual([]);
});

test.each([
  ['unknown version', (v: any) => { v.schemaVersion = 2; }, 'snapshot-invalid'],
  ['Swift epoch seconds', (v: any) => { v.generatedAtMs = 821_692_800; }, 'publisher-stale'],
  ['stale heartbeat', (v: any) => { v.generatedAtMs = now - 90_001; }, 'publisher-stale'],
  ['future heartbeat', (v: any) => { v.generatedAtMs = now + 30_001; }, 'snapshot-invalid'],
  ['untrusted catalog', (v: any) => { v.catalogTrusted = false; }, 'catalog-untrusted'],
  ['too many accounts', (v: any) => { v.accounts = Array(257).fill(v.accounts[0]); }, 'snapshot-invalid'],
  ['missing nullable usage', (v: any) => { delete v.accounts[0].usage; }, 'row'],
  ['out of range percentage', (v: any) => { v.accounts[0].usage.fiveHour.remainingPercent = 101; }, 'row'],
  ['future observation', (v: any) => { v.accounts[0].usage.observedAtMs = now + 30_001; }, 'row'],
  ['identity mismatch', (v: any) => { v.accounts[0].usage.identityKey = v.accounts[1].identityKey; }, 'row'],
  ['unexpected secret', (v: any) => { v.accounts[0].password = 'fixture-only'; }, 'row'],
])('%s is rejected at its trust boundary', (_name, mutate, code) => {
  const value = fresh(); mutate(value);
  const result = validateSnapshot(value, now);
  if (code === 'row') {
    expect(result.ok).toBe(true);
    if (result.ok) { expect(result.snapshot.accounts).toHaveLength(2); expect(result.exclusions).toHaveLength(1); }
  } else expect(result).toEqual({ ok: false, code });
});

test.each(['identityKey', 'credentialID'])('all duplicate %s bindings are excluded', field => {
  const value = fresh(); value.accounts[1][field] = value.accounts[0][field];
  const result = validateSnapshot(value, now);
  expect(result.ok).toBe(true);
  if (result.ok) {
    expect(result.snapshot.accounts.map(row => row.credentialID)).toEqual(['credential-c']);
    expect(result.exclusions.map(row => row.code)).toEqual(['binding-conflict', 'binding-conflict']);
  }
});

test('bounded reader rechecks heartbeat and prevents sequence/observation regression', async () => {
  const home = await mkdtemp(join(process.env.TMPDIR!, 'expiry-snapshot-'));
  const path = join(home, 'snapshot.json');
  const reader = new SnapshotReader(path);
  try {
    await writeFile(path, JSON.stringify(fixture));
    expect((await reader.readSnapshot(now)).ok).toBe(true);
    expect(await reader.readSnapshot(now + 90_001)).toEqual({ ok: false, code: 'publisher-stale' });
    const older = fresh(); older.sequence--;
    await writeFile(path, JSON.stringify(older));
    expect(await reader.readSnapshot(now)).toEqual({ ok: false, code: 'snapshot-invalid' });
    const newer = fresh(); newer.sequence++; newer.accounts[0].usage.observedAtMs -= 1000;
    await writeFile(path, JSON.stringify(newer));
    const result = await reader.readSnapshot(now);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.snapshot.accounts[0]?.usage?.observedAtMs).toBe(1_799_999_990_000);
    expect((await reader.readSnapshot(now)).ok).toBe(true);
    await writeFile(path, ' '.repeat(1_048_577));
    expect(await reader.readSnapshot(now)).toEqual({ ok: false, code: 'snapshot-invalid' });
  } finally { await rm(home, { recursive: true, force: true }); }
});

test('Swift-encoded shared fixture passes the identical validator', async () => {
  const data = JSON.parse(await readFile(new URL('../.runtime/swift-export.json', import.meta.url), 'utf8'));
  const result = validateSnapshot(data, now);
  expect(result.ok).toBe(true);
  if (result.ok) expect(result.snapshot).toEqual(fixture);
});
