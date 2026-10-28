// Claude Code SessionStart hook: warns when the user settings lose a key this host depends on.
//   1. permissions.deny has a Bash rule (the whole `Bash` or a scoped `Bash(...)`) but env has no
//      CLAUDE_CODE_USE_POWERSHELL_TOOL=1: with Git Bash installed, any Bash deny rule also turns off the PowerShell
//      tool, so the session has no shell tool and every command goes through the Terminal panel with a prompt;
//   2. env has no DISABLE_AUTOUPDATER=1: the background updater fails on this network in every session, and it
//      installs into its own home rather than D:\claude\claude.exe.
// Both keys live in the env block of the user settings file (CLAUDE_CONFIG_DIR, else %USERPROFILE%\.claude), which
// provider switches rewrite. The hook reads that file and reports key names only, never values.
// It also warns when UniGetUI's WinGetForceLocationOnUpdate is on (the flag file under %LOCALAPPDATA% exists): WinGet
// updates then install a second copy under the global install location instead of upgrading in place. Under Claude
// Desktop the hook sees the package's merged view of AppData, which matches the real file unless something inside
// the package deleted it.
// After a compaction (source "compact") the agent also gets a pointer to transcripts.py, the bounded way to read back
// pre-compaction text from the transcript.
// OK = print nothing and exit 0. Problem = print {"systemMessage":...,"hookSpecificOutput":{...}} and exit 0: the
// user sees the warning and the agent gets the same text as context; the compaction pointer goes to the agent only.
// SessionStart cannot block; an internal error prints nothing.
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const TRUTHY = /^(?:1|true|yes|on)$/i
const BASH_RULE = /^Bash(?:\(|$)/
const DOC = 'D:\\Codex\\.codex\\docs\\agent-guidance\\host-runbook\\claude-code-host-hooks.md'
const UNIGETUI_DOC = 'D:\\Codex\\.codex\\docs\\agent-guidance\\host-runbook\\shell-and-runtime.md'
const TRANSCRIPTS = 'C:\\Users\\WINDOWS\\.claude\\skills\\retro\\scripts\\transcripts.py'

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

export function forceLocationFlagPath(env = process.env) {
  return join(env.LOCALAPPDATA || join(homedir(), 'AppData', 'Local'), 'UniGetUI', 'Configuration', 'WinGetForceLocationOnUpdate')
}

export function forceLocationMessage(flagPath) {
  return `UniGetUI 的 WinGetForceLocationOnUpdate 开着（${flagPath} 存在）：WinGet 更新会按全局安装位置另装一份，不在原目录升级；` +
    '2026-10-27 UU 远程、Grok Bot、微信开发者工具因此各装出第二份，UU 打不开。' +
    `关掉用 D:\\UniGetUI\\uniget.exe settings clear --key WinGetForceLocationOnUpdate（经 IPC 由运行中的 UniGetUI 自己改）。说明见 ${UNIGETUI_DOC} 的 UniGetUI 段落。`
}

export function compactContext(transcriptPath) {
  const transcript = transcriptPath || '<会话记录.jsonl>'
  return `上下文刚压缩过。要找回压缩前的原文（命令、报错、生成内容），先用 python ${TRANSCRIPTS} find <关键词> ${transcript} 拿行号，` +
    `再用 show ${transcript} <行号> --grep <正则> 只取那一条；Grep 直接扫 .jsonl 时一行就是整条消息，一次能带出上万字符。`
}

// The hook output for the warnings (user and agent) and the agent-only context, or null when there is neither.
export function compose(warnings, context) {
  const all = [...warnings, ...context]
  if (!all.length) return null
  const output = { hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: all.join('\n\n') } }
  return warnings.length ? { systemMessage: warnings.join('\n\n'), ...output } : output
}

function main() {
  let input = null
  try {
    input = JSON.parse(readFileSync(0, 'utf8') || 'null')
  } catch {
    // No stdin, or not JSON.
  }
  const warnings = []
  const path = settingsPath()
  let text = null
  let readable = true
  try {
    text = readFileSync(path, 'utf8')
  } catch (error) {
    readable = error?.code === 'ENOENT'
  }
  const settings = readable ? evaluate(text, path) : null
  if (settings) warnings.push(settings)
  const flag = forceLocationFlagPath()
  if (existsSync(flag)) warnings.push(forceLocationMessage(flag))
  const context = input?.source === 'compact' ? [compactContext(input?.transcript_path)] : []
  const output = compose(warnings, context)
  if (output) process.stdout.write(JSON.stringify(output))
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
    [settingsPath({ CLAUDE_CONFIG_DIR: 'D:\\cfg' }) === join('D:\\cfg', 'settings.json'), 'CLAUDE_CONFIG_DIR moves the settings file'],
    [forceLocationFlagPath({ LOCALAPPDATA: 'D:\\la' }) === join('D:\\la', 'UniGetUI', 'Configuration', 'WinGetForceLocationOnUpdate'), 'LOCALAPPDATA moves the UniGetUI flag'],
    [/WinGetForceLocationOnUpdate/.test(forceLocationMessage('x')) && /settings clear/.test(forceLocationMessage('x')), 'the UniGetUI warning names the flag and the fix'],
    [compactContext('D:\\t.jsonl').includes('D:\\t.jsonl') && compactContext().includes('<会话记录.jsonl>'), 'the compaction pointer names the transcript'],
    [compose([], []) === null, 'nothing to say prints nothing'],
    [compose([], ['c']).systemMessage === undefined && compose([], ['c']).hookSpecificOutput.additionalContext === 'c', 'context alone stays with the agent'],
    [compose(['w'], ['c']).systemMessage === 'w' && compose(['w'], ['c']).hookSpecificOutput.additionalContext === 'w\n\nc', 'warnings reach both the user and the agent']
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
