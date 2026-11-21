'use strict';
/**
 * Single-command, read-only, redacted health probe for Antigravity 2.34+ local
 * backend auth and context-viewer quota/accounts state.
 * Never prints CSRF tokens, OAuth tokens, cookies, or historical quotaIntervals.
 */
const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');
const os = require('node:os');
const path = require('node:path');

const DEFAULT_ADDONS_STATE_DIR = 'D:/Codex/tools/antigravity-addons/state';

function parseArgs(argv) {
  const opts = {
    daemonDir: null,
    accountsPath: null,
    stateDir: null,
    backendOnly: false,
    timeoutMs: 5000,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--daemon-dir') opts.daemonDir = argv[++i];
    else if (a === '--accounts-path') opts.accountsPath = argv[++i];
    else if (a === '--state-dir') opts.stateDir = argv[++i];
    else if (a === '--backend-only') opts.backendOnly = true;
    else if (a === '--timeout-ms') opts.timeoutMs = Math.max(500, Number(argv[++i]) || 5000);
    else throw new Error(`Unknown argument: ${a}`);
  }
  return opts;
}

function isPidAlive(pid) {
  const num = Number(pid);
  if (!Number.isInteger(num) || num <= 0) return false;
  try {
    process.kill(num, 0);
    return true;
  } catch (err) {
    return err?.code === 'EPERM';
  }
}

function readJsonSafe(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
}

function scanDaemonHubs(daemonDir, checkAlive = isPidAlive) {
  const live = [];
  let staleCount = 0;
  if (!fs.existsSync(daemonDir)) {
    return { daemonDirExists: false, live, staleCount };
  }
  const files = fs.readdirSync(daemonDir).filter((name) => /^hub_.*\.json$/i.test(name));
  for (const name of files) {
    const fp = path.join(daemonDir, name);
    try {
      const st = fs.statSync(fp);
      const raw = JSON.parse(fs.readFileSync(fp, 'utf8'));
      const alive = checkAlive(raw?.pid);
      if (!alive) {
        staleCount += 1;
        continue;
      }
      live.push({
        file: name,
        pid: Number(raw.pid),
        httpsPort: Number.isInteger(Number(raw.httpsPort)) && Number(raw.httpsPort) > 0 ? Number(raw.httpsPort) : null,
        httpPort: Number.isInteger(Number(raw.httpPort)) && Number(raw.httpPort) > 0 ? Number(raw.httpPort) : null,
        lsVersion: typeof raw.lsVersion === 'string' ? raw.lsVersion : null,
        hasCsrfToken: typeof raw.csrfToken === 'string' && raw.csrfToken.trim().length > 0,
        mtimeMs: Number(st.mtimeMs) || 0,
        _token: typeof raw.csrfToken === 'string' ? raw.csrfToken.trim() : '',
      });
    } catch {
      staleCount += 1;
    }
  }
  live.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return { daemonDirExists: true, live, staleCount };
}

function probeRootHtml(origin, timeoutMs) {
  return new Promise((resolve) => {
    let url;
    try {
      url = new URL('/', origin);
    } catch {
      return resolve({ ok: false, error: 'invalid-origin' });
    }
    const mod = url.protocol === 'https:' ? https : http;
    const req = mod.request(
      url,
      { method: 'GET', agent: false, rejectUnauthorized: false },
      (res) => {
        let body = '';
        res.on('data', (c) => {
          if (body.length < 16384) body += c;
        });
        res.on('end', () => {
          const m = body.match(/window\.__APP_CONFIG__\s*=\s*(\{.*?\})\s*;/s);
          let hasAppConfig = false;
          let appVersion = null;
          let htmlCsrfTokenPresent = false;
          if (m) {
            try {
              const cfg = JSON.parse(m[1]);
              hasAppConfig = true;
              appVersion = typeof cfg?.appVersion === 'string' ? cfg.appVersion : null;
              htmlCsrfTokenPresent = typeof cfg?.csrfToken === 'string' && cfg.csrfToken.trim().length > 0;
            } catch {
              hasAppConfig = false;
            }
          }
          resolve({
            ok: res.statusCode === 200,
            statusCode: res.statusCode ?? 0,
            hasAppConfig,
            appVersion,
            htmlCsrfTokenPresent,
          });
        });
      },
    );
    req.setTimeout(timeoutMs, () => {
      req.destroy();
      resolve({ ok: false, error: 'timeout' });
    });
    req.on('error', (err) => resolve({ ok: false, error: err.code || err.message }));
    req.end();
  });
}

