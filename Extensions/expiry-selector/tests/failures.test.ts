import { expect, test } from 'vitest';
import { classifyLimitFailure } from '../src/policy/limit-failure.js';
const now = 1_800_000_000_000;
const identityKey = 'a'.repeat(64);
const classify = (extra = {}) => classifyLimitFailure({ identityKey, errorType: 'provider.quota', nowMs: now, ...extra });

test.each(['provider.quota', 'provider.free-limit', 'provider.budget-limit', 'provider.model-budget-limit'])('%s without hint waits one hour', errorType => {
  expect(classify({ errorType })).toEqual({ identityKey, failedAtMs: now, resetAtMs: now + 3_600_000, reason: 'quota', source: 'fallback' });
});
test.each(['provider.auth', 'provider.network', 'provider.server', 'provider.context-length', 'cancelled', 'parse'])('%s is not exhaustion', errorType => {
  expect(classify({ errorType })).toBeNull();
});
test('rate-limit threshold is exactly 60 seconds', () => {
  expect(classify({ errorType: 'provider.rate-limit', retryAfterMs: 59_999 })).toBeNull();
  expect(classify({ errorType: 'provider.rate-limit', retryAfterMs: 60_000 })).toMatchObject({ resetAtMs: now + 60_000, reason: 'long-rate-limit' });
  expect(classify({ errorType: 'provider.rate-limit', proposedDelayMs: 60_000 })).toMatchObject({ resetAtMs: now + 60_000 });
});
test.each([1_800_000_120, 1_800_000_120_000, '1800000120', '1800000120000', new Date(now + 120_000).toISOString()])('reset hint %s uses explicit provider time', reset_at => {
  expect(classify({ hints: { error: { reset_at } } })).toMatchObject({ resetAtMs: now + 120_000, source: 'provider' });
});
test.each(['garbage', '', -1, 0, now - 1000, Infinity, Number.MAX_SAFE_INTEGER + 1, now + 31 * 86_400_000 + 1])('invalid reset hint %s falls back', reset_at => {
  expect(classify({ hints: { reset_at } })).toMatchObject({ resetAtMs: now + 3_600_000, source: 'fallback' });
});
test('latest known exhausted window reset wins only without provider timing', () => {
  const usage = { observedAtMs: now - 1000, identityKey, allowed: false, limitReached: true,
    fiveHour: { remainingPercent: 0, resetAtMs: now + 2000 },
    sevenDay: { state: 'available', remainingPercent: 0, resetAtMs: now + 5000 } };
  expect(classify({ usage })).toMatchObject({ resetAtMs: now + 5000, source: 'usage' });
  expect(classify({ usage, hints: { retry_after: '120' } })).toMatchObject({ resetAtMs: now + 120_000, source: 'provider' });
  expect(classify({ usage: { ...usage, identityKey: 'b'.repeat(64) } })).toMatchObject({ source: 'fallback' });
});
