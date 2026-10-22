// Claude Code SessionStart hook: warns when the user settings lose a key this host depends on.
//   1. permissions.deny has a Bash rule (the whole `Bash` or a scoped `Bash(...)`) but env has no
//      CLAUDE_CODE_USE_POWERSHELL_TOOL=1: with Git Bash installed, any Bash deny rule also turns off the PowerShell
//      tool, so the session has no shell tool and every command goes through the Terminal panel with a prompt;
//   2. env has no DISABLE_AUTOUPDATER=1: the background updater fails on this network in every session, and it
//      installs into its own home rather than D:\claude\claude.exe.
// Both keys live in the env block of the user settings file (CLAUDE_CONFIG_DIR, else %USERPROFILE%\.claude), which
// provider switches rewrite. The hook reads that file and reports key names only, never values.
// OK = print nothing and exit 0. Problem = print {"systemMessage":...,"hookSpecificOutput":{...}} and exit 0: the
// user sees the warning and the agent gets the same text as context. SessionStart cannot block; an internal error
// prints nothing.
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const TRUTHY = /^(?:1|true|yes|on)$/i
const BASH_RULE = /^Bash(?:\(|$)/
const DOC = 'D:\\Codex\\.codex\\docs\\agent-guidance\\host-runbook\\claude-code-host-hooks.md'

const PROBLEMS = {
  unparseable: '无法按 JSON 解析，没做下面两项检查；文件真坏了的话，Claude Code 会忽略其中全部设置（权限、hooks、env）。',
  powershellTool: '`permissions.deny` 有 Bash 规则，`env` 却没有 `CLAUDE_CODE_USE_POWERSHELL_TOOL=1`：会话没有 PowerShell 工具，命令改走 Terminal 面板、逐条弹窗确认。',
  autoUpdater: '`env` 没有 `DISABLE_AUTOUPDATER=1`：后台自动更新在本机网络下每个会话都会失败，而且它装到 `%USERPROFILE%\\.local\\bin`，不是 `D:\\claude\\claude.exe`。'
}

export function settingsPath(env = process.env) {
  return join(env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'settings.json')
}

// Problem names for the text of a settings file; null stands for a missing file, which is an empty one.
export function check(text) {
  let settings
  try {
    const body = text === null ? '{}' : text
    settings = JSON.parse(body.charCodeAt(0) === 0xfeff ? body.slice(1) : body)
  } catch {
    return ['unparseable']
  }
  const deny = settings?.permissions?.deny
  const env = settings?.env
  const enabled = name => env !== null && typeof env === 'object' && TRUTHY.test(String(env[name] ?? '').trim())
  const problems = []
  const bashDenied = Array.isArray(deny) && deny.some(rule => BASH_RULE.test(String(rule).trim()))
  if (bashDenied && !enabled('CLAUDE_CODE_USE_POWERSHELL_TOOL')) problems.push('powershellTool')
  if (!enabled('DISABLE_AUTOUPDATER')) problems.push('autoUpdater')
  return problems
}

export function evaluate(text, path = settingsPath()) {
  const problems = check(text)
  if (!problems.length) return null
  return `Claude Code 用户设置 ${path}：\n` +
    `${problems.map(problem => `- ${PROBLEMS[problem]}`).join('\n')}\n` +
    `改法见 ${DOC}；settings 改完要新开会话才生效。`
}

function main() {
  try {
    readFileSync(0) // The hook input; this check does not need it.
  } catch {
    // No stdin.
  }
  const path = settingsPath()
  let text = null
  try {
    text = readFileSync(path, 'utf8')
  } catch (error) {
    if (error?.code !== 'ENOENT') return
  }
  const message = evaluate(text, path)
  if (message) {
    process.stdout.write(JSON.stringify({
      systemMessage: message,
      hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: message }
    }))
  }
}

if (process.argv.includes('--self-test')) {
  const json = value => JSON.stringify(value)
  const both = { CLAUDE_CODE_USE_POWERSHELL_TOOL: '1', DISABLE_AUTOUPDATER: '1' }
  const cases = [
    [json({ permissions: { deny: ['Bash'] }, env: both }), []],
    [json({ permissions: { deny: ['Bash'] }, env: { DISABLE_AUTOUPDATER: '1' } }), ['powershellTool']],
    [json({ permissions: { deny: ['Bash(git push *)'] }, env: { DISABLE_AUTOUPDATER: '1' } }), ['powershellTool']],
    [json({ permissions: { deny: ['Bash'] }, env: { CLAUDE_CODE_USE_POWERSHELL_TOOL: '0', DISABLE_AUTOUPDATER: '1' } }), ['powershellTool']],
    [json({ permissions: { deny: ['Bash'] }, env: { CLAUDE_CODE_USE_POWERSHELL_TOOL: '1' } }), ['autoUpdater']],
    [json({ permissions: { deny: ['Bash'] } }), ['powershellTool', 'autoUpdater']],
    [json({ permissions: { deny: ['WebFetch', 'BashOutput'] }, env: { DISABLE_AUTOUPDATER: 'true' } }), []],
    [json({ permissions: { deny: 'Bash' }, env: { DISABLE_AUTOUPDATER: '1' } }), []],
    [json({ env: { DISABLE_AUTOUPDATER: '1' } }), []],
    [String.fromCharCode(0xfeff) + json({ env: { DISABLE_AUTOUPDATER: '1' } }), []],
    [null, ['autoUpdater']],
    ['null', ['autoUpdater']],
    ['{"env": {', ['unparseable']]
  ]
  let failed = 0
  for (const [text, expected] of cases) {
    const actual = check(text)
    if (json(actual) !== json(expected)) {
      failed++
      console.error(`FAIL ${json(text)} -> ${json(actual)}, expected ${json(expected)}`)
    }
  }
  // Values never reach the message, not even from a file that does not parse.
  const marker = 'value-' + 'that-must-not-leak'
  const leaky = json({ permissions: { deny: ['Bash'] }, env: { ANTHROPIC_AUTH_TOKEN: marker } })
  const checks = [
    [evaluate(json({ permissions: { deny: ['Bash'] }, env: both }), 'x') === null, 'all keys set gives no message'],
    [/CLAUDE_CODE_USE_POWERSHELL_TOOL/.test(evaluate(leaky, 'x')), 'the message names the missing key'],
    [!evaluate(leaky, 'x').includes(marker), 'the message carries no env value'],
    [!evaluate(`{"env": {"ANTHROPIC_AUTH_TOKEN": "${marker}"`, 'x').includes(marker), 'a parse failure carries no file content'],
    [settingsPath({ CLAUDE_CONFIG_DIR: 'D:\\cfg' }) === join('D:\\cfg', 'settings.json'), 'CLAUDE_CONFIG_DIR moves the settings file']
  ]
  for (const [ok, label] of checks) {
    if (!ok) {
      failed++
      console.error(`FAIL ${label}`)
    }
  }
  const total = cases.length + checks.length
  console.log(`self-test: ${total - failed}/${total} passed`)
  process.exit(failed ? 1 : 0)
} else {
  try {
    main()
  } catch {
    // Print nothing on any internal error.
  }
}
