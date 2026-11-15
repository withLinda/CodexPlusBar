import type { Plugin } from '@opencode/plugin';
import { RequestObserver, repairTransportHeaders, type RequestScope } from './request-observer.js';
import { requireHookRegistration } from '../shared/compatibility.js';

/** Capability-checked native hooks. No credentials, bodies, or prompts are retained. */
export async function registerTransportHooks(ctx: Plugin.Context, observer: RequestObserver,
  managed: () => ReadonlySet<string>, unsupported: (reason: string) => void = () => {},
  lifecycle: (event: { type: string; created: number; location?: { directory: string }; data: unknown }) => void = () => {}) {
  const locationKey = ctx.location.directory;
  const scope = (event: { sessionID: string; model: { providerID: string; id: string }; agent: string; kind: RequestScope['kind'] }): RequestScope =>
    ({ locationKey, sessionID: event.sessionID, providerID: event.model.providerID, modelID: event.model.id, agent: event.agent, kind: event.kind });
  const registrations: { dispose(): Promise<void> }[] = [];
  const abort = new AbortController();
  try {
    registrations.push(requireHookRegistration(await ctx.session.hook('model.request', event => { observer.beginPrimary(scope(event)); }, { providerID: 'openai' })));
    registrations.push(requireHookRegistration(await ctx.session.hook('http.request', event => {
      const result = repairTransportHeaders({ url: event.request.url, headers: event.request.headers, managed: managed() });
      if (result.reason) unsupported(result.reason);
      const request = scope(event), generation = observer.generation(request);
      if (generation !== null) observer.observeTransport({ ...request, generation, identity: result.identity, transport: 'http', observedAtMs: Date.now() });
    }, { providerID: 'openai' })));
    registrations.push(requireHookRegistration(await ctx.session.hook('experimental.ws.handshake', event => {
      const result = repairTransportHeaders({ url: event.url, headers: new Headers(event.headers), managed: managed() });
      if (result.reason) unsupported(result.reason);
      else event.headers = Object.fromEntries(result.headers);
      const request = scope(event), generation = observer.generation(request);
      if (generation !== null) observer.observeTransport({ ...request, generation, identity: result.identity, transport: 'websocket', observedAtMs: Date.now() });
    }, { providerID: 'openai' })));
    const events = (() => {
      try {
        const stream = ctx.event.subscribe({ types: ['session.execution.succeeded', 'session.execution.failed', 'session.execution.interrupted', 'session.deleted', 'config.updated'], signal: abort.signal });
        if (!stream || typeof stream[Symbol.asyncIterator] !== 'function') throw new Error('lifecycle-unavailable');
        return stream;
      } catch {
        unsupported('lifecycle-unavailable');
        throw new Error('lifecycle-unavailable');
      }
    })();
    const consume = (async () => {
      try { for await (const event of events) {
        if (event.type !== 'config.updated') observer.handleLifecycle(event);
        lifecycle(event);
      } }
      catch { /* Unexpected stream termination is handled below, including a clean early end. */ }
      finally { if (!abort.signal.aborted) { observer.forgetLocation(locationKey); unsupported('lifecycle-unavailable'); } }
    })();
    return async () => {
      abort.abort();
      await Promise.allSettled(registrations.reverse().map(async registration => { await registration.dispose(); }));
      await consume;
      observer.forgetLocation(locationKey);
    };
  } catch (error) {
    abort.abort();
    await Promise.allSettled(registrations.map(async registration => { await registration.dispose(); }));
    throw error;
  }
}
