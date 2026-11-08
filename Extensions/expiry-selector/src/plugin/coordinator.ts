import { randomUUID } from 'node:crypto';
import { selectAccount, type SelectionInput } from '../policy/eligibility.js';
import { classifyLimitFailure, type LimitFailureInput } from '../policy/limit-failure.js';
import { initialState, type SelectorState } from './state-store.js';
import type { Mode, NativeConnection, SelectionDecision, SnapshotReadResult, Trigger } from '../shared/contracts.js';

export interface NativeAccess {
  locationKey: string;
  version(): string;
  pluginIDs(): Promise<string[]>;
  connections(): Promise<NativeConnection[]>;
  activeID(): Promise<string | null>;
  validateIdentity(id: string): Promise<{ identityKey: string; accountID: string; methodID: string }>;
  activate(id: string): Promise<void>;
}
export type CoordinatorDependencies = {
  now: () => number; owns: () => boolean; readSnapshot: (now: number) => Promise<SnapshotReadResult>;
  loadState: () => Promise<SelectorState>; saveState: (state: SelectorState) => Promise<void>;
};
export type AttributedRetry = Omit<LimitFailureInput, 'nowMs' | 'usage'> & { locationKey: string; sessionID: string; modelID: string; attempt: number };
export type SelectorStatus = {
  mode: Mode; blockedReason: string | null; supportedVersions: { opencode: string; openchamber: string };
  activeCredentialID: string | null; activeLabel: string | null; nextCredentialID: string | null;
  snapshotAgeMs: number | null; exclusions: { credentialID: string; code: string }[];
  holdsCount: number; lastSwitch: { atMs: number; credentialID: string } | null;
  recentHistory: SelectorState['recentHistory']; checking: boolean;
};

export class SelectorCoordinator {
  private adapters = new Map<string, NativeAccess>();
  private state = initialState();
  private initialized = false;
  private generation = 0;
  private tail: Promise<unknown> = Promise.resolve();
  private coalesced: Promise<SelectionDecision> | undefined;
  private managed = new Set<string>();
  private unsupported = new Set<string>();
  private holds = new Map<string, string>();
  private operations = new Map<string, { signature: string; result: Promise<unknown>; settled: boolean }>();
  private chains = new Map<string, { attempt: number; failed: Set<string>; locationKey: string; sessionID: string; startedAtMs: number }>();
  private view: SelectorStatus = { mode: 'paused', blockedReason: 'paused', supportedVersions: { opencode: '2.2.6', openchamber: '2.7.0' },
    activeCredentialID: null, activeLabel: null, nextCredentialID: null, snapshotAgeMs: null, exclusions: [], holdsCount: 0,
    lastSwitch: null, recentHistory: [], checking: false };
  constructor(private readonly dependencies: CoordinatorDependencies) {}

  async initialize(): Promise<void> {
    this.state = await this.dependencies.loadState(); this.initialized = true;
    this.view.mode = this.state.desiredMode;
    this.view.blockedReason = this.state.diagnostic ?? (this.state.maintenanceRecovery ? 'maintenance' : this.state.desiredMode === 'paused' ? 'paused' : null);
    this.view.recentHistory = this.state.recentHistory;
  }

  attach(adapter: NativeAccess): () => Promise<void> {
    if (this.adapters.has(adapter.locationKey)) throw new Error('Location already attached');
    this.adapters.set(adapter.locationKey, adapter);
    this.generation++;
    return async () => {
      if (this.adapters.get(adapter.locationKey) === adapter) { this.adapters.delete(adapter.locationKey); this.generation++; }
      this.unsupported.delete(adapter.locationKey);
      for (const [key, chain] of this.chains) if (chain.locationKey === adapter.locationKey) this.chains.delete(key);
      await this.tail;
    };
  }

  status(): SelectorStatus { return structuredClone({ ...this.view, holdsCount: this.holds.size + (this.state.maintenanceRecovery && !this.holds.size ? 1 : 0) }); }
  invalidate(reason: string): void { this.generation++; this.view.blockedReason = reason; }
  unsupportedRoute(locationKey: string): void { this.unsupported.add(locationKey); this.invalidate('unsupported-route'); }
  managedIdentities(): ReadonlySet<string> { return new Set(this.managed); }
  async refreshSnapshot(): Promise<SnapshotReadResult> {
    const result = await this.dependencies.readSnapshot(this.dependencies.now());
    this.managed = new Set(result.ok ? result.snapshot.accounts.map(row => row.identityKey) : []);
    return result;
  }
  handleLifecycle(event: { type: string; created: number; location?: { directory: string }; data: unknown }): void {
    if (event.type === 'config.updated') { this.invalidate('checking'); void this.requestSelection('snapshot'); return; }
    if (!['session.execution.succeeded', 'session.execution.failed', 'session.execution.interrupted', 'session.deleted'].includes(event.type) ||
        !event.data || typeof event.data !== 'object' || !('sessionID' in event.data)) return;
    for (const [key, chain] of this.chains) if (chain.sessionID === event.data.sessionID && chain.startedAtMs <= event.created &&
        (!event.location || event.location.directory === chain.locationKey)) this.chains.delete(key);
  }
  async close(): Promise<void> { this.generation++; this.adapters.clear(); await this.tail; }

