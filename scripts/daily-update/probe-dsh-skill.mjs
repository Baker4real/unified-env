// Load the selected desktop preset's skill provider in an isolated Cordis scope.
// The installed SDK composes the same profile patches. Only skill code is mounted.
import { createHash } from 'node:crypto';
import { readFile, realpath } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const PRESET_SKILL_ROOT = "process.getBuiltinModule('node:path').join(process.getBuiltinModule('node:path').dirname(process.getBuiltinModule('node:module').createRequire(baseUrl).resolve('@deepseek-ai/dsh-agent-preset/package.json')), 'skills')";
const packageName = '@deepseek-ai/dsh-skill-filesystem';
const { DSH_INSTALL_DIR: install, DSH_HOME: home, DSH_PROFILE: profile } = process.env;
const [preset, cwd, name] = process.argv.slice(2);

function requireCondition(condition, code) {
  if (!condition) throw new Error(code);
}

async function probe() {
  requireCondition(profile === 'desktop' && [install, home, cwd].every(p => p && isAbsolute(p)), 'desktop-profile-unavailable');
  const anchor = join(install, 'package.json');
  const resolve = createRequire(anchor).resolve;
  const dependencies = dirname(install);
  const load = id => import(pathToFileURL(join(dependencies, id.split('/').at(-1), 'lib', 'index.js')).href);
  const app = await load('@deepseek-ai/dsh-app-boot');
  const dir = join(home, 'profiles', profile);
  const loaded = app.loadProfileDirectory('dsh', dir, anchor);
  const patches = app.readProfilePatches('dsh', { name: profile, dir, installAnchor: anchor, home, overlays: [] }, loaded);
  const entries = app.composeEntries([patches]);
  const rows = entries.filter(row => row.name === '@deepseek-ai/dsh-agent-preset' && row.config?.id === preset);
  requireCondition(rows.length === 1 && [undefined, false].includes(rows[0].disabled), 'preset-unavailable');
  const providers = rows[0].config.plugins.filter(row => row.name === packageName);
  requireCondition(providers.length === 1 && [undefined, false].includes(providers[0].disabled), 'preset-filesystem-provider-unavailable');
  const declared = providers[0].config ?? {};
  const config = { ...declared, watch: false };
  config.customSkillDirs = (declared.customSkillDirs ?? []).map(root => {
    if (typeof root === 'string' && isAbsolute(root)) return root;
    requireCondition(root?.__jsExpr === PRESET_SKILL_ROOT, 'unknown-preset-directory-expression');
    return join(dirname(resolve('@deepseek-ai/dsh-agent-preset/package.json')), 'skills');
  });
  requireCondition(!JSON.stringify(config).includes('"__jsExpr"'), 'unknown-provider-expression');

  const { Context } = await load('@deepseek-ai/cordis');
  const { createScope } = await load('@deepseek-ai/dsh-scope');
  const { SkillRegistry } = await load('@deepseek-ai/dsh-skill');
  const filesystem = await load(packageName);
  const ctx = new Context();
  try {
    await ctx.plugin(SkillRegistry);
    const key = {};
    const scope = createScope(ctx, key);
    try {
      await scope.ctx.plugin(filesystem, config);
      const registry = ctx.get('skills');
      const options = { cwd, scope: key, signal: AbortSignal.timeout(25000) };
      const snapshot = await registry.snapshot(options);
      requireCondition(snapshot.complete === true, 'incomplete-discovery');
      const entry = snapshot.skills.find(skill => skill.name === name);
      requireCondition(entry?.source === 'user-dsh' && entry.path, 'skill-not-discovered-from-user-dsh');
      const definition = await registry.get(name, options);
      requireCondition(definition?.name === name && definition.path === entry.path && definition.source === entry.source && definition.content?.trim(), 'skill-body-unavailable');
      const { modelInvocable, userInvocable } = definition.invocation;
      requireCondition(typeof modelInvocable === 'boolean' && typeof userInvocable === 'boolean'
        && modelInvocable === entry.invocation.modelInvocable && userInvocable === entry.invocation.userInvocable, 'invocation-policy-mismatch');
      const sha256 = createHash('sha256').update(await readFile(entry.path)).digest('hex');
      return { ok: true, preset, source: entry.source, path: await realpath(entry.path), sha256, modelInvocable, userInvocable, bodyLoaded: true };
    } finally {
      await scope.dispose();
    }
  } finally {
    await ctx.fiber.dispose();
  }
}

try {
  const result = await probe();
  process.stdout.write(`${JSON.stringify(result)}\n`);
} catch (error) {
  const known = /^[a-z]+(?:-[a-z]+)+$/u.test(error?.message ?? '');
  process.stdout.write(`${JSON.stringify({ ok: false, reason: known ? error.message : 'dsh-runtime-probe-failed' })}\n`);
  process.exitCode = 1;
}
