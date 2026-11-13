// Session policy shared by the official sky adapter and the local native transport.
import { selectScreenshotForClick } from './screenshot-geometry.mjs';

const nativeOwners = new WeakSet();
export function createNativeSession(backend, { signal, maxFailures = 2 } = {}) {
  if (nativeOwners.has(backend)) throw new Error('This backend already has a session; reuse it');
  if (!['observe', 'verify', 'click', 'activate'].every(k => typeof backend?.[k] === 'function') || ![1, 2].includes(maxFailures)) throw new Error('Provide a native backend and a failure budget of 1 or 2');
  nativeOwners.add(backend);
  let observation, revision = 0, failures = 0, busy = false, status = 'ready';
  const check = () => { if (signal?.aborted) status = 'stopped'; if (status !== 'ready') throw new DOMException('GUI session stopped; manual review or new authorization required', 'AbortError'); };
  const fail = error => { observation = undefined; status = isUserStop(error) ? 'stopped' : ++failures >= maxFailures ? 'manual-review' : 'ready'; };
  const validFrame = frame => {
    if (!frame?.foreground) throw new Error('Target lost focus; evidence invalid');
    if (!frame.unobscured) throw new Error('Target is occluded; evidence invalid');
    const w = frame.window, b = w?.bounds;
    if (!w?.id || !w.pid || !w.startedAt || !(w.dpi > 0) || !b || ![b.x, b.y, b.width, b.height].every(Number.isFinite) || b.width <= 0 || b.height <= 0) throw new Error('Invalid window identity or geometry');
  };
  const identity = w => JSON.stringify([w.id, w.pid, w.startedAt, w.title, w.dpi, w.bounds.x, w.bounds.y, w.bounds.width, w.bounds.height]);
  async function verify(window) {
    check(); const fresh = await backend.verify(window); check(); validFrame(fresh);
    if (identity(window) !== identity(fresh.window)) throw new Error('Window identity or geometry changed; observe again');
  }
  async function capture(expectedWindow) {
    check(); const frame = await backend.observe(expectedWindow); check(); validFrame(frame);
    if (expectedWindow && identity(frame.window) !== identity(expectedWindow)) throw new Error('Window identity or geometry changed during capture');
    // Freeze an owned copy so callers cannot rewrite the identity behind a token.
    const state = structuredClone(frame);
    for (const shot of state.screenshots || []) Object.freeze(shot);
    Object.freeze(state.screenshots); Object.freeze(state.window.bounds); Object.freeze(state.window); Object.freeze(state);
    observation = Object.freeze({ revision: ++revision, state });
    return observation;
  }
  async function exclusive(work) {
    check(); if (busy) throw new Error('Concurrent GUI operations are not allowed'); busy = true;
    try { return await work(); } catch (error) { fail(error); throw error; } finally { busy = false; }
  }
  return Object.freeze({
    backend: 'native', get status() { return signal?.aborted ? 'stopped' : status; }, get stopped() { return status !== 'ready' || Boolean(signal?.aborted); },
    stop() { status = 'stopped'; observation = undefined; },
    observe() { return exclusive(capture); },
    // Explicit activation only; no activation or Alt injection during click/observe.
    activate() { return exclusive(async () => { observation = undefined; await backend.activate(); return capture(); }); },
    click(token, { screenshotId, x, y } = {}) {
      return exclusive(async () => {
        if (token !== observation) throw new Error('Observation expired; inspect a fresh screenshot');
        const bounds = token.state.window.bounds;
        const point = selectScreenshotForClick({ screenshots: token.state.screenshots, windowBounds: { x: 0, y: 0, width: bounds.width, height: bounds.height }, point: { x, y } });
        if (point.screenshotId !== screenshotId) throw new Error('Coordinate input requires the observed screenshot');
        observation = undefined;
        await verify(token.state.window);
        await backend.click({ window: token.state.window, x, y });
        await verify(token.state.window); // never capture another app after focus loss
        const fresh = await capture(token.state.window); failures = 0; return fresh;
      });
    },
    rejectObservation(token) {
      check(); if (token !== observation) throw new Error('Observation expired'); fail(new Error('Rejected observation'));
      return { status: status === 'ready' ? 'reobserve' : status, failures };
    },
  });
}
const owners = new WeakMap();
export function isUserStop(error) {
  return error?.name === 'AbortError' || /user (?:stopped|cancelled|canceled)|turn ended|physical esc|computer use.*stopped/i.test(String(error?.message || error));
}