function probeRpc(origin, method, csrfToken, timeoutMs) {
  return new Promise((resolve) => {
    let url;
    try {
      url = new URL(`/exa.language_server_pb.LanguageServerService/${method}`, origin);
    } catch {
      return resolve({ ok: false, statusCode: 0, error: 'invalid-origin' });
    }
    const mod = url.protocol === 'https:' ? https : http;
    const payload = '{}';
    const headers = {
      'Content-Type': 'application/json',
      'Content-Length': String(Buffer.byteLength(payload)),
      'Connect-Protocol-Version': '1',
      ...(csrfToken ? { 'x-codeium-csrf-token': csrfToken } : {}),
    };
    const req = mod.request(
      url,
      { method: 'POST', agent: false, rejectUnauthorized: false, headers },
      (res) => {
        let body = '';
        res.on('data', (c) => {
          if (body.length < 131072) body += c;
        });
        res.on('end', () => {
          let parsed = null;
          try {
            parsed = JSON.parse(body);
          } catch {}
          const status = res.statusCode ?? 0;
          resolve({
            ok: status === 200,
            statusCode: status,
            topKeys: parsed && typeof parsed === 'object' ? Object.keys(parsed) : [],
            hasEmail: Boolean(parsed?.userStatus?.email),
            configsCount: Array.isArray(parsed?.userStatus?.cascadeModelConfigData?.clientModelConfigs)
              ? parsed.userStatus.cascadeModelConfigData.clientModelConfigs.length
              : null,
            errorCode: status !== 200 && typeof parsed?.code === 'string' ? parsed.code : null,
          });
        });
      },
    );
    req.setTimeout(timeoutMs, () => {
      req.destroy();
      resolve({ ok: false, statusCode: 0, error: 'timeout' });
    });
    req.on('error', (err) => resolve({ ok: false, statusCode: 0, error: err.code || err.message }));
    req.end(payload);
  });
}

function summarizeAccountsState(accountsPath) {
  if (!fs.existsSync(accountsPath)) {
    return { exists: false, ok: false, reason: 'accounts-file-missing' };
  }
  const raw = readJsonSafe(accountsPath);
  if (!raw || typeof raw !== 'object') {
    return { exists: true, ok: false, reason: 'accounts-file-unparseable' };
  }
  const activeEmail = typeof raw.activeAccountEmail === 'string' ? raw.activeAccountEmail : null;
  const acct = activeEmail && raw.accounts && typeof raw.accounts === 'object' ? raw.accounts[activeEmail] : null;
  if (!acct || typeof acct !== 'object') {
    return { exists: true, ok: false, activeAccountPresent: false, reason: 'active-account-missing' };
  }
  const snap = acct.quotaSnapshot && typeof acct.quotaSnapshot === 'object' ? acct.quotaSnapshot : null;
  const pools = Array.isArray(snap?.pools)
    ? snap.pools.map((p) => ({
        title: p?.title || p?.poolKey || null,
        percentText: p?.percentText ?? null,
        statusLabel: p?.statusLabel ?? null,
        buckets: Array.isArray(p?.buckets)
          ? p.buckets.map((b) => ({
              windowShort: b?.windowShort ?? null,
              percentText: b?.percentText ?? null,
              resetTimeText: b?.resetTimeText ?? null,
            }))
          : [],
      }))
    : [];
  const lastQuotaError = acct.lastQuotaError ?? null;
  const syncState = snap?.syncState ?? null;
  const ok = !lastQuotaError && syncState === 'fresh' && pools.length > 0;
  return {
    exists: true,
    ok,
    activeAccountPresent: true,
    lastQuotaUpdatedAt: Number.isFinite(Number(acct.lastQuotaUpdatedAtMs))
      ? new Date(Number(acct.lastQuotaUpdatedAtMs)).toISOString()
      : null,
    lastQuotaError,
    syncState,
    planTierName: snap?.planTierName ?? null,
    poolsCount: pools.length,
    pools,
    quotaIntervalsSkipped: Array.isArray(raw.quotaIntervals) ? raw.quotaIntervals.length : 0,
  };
}

