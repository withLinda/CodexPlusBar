import { open } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { limits, type SelectorAccount, type SelectorExportV1, type SnapshotReadResult } from './contracts.js';

type ObjectValue = Record<string, unknown>;
const object = (value: unknown): value is ObjectValue => typeof value === 'object' && value !== null && !Array.isArray(value);
const exact = (value: ObjectValue, keys: string[]) => keys.length === Object.keys(value).length && keys.every(key => key in value);
const integer = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
const text = (value: unknown): value is string => typeof value === 'string' && value.length > 0 && value.length <= 512 && value.trim() === value;
const uuid = (value: unknown) => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const hash = (value: unknown) => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const observed = (value: unknown, now: number) => integer(value) && value <= now + limits.futureSkewMs;
const window = (v: ObjectValue) => integer(v.remainingPercent) && v.remainingPercent <= 100 && integer(v.resetAtMs) && v.resetAtMs > 0;

function rowValid(value: unknown, now: number): value is SelectorAccount {
  if (!object(value) || !exact(value, ['profileID', 'credentialID', 'identityKey', 'accountID', 'label', 'bindingObservedAtMs', 'usage', 'entitlement', 'unavailableReasons']) ||
      !uuid(value.profileID) || !text(value.credentialID) || !hash(value.identityKey) || !text(value.accountID) ||
      typeof value.label !== 'string' || [...value.label].length > 200 || !observed(value.bindingObservedAtMs, now) ||
      !Array.isArray(value.unavailableReasons) || value.unavailableReasons.length > 32 ||
      !value.unavailableReasons.every(code => typeof code === 'string' && /^[a-z][a-z-]{0,63}$/.test(code))) return false;
  const u = value.usage;
  if (u !== null) {
    if (!object(u) || !exact(u, ['observedAtMs', 'identityKey', 'allowed', 'limitReached', 'fiveHour', 'sevenDay']) ||
        !observed(u.observedAtMs, now) || u.identityKey !== value.identityKey || typeof u.allowed !== 'boolean' || typeof u.limitReached !== 'boolean' ||
        !object(u.fiveHour) || !exact(u.fiveHour, ['remainingPercent', 'resetAtMs']) || !window(u.fiveHour) || !object(u.sevenDay)) return false;
    if (u.sevenDay.state === 'available') {
      if (!exact(u.sevenDay, ['state', 'remainingPercent', 'resetAtMs']) || !window(u.sevenDay)) return false;
    } else if (u.sevenDay.state !== 'not-applicable' || !exact(u.sevenDay, ['state'])) return false;
  }
  const e = value.entitlement;
  return e === null || (object(e) && exact(e, ['observedAtMs', 'accountID', 'expiresAtMs', 'active', 'deactivated', 'usable', 'match']) &&
    observed(e.observedAtMs, now) && e.accountID === value.accountID && (e.expiresAtMs === null || integer(e.expiresAtMs)) &&
    (e.active === null || typeof e.active === 'boolean') && typeof e.deactivated === 'boolean' && typeof e.usable === 'boolean' &&
    (e.match === 'canonical' || e.match === 'unique-alias'));
}

export function validateSnapshot(value: unknown, nowMs: number): SnapshotReadResult {
  if (!object(value) || !exact(value, ['schemaVersion', 'sourceInstanceID', 'sequence', 'generatedAtMs', 'catalogTrusted', 'accounts']) ||
      value.schemaVersion !== 1 || !uuid(value.sourceInstanceID) || !integer(value.sequence) || !observed(value.generatedAtMs, nowMs) ||
      typeof value.catalogTrusted !== 'boolean' || !Array.isArray(value.accounts) || value.accounts.length > limits.accounts) return { ok: false, code: 'snapshot-invalid' };
  if (nowMs - (value.generatedAtMs as number) > limits.heartbeatAgeMs) return { ok: false, code: 'publisher-stale' };
  if (!value.catalogTrusted) return { ok: false, code: 'catalog-untrusted' };
  // Count bindings before validating rows: a malformed duplicate must not hide a conflict.
  const rows = value.accounts;
  const count = (field: string, item: ObjectValue) => rows.filter((other: unknown) => object(other) && other[field] === item[field]).length;
  const accounts: SelectorAccount[] = [], exclusions: { credentialID: string; code: string }[] = [];
  for (const row of value.accounts) {
    const conflict = object(row) && ['identityKey', 'credentialID', 'profileID'].some(field => text(row[field]) && count(field, row) > 1);
    if (conflict || !rowValid(row, nowMs)) {
      exclusions.push({ credentialID: object(row) && text(row.credentialID) ? row.credentialID : '', code: conflict ? 'binding-conflict' : 'snapshot-invalid' });
    } else accounts.push(row);
  }
  return { ok: true, snapshot: { ...value, accounts } as SelectorExportV1, exclusions };
}

export class SnapshotReader {
  private accepted: SelectorExportV1 | undefined;
  private acceptedRaw: unknown;
  constructor(private readonly path = join(homedir(), 'Library/Application Support/CodexPlusBar/Exports/openchamber-selector-v1.json')) {}

  async readSnapshot(nowMs: number): Promise<SnapshotReadResult> {
    let file;
    try {
      file = await open(this.path, 'r');
      const stat = await file.stat();
      if (!stat.isFile() || stat.size > limits.snapshotBytes) return { ok: false, code: 'snapshot-invalid' };
      const buffer = Buffer.alloc(limits.snapshotBytes + 1);
      let offset = 0;
      while (offset < buffer.length) {
        const { bytesRead } = await file.read(buffer, offset, buffer.length - offset, null);
        if (!bytesRead) break;
        offset += bytesRead;
      }
      if (offset > limits.snapshotBytes) return { ok: false, code: 'snapshot-invalid' };
      const raw: unknown = JSON.parse(buffer.subarray(0, offset).toString('utf8'));
      const result = validateSnapshot(structuredClone(raw), nowMs);
      if (!result.ok) return result;
      const previous = this.accepted, next = result.snapshot;
      if (previous && previous.sourceInstanceID === next.sourceInstanceID) {
        if (next.sequence < previous.sequence || next.generatedAtMs < previous.generatedAtMs) return { ok: false, code: 'snapshot-invalid' };
        if (next.sequence === previous.sequence && !isDeepStrictEqual(raw, this.acceptedRaw)) return { ok: false, code: 'snapshot-invalid' };
        for (const row of next.accounts) {
          const old = previous.accounts.find(old => old.credentialID === row.credentialID && old.identityKey === row.identityKey);
          if (!old) continue;
          if (row.usage && old.usage && row.usage.observedAtMs < old.usage.observedAtMs) row.usage = old.usage;
          if (row.entitlement && old.entitlement && row.entitlement.observedAtMs < old.entitlement.observedAtMs) row.entitlement = old.entitlement;
        }
      }
      this.accepted = structuredClone(next);
      this.acceptedRaw = raw;
      return result;
    } catch (error) {
      return { ok: false, code: (error as NodeJS.ErrnoException).code === 'ENOENT' ? 'snapshot-missing' : 'snapshot-invalid' };
    } finally { await file?.close(); }
  }
}

const defaultReader = new SnapshotReader();
export const readSnapshot = (nowMs: number) => defaultReader.readSnapshot(nowMs);