  private queue<T>(work: () => Promise<T>): Promise<T> {
    const result = this.tail.then(work);
    this.tail = result.catch(() => {});
    return result;
  }
  private blocked(code: string): SelectionDecision {
    this.view.blockedReason = code;
    return { action: 'blocked', code, exclusions: this.view.exclusions };
  }
  private adapter(locationKey?: string): NativeAccess | undefined { return locationKey ? this.adapters.get(locationKey) : this.adapters.values().next().value; }
  private baseGuard(adapter: NativeAccess | undefined, auto = true): string | null {
    if (!this.initialized || this.state.diagnostic) return 'persistence-unavailable';
    if (!this.dependencies.owns()) return 'ownership-unavailable';
    if (this.unsupported.size) return 'unsupported-route';
    if (!adapter || this.adapters.get(adapter.locationKey) !== adapter) return 'native-unavailable';
    if (adapter.version() !== '2.2.6') return 'unsupported-runtime';
    if (this.holds.size || this.state.maintenanceRecovery) return 'maintenance';
    if (auto && this.state.desiredMode !== 'auto') return 'paused';
    return null;
  }
  private async guard(adapter: NativeAccess | undefined, generation: number, auto = true): Promise<string | null> {
    if (generation !== this.generation) return 'checking-cancelled';
    const first = this.baseGuard(adapter, auto);
    if (first) return first;
    for (const location of this.adapters.values()) {
      if (location.version() !== '2.2.6') return 'unsupported-runtime';
      const plugins = await location.pluginIDs();
      if (generation !== this.generation) return 'checking-cancelled';
      if (plugins.includes('openchamber-limit-failover')) return 'competing-switcher';
    }
    return this.baseGuard(adapter, auto);
  }
  private async persist(next: SelectorState): Promise<void> {
    try { await this.dependencies.saveState(next); this.state = next; this.view.mode = next.desiredMode; this.view.recentHistory = next.recentHistory; }
    catch { this.state = { ...this.state, desiredMode: 'paused', diagnostic: 'persistence-unavailable' };
      this.view.mode = 'paused'; this.view.blockedReason = 'persistence-unavailable'; this.generation++; throw new Error('persistence-unavailable'); }
  }

  requestSelection(_trigger: Trigger, locationKey?: string): Promise<SelectionDecision> {
    if (this.coalesced) return this.coalesced;
    const generation = this.generation;
    const operation = this.queue(() => this.select(locationKey, new Set(), generation));
    this.coalesced = operation;
    void operation.finally(() => { if (this.coalesced === operation) this.coalesced = undefined; });
    return operation;
  }