function summarizeReconcilerState(stateDir) {
  const active = readJsonSafe(path.join(stateDir, 'active-build.json'));
  const lastSync = readJsonSafe(path.join(stateDir, 'last-sync.json'));
  const pending = readJsonSafe(path.join(stateDir, 'pending-apply.json'));
  return {
    activeVersion: active?.version ?? null,
    activeCombinedSha256: active?.combinedSha256 ?? null,
    lastSyncStatus: lastSync?.reconcile?.status ?? null,
    lastSyncTimestamp: lastSync?.timestamp ?? null,
    hasPendingBuild: Boolean(pending),
  };
}

async function runQuotaHealthCheck(rawOpts = {}) {
  const daemonDir = rawOpts.daemonDir || path.join(os.homedir(), '.gemini', 'antigravity', 'daemon');
  const stateDir = rawOpts.stateDir || DEFAULT_ADDONS_STATE_DIR;
  const accountsPath = rawOpts.accountsPath || path.join(stateDir, 'context', 'accounts_v1.json');
  const timeoutMs = Number(rawOpts.timeoutMs) || 5000;

  const hubs = scanDaemonHubs(daemonDir, rawOpts.isPidAlive || isPidAlive);
  const primary = hubs.live[0] || null;
  const origin = primary
    ? (primary.httpsPort ? `https://127.0.0.1:${primary.httpsPort}` : (primary.httpPort ? `http://127.0.0.1:${primary.httpPort}` : null))
    : null;

  let backend = { ok: false, reason: 'no-live-daemon-hub', origin: null };
  if (primary && origin) {
    const [rootHtml, getUserStatus, retrieveQuota, unauthCheck] = await Promise.all([
      probeRootHtml(origin, timeoutMs),
      probeRpc(origin, 'GetUserStatus', primary._token, timeoutMs),
      probeRpc(origin, 'RetrieveUserQuotaSummary', primary._token, timeoutMs),
      probeRpc(origin, 'GetUserStatus', '', timeoutMs),
    ]);
    backend = {
      ok: Boolean(rootHtml.ok && getUserStatus.ok && retrieveQuota.ok),
      origin,
      rootHtml,
      authenticatedBootstrapActive: Boolean(rootHtml.hasAppConfig && !rootHtml.htmlCsrfTokenPresent),
      rpcWithDaemonCsrf: {
        GetUserStatus: getUserStatus,
        RetrieveUserQuotaSummary: retrieveQuota,
      },
      rpcWithoutCsrfStatusCode: unauthCheck.statusCode,
    };
  }

  const accounts = rawOpts.backendOnly ? null : summarizeAccountsState(accountsPath);
  const reconciler = summarizeReconcilerState(stateDir);
  const ok = rawOpts.backendOnly ? backend.ok : Boolean(backend.ok && accounts?.ok);

  return {
    ok,
    checkedAtUtc: new Date().toISOString(),
    daemon: {
      daemonDirExists: hubs.daemonDirExists,
      liveCount: hubs.live.length,
      staleCount: hubs.staleCount,
      primary: primary
        ? {
            file: primary.file,
            pid: primary.pid,
            httpsPort: primary.httpsPort,
            httpPort: primary.httpPort,
            lsVersion: primary.lsVersion,
            hasCsrfToken: primary.hasCsrfToken,
          }
        : null,
    },
    backend,
    accounts,
    reconciler,
  };
}

if (require.main === module) {
  const opts = parseArgs(process.argv.slice(2));
  runQuotaHealthCheck(opts)
    .then((report) => {
      console.log(JSON.stringify(report, null, 2));
      if (!report.ok) process.exitCode = 1;
    })
    .catch((err) => {
      console.error(JSON.stringify({ ok: false, error: err?.message || String(err) }));
      process.exitCode = 2;
    });
}

module.exports = {
  parseArgs,
  scanDaemonHubs,
  summarizeAccountsState,
  runQuotaHealthCheck,
};
