import { limits, type Cooldown, type NativeConnection, type SelectionDecision, type SelectorAccount, type SelectorExportV1, type UsageObservation } from '../shared/contracts.js';
import { validateSnapshot } from '../shared/snapshot-reader.js';

export type SelectionInput = {
  snapshot: SelectorExportV1; connections: NativeConnection[]; activeCredentialID: string | null;
  cooldowns: Record<string, Cooldown>; failedIdentityKeys: Set<string>; nowMs: number;
};
export const supportedMethods = new Set(['oauth', 'chatgpt-browser', 'chatgpt-headless']);

const fresh = (time: number, maximum: number, now: number) => Number.isSafeInteger(time) && time >= 0 && time <= now + limits.futureSkewMs && now - time <= maximum;
export function positiveUsage(usage: UsageObservation, now: number): boolean {
  return fresh(usage.observedAtMs, limits.usageAgeMs, now) && usage.allowed && !usage.limitReached &&
    usage.fiveHour.remainingPercent > 0 && usage.fiveHour.resetAtMs > now &&
    (usage.sevenDay.state === 'not-applicable' || (usage.sevenDay.remainingPercent > 0 && usage.sevenDay.resetAtMs > now));
}
export function cooldownCleared(cooldown: Cooldown, usage: UsageObservation | null, now: number): boolean {
  return cooldown.resetAtMs <= now && usage !== null && usage.identityKey === cooldown.identityKey &&
    usage.observedAtMs >= Math.max(cooldown.resetAtMs, cooldown.failedAtMs) && positiveUsage(usage, now);
}

function exclusion(row: SelectorAccount, input: SelectionInput): string | null {
  const { nowMs: now } = input;
  const connections = input.connections.filter(connection => connection.id === row.credentialID);
  if (connections.length === 0) return 'binding-missing';
  if (connections.length > 1) return 'binding-conflict';
  if (!supportedMethods.has(connections[0]!.method)) return 'native-unavailable';
  const entitlement = row.entitlement;
  if (!entitlement || entitlement.expiresAtMs === null) return 'expiry-unknown';
  if (!fresh(entitlement.observedAtMs, limits.entitlementAgeMs, now)) return 'expiry-stale';
  if (entitlement.expiresAtMs <= now) return 'expired';
  if (entitlement.active === false) return 'inactive';
  if (entitlement.deactivated || !entitlement.usable) return 'unusable';
  const usage = row.usage;
  if (!usage) return 'usage-unknown';
  if (!fresh(usage.observedAtMs, limits.usageAgeMs, now)) return 'usage-stale';
  if (!usage.allowed || usage.limitReached) return 'usage-denied';
  if (usage.fiveHour.remainingPercent <= 0) return 'five-hour-empty';
  if (usage.sevenDay.state === 'available' && usage.sevenDay.remainingPercent <= 0) return 'seven-day-empty';
  if (usage.fiveHour.resetAtMs <= now || (usage.sevenDay.state === 'available' && usage.sevenDay.resetAtMs <= now)) return 'reset-unconfirmed';
  const cooldown = input.cooldowns[row.identityKey];
  if (input.failedIdentityKeys.has(row.identityKey) || (cooldown && !cooldownCleared(cooldown, usage, now))) return 'cooldown';
  return null;
}

export function selectAccount(input: SelectionInput): SelectionDecision {
  if (!Number.isSafeInteger(input.nowMs) || input.nowMs < 0) return { action: 'blocked', code: 'snapshot-invalid', exclusions: [] };
  const validated = validateSnapshot(input.snapshot, input.nowMs);
  if (!validated.ok) return { action: 'blocked', code: validated.code, exclusions: [] };
  const exclusions = [...validated.exclusions], eligible: SelectorAccount[] = [];
  for (const row of validated.snapshot.accounts) {
    const code = exclusion(row, input);
    if (code) exclusions.push({ credentialID: row.credentialID, code });
    else eligible.push(row);
  }
  eligible.sort((a, b) => {
    const expiry = a.entitlement!.expiresAtMs! - b.entitlement!.expiresAtMs!;
    if (expiry) return expiry;
    if (a.credentialID === input.activeCredentialID) return -1;
    if (b.credentialID === input.activeCredentialID) return 1;
    return a.identityKey < b.identityKey ? -1 : a.identityKey > b.identityKey ? 1 : a.credentialID < b.credentialID ? -1 : 1;
  });
  const candidate = eligible[0];
  if (!candidate) return { action: 'blocked', code: 'no-eligible-account', exclusions };
  if (candidate.credentialID === input.activeCredentialID) return { action: 'keep', credentialID: candidate.credentialID, exclusions };
  return { action: 'activate', credentialID: candidate.credentialID, identityKey: candidate.identityKey, exclusions };
}