  private async select(locationKey: string | undefined, failed: Set<string>, generation = this.generation): Promise<SelectionDecision> {
    const adapter = this.adapter(locationKey);
    const observationOnly = this.state.desiredMode === 'paused';
    const rejected = new Set<string>();
    const eligibleConnections = (connections: NativeConnection[]) => connections.map(row => rejected.has(row.id) ? { ...row, method: 'unavailable' } : row);
    const choose = (input: SelectionInput): SelectionDecision => {
      const decision = selectAccount(input);
      // A late quota failure must not displace another session's healthy replacement.
      if (failed.size && decision.action !== 'blocked' && input.activeCredentialID &&
          input.snapshot.accounts.some(row => row.credentialID === input.activeCredentialID) &&
          !decision.exclusions.some(row => row.credentialID === input.activeCredentialID)) {
        return { action: 'keep', credentialID: input.activeCredentialID, exclusions: decision.exclusions };
      }
      return decision;
    };
    this.view.checking = true;
    try {
      for (let iteration = 0; iteration < 3; iteration++) {
        const problem = await this.guard(adapter, generation, !observationOnly);
        if (problem) return this.blocked(problem);
        const snapshot = await this.refreshSnapshot();
        if (generation !== this.generation) return this.blocked('checking-cancelled');
        if (!snapshot.ok) return this.blocked(snapshot.code);
        const connections = await adapter!.connections();
        if (generation !== this.generation) return this.blocked('checking-cancelled');
        const activeCredentialID = await adapter!.activeID();
        if (generation !== this.generation) return this.blocked('checking-cancelled');
        this.view.activeCredentialID = activeCredentialID;
        this.view.activeLabel = connections.find(connection => connection.id === activeCredentialID)?.label ?? null;
        this.view.snapshotAgeMs = this.dependencies.now() - snapshot.snapshot.generatedAtMs;
        const decision = choose({ snapshot: snapshot.snapshot, connections: eligibleConnections(connections), activeCredentialID, cooldowns: this.state.cooldowns,
          failedIdentityKeys: failed, nowMs: this.dependencies.now() });
        this.view.exclusions = [...snapshot.exclusions, ...decision.exclusions];
        if (decision.action === 'blocked') { this.view.nextCredentialID = null; return this.blocked(decision.code); }
        this.view.nextCredentialID = decision.credentialID;
        if (observationOnly) return this.blocked('paused');
        const target = snapshot.snapshot.accounts.find(row => row.credentialID === decision.credentialID)!;
        let identity;
        try { identity = await adapter!.validateIdentity(target.credentialID); }
        catch { if (generation !== this.generation) return this.blocked('checking-cancelled'); rejected.add(target.credentialID); continue; }
        if (generation !== this.generation) return this.blocked('checking-cancelled');
        if (!['chatgpt-browser', 'chatgpt-headless'].includes(identity.methodID) || identity.identityKey !== target.identityKey || identity.accountID !== target.accountID) {
          rejected.add(target.credentialID); continue;
        }
        const recheck = await this.guard(adapter, generation);
        if (recheck) return this.blocked(recheck);
        const fresh = await this.refreshSnapshot();
        if (generation !== this.generation) return this.blocked('checking-cancelled');
        const inventory = await adapter!.connections();
        if (generation !== this.generation) return this.blocked('checking-cancelled');
        const active = await adapter!.activeID();
        if (generation !== this.generation) return this.blocked('checking-cancelled');
        if (!fresh.ok) return this.blocked(fresh.code);
        if (JSON.stringify(fresh) !== JSON.stringify(snapshot) || JSON.stringify(inventory) !== JSON.stringify(connections) || active !== activeCredentialID) continue;
        const finalGuard = await this.guard(adapter, generation);
        if (finalGuard) return this.blocked(finalGuard);
        // Re-evaluate time after native refresh; passing time may invalidate quota/reset/expiry.
        const finalDecision = choose({ snapshot: fresh.snapshot, connections: eligibleConnections(inventory), activeCredentialID: active,
          cooldowns: this.state.cooldowns, failedIdentityKeys: failed, nowMs: this.dependencies.now() });
        if (finalDecision.action === 'blocked' || finalDecision.credentialID !== target.credentialID) continue;
        if (active === target.credentialID) { this.view.blockedReason = null; return { action: 'keep', credentialID: active, exclusions: this.view.exclusions }; }
        await adapter!.activate(target.credentialID);
        // Once dispatched, always await readback before the next queued operation.
        const readback = await adapter!.activeID();
        this.view.activeCredentialID = readback;
        if (readback !== target.credentialID) return this.blocked('activation-unconfirmed');
        if (generation !== this.generation || this.baseGuard(adapter)) return this.blocked('checking-cancelled');
        this.view.activeLabel = target.label; this.view.lastSwitch = { atMs: this.dependencies.now(), credentialID: target.credentialID };
        const history = [...this.state.recentHistory, { atMs: this.dependencies.now(), code: 'activated', credentialID: target.credentialID }].slice(-100);
        await this.persist({ ...this.state, recentHistory: history });
        if (generation !== this.generation) return this.blocked('checking-cancelled');
        this.view.blockedReason = null;
        return { action: 'activate', credentialID: target.credentialID, identityKey: target.identityKey, exclusions: this.view.exclusions };
      }
      return this.blocked('snapshot-changed');
    } catch { return this.blocked(this.state.diagnostic ?? 'native-unavailable'); }
    finally { this.view.checking = false; }
  }

