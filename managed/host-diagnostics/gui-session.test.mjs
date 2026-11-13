import test from 'node:test';
import assert from 'node:assert/strict';
import { createSkySession, createNativeSession } from './gui-session.mjs';
import { createFilterTransaction, isTargetPreload, preloadFilter, validateSamples } from './wechat-console-filter.mjs';

function nativeFake() {
  let frame = { window: { id: 7, pid: 91, startedAt: '12', title: 'calendar', dpi: 144, bounds: { x: 10, y: 20, width: 300, height: 400 } }, foreground: true, unobscured: true, screenshots: [{ id: 'shot', originX: 0, originY: 0, width: 300, height: 400 }] };
  const calls = [];
  const backend = { observe: async () => { calls.push('capture'); return structuredClone(frame); }, verify: async () => { calls.push('verify'); return structuredClone(frame); }, click: async () => { calls.push('click'); }, activate: async () => { calls.push('activate'); } };
  return { backend, calls, get frame() { return frame; }, set frame(value) { frame = value; } };
}
test('native input consumes observed coordinates and never activates an already foreground window', async () => {
  const h = nativeFake(), session = createNativeSession(h.backend);
  const first = await session.observe();
  const next = await session.click(first, { screenshotId: 'shot', x: 100, y: 120 });
  assert.ok(next.revision > first.revision);
  await assert.rejects(session.click(first, { screenshotId: 'shot', x: 100, y: 120 }), /expired/);
  assert.equal(h.calls.filter(x => x === 'click').length, 1);
  assert.ok(!h.calls.includes('activate'));
});
test('native identity, geometry, DPI or focus drift forbids input and does not capture after failure', async () => {
  for (const change of [f => { f.window.pid++; }, f => { f.window.bounds.x++; }, f => { f.window.dpi++; }, f => { f.foreground = false; }, f => { f.unobscured = false; }]) {
    const h = nativeFake(), session = createNativeSession(h.backend), token = await session.observe();
    change(h.frame);
    await assert.rejects(session.click(token, { screenshotId: 'shot', x: 3, y: 4 }), /changed|focus|occluded/);
    assert.ok(!h.calls.includes('click'));
    assert.equal(h.calls.filter(x => x === 'capture').length, 1);
  }
});
test('native focus loss during input stops capture, two failures require manual review', async () => {
  const h = nativeFake(), session = createNativeSession(h.backend);
  h.backend.click = async () => { h.calls.push('click'); h.frame.foreground = false; };
  for (let i = 0; i < 2; i++) {
    h.frame.foreground = true;
    const token = await session.observe();
    await assert.rejects(session.click(token, { screenshotId: 'shot', x: 4, y: 5 }), /focus/);
  }
  assert.equal(h.calls.filter(x => x === 'capture').length, 2);
  assert.equal(session.stopped, true);
  assert.equal(session.status, 'manual-review');
  await assert.rejects(session.observe(), /stopped/);
});

function fake() {
  const calls = [];
  const window = { id: 7, app: 'devtools', title: 'calendar' };
  const sky = {
    list_windows: async () => { calls.push('list'); return [window]; },
    get_window: async () => { calls.push('bind'); return window; },
    get_window_state: async () => { calls.push('observe'); return { window, accessibility: { tree: '\t12 编辑 (settable, string) Filter Description: Filter' }, screenshots: [{ id: 'shot' }] }; },
    set_value: async args => { calls.push(['set', args.value]); },
    click: async () => { calls.push('click'); },
  };
  return { sky, calls, session: createSkySession(sky, { selectWindow: item => item.app === 'devtools' && item.title === 'calendar' }) };
}

test('one observed action invalidates old controls and uses returned window', async () => {
  const { session, calls } = fake();
  const first = await session.observe();
  const second = await session.act(first, 'set_value', { element_index: 12, value: 'value' });
  assert.ok(second.revision > first.revision);
  await assert.rejects(session.act(first, 'click', { element_index: 12 }), /expired/);
  assert.equal(calls.filter(item => Array.isArray(item)).length, 1);
});
test('stale binding reselects once; two failures stop all input', async () => {
  const { sky, session, calls } = fake();
  sky.get_window_state = async () => { calls.push('failure'); throw new Error('window gone'); };
  await assert.rejects(session.observe(), /window gone/);
  assert.equal(calls.filter(item => item === 'list').length, 2);
  assert.equal(session.stopped, true);
  await assert.rejects(session.observe(), { name: 'AbortError' });
});
test('uncertain input is not replayed; next operation requires fresh observation', async () => {
  const { sky, session } = fake();
  let inputs = 0;
  sky.click = async () => { inputs++; throw new Error('stale control'); };
  const first = await session.observe();
  await assert.rejects(session.act(first, 'click', { element_index: 12 }), /stale/);
  const second = await session.observe();
  await assert.rejects(session.act(second, 'click', { element_index: 12 }), /stale/);
  assert.equal(inputs, 2);
  assert.equal(session.stopped, true);
});
test('occluded observations are rejected and bounded; screenshots cannot be reused', async () => {
  const { session } = fake();
  let state = await session.observe();
  await assert.rejects(session.act(state, 'click', { x: 1, y: 1, screenshotId: 'old' }), /observed screenshot/);
  assert.equal(session.rejectObservation(state).status, 'reobserve');
  state = await session.observe();
  assert.equal(session.rejectObservation(state).status, 'stopped');
});
test('Esc stops immediately without another observation or rollback input', async () => {
  const { session, sky, calls } = fake();
  const first = await session.observe();
  const count = calls.length;
  sky.set_value = async () => { throw new Error('user stopped Computer Use'); };
  await assert.rejects(session.act(first, 'set_value', { element_index: 12, value: 'x' }), /user stopped/);
  assert.equal(session.stopped, true);
  assert.equal(calls.length, count);
});
test('backend is locked, ambiguous targets fail before input, abort is terminal', async () => {
  const { sky, session } = fake();
  assert.throws(() => createSkySession(sky, { selectWindow: () => true }), /already has/);
  sky.list_windows = async () => [{ id: 1, app: 'devtools', title: 'calendar' }, { id: 2, app: 'devtools', title: 'calendar' }];
  await assert.rejects(session.observe(), /found 2/);
  const controller = new AbortController();
  const other = createSkySession({}, { selectWindow: () => true, signal: controller.signal });
  controller.abort();
  await assert.rejects(other.observe(), { name: 'AbortError' });
});
test('input requires current indexed control or observed focus', async () => {
  const { session, sky } = fake();
  const first = await session.observe();
  await assert.rejects(session.act(first, 'set_value', { value: 'x' }), /observed index/);
  await assert.rejects(session.act(first, 'type_text', { text: 'x' }), /observed focus/);
  sky.get_window_state = async () => ({ window: first.state.window, accessibility: { tree: '[12] edit Message with number 99' }, screenshots: [] });
  const second = await session.observe();
  await assert.rejects(session.act(second, 'click', { element_index: 99 }), /not observed/);
});
test('reused window handle with another project title cannot yield an input token', async () => {
  const { session, sky } = fake();
  const first = await session.observe();
  sky.get_window_state = async () => ({ ...first.state, window: { ...first.state.window, title: 'another-project' } });
  await assert.rejects(session.observe(), /target changed/);
  assert.equal(session.stopped, true);
});

