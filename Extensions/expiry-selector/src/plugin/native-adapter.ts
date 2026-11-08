import type { Plugin } from '@opencode/plugin';

/** Thin location-scoped native API seam. Never caches credential material. */
export class NativeAdapter {
  constructor(private readonly ctx: Plugin.Context) {}

  async activeID(): Promise<string | null> {
    const connection = await this.ctx.integration.connection.active('openai');
    return connection?.type === 'credential' ? connection.id : null;
  }

  async activate(credentialID: string): Promise<void> {
    await this.ctx.credential.activate({ credentialID });
  }
}
