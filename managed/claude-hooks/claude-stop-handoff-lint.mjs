// Claude Code Stop hook: lints the shell commands the reply that just ended hands to the user.
// The user runs them in two shells: `! <command>` goes to bash, the desktop Terminal panel is PowerShell 7.
// A handed-off command has to parse in both, so the hook blocks the stop once, with the fix, when a shell code
// block has
//   1. a line that starts with a quoted path followed by an argument: PowerShell reads the quoted path as a
//      string value and fails with ParserError (Unexpected token);
//   2. a line of a bash/sh block that starts with PowerShell's call operator `&`: bash fails with a syntax error;
//   3. an unquoted backslash path in a bash/sh block: bash drops the backslashes as escapes;
//   4. bash-only compound syntax (`; do`, `done`, `; then`, `fi`, `esac`, `[[ ]]`): PowerShell cannot parse it;
//   5. a git command that changes repository state with neither `-C <path>` nor an earlier `cd` in the block:
//      the Terminal panel opens in whatever directory it last used, so the command can hit another repository;
//   6. an unquoted <placeholder>: bash reads it as a redirect, PowerShell fails with ParserError;
//   7. a `/x` switch in a bash/sh block (`/v`, `/query`, `/T:5`): Git Bash's MSYS runtime rewrites it into a Windows
//      path before a native program sees it, quoted or not (`/v` -> `V:/`, `/query` -> `C:/Program Files/Git/query`),
//      so `reg query ... /v` fails with "Invalid syntax" under `!` (2026-11-08);
//   8. `reg delete` (or reg.exe) with a `-f` switch, in either block: reg delete only takes /f ("ERROR: Invalid syntax."
//      in PowerShell 7, 2026-11-15) although reg query takes -v, so a - switch working depends on the subcommand.
//      Bash needs //f, which Git Bash passes on as /f.
// Rules 4-6 and 8 apply to bash and PowerShell blocks alike; 4-6 report at most once per block.
// FAILS_IN names the shell each rule is about. lintCommand also serves the PreToolUse guard (claude-pretool-guard.mjs):
// it imports this file to check hand_off commands with the rules of the shell that runs them, and shell tool commands
// with rule 8. The hook entry at the bottom runs only when node started this file, so importing it reads no stdin.
// The hook also blocks once when the reply is empty or holds only tags such as a stray `</reasoning_effort>` and the
// turn called no tool, so the user got no answer at all (2026-11-08). Whether the turn called a tool comes from the
// transcript (transcript_path), read back to the user prompt that started the turn; a transcript that cannot be read
// or holds no such prompt allows the stop.
// Allow =print nothing and exit 0. Block = print {"decision":"block","reason":...} and exit 0.
// stop_hook_active (the turn already continues because of a stop hook) and any internal error allow the stop,
// so the hook blocks at most once per turn and a broken hook never holds a session.
import { readFileSync } from 'node:fs'
import { win32 } from 'node:path'
import { fileURLToPath } from 'node:url'

