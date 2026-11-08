import type { Plugin } from '@opencode/plugin';
import { NativeAdapter } from './native-adapter.js';
import { RequestObserver } from './request-observer.js';
import { registerTransportHooks } from './transport-hooks.js';
import { registerSelectionHooks } from './hooks.js';
import { acquireOwnership, type OwnershipOptions } from './ownership.js';

export async function installSelector(ctx: Plugin.Context, options: OwnershipOptions = {}) {
  const adapter = new NativeAdapter(ctx);
  return acquireOwnership(adapter, { ...options, setupLocation: async coordinator => {
    const observer = new RequestObserver();
    const disposals: (() => Promise<void>)[] = [];
    try {
      await coordinator.refreshSnapshot();
      disposals.push(await registerTransportHooks(ctx, observer, () => coordinator.managedIdentities(), reason => {
        if (reason === 'unsupported-route') coordinator.unsupportedRoute(adapter.locationKey);
      }, event => coordinator.handleLifecycle(event)));
      disposals.push(await registerSelectionHooks(ctx, adapter, coordinator, observer));
    } catch (error) { await Promise.allSettled(disposals.map(dispose => dispose())); throw error; }
    return async () => { await Promise.allSettled(disposals.reverse().map(dispose => dispose())); observer.forgetLocation(adapter.locationKey); };
  } });
}

export default {
  id: 'codexplusbar-expiry-selector',
  async setup(ctx) { const owner = await installSelector(ctx); return owner.detach; },
} satisfies Plugin.Plugin;
