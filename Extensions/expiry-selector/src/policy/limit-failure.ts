import { limits, type Cooldown, type UsageObservation } from '../shared/contracts.js';

export type LimitFailureInput = {
  identityKey: string; errorType: string; hints?: unknown; retryAfterMs?: number; proposedDelayMs?: number;
  usage?: UsageObservation | null; nowMs: number;
};
const quotaTypes = new Set(['provider.quota', 'provider.free-limit', 'provider.budget-limit', 'provider.model-budget-limit']);
const maximumWait = 31 * 86_400_000;
const object = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === 'object' && !Array.isArray(v);
const numeric = (v: unknown): number | null => {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  if (typeof v === 'string' && /^\d+(\.\d+)?$/.test(v)) return Number(v);
  return null;
};
const validReset = (value: number, now: number) => Number.isSafeInteger(value) && value > now && value - now <= maximumWait;
const delayReset = (v: unknown, factor: number, now: number): number | null => {
  const delay = numeric(v);
  if (delay === null || delay <= 0) return null;
  const reset = now + delay * factor;
  return validReset(reset, now) ? reset : null;
};
function hintsReset(hints: unknown, now: number): number | null {
  if (!object(hints)) return null;
  for (const key of ['resets_at', 'reset_at', 'resetsAt', 'resetAt']) {
    const raw = hints[key], value = numeric(raw);
    const reset = value !== null ? (value < 1e10 ? value * 1000 : value) :
      typeof raw === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(raw) ? Date.parse(raw) : NaN;
    if (validReset(reset, now)) return reset;
  }
  for (const key of ['retry_after', 'retryAfter', 'resets_in_seconds', 'reset_in_seconds']) {
    const reset = delayReset(hints[key], 1000, now);
    if (reset !== null) return reset;
  }
  return null;
}

export function classifyLimitFailure(input: LimitFailureInput): Cooldown | null {
  const { nowMs: now, identityKey, errorType } = input;
  if (!/^[a-f0-9]{64}$/.test(identityKey) || !Number.isSafeInteger(now) || now < 0 || !Number.isSafeInteger(now + maximumWait)) return null;
  if (!quotaTypes.has(errorType) && errorType !== 'provider.rate-limit') return null;
  const provider = delayReset(input.retryAfterMs, 1, now) ?? hintsReset(input.hints, now) ??
    (object(input.hints) ? hintsReset(input.hints.error, now) : null);
  const proposed = delayReset(input.proposedDelayMs, 1, now);
  if (errorType === 'provider.rate-limit' && Math.max((provider ?? now) - now, (proposed ?? now) - now) < 60_000) return null;
  let resetAtMs = provider ?? (proposed !== null && proposed - now >= 60_000 ? proposed : null);
  let source: Cooldown['source'] = 'provider';
  if (resetAtMs === null) {
    const usage = input.usage;
    const resets: number[] = [];
    if (usage && usage.identityKey === identityKey && Number.isSafeInteger(usage.observedAtMs) &&
        now - usage.observedAtMs <= limits.usageAgeMs && usage.observedAtMs <= now + limits.futureSkewMs) {
      if (usage.fiveHour.remainingPercent === 0 && validReset(usage.fiveHour.resetAtMs, now)) resets.push(usage.fiveHour.resetAtMs);
      if (usage.sevenDay.state === 'available' && usage.sevenDay.remainingPercent === 0 && validReset(usage.sevenDay.resetAtMs, now)) resets.push(usage.sevenDay.resetAtMs);
    }
    resetAtMs = resets.length ? Math.max(...resets) : now + 3_600_000;
    source = resets.length ? 'usage' : 'fallback';
  }
  return { identityKey, failedAtMs: now, resetAtMs, reason: errorType === 'provider.rate-limit' ? 'long-rate-limit' : 'quota', source };
}