const BASH_TAGS = new Set(['bash', 'sh', 'shell', 'zsh'])
const POWERSHELL_TAGS = new Set(['powershell', 'pwsh', 'ps1', 'ps'])
const FENCE = /^[ \t]*```([^\n`]*)\n([\s\S]*?)^[ \t]*```/gm
// A quoted string holding a path separator, then whitespace and an argument rather than an operator or redirect.
const QUOTED_PATH_COMMAND = /^(['"])[^'"\n]*[\\/][^'"\n]*\1\s+[^\s|;)>,+=]/
const CALL_OPERATOR = /^&\s/
const QUOTED = /'[^'\n]*'|"(?:[^"\\\n]|\\.)*"/g
const BACKSLASH_PATH = /[A-Za-z]:\\|[\w.~-]\\[\w.-]/
// A word Git Bash rewrites into a path for a native program: /v, /query, /T:5. It leaves //c (passed on as /c), /? and
// /grant:r alone, and a word with a second slash such as /dev/null is a real path.
const SLASH_SWITCH = /^\/[A-Za-z][A-Za-z0-9]*$|^\/[A-Za-z]:/
// Bash compound-command keywords that PowerShell has no grammar for. `do` counts only when no `{` follows it,
// so a PowerShell do { } while () loop passes.
const BASH_ONLY = /(?:^|;)\s*(?:then|done|fi|esac)(?=\s|;|$)|(?:^|;)\s*do(?=\s+[^{\s]|\s*$)|\[\[\s/
const PLACEHOLDER = /<[^<>\s|;&'"]+>/
const CHANGES_DIRECTORY = /^(?:cd|chdir|pushd|sl|set-location|push-location)$/i
// git subcommands that change the repository whatever their arguments ...
const GIT_WRITES = new Set(['push', 'pull', 'reset', 'restore', 'checkout', 'switch', 'clean', 'rebase', 'merge',
  'cherry-pick', 'revert', 'commit', 'rm', 'mv', 'am', 'apply'])
// ... and the ones that change it only with one of these arguments (git stash: anything but list and show).
const GIT_WRITE_ARGS = {
  remote: /^(?:add|remove|rm|rename|set-url|set-head|set-branches|prune|update)$/,
  branch: /^(?:-[dDmMfu]|--delete|--move|--force|--set-upstream-to(?:=.*)?|--unset-upstream)$/,
  tag: /^(?:-[df]|--delete|--force)$/,
  fetch: /^(?:-p|--prune|--prune-tags)$/
}
const MAX_FINDINGS = 5
// A reply that shows the user nothing: empty, or nothing but tags like </reasoning_effort>.
const MARKUP_ONLY = /^(?:<\/?[A-Za-z_][\w-]*>\s*)*$/
const SPACE_PATH_FIX = '路径含空格时写成 pwsh -NoProfile -Command "& \'<路径>\' <参数>"'

const RULES = {
  quotedPath: `以带引号的路径开头又跟着参数，PowerShell 会把引号路径当成字符串值，报 ParserError（Unexpected token）。程序路径改用正斜杠且不加引号；${SPACE_PATH_FIX}。`,
  callOperator: `以 & 开头，bash 报语法错误。去掉 &，程序路径用正斜杠且不加引号；${SPACE_PATH_FIX}。`,
  backslashPath: '有未加引号的反斜杠路径，bash 会把反斜杠当转义吞掉。给这个参数加单引号，或改用正斜杠（注册表键名不行：reg 不认正斜杠）。',
  slashSwitch: '有 /v 这类开关：Git Bash 会先把它改写成路径再交给程序（/v 变成 V:/，/query 变成 C:/Program Files/Git/query），加引号也一样，用 ! 跑会失败。bash 里写成双斜杠（//v、//c），Git Bash 把它当 /v、/c 交给程序；PowerShell 照写 /v，两种 shell 各给一个代码块。改用 - 写法只限实测认的子命令：reg query 认 -v，两种 shell 都能跑；reg delete 不认 -f，bash 里写 //f。',
  bashOnly: '用了 bash 独有的复合语法（do/done、then/fi、[[ ]]），Terminal 面板的 PowerShell 解析不了。改成逐条单独的命令，或用 ; 串起两种 shell 都能跑的单行。',
  gitTarget: "改仓库状态的 git 命令没有锁定仓库：Terminal 面板停在哪个目录，命令就作用在哪个仓库。加 -C '<仓库绝对路径>'；只该在别的机器上跑的命令，写明是哪台机器，路径用带引号的占位符。",
  placeholder: '有没加引号的 <占位符>：bash 把它当重定向，PowerShell 报 ParserError。给占位符加单引号，或换成真实值。',
  regDeleteForce: 'reg delete 不认 -f，报 ERROR: Invalid syntax.（2026-11-15 PowerShell 7 实测）；reg query 认 -v 不代表其他子命令也认 - 写法。PowerShell 里写 /f；bash 里（包括输入框 ! 前缀的命令）写 //f：Git Bash 会把 /f 改写成 F:/，//f 才以 /f 交给 reg。'
}
// The shell in which a rule's command fails: 'bash' (the `!` prefix runs Git Bash), 'powershell' (the Terminal
// panel's PowerShell 7) or 'any' (every shell; for gitTarget, wherever the terminal happens to stand).
const FAILS_IN = {
  quotedPath: 'powershell',
  callOperator: 'bash',
  backslashPath: 'bash',
  slashSwitch: 'bash',
  bashOnly: 'powershell',
  gitTarget: 'any',
  placeholder: 'any',
  regDeleteForce: 'any'
}

// Words of each simple command on a line, quotes removed; splits on ; & | ( ) { } outside quotes.
function commandsOf(line) {
  const commands = []
  let words = []
  let word = ''
  let inWord = false
  let quote = ''
  const endWord = () => { if (inWord) words.push(word); word = ''; inWord = false }
  const endCommand = () => { endWord(); if (words.length) commands.push(words); words = [] }
  for (const ch of line) {
    if (quote) {
      if (ch === quote) quote = ''
      else word += ch
    } else if (ch === '"' || ch === "'") {
      quote = ch
      inWord = true
    } else if (/[;&|(){}]/.test(ch)) {
      endCommand()
    } else if (/\s/.test(ch)) {
      endWord()
    } else {
      word += ch
      inWord = true
    }
  }
  endCommand()
  return commands
}

// True for a git command that changes a repository it finds through the current directory.
function unlockedGitWrite(words) {
  let i = 0
  while (i < words.length && /^[A-Za-z_]\w*=/.test(words[i])) i++ // VAR=value prefixes
  if (!/^git(?:\.exe)?$/i.test((words[i] || '').split(/[\\/]/).pop())) return false
  for (i++; i < words.length && words[i].startsWith('-'); i++) {
    if (words[i] === '-C' || /^--(?:git-dir|work-tree)(?:=|$)/.test(words[i])) return false
    if (words[i] === '-c') i++
  }
  const subcommand = words[i]
  const args = words.slice(i + 1)
  if (GIT_WRITES.has(subcommand)) return true
  if (subcommand === 'stash') return !['list', 'show'].includes(args[0])
  const pattern = GIT_WRITE_ARGS[subcommand]
  return Boolean(pattern) && args.some(arg => pattern.test(arg))
}

// Rule 8: reg delete (reg.exe, any path) with a -f switch before a # comment. The PreToolUse guard runs it on its own
// quote-aware split of tool commands.
export function regDeleteForce(words) {
  let i = 0
  while (i < words.length && /^[A-Za-z_]\w*=/.test(words[i])) i++ // VAR=value prefixes
  if (!/^reg(?:\.exe)?$/i.test((words[i] || '').split(/[\\/]/).pop()) || !/^delete$/i.test(words[i + 1] || '')) return false
  const comment = words.findIndex((word, k) => k > i + 1 && word.startsWith('#'))
  return words.slice(i + 2, comment < 0 ? words.length : comment).some(word => /^-f$/i.test(word))
}

// The trimmed lines of a body grouped by command: a line ending in \ or ` continues on the next one.
function lineGroups(body) {
  const groups = []
  let group = []
  for (const rawLine of body.split('\n')) {
    const line = rawLine.replace(/\r$/, '').trim()
    group.push(line)
    if (!/[\\`]$/.test(line)) {
      groups.push(group)
      group = []
    }
  }
  if (group.length) groups.push(group)
  return groups
}

// The line of a command group that breaks rule 8, or the whole continued command when only its lines together do.
// Each line counts on its own as well, since a PowerShell line can end in a backslash (cd D:\) without continuing.
function regDeleteForceLine(lines) {
  const breaks = line => !line.startsWith('#') && commandsOf(line).some(regDeleteForce)
  const whole = lines.map(line => line.replace(/[\\`]$/, '')).join(' ')
  return lines.find(breaks) ?? (lines.length > 1 && breaks(whole) ? whole : null)
}

// Findings { rule, line } for command text the user runs in the given shells: { bash, powershell }, both for a block
// that may be pasted into either shell; with neither, only the rules that fail in every shell.
export function lintCommand(body, { bash = false, powershell = false } = {}) {
  const applies = rule => FAILS_IN[rule] === 'any' || (FAILS_IN[rule] === 'bash' ? bash : powershell)
  const findings = []
  let continued = false
  let located = false
  const reported = new Set()
  const reportOnce = (rule, line) => {
    if (!reported.has(rule)) findings.push({ rule, line })
    reported.add(rule)
  }
  for (const rawLine of body.split('\n')) {
    const line = rawLine.replace(/\r$/, '').trim()
    const continuation = continued
    continued = /[\\`]$/.test(line)
    if (!line || line.startsWith('#')) continue
    const unquoted = line.replace(QUOTED, "''")
    let rule = null
    if (applies('quotedPath') && !continuation && QUOTED_PATH_COMMAND.test(line)) rule = 'quotedPath'
    else if (applies('callOperator') && !continuation && CALL_OPERATOR.test(line)) rule = 'callOperator'
    else if (applies('backslashPath') && BACKSLASH_PATH.test(unquoted)) rule = 'backslashPath'
    if (rule) findings.push({ rule, line })
    const commands = commandsOf(line)
    // a continued line starts with arguments; every other command starts with its program
    const switched = commands.some((words, i) => words.slice(continuation && i === 0 ? 0 : 1).some(word => SLASH_SWITCH.test(word)))
    if (applies('slashSwitch') && switched) findings.push({ rule: 'slashSwitch', line })
    if (applies('bashOnly') && BASH_ONLY.test(unquoted)) reportOnce('bashOnly', line)
    if (applies('placeholder') && PLACEHOLDER.test(unquoted)) reportOnce('placeholder', line)
    for (const words of commands) {
      if (CHANGES_DIRECTORY.test(words[0]) && words.length > 1) located = true
      else if (applies('gitTarget') && !located && unlockedGitWrite(words)) reportOnce('gitTarget', line)
    }
  }
  if (applies('regDeleteForce')) {
    for (const lines of lineGroups(body)) {
      const line = regDeleteForceLine(lines)
      if (line) findings.push({ rule: 'regDeleteForce', line })
    }
  }
  return findings
}

// Findings { rule, line } for the shell code blocks of a reply. A bash block may be pasted into either shell, so it
// gets the rules of both; a PowerShell block gets the PowerShell ones.
export function lint(text) {
  const findings = []
  for (const [, info, body] of text.matchAll(FENCE)) {
    const tag = info.trim().split(/\s+/)[0].toLowerCase()
    const bash = BASH_TAGS.has(tag)
    if (!bash && !POWERSHELL_TAGS.has(tag)) continue
    findings.push(...lintCommand(body, { bash, powershell: true }))
  }
  return findings
}

// The findings as "- <line>" items, each followed by its fix, at most MAX_FINDINGS of them.
export function formatFindings(findings) {
  return findings.slice(0, MAX_FINDINGS).map(({ rule, line }) => {
    const shown = line.length > 120 ? `${line.slice(0, 117)}...` : line
    return `- ${shown}\n  ${RULES[rule]}`
  }).join('\n')
}

export function emptyReply(message) {
  return typeof message === 'string' && MARKUP_ONLY.test(message.trim())
}

// Whether the turn that just ended called a tool, from the transcript (one JSON entry per line) read back to the user
// prompt that started the turn. Tool results and isMeta entries are user entries too; they do not start a turn.
// null when no such prompt is found.
export function turnCalledTool(transcript) {
  const lines = transcript.split('\n')
  for (let i = lines.length - 1; i >= 0; i--) {
    let entry
    try {
      entry = JSON.parse(lines[i])
    } catch {
      continue
    }
    if (!entry || entry.isSidechain) continue
    const content = Array.isArray(entry.message?.content) ? entry.message.content : []
    if (entry.type === 'assistant' && content.some(block => /tool_use$/.test(block?.type || ''))) return true
    if (entry.type !== 'user' || entry.isMeta) continue
    return entry.toolUseResult !== undefined || content.some(block => block?.type === 'tool_result')
  }
  return null
}

function emptyReplyReason(message) {
  const shown = message.trim()
  const what = shown ? `只有标记 ${shown.length > 120 ? `${shown.slice(0, 117)}...` : shown}` : '是空的'
  return `刚才的回复${what}，本轮也没有调用工具，用户什么都没看到。现在按用户最后一条消息作答或开始执行。`
}

export function evaluate(payload, readTranscript = path => readFileSync(path, 'utf8')) {
  if (payload?.stop_hook_active) return null
  const message = payload?.last_assistant_message
  if (emptyReply(message)) {
    let calledTool = null
    try {
      if (payload?.transcript_path) calledTool = turnCalledTool(readTranscript(payload.transcript_path))
    } catch {
      // A transcript that cannot be read allows the stop.
    }
    return calledTool === false ? emptyReplyReason(message) : null
  }
  const findings = lint(String(message || ''))
  if (!findings.length) return null
  return `交给用户的命令要在 bash（! 前缀）和 PowerShell 7（Terminal 面板）里都能解析，并且不依赖终端当前所在的目录，刚才回复的 shell 代码块里有 ${findings.length} 处不行：\n` +
    `${formatFindings(findings)}\n` +
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

// node started this file (as the Stop hook or for its self-test) rather than the guard importing it.
const started = win32.basename(process.argv[1] || '').toLowerCase() === win32.basename(fileURLToPath(import.meta.url)).toLowerCase()

if (started && process.argv.includes('--self-test')) {
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
    ["行内代码 `'D:/x/run.cmd' --dry-run` 不检查", null],
    [fence('bash', 'for r in a b; do gh repo edit "Baker4real/$r" --visibility public; done'), 'bashOnly'],
    [fence('bash', 'if [ -d .git ]; then git status; fi'), 'bashOnly'],
    [fence('bash', 'for f in a b\ndo\n  echo $f\ndone'), 'bashOnly'],
    [fence('powershell', '[[ -n "$x" ]] && echo y'), 'bashOnly'],
    [fence('powershell', "foreach ($r in 'a', 'b') { gh repo view \"Baker4real/$r\" }"), null],
    [fence('powershell', 'do { $i++ } while ($i -lt 3)'), null],
    [fence('bash', 'echo done'), null],
    [fence('bash', 'git remote set-url private https://github.com/o/r.git; git fetch --prune private; git reset --keep private/main'), 'gitTarget'],
    [fence('powershell', 'git push origin main'), 'gitTarget'],
    [fence('bash', 'git stash pop'), 'gitTarget'],
    [fence('bash', 'git branch -D old'), 'gitTarget'],
    [fence('bash', "git -C 'D:/Codex/projects/x' reset --keep private/main"), null],
    [fence('bash', "cd 'D:/Codex/projects/x'; git reset --keep private/main"), null],
    [fence('bash', 'git fetch private'), null],
    [fence('bash', 'git remote -v'), null],
    [fence('bash', 'git branch -a'), null],
    [fence('bash', 'git stash list'), null],
    [fence('bash', 'git clone https://github.com/o/r.git D:/x'), null],
    [fence('bash', 'git -C <repo> status'), 'placeholder'],
    [fence('bash', "git -C '<clone 路径>' reset --keep private/main"), null],
    [fence('bash', 'git log --oneline -3 2>&1 | head -1'), null],
    [fence('bash', "reg query 'HKCU\\Environment' /v MAGPIE_MIRRORS"), 'slashSwitch'],
    [fence('bash', "reg query 'HKCU\\Environment' '/v' MAGPIE_MIRRORS"), 'slashSwitch'],
    [fence('sh', "schtasks /query /tn 'x'"), 'slashSwitch'],
    [fence('bash', 'cmd /c echo hi'), 'slashSwitch'],
    [fence('bash', "reg query 'HKCU\\Environment' \\\n  /v MAGPIE_MIRRORS"), 'slashSwitch'],
    [fence('bash', "reg query 'HKCU\\Environment' -v MAGPIE_MIRRORS"), null],
    [fence('bash', 'cmd //c echo hi'), null],
    [fence('bash', "icacls 'D:/x' /grant:r 'u:(R)'"), null],
    [fence('bash', 'some-tool --flag /? > /dev/null'), null],
    [fence('powershell', 'cmd /c echo hi'), null],
    // Rule 8: reg delete takes /f only (PowerShell) or //f (Git Bash); reg query takes -v.
    [fence('bash', "reg delete 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss' -f"), 'regDeleteForce'],
    [fence('powershell', "reg delete 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss' -f"), 'regDeleteForce'],
    [fence('powershell', "& 'C:/Windows/System32/reg.exe' delete 'HKCU\\Software\\X' -v a -f"), 'regDeleteForce'],
    [fence('bash', "MSYS_NO_PATHCONV=1 REG.EXE DELETE 'HKCU\\Software\\X' -F"), 'regDeleteForce'],
    [fence('powershell', "reg delete 'HKCU\\Software\\X' -va `\n  -f"), 'regDeleteForce'],
    [fence('powershell', "Set-Location D:\\\nreg delete 'HKCU\\Software\\X' -f"), 'regDeleteForce'],
    [fence('powershell', "reg delete 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss' /f"), null],
    [fence('bash', "reg delete 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss' //f"), null],
    [fence('bash', "reg delete 'HKCU\\Software\\X' /f"), 'slashSwitch'],
    [fence('powershell', "reg query 'HKCU\\Environment' -v MAGPIE_MIRRORS"), null],
    [fence('powershell', "reg delete 'HKCU\\Software\\X' /f # -f fails"), null],
    [fence('powershell', "Write-Output 'reg delete HKCU\\Software\\X -f'"), null],
    [fence('powershell', "'{0}' -f (reg query 'HKCU\\Software\\X')"), null],
    [fence('text', "reg delete 'HKCU\\Software\\X' -f"), null]
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
  const entry = (type, content, extra = {}) => JSON.stringify({ type, message: { role: type, content }, ...extra })
  const prompt = entry('user', '继续')
  const toolUse = entry('assistant', [{ type: 'tool_use', id: 't1', name: 'Read', input: {} }])
  const toolResult = entry('user', [{ type: 'tool_result', tool_use_id: 't1', content: 'x' }], { toolUseResult: {} })
  const stray = entry('assistant', [{ type: 'text', text: '</reasoning_effort>' }])
  const thinking = entry('assistant', [{ type: 'thinking', thinking: '' }])
  const meta = entry('user', [{ type: 'text', text: '[Image: source: x]' }], { isMeta: true })
  const imagePrompt = entry('user', [{ type: 'image' }, { type: 'text', text: '看图' }])
  const summary = JSON.stringify({ type: 'system', subtype: 'stop_hook_summary' })
  const jsonl = (...lines) => lines.join('\n') + '\n'
  const noToolTurn = jsonl(toolUse, toolResult, prompt, meta, stray, thinking, summary)
  const toolTurn = jsonl(prompt, toolUse, toolResult, stray)
  let reads = 0
  const counting = () => { reads++; return noToolTurn }
  const fails = () => { throw new Error('unreadable') }
  const of = text => () => text
  const checks = [
    [evaluate({ last_assistant_message: bad }) !== null, 'a finding blocks the stop'],
    [JSON.stringify(lint(fence('bash', String.raw`reg query HKCU\Environment /v X`)).map(f => f.rule)) === '["backslashPath","slashSwitch"]',
      'a backslash path and a /x switch on one line both report'],
    [evaluate({ last_assistant_message: bad, stop_hook_active: true }) === null, 'stop_hook_active allows the stop'],
    [evaluate({}) === null, 'a missing message allows the stop'],
    [['', ' \n', '</reasoning_effort>', '</reasoning_effort>\n<thinking>'].every(emptyReply), 'empty and tag-only replies count as empty'],
    [!['好的', '<b>注意</b>', undefined].some(emptyReply), 'text, tags around text and a missing message do not'],
    [turnCalledTool(noToolTurn) === false, 'a turn with only a reply called no tool'],
    [turnCalledTool(toolTurn) === true, 'a tool call in the turn counts'],
    [turnCalledTool(jsonl(prompt, toolUse, stray)) === true, 'a tool call without its result counts'],
    [turnCalledTool(jsonl(toolUse, toolResult, imagePrompt, stray)) === false, 'a prompt with an image starts the turn'],
    [turnCalledTool(jsonl(stray, 'not json', summary)) === null, 'no prompt gives no answer'],
    [/<\/reasoning_effort>/.test(evaluate({ last_assistant_message: '</reasoning_effort>', transcript_path: 't' }, of(noToolTurn)) || ''), 'a tag-only reply in a turn without tools blocks and shows the tag'],
    [evaluate({ last_assistant_message: '', transcript_path: 't' }, of(noToolTurn)) !== null, 'an empty reply in a turn without tools blocks'],
    [evaluate({ last_assistant_message: '</reasoning_effort>', transcript_path: 't' }, of(toolTurn)) === null, 'an empty reply after a tool call allows the stop'],
    [evaluate({ last_assistant_message: '', transcript_path: 't', stop_hook_active: true }, of(noToolTurn)) === null, 'stop_hook_active allows an empty reply'],
    [evaluate({ last_assistant_message: '', transcript_path: 't' }, fails) === null, 'an unreadable transcript allows the stop'],
    [evaluate({ last_assistant_message: '' }, counting) === null && reads === 0, 'no transcript path allows the stop'],
    [evaluate({ last_assistant_message: '好的', transcript_path: 't' }, counting) === null && reads === 0, 'a reply with text does not read the transcript'],
    // lintCommand for one shell, as the PreToolUse guard calls it for hand_off and shell tool commands.
    [lintCommand("reg delete 'HKCU\\Software\\X' -f")[0]?.rule === 'regDeleteForce', 'with no shell named, rule 8 still applies'],
    [lintCommand("'D:/x/run.cmd' --dry-run").length === 0 && lintCommand("reg query 'HKCU\\Environment' /v X").length === 0,
      'with no shell named, the rules of one shell do not'],
    [lintCommand('for f in a b; do echo $f; done', { bash: true }).length === 0, 'bash alone takes bash syntax'],
    [lintCommand('for f in a b; do echo $f; done', { powershell: true })[0]?.rule === 'bashOnly', 'PowerShell alone does not'],
    [lintCommand("reg query 'HKCU\\Environment' /v X", { powershell: true }).length === 0 &&
      lintCommand("reg query 'HKCU\\Environment' /v X", { bash: true })[0]?.rule === 'slashSwitch', '/v is right in PowerShell and wrong in Git Bash'],
    [formatFindings(lint(fence('bash', "reg delete 'HKCU\\Software\\X' -f"))).includes('//f'), 'the rule 8 fix names //f for bash']
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
} else if (started) {
  try {
    main()
  } catch {
    // Allow the stop on any internal error.
  }
}
