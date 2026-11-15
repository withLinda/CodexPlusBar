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
    const cleanup = async () => {
      await Promise.allSettled(disposals.splice(0).reverse().map(async dispose => { await dispose(); }));
      observer.forgetLocation(adapter.locationKey);
    };
    // Keep the control/status bridge available even when this host lacks an API.
    const issue = adapter.compatibilityIssue();
    if (issue && issue !== 'hooks-not-ready') {
      coordinator.invalidate(issue);
      return cleanup;
    }
    try {
      await coordinator.refreshSnapshot();
      disposals.push(await registerTransportHooks(ctx, observer, () => coordinator.managedIdentities(), reason => {
        if (reason === 'unsupported-route') coordinator.unsupportedRoute(adapter.locationKey);
        if (reason === 'lifecycle-unavailable') {
          adapter.blockHooks(reason);
          coordinator.invalidate(reason);
        }
      }, event => coordinator.handleLifecycle(event)));
      disposals.push(await registerSelectionHooks(ctx, adapter, coordinator, observer));
      adapter.hooksReady();
    } catch {
      if (adapter.compatibilityIssue() === 'hooks-not-ready') adapter.blockHooks('hooks-unavailable');
      coordinator.invalidate(adapter.compatibilityIssue() ?? 'hooks-unavailable');
      await cleanup();
    }
    return async () => { adapter.blockHooks('hooks-not-ready'); await cleanup(); };
  } });
}

export default {
  id: 'codexplusbar-expiry-selector',
  async setup(ctx) { const owner = await installSelector(ctx); return owner.detach; },
} satisfies Plugin.Plugin;
