import { expect, test } from 'vitest';
import { PanelControl } from '../src/panel/control.js';
import { SelectorCoordinator } from '../src/plugin/coordinator.js';
import { initialState } from '../src/plugin/state-store.js';
const status = () => new SelectorCoordinator({ now: Date.now, owns: () => true, readSnapshot: async () => ({ ok: false, code: 'snapshot-missing' }),
  loadState: async () => initialState(), saveState: async () => {} }).status();

test('Pause remains pending with previous auto status until acknowledged', async () => {
  const gate = Promise.withResolvers<{ status: number; body: string }>();
  let calls = 0;
  const model = new PanelControl(async () => ++calls === 1 ? { status: 200, body: JSON.stringify({ ...status(), mode: 'auto' }) } : gate.promise);
  await model.load();
  const pending = model.command('mode', 'paused');
  expect(model.state).toMatchObject({ phase: 'pending', status: { mode: 'auto' } });
  gate.resolve({ status: 200, body: JSON.stringify(status()) }); await pending;
  expect(model.state).toMatchObject({ phase: 'ready', status: { mode: 'paused' }, pending: null });
});

test('lost acknowledgement preserves operation ID for explicit retry and blocks competing commands', async () => {
  const bodies: unknown[] = [];
  const model = new PanelControl(async input => {
    bodies.push(input.body); if (bodies.length === 1) throw new Error('secret upstream error');
    return { status: 200, body: JSON.stringify(status()) };
  });
  await model.command('mode', 'paused');
  expect(model.state.phase).toBe('unconfirmed');
  expect(model.state.error).not.toContain('secret');
  await model.command('mode', 'auto'); expect(bodies).toHaveLength(1);
  await model.retry(); expect(bodies).toHaveLength(2); expect(bodies[0]).toEqual(bodies[1]);
  expect(model.state.phase).toBe('ready');
});

test('late read cannot overwrite acknowledged command and malformed status is never success', async () => {
  const read = Promise.withResolvers<{ status: number; body: string }>();
  const model = new PanelControl(async input => input.method === 'GET' ? read.promise : { status: 200, body: JSON.stringify(status()) });
  const loading = model.load(); await model.command('mode', 'paused');
  read.resolve({ status: 200, body: JSON.stringify({ ...status(), mode: 'auto' }) }); await loading;
  expect(model.state.status?.mode).toBe('paused');
  const invalid = new PanelControl(async () => ({ status: 200, body: '{}' }));
  await invalid.command('mode', 'auto'); expect(invalid.state.phase).toBe('unconfirmed');
});

test('verified control refusal releases pending state and displays the blocking reason', async () => {
  const model = new PanelControl(async () => ({ status: 409, body: JSON.stringify({ code: 'control-conflict', status: { ...status(), blockedReason: 'competing-switcher' } }) }));
  await model.command('mode', 'auto');
  expect(model.state).toMatchObject({ phase: 'ready', pending: null, status: { blockedReason: 'competing-switcher' } });
});
