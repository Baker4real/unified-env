import { isUserStop } from './gui-session.mjs';

// No anchors: DevTools may prepend an anchor or split its message text nodes.
const source = 'The\\s+resource\\s+http:\\/\\/127[.]0[.]0[.]1:[0-9]+\\/__dev__\\/(WAServiceMainContext|WAAutoService)[.]js[?][^\\s]*\\s+was\\s+preloaded\\s+using\\s+link\\s+preload\\s+but\\s+not\\s+used\\s+within\\s+a\\s+few\\s+seconds';
export const preloadFilter = `-/${source}/`;
const pattern = new RegExp(source);
export const isTargetPreload = text => pattern.test(text);

export function validateSamples(samples) {
  if (!Array.isArray(samples) || samples.some(item => typeof item?.text !== 'string')) throw new Error('Provide observed message text and level');
  for (const file of ['WAServiceMainContext.js', 'WAAutoService.js']) {
    if (!samples.some(item => item.level === 'warning' && item.text.includes(file) && isTargetPreload(item.text))) throw new Error(`Missing actual preload warning sample: ${file}`);
  }
  for (const level of ['warning', 'error']) {
    if (!samples.some(item => item.level === level && !isTargetPreload(item.text))) throw new Error(`Missing preserved ${level} sample`);
  }
  if (samples.some(item => item.level === 'error' && isTargetPreload(item.text))) throw new Error('A real error would be hidden by this text-only filter');
  return samples.map(item => ({ text: item.text, level: item.level, hidden: isTargetPreload(item.text) }));
}

// Stepwise transaction keeps observation and input in separate REPL cells.
// The caller performs requested writes through the same createSkySession instance.
export function createFilterTransaction({ samples, originalFilter, revision, session }) {
  const expected = validateSamples(samples);
  if (typeof originalFilter !== 'string' || !Number.isInteger(revision) || revision < 1 || !session) throw new Error('Require original filter, observation revision and GUI session');
  let stage = 'apply', lastRevision = revision;
  const ensureRunning = () => {
    if (session.stopped || stage === 'stopped') { stage = 'stopped'; throw new DOMException('GUI session stopped', 'AbortError'); }
  };
  const fail = error => {
    if (isUserStop(error) || session.stopped) { session.stop(); stage = 'stopped'; return { status: 'stopped', rollback: false }; }
    if (['verified', 'rolled-back', 'stopped'].includes(stage)) throw new Error('Transaction is terminal');
    stage = 'rollback';
    return { status: 'rollback-required', filter: originalFilter };
  };
  const checked = work => {
    try { return work(); }
    catch (error) {
      if (!['verified', 'rolled-back', 'stopped'].includes(stage)) fail(error);
      throw error;
    }
  };
  return Object.freeze({
    get stage() { return stage; },
    get requestedFilter() { return stage === 'rollback' ? originalFilter : preloadFilter; },
    verify({ filter, visibleMessages, revision: nextRevision }) {
      return checked(() => {
      ensureRunning();
      if (!['apply', 'after-compile', 'rollback'].includes(stage)) throw new Error('Unexpected verification stage');
      if (!Number.isInteger(nextRevision) || nextRevision <= lastRevision) throw new Error('Verification needs a newer observation');
      lastRevision = nextRevision;
      if (stage === 'rollback') {
        if (filter !== originalFilter) throw new Error('Original filter was not restored');
        stage = 'rolled-back';
        return { status: stage };
      }
      if (filter !== preloadFilter || !Array.isArray(visibleMessages)) throw new Error('Filter readback or visible messages missing');
      if (visibleMessages.some(isTargetPreload)) throw new Error('Target preload warnings remain visible');
      for (const item of expected.filter(item => !item.hidden)) {
        if (!visibleMessages.includes(item.text)) throw new Error(`Preserved ${item.level} is not visible`);
      }
      stage = stage === 'apply' ? 'compile' : 'verified';
      return { status: stage, targetsHidden: 2, controlsPreserved: expected.filter(item => !item.hidden).length };
      });
    },
    compiled({ revision: nextRevision }) {
      return checked(() => {
      ensureRunning();
      if (stage !== 'compile' || !Number.isInteger(nextRevision) || nextRevision <= lastRevision) throw new Error('Require a fresh completed compilation observation');
      lastRevision = nextRevision;
      stage = 'after-compile';
      });
    },
    fail,
  });
}
