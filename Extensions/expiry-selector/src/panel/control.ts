import { publicStatus, type PublicStatus } from '../shared/status.js';

type Pending = { route: 'mode' | 'recheck'; body: { operationID: string; mode?: string } };
export type PanelState = { phase: 'loading' | 'ready' | 'pending' | 'unconfirmed' | 'unavailable';
  status: PublicStatus | null; error: string | null; pending: Pending | null };
type Request = (input: { method: 'GET' | 'POST'; path: string; body?: string }) => Promise<{ status: number; body: string }>;

export class PanelControl {
  state: PanelState = { phase: 'loading', status: null, error: null, pending: null };
  private generation = 0;
  constructor(private readonly request: Request, private readonly changed: (state: PanelState) => void = () => {}) {}
  private publish(value: Partial<PanelState>) { this.state = { ...this.state, ...value }; this.changed(this.state); }
  private result(response: { status: number; body: string }) {
    if (response.status !== 200 || response.body.length > 1_048_576) throw new Error('unavailable');
    return publicStatus(JSON.parse(response.body));
  }
  async load() {
    if (this.state.pending) return;
    const generation = ++this.generation;
    try {
      const result = this.result(await this.request({ method: 'GET', path: '/v1/status' }));
      if (generation === this.generation) this.publish({ phase: 'ready', status: result, error: null });
    } catch {
      if (generation === this.generation) this.publish({ phase: 'unavailable', error: 'Selector status could not be verified. Check the extension and local OpenChamber instance.' });
    }
  }
  async command(route: 'mode' | 'recheck', mode?: 'auto' | 'paused') {
    if (this.state.pending) return;
    this.generation++;
    this.publish({ pending: { route, body: { operationID: crypto.randomUUID(), ...(mode ? { mode } : {}) } } });
    await this.retry();
  }
  async retry() {
    const pending = this.state.pending;
    if (!pending || this.state.phase === 'pending') return;
    this.publish({ phase: 'pending', error: null });
    try {
      const response = await this.request({ method: 'POST', path: `/v1/${pending.route}`, body: JSON.stringify(pending.body) });
      if (response.status === 409 && response.body.length <= 1_048_576) {
        const refusal = JSON.parse(response.body);
        if (refusal.code === 'control-conflict') {
          this.publish({ phase: 'ready', pending: null, status: publicStatus(refusal.status), error: null }); return;
        }
      }
      const status = this.result(response);
      this.publish({ phase: 'ready', pending: null, status });
    } catch {
      this.publish({ phase: 'unconfirmed', error: 'The control result is unconfirmed. Retry acknowledgement before making another change.' });
    }
  }
}