const warning = file => `The resource http://127.0.0.1:44968/__dev__/${file}?t=wechat&v=3.16.1 was preloaded using link preload but not used within a few seconds from the window's load event. Please make sure it has an appropriate \`as\` value and it is preloaded intentionally.`;
const samples = [
  { level: 'warning', text: warning('WAServiceMainContext.js') },
  { level: 'warning', text: warning('WAAutoService.js') },
  { level: 'warning', text: 'Storage quota nearly full' },
  { level: 'error', text: 'TypeError: render failed' },
];
const controls = samples.slice(2).map(item => item.text);
function transaction() { return createFilterTransaction({ samples, originalFilter: '-legacy', revision: 1, session: fake().session }); }

test('specific rule matches actual preload samples and preserves unrelated failures', () => {
  assert.equal(validateSamples(samples).filter(item => item.hidden).length, 2);
  assert.equal(isTargetPreload('anchor.js:1 ' + warning('WAAutoService.js')), true);
  assert.equal(isTargetPreload(warning('WAWebview.js')), false);
  assert.equal(isTargetPreload('Failed to load resource http://127.0.0.1:44968/__dev__/WAAutoService.js: 500'), false);
  assert.equal(isTargetPreload(warning('WAAutoService.js').replace('127.0.0.1', 'example.com')), false);
  assert.throws(() => validateSamples(samples.slice(0, 2)), /preserved warning/);
  assert.throws(() => validateSamples([...samples, { level: 'error', text: samples[0].text }]), /real error/);
  const regexFromConsoleToken = new RegExp(preloadFilter.slice(2, -1));
  assert.ok(regexFromConsoleToken.test(samples[0].text));
});
test('filter requires both preserved levels and fresh verification after compilation', () => {
  const tx = transaction();
  assert.equal(tx.verify({ filter: preloadFilter, visibleMessages: controls, revision: 2 }).status, 'compile');
  tx.compiled({ revision: 3 });
  assert.equal(tx.verify({ filter: preloadFilter, visibleMessages: controls, revision: 4 }).status, 'verified');
  const stale = transaction();
  assert.throws(() => stale.verify({ filter: preloadFilter, visibleMessages: controls, revision: 1 }), /newer/);
  assert.equal(stale.stage, 'rollback');
  const wrongStage = transaction();
  wrongStage.verify({ filter: preloadFilter, visibleMessages: controls, revision: 2 });
  assert.throws(() => wrongStage.verify({ filter: preloadFilter, visibleMessages: controls, revision: 3 }), /stage/);
  assert.equal(wrongStage.stage, 'rollback');
});
test('ineffective filter and lost errors fail; ordinary failure requires original-value readback', () => {
  for (const visibleMessages of [[...controls, samples[0].text], [controls[0]]]) {
    const tx = transaction();
    assert.throws(() => tx.verify({ filter: preloadFilter, visibleMessages, revision: 2 }), /visible/);
    assert.equal(tx.stage, 'rollback');
    assert.deepEqual(tx.fail(new Error('verification failed')), { status: 'rollback-required', filter: '-legacy' });
    assert.equal(tx.requestedFilter, '-legacy');
    assert.throws(() => tx.verify({ filter: preloadFilter, revision: 3 }), /restored/);
    assert.equal(tx.verify({ filter: '-legacy', revision: 4 }).status, 'rolled-back');
  }
});
test('Esc in filter transaction forbids rollback and later verification', () => {
  const tx = transaction();
  assert.deepEqual(tx.fail(new Error('user stopped Computer Use')), { status: 'stopped', rollback: false });
  assert.throws(() => tx.verify({ filter: '-legacy', revision: 2 }), { name: 'AbortError' });
});
