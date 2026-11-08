import type { SelectorStatus } from '../plugin/coordinator.js';
export type PublicStatus = SelectorStatus;
const text = (v: unknown): v is string => typeof v === 'string' && v.length <= 512;
const nullableText = (v: unknown) => v === null || text(v);
const number = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;
const nullableNumber = (v: unknown) => v === null || number(v);
const percent = (v: unknown) => v === null || (number(v) && v <= 100);
const code = (v: unknown): v is string => typeof v === 'string' && /^[a-z][a-z-]{0,63}$/.test(v);

// Explicit projection: the host/panel never receives raw upstream fields or a bearer.
export function publicStatus(v: any): PublicStatus {
  const invalid = () => { throw new Error('control-unavailable'); };
  if (!v || !['auto', 'paused'].includes(v.mode) || !(v.blockedReason === null || code(v.blockedReason)) ||
      !nullableText(v.activeCredentialID) || !nullableText(v.activeLabel) || !nullableText(v.nextCredentialID) ||
      !(v.snapshotAgeMs === null || number(v.snapshotAgeMs)) || !number(v.holdsCount) || v.holdsCount > 256 || typeof v.checking !== 'boolean' ||
      !text(v.supportedVersions?.opencode) || !text(v.supportedVersions?.openchamber) ||
      !nullableNumber(v.snapshotGeneratedAtMs) || !nullableNumber(v.nativeObservedAtMs) || !Array.isArray(v.accounts) || v.accounts.length > 256 ||
      !Array.isArray(v.exclusions) || v.exclusions.length > 512 || !Array.isArray(v.recentHistory) || v.recentHistory.length > 100) invalid();
  return { mode: v.mode, blockedReason: v.blockedReason, activeCredentialID: v.activeCredentialID, activeLabel: v.activeLabel,
    nextCredentialID: v.nextCredentialID, snapshotAgeMs: v.snapshotAgeMs, holdsCount: v.holdsCount, checking: v.checking,
    supportedVersions: { opencode: v.supportedVersions.opencode, openchamber: v.supportedVersions.openchamber },
    snapshotGeneratedAtMs: v.snapshotGeneratedAtMs, nativeObservedAtMs: v.nativeObservedAtMs,
    accounts: v.accounts.map((row: any) => text(row?.credentialID) && text(row?.label) && nullableNumber(row?.expiresAtMs) &&
      percent(row?.fiveHourRemaining) && (row?.sevenDayRemaining === 'not-applicable' || percent(row?.sevenDayRemaining)) &&
      nullableNumber(row?.usageObservedAtMs) && nullableNumber(row?.entitlementObservedAtMs) ? {
        credentialID: row.credentialID, label: row.label, expiresAtMs: row.expiresAtMs, fiveHourRemaining: row.fiveHourRemaining,
        sevenDayRemaining: row.sevenDayRemaining, usageObservedAtMs: row.usageObservedAtMs, entitlementObservedAtMs: row.entitlementObservedAtMs,
      } : invalid()),
    lastSwitch: v.lastSwitch === null ? null : number(v.lastSwitch?.atMs) && text(v.lastSwitch?.credentialID)
      ? { atMs: v.lastSwitch.atMs, credentialID: v.lastSwitch.credentialID } : invalid(),
    exclusions: v.exclusions.map((row: any) => text(row?.credentialID) && code(row?.code) ? { credentialID: row.credentialID, code: row.code } : invalid()),
    recentHistory: v.recentHistory.map((row: any) => number(row?.atMs) && code(row?.code) && nullableText(row.credentialID)
      ? { atMs: row.atMs, code: row.code, credentialID: row.credentialID } : invalid()),
  };
}
