// Claude Code Stop hook: lints the shell commands the reply that just ended hands to the user.
// The user runs them in two shells: `! <command>` goes to bash, the desktop Terminal panel is PowerShell 7.
// A handed-off command has to parse in both, so the hook blocks the stop once, with the fix, when a shell code
// block has
//   1. a line that starts with a quoted path followed by an argument: PowerShell reads the quoted path as a
//      string value and fails with ParserError (Unexpected token);
//   2. a line of a bash/sh block that starts with PowerShell's call operator `&`: bash fails with a syntax error;
//   3. an unquoted backslash path in a bash/sh block: bash drops the backslashes as escapes.
// Allow = print nothing and exit 0. Block = print {"decision":"block","reason":...} and exit 0.
// stop_hook_active (the turn already continues because of a stop hook) and any internal error allow the stop,
// so the hook blocks at most once per turn and a broken hook never holds a session.
import { readFileSync } from 'node:fs'

const BASH_TAGS = new Set(['bash', 'sh', 'shell', 'zsh'])
const POWERSHELL_TAGS = new Set(['powershell', 'pwsh', 'ps1', 'ps'])
const FENCE = /^[ \t]*```([^\n`]*)\n([\s\S]*?)^[ \t]*```/gm
// A quoted string holding a path separator, then whitespace and an argument rather than an operator or redirect.
const QUOTED_PATH_COMMAND = /^(['"])[^'"\n]*[\\/][^'"\n]*\1\s+[^\s|;)>,+=]/
const CALL_OPERATOR = /^&\s/
const QUOTED = /'[^'\n]*'|"(?:[^"\\\n]|\\.)*"/g
const BACKSLASH_PATH = /[A-Za-z]:\\|[\w.~-]\\[\w.-]/
const MAX_FINDINGS = 5
const SPACE_PATH_FIX = '路径含空格时写成 pwsh -NoProfile -Command "& \'<路径>\' <参数>"'

const RULES = {
  quotedPath: `以带引号的路径开头又跟着参数，PowerShell 会把引号路径当成字符串值，报 ParserError（Unexpected token）。程序路径改用正斜杠且不加引号；${SPACE_PATH_FIX}。`,
  callOperator: `以 & 开头，bash 报语法错误。去掉 &，程序路径用正斜杠且不加引号；${SPACE_PATH_FIX}。`,
  backslashPath: '有未加引号的反斜杠路径，bash 会把反斜杠当转义吞掉。改用正斜杠，或给这个参数加单引号。'
}

// Findings { rule, line } for the shell code blocks of a reply.
export function lint(text) {
  const findings = []
  for (const [, info, body] of text.matchAll(FENCE)) {
    const tag = info.trim().split(/\s+/)[0].toLowerCase()
    const bash = BASH_TAGS.has(tag)
    if (!bash && !POWERSHELL_TAGS.has(tag)) continue
    let continued = false
    for (const rawLine of body.split('\n')) {
      const line = rawLine.replace(/\r$/, '').trim()
      const continuation = continued
      continued = /[\\`]$/.test(line)
      if (!line || line.startsWith('#')) continue
      let rule = null
      if (!continuation && QUOTED_PATH_COMMAND.test(line)) rule = 'quotedPath'
      else if (bash && !continuation && CALL_OPERATOR.test(line)) rule = 'callOperator'
      else if (bash && BACKSLASH_PATH.test(line.replace(QUOTED, "''"))) rule = 'backslashPath'
      if (rule) findings.push({ rule, line })
    }
  }
  return findings
}

export function evaluate(payload) {
  if (payload?.stop_hook_active) return null
  const findings = lint(String(payload?.last_assistant_message || ''))
  if (!findings.length) return null
  const items = findings.slice(0, MAX_FINDINGS).map(({ rule, line }) => {
    const shown = line.length > 120 ? `${line.slice(0, 117)}...` : line
    return `- ${shown}\n  ${RULES[rule]}`
  })
  return `交给用户的命令要在 bash（! 前缀）和 PowerShell 7（Terminal 面板）里都能解析，刚才回复的 shell 代码块里有 ${findings.length} 行不行：\n` +
    `${items.join('\n')}\n` +
    '改好后重新给出这些命令。如果这是故意展示的错误示例，把它放进 text 代码块。'
}

function main() {
  let payload
  try {
    payload = JSON.parse(readFileSync(0, 'utf8') || '{}')
  } catch {
    return
  }
  const reason = evaluate(payload)
  if (reason) process.stdout.write(JSON.stringify({ decision: 'block', reason }))
}

if (process.argv.includes('--self-test')) {
  const fence = (tag, body) => '```' + tag + '\n' + body + '\n```'
  const cases = [
    [fence('bash', "'D:/tools/x/run.cmd' --candidate 'D:/x' --update"), 'quotedPath'],
    [fence('bash', String.raw`"C:\Program Files\Git\bin\git.exe" status`), 'quotedPath'],
    [fence('powershell', "'D:/x/run.cmd' --dry-run"), 'quotedPath'],
    ['1. 运行：\n   ' + fence('bash', "   'D:/x/run.cmd' -Mode Plan").replace(/\n```$/, '\n   ```'), 'quotedPath'],
    [fence('bash', "& 'D:/x/run.cmd' --dry-run"), 'callOperator'],
    [fence('bash', String.raw`D:\tools\x\run.cmd --help`), 'backslashPath'],
    [fence('sh', String.raw`python -X utf8 tools\check.py`), 'backslashPath'],
    [fence('bash', "D:/tools/x/run.cmd --candidate 'D:/x' --update"), null],
    [fence('bash', `pwsh -NoProfile -Command "& 'D:/path with space/x.cmd' --arg 'D:/y'"`), null],
    [fence('bash', "git -C 'D:/agents/x' status"), null],
    [fence('bash', String.raw`echo 'D:\agents\x' "C:\Users\x"`), null],
    [fence('bash', "D:/x/run.cmd --candidate \\\n  'D:/y' --update"), null],
    [fence('powershell', "D:/x/run.cmd --candidate `\n  'D:/y' --update"), null],
    [fence('bash', "# 'D:/x/run.cmd' --dry-run"), null],
    [fence('bash', "'D:/x/notes.txt' | Out-File y"), null],
    [fence('powershell', String.raw`Get-ChildItem D:\agents`), null],
    [fence('powershell', "& 'D:/x/run.cmd' --dry-run"), null],
    [fence('text', "'D:/x/run.cmd' --dry-run"), null],
    [fence('', "'D:/x/run.cmd' --dry-run"), null],
    ["行内代码 `'D:/x/run.cmd' --dry-run` 不检查", null]
  ]
  let failed = 0
  for (const [text, expected] of cases) {
    const rules = lint(text).map(finding => finding.rule)
    const actual = rules[0] || null
    if (actual !== expected || rules.length > 1) {
      failed++
      console.error(`FAIL ${JSON.stringify(text)} -> ${JSON.stringify(rules)}, expected ${expected}`)
    }
  }
  const bad = fence('bash', "'D:/x/run.cmd' --dry-run")
  const checks = [
    [evaluate({ last_assistant_message: bad }) !== null, 'a finding blocks the stop'],
    [evaluate({ last_assistant_message: bad, stop_hook_active: true }) === null, 'stop_hook_active allows the stop'],
    [evaluate({}) === null, 'a missing message allows the stop']
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
    // Allow the stop on any internal error.
  }
}