export function createSkySession(sky, { selectWindow, signal, maxFailures = 2 } = {}) {
  if (owners.has(sky)) throw new Error('This backend already has a session; reuse it');
  if (typeof selectWindow !== 'function' || !Number.isInteger(maxFailures) || maxFailures < 1 || maxFailures > 2) throw new Error('Provide selectWindow and a failure budget of 1 or 2');
  let window, observation, revision = 0, failures = 0, stopped = false, busy = false;
  const check = () => {
    if (signal?.aborted) stopped = true;
    if (stopped) throw new DOMException('GUI session stopped', 'AbortError');
  };
  const failed = error => {
    observation = undefined;
    window = undefined;
    if (isUserStop(error) || ++failures >= maxFailures) stopped = true;
  };
  async function exclusive(work) {
    check();
    if (busy) throw new Error('Concurrent GUI operations are not allowed');
    busy = true;
    try { return await work(); } finally { busy = false; }
  }
  async function capture() {
    check();
    if (!window) {
      const windows = (await sky.list_windows()).filter(selectWindow);
      check();
      if (windows.length !== 1) throw new Error(`Expected one matching window; found ${windows.length}`);
      window = await sky.get_window({ id: windows[0].id, app: windows[0].app });
      if (window.id !== windows[0].id || window.app !== windows[0].app || !selectWindow(window)) throw new Error('Window identity changed while binding');
    }
    check();
    const state = await sky.get_window_state({ window, include_text: true, include_screenshot: true });
    check();
    if (state.window?.id !== window.id || state.window?.app !== window.app || !selectWindow(state.window)) throw new Error('Capture target changed');
    window = state.window;
    observation = Object.freeze({ revision: ++revision, state });
    return observation;
  }
  const session = Object.freeze({
    backend: 'sky',
    get stopped() { return stopped || Boolean(signal?.aborted); },
    stop() { stopped = true; observation = undefined; },
    // Retry observation/binding only. An uncertain input is never replayed.
    observe() {
      return exclusive(async () => {
        for (let attempt = 0; attempt < 2; attempt++) {
          try { return await capture(); }
          catch (error) { failed(error); if (stopped || attempt === 1) throw error; }
        }
      });
    },
    rejectObservation(token, reason = 'Target is occluded or state is stale') {
      check();
      if (token !== observation) throw new Error('Observation has expired');
      failed(new Error(reason));
      return { status: stopped ? 'stopped' : 'reobserve', failures };
    },
    act(token, method, args = {}) {
      return exclusive(async () => {
        if (token !== observation) throw new Error('Observation has expired; observe and inspect again');
        if (!['click', 'set_value', 'press_key', 'type_text', 'activate_window'].includes(method)) throw new Error('Unsupported input method');
        if ('window' in args) throw new Error('The session owns the target window');
        const tree = token.state.accessibility?.tree || '';
        if (method === 'set_value' && (!Number.isInteger(args.element_index) || typeof args.value !== 'string')) throw new Error('set_value requires an observed index and string value');
        if (method === 'type_text' && (typeof args.text !== 'string' || !token.state.accessibility?.focused_element)) throw new Error('type_text requires observed focus and string text');
        if (method === 'press_key' && (typeof args.key !== 'string' || !args.key.trim())) throw new Error('press_key requires a key');
        if ('element_index' in args && (!Number.isInteger(args.element_index) || !new RegExp(`(?:^|\\n)\\s*(?:[-•]\\s*)?(?:\\[${args.element_index}\\]|${args.element_index}(?:[.:]|\\s))`).test(tree))) throw new Error('Element was not observed');
        if (method === 'click' && !('element_index' in args)) {
          const shot = token.state.screenshots?.find(item => item.id === args.screenshotId);
          if (!shot || !Number.isFinite(args.x) || !Number.isFinite(args.y)) throw new Error('Coordinate input requires the observed screenshot and finite window coordinates');
        }
        observation = undefined;
        try {
          check();
          await sky[method]({ ...args, window: token.state.window });
          check();
          const fresh = await capture();
          failures = 0;
          return fresh;
        } catch (error) { failed(error); throw error; }
      });
    },
  });
  owners.set(sky, session);
  return session;
}
