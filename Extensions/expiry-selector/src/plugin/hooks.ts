import type { Plugin } from '@opencode/plugin';
import type { NativeAdapter } from './native-adapter.js';
import type { SelectorCoordinator } from './coordinator.js';
import type { RequestObserver } from './request-observer.js';

const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const hintKeys = ['resets_at', 'reset_at', 'resetsAt', 'resetAt', 'retry_after', 'retryAfter', 'resets_in_seconds', 'reset_in_seconds'];
function resetHints(body: unknown): unknown {
  try {
    const value: unknown = typeof body === 'string' && body.length <= 65_536 ? JSON.parse(body) : null;
    if (!object(value)) return undefined;
    const pick = (v: Record<string, unknown>) => Object.fromEntries(hintKeys.flatMap(key => {
      const item = v[key];
      return typeof item === 'number' || (typeof item === 'string' && item.length <= 128) ? [[key, item]] : [];
    }));
    return { ...pick(value), ...(object(value.error) ? { error: pick(value.error) } : {}) };
  } catch { return undefined; }
}

export async function registerSelectionHooks(ctx: Plugin.Context, adapter: NativeAdapter, coordinator: SelectorCoordinator, observer: RequestObserver) {
  const registrations: { dispose(): Promise<void> }[] = [];
  try {
    registrations.push(await ctx.session.hook('prompt', async event => {
      try {
        if (await adapter.promptProvider(event.sessionID) === 'openai') await coordinator.requestSelection('prompt', adapter.locationKey);
      } catch { /* Preserve prompt admission on unknown native state. */ }
    }));
    registrations.push(await ctx.session.hook('retry', async event => {
      try {
        const attribution = observer.takeRetryAttribution({ locationKey: adapter.locationKey, sessionID: event.sessionID,
          providerID: event.model.providerID, modelID: event.model.id, agent: event.agent });
        if (!attribution) return;
        const error = event.error;
        const result = await coordinator.handleRetry({ locationKey: adapter.locationKey, sessionID: event.sessionID, modelID: event.model.id,
          attempt: event.attempt, identityKey: attribution.identity.identityKey, errorType: error.type,
          hints: resetHints('response' in error ? error.response?.body : undefined),
          ...('retryAfterMs' in error && typeof error.retryAfterMs === 'number' ? { retryAfterMs: error.retryAfterMs } : {}),
          ...(event.decision.retry ? { proposedDelayMs: event.decision.delay } : {}) });
        if (result) event.decision = result;
      } catch { /* A failed selector never replaces native retry handling. */ }
    }, { providerID: 'openai' }));
  } catch (error) {
    await Promise.allSettled(registrations.map(registration => registration.dispose()));
    throw error;
  }
  return async () => { await Promise.allSettled(registrations.map(registration => registration.dispose())); };
}
