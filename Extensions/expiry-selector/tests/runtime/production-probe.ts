import type { Plugin } from '@opencode/plugin';
import { installSelector } from '../../src/plugin/index.js';
import { join } from 'node:path';
import { homedir } from 'node:os';

// Only transport redirection and sanitized inspection are test-owned here.
export default {
  id: 'codexplusbar-expiry-selector-probe',
  async setup(ctx) {
    const selector = await installSelector(ctx, { port: Number(ctx.options.coordinatorPort),
      snapshotPath: join(homedir(), 'fixture-snapshot.json') });
    await ctx.rpc.register({ id: 'expiry.probe', methods: {
      status: { input: { type: 'object' }, output: { type: 'object' } },
      mode: { input: { type: 'object' }, output: { type: 'object' } },
    }, events: {} }, {
      async status() { return selector.coordinator.status(); },
      async mode(input) { return selector.coordinator.setMode((input as { mode: 'auto' | 'paused' }).mode, crypto.randomUUID()); },
    });
    await ctx.session.hook('title', event => { event.result = 'Fixture'; });
    await ctx.session.hook('http.request', event => {
      const route = new URL(event.request.url);
      if (route.origin !== 'https://chatgpt.com') throw new Error('Unexpected fixture route');
      event.request.headers.set('x-fixture-kind', event.kind);
      event.request = new Request(String(ctx.options.fixtureOrigin) + route.pathname, event.request);
    }, { providerID: 'openai' });
    await ctx.session.hook('experimental.ws.handshake', event => {
      event.url = String(ctx.options.fixtureOrigin).replace('http:', 'ws:') + '/refuse';
    }, { providerID: 'openai' });
    return selector.detach;
  },
} satisfies Plugin.Plugin;
