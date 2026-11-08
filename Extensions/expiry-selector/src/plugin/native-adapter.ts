import type { Plugin } from '@opencode/plugin';
import { tokenIdentity } from '../shared/identity.js';
import type { NativeAccess } from './coordinator.js';

const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const text = (v: unknown): v is string => typeof v === 'string' && v.length > 0 && v.length <= 512;

/** Thin location-scoped native API seam. Never caches credential material. */
export class NativeAdapter implements NativeAccess {
  constructor(private readonly ctx: Plugin.Context) {}
  get locationKey() { return this.ctx.location.directory; }
  version() { return this.ctx.app.version; }

  async pluginIDs(): Promise<string[]> {
    const result: unknown = await this.ctx.plugin.list();
    if (!object(result) || !Array.isArray(result.data) || !result.data.every(row => object(row) && text(row.id))) throw new Error('native-unavailable');
    return result.data.map(row => row.id as string);
  }

  private async inventory() {
    const result = await this.ctx.integration.get({ integrationID: 'openai' });
    if (!object(result?.data) || result.data.id !== 'openai' || !Array.isArray(result.data.connections)) throw new Error('native-unavailable');
    if (!result.data.connections.every(row => object(row) && (row.type === 'env' ||
        (row.type === 'credential' && text(row.id) && typeof row.label === 'string' && ['oauth', 'key', 'external'].includes(row.method))))) throw new Error('native-unavailable');
    return result.data.connections;
  }

  async connections() {
    return (await this.inventory()).filter(row => row.type === 'credential').map(row =>
      ({ id: row.id, label: row.label, method: row.status ? 'unavailable' : row.method }));
  }

  async validateIdentity(id: string) {
    const matches = (await this.inventory()).filter(row => row.type === 'credential' && row.id === id);
    const connection = matches[0];
    if (matches.length !== 1 || !connection || connection.type !== 'credential' || connection.method !== 'oauth' || connection.status) throw new Error('native-unavailable');
    // Resolve delegates refresh and persistence to OpenCode. Only this projection escapes.
    const value = await this.ctx.integration.connection.resolve(connection);
    if (value?.type !== 'oauth' || !['chatgpt-browser', 'chatgpt-headless'].includes(value.methodID) ||
        !Number.isSafeInteger(value.expires) || value.expires <= Date.now()) throw new Error('native-unavailable');
    const identity = tokenIdentity(`Bearer ${value.access}`);
    if (!identity || value.metadata?.accountID !== identity.accountID) throw new Error('identity-mismatch');
    return { ...identity, methodID: value.methodID };
  }

  async promptProvider(sessionID: string): Promise<string | null> {
    const session = await this.ctx.session.get({ sessionID });
    return session.model && text(session.model.providerID) ? session.model.providerID : null;
  }

  async activeID(): Promise<string | null> {
    const connection = await this.ctx.integration.connection.active('openai');
    return connection?.type === 'credential' ? connection.id : null;
  }

  async activate(credentialID: string): Promise<void> {
    await this.ctx.credential.activate({ credentialID });
  }
}
