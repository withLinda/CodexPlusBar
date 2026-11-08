import { tokenIdentity, type Identity } from '../shared/identity.js';

export type RequestScope = { locationKey: string; sessionID: string; providerID: string; modelID: string; agent: string;
  kind: 'primary' | 'title' | 'generate' | 'compaction' };
export type RetryScope = Omit<RequestScope, 'kind'>;
export type TransportObservation = RequestScope & { generation: number; transport: 'http' | 'websocket'; identity: Identity | null; observedAtMs: number };
export type AttemptAttribution = { identity: Identity; generation: number; observedAtMs: number };
export type HeaderInput = { url: string; headers: Headers; managed: ReadonlySet<string> };
export type HeaderResult = { headers: Headers; identity: Identity | null; reason: 'unsupported-route' | 'attribution-unknown' | null };

export function repairTransportHeaders(input: HeaderInput): HeaderResult {
  const { url, headers, managed } = input;
  let route: URL;
  try { route = new URL(url); } catch { return { headers, identity: null, reason: 'unsupported-route' }; }
  if (!['https:', 'wss:'].includes(route.protocol) || route.hostname !== 'chatgpt.com' || route.port || route.username || route.password ||
      !route.pathname.startsWith('/backend-api/codex/')) return { headers, identity: null, reason: 'unsupported-route' };
  const identity = tokenIdentity(headers.get('authorization'));
  if (!identity || !managed.has(identity.identityKey)) return { headers, identity: null, reason: 'attribution-unknown' };
  headers.set('chatgpt-account-id', identity.accountID);
  return { headers, identity, reason: null };
}

/** Only repairs the account header to agree with the actual native token. */
export function cohereAccountHeader(url: string, headers: Headers, managed: ReadonlySet<string>): Identity | null {
  return repairTransportHeaders({ url, headers, managed }).identity;
}

type RecordValue = { scope: RequestScope; generation: number; startedAtMs: number; observedAtMs: number;
  identity: Identity | null; ambiguous: boolean; transports: Set<string>; consumed: boolean };
const sessionKey = (location: string, session: string) => JSON.stringify([location, session]);
const sameScope = (a: RetryScope, b: RetryScope) => a.locationKey === b.locationKey && a.sessionID === b.sessionID &&
  a.providerID === b.providerID && a.modelID === b.modelID && a.agent === b.agent;
const finished = new Set(['session.execution.succeeded', 'session.execution.failed', 'session.execution.interrupted', 'session.deleted']);

export class RequestObserver {
  private records = new Map<string, RecordValue>();
  private next = 0;
  constructor(private readonly maximum = 10_000, private readonly now = Date.now) {}
  get size() { return this.records.size; }

  beginPrimary(scope: RequestScope): number {
    if (scope.kind !== 'primary' || scope.providerID !== 'openai') return 0;
    const generation = ++this.next, key = sessionKey(scope.locationKey, scope.sessionID);
    this.records.delete(key);
    while (this.records.size >= this.maximum) this.records.delete(this.records.keys().next().value!);
    this.records.set(key, { scope: { ...scope }, generation, startedAtMs: this.now(), observedAtMs: 0,
      identity: null, ambiguous: false, transports: new Set(), consumed: false });
    return generation;
  }

  generation(scope: RetryScope): number | null {
    const record = this.records.get(sessionKey(scope.locationKey, scope.sessionID));
    return record && sameScope(scope, record.scope) ? record.generation : null;
  }

  observeTransport(input: TransportObservation): void {
    if (input.kind !== 'primary') return;
    const record = this.records.get(sessionKey(input.locationKey, input.sessionID));
    if (!record || !sameScope(input, record.scope) || input.generation !== record.generation || record.consumed) return;
    if (!input.identity || record.transports.has(input.transport) ||
        (record.identity && (record.identity.identityKey !== input.identity.identityKey || record.identity.accountID !== input.identity.accountID))) {
      record.ambiguous = true;
    }
    record.transports.add(input.transport);
    record.identity = input.identity ? { ...input.identity } : null;
    record.observedAtMs = input.observedAtMs;
  }

  takeRetryAttribution(scope: RetryScope): AttemptAttribution | null {
    const record = this.records.get(sessionKey(scope.locationKey, scope.sessionID));
    if (!record || !sameScope(scope, record.scope) || record.consumed) return null;
    record.consumed = true;
    if (record.ambiguous || !record.identity) return null;
    return { identity: { ...record.identity }, generation: record.generation, observedAtMs: record.observedAtMs };
  }

  forgetSession(locationKey: string, sessionID: string, expectedGeneration?: number): void {
    const key = sessionKey(locationKey, sessionID), record = this.records.get(key);
    if (record && (expectedGeneration === undefined || record.generation === expectedGeneration)) this.records.delete(key);
  }

  forgetLocation(locationKey: string): void {
    for (const [key, record] of this.records) if (record.scope.locationKey === locationKey) this.records.delete(key);
  }

  handleLifecycle(event: { type: string; created: number; location?: { directory: string }; data: { sessionID: string } }): void {
    if (!finished.has(event.type)) return;
    // Execution events originate from the global coordinator and may omit location.
    // Session IDs are global; still limit directory when the event supplies one.
    for (const record of this.records.values()) {
      if (record.scope.sessionID === event.data.sessionID && (!event.location || record.scope.locationKey === event.location.directory)
          && record.startedAtMs <= event.created) this.forgetSession(record.scope.locationKey, record.scope.sessionID, record.generation);
    }
  }
}
