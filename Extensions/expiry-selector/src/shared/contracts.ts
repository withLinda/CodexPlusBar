export const limits = {
  heartbeatIntervalMs: 30_000, heartbeatAgeMs: 90_000, usageAgeMs: 900_000,
  entitlementAgeMs: 86_400_000, futureSkewMs: 30_000, reevaluateIntervalMs: 15_000,
  debounceMs: 250, snapshotBytes: 1_048_576, accounts: 256,
} as const;

export type QuotaWindow = { remainingPercent: number; resetAtMs: number };
export type UsageObservation = {
  observedAtMs: number; identityKey: string; allowed: boolean; limitReached: boolean;
  fiveHour: QuotaWindow; sevenDay: ({ state: 'available' } & QuotaWindow) | { state: 'not-applicable' };
};
export type EntitlementObservation = {
  observedAtMs: number; accountID: string; expiresAtMs: number | null; active: boolean | null;
  deactivated: boolean; usable: boolean; match: 'canonical' | 'unique-alias';
};
export type SelectorAccount = {
  profileID: string; credentialID: string; identityKey: string; accountID: string; label: string;
  bindingObservedAtMs: number; usage: UsageObservation | null; entitlement: EntitlementObservation | null;
  unavailableReasons: string[];
};
export type SelectorExportV1 = {
  schemaVersion: 1; sourceInstanceID: string; sequence: number; generatedAtMs: number;
  catalogTrusted: boolean; accounts: SelectorAccount[];
};
export type Exclusion = { credentialID: string; code: string };
export type SnapshotReadResult =
  | { ok: true; snapshot: SelectorExportV1; exclusions: Exclusion[] }
  | { ok: false; code: 'snapshot-missing' | 'snapshot-invalid' | 'publisher-stale' | 'catalog-untrusted' };