  handleRetry(input: AttributedRetry): Promise<{ retry: true; delay: 0 } | null> {
    const generation = this.generation;
    return this.queue(async () => {
      try {
        if (input.attempt < 2 || input.attempt > 10 || !Number.isInteger(input.attempt)) return null;
        const adapter = this.adapter(input.locationKey);
        const problem = await this.guard(adapter, generation);
        if (problem) { this.blocked(problem); return null; }
        const snapshot = await this.refreshSnapshot();
        if (!snapshot.ok || generation !== this.generation) return null;
        const usage = snapshot.snapshot.accounts.find(row => row.identityKey === input.identityKey)?.usage;
        const cooldown = classifyLimitFailure({ ...input, usage: usage ?? null, nowMs: this.dependencies.now() });
        if (!cooldown) return null;
        const key = JSON.stringify([input.locationKey, input.sessionID, input.modelID]);
        let chain = this.chains.get(key);
        if (input.attempt === 2 || !chain) chain = { attempt: input.attempt, failed: new Set(), locationKey: input.locationKey,
          sessionID: input.sessionID, startedAtMs: this.dependencies.now() };
        chain.attempt = input.attempt; chain.failed.add(input.identityKey);
        this.chains.delete(key); this.chains.set(key, chain);
        while (this.chains.size > 10_000) this.chains.delete(this.chains.keys().next().value!);
        const previous = this.state.cooldowns[cooldown.identityKey];
        if (previous && previous.resetAtMs > cooldown.resetAtMs) cooldown.resetAtMs = previous.resetAtMs;
        await this.persist({ ...this.state, cooldowns: { ...this.state.cooldowns, [cooldown.identityKey]: cooldown },
          recentHistory: [...this.state.recentHistory, { atMs: this.dependencies.now(), code: 'cooldown', credentialID: null }].slice(-100) });
        if (generation !== this.generation) return null;
        const decision = await this.select(input.locationKey, chain.failed);
        if (decision.action === 'blocked') return null;
        const finalGuard = await this.guard(adapter, generation);
        if (finalGuard) { this.blocked(finalGuard); return null; }
        return await adapter!.activeID() === decision.credentialID && generation === this.generation ? { retry: true, delay: 0 } : null;
      } catch { return null; }
    });
  }

  private once<T>(operationID: string, signature: string, work: () => Promise<T>): Promise<T> {
    const existing = this.operations.get(operationID);
    if (existing) return existing.signature === signature ? existing.result as Promise<T> : Promise.reject(new Error('operation-conflict'));
    if (this.operations.size >= 256) {
      const evict = [...this.operations].find(([id, value]) => value.settled && ![...this.holds.values()].includes(id));
      if (!evict) return Promise.reject(new Error('control-capacity'));
      this.operations.delete(evict[0]);
    }
    const result = this.queue(work);
    const operation = { signature, result, settled: false };
    this.operations.set(operationID, operation);
    void result.then(() => { operation.settled = true; }, () => { operation.settled = true; });
    return result;
  }
  recheck(operationID: string): Promise<SelectorStatus> {
    const generation = this.generation;
    return this.once(operationID, 'recheck', async () => {
      await this.select(undefined, new Set(), generation);
      return this.status();
    });
  }
  setMode(mode: Mode, operationID: string): Promise<SelectorStatus> {
    if (mode === 'paused' && !this.operations.has(operationID)) this.generation++;
    const generation = this.generation;
    return this.once(operationID, `mode:${mode}`, async () => {
      if (mode === 'auto') {
        const problem = await this.guard(this.adapter(), generation, false);
        if (problem) { this.blocked(problem); throw new Error(problem); }
        const snapshot = await this.refreshSnapshot();
        if (generation !== this.generation) throw new Error('checking-cancelled');
        if (!snapshot.ok) { this.blocked(snapshot.code); throw new Error(snapshot.code); }
      }
      await this.persist({ ...this.state, desiredMode: mode });
      this.generation++; this.view.blockedReason = mode === 'paused' ? 'paused' : null;
      return this.status();
    });
  }
  beginMaintenance(operationID: string, reason: string): Promise<{ holdToken: string }> {
    if (!this.operations.has(operationID)) this.generation++;
    return this.once(operationID, `begin:${reason}`, async () => {
      await this.persist({ ...this.state, desiredMode: 'paused', maintenanceRecovery: true });
      const holdToken = randomUUID(); this.holds.set(holdToken, operationID);
      this.view.blockedReason = 'maintenance'; return { holdToken };
    });
  }
  endMaintenance(operationID: string, holdToken: string): Promise<SelectorStatus> {
    return this.once(operationID, `end:${holdToken}`, async () => {
      if (!this.holds.has(holdToken)) throw new Error('maintenance-token-unknown');
      await this.persist({ ...this.state, desiredMode: 'paused', maintenanceRecovery: this.holds.size > 1 });
      this.holds.delete(holdToken); this.view.blockedReason = this.holds.size ? 'maintenance' : 'paused';
      return this.status();
    });
  }
}
