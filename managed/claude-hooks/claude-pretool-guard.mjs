// Claude Code PreToolUse guard (matcher PowerShell|Bash).
// Denies three mechanical mistakes before the command runs:
//   1. recursive directory deletes that bypass the managed safe-tree-delete entry;
//   2. PowerShell native-CLI flags followed by an unquoted comma list, which PowerShell splits into an array;
//   3. `git clone` from a local path without --no-hardlinks: git hardlinks the source's .git/objects into the
//      clone, and safe-tree-delete refuses hardlinked files, so the clone can never be deleted afterwards.
// Allow = print nothing and exit 0. Deny = print a PreToolUse permissionDecision JSON and exit 0.
// Any internal error allows the command: the registration keeps onFailure=continue, so a broken guard
// never locks the shell.
import { readFileSync } from 'node:fs'

const MANAGED_DELETE = 'D:\\Codex\\.codex\\scripts\\invoke-safe-tree-delete.ps1'

const RECURSIVE_DELETE_PATTERNS = [
  // PowerShell Remove-Item and its aliases with -Recurse (or an unambiguous prefix such as -r / -rec).
  // `git rm -r` only unstages paths, so it is excluded here and below.
  /(?<!\bgit\s+)\b(?:remove-item|ri|rm|del|erase|rd|rmdir)\b[^\n;|&]*?\s-r(?:e(?:c(?:u(?:r(?:s(?:e)?)?)?)?)?)?\b/i,
  // POSIX rm with a recursive flag (-r, -rf, -fr, -R, --recursive).
  /(?<!\bgit\s+)\brm\s+(?:-[a-z]*r[a-z]*|--recursive)\b/i,
  // cmd.exe rmdir / rd /s and del /s.
  /\b(?:rmdir|rd)\s+\/s\b/i,
  /\bdel\b[^\n;|&]*\s\/s\b/i,
  // .NET Directory.Delete(path, true).
  /directory\]?::delete\s*\([^)]*,\s*\$?true\b/i,
  // Node fs.rm / rmSync / rmdirSync with recursive: true, python shutil.rmtree, rimraf.
  /\b(?:rm|rmSync|rmdirSync|rmdir)\s*\([^)]*recursive\s*:\s*true/i,
  /\bshutil\.rmtree\s*\(/i,
  /\brimraf\b/i
]

// A double-dash flag followed by a bare token containing a comma: PowerShell turns a,b into two argv items.
// Quoted values, variables ($x), subexpressions and splats are skipped.
const UNQUOTED_COMMA_LIST = /(?:^|\s)(--[a-z][\w-]*)\s+(?!['"$@({])([^\s'"`]*,[^\s'"`]*)/i

// git clone options that take a separate value, so the value is not mistaken for the source repository.
const CLONE_VALUE_OPTIONS = new Set([
  '-o', '--origin', '-b', '--branch', '-u', '--upload-pack', '-c', '--config', '-j', '--jobs',
  '--template', '--reference', '--reference-if-able', '--separate-git-dir', '--depth',
  '--shallow-since', '--shallow-exclude', '--filter', '--server-option', '--bundle-uri',
  '--revision', '--ref-format'
])
// Flags that make git copy or borrow objects instead of hardlinking them (-s is --shared).
const CLONE_NO_HARDLINK_FLAG = /^(?:--no-hardlinks|--no-local|--shared|-[a-z]*s[a-z]*)$/

// Splits a command line into simple commands (on ; & | ( ) { } and newlines outside quotes) and each command
// into words with the quotes removed. A rough shell model, only good enough to find `git ... clone` words.
function simpleCommands(command) {
  const commands = []
  let words = []
  let word = ''
  let inWord = false
  let quote = ''
  const endWord = () => { if (inWord) words.push(word); word = ''; inWord = false }
  const endCommand = () => { endWord(); if (words.length) commands.push(words); words = [] }
  for (const ch of command) {
    if (quote) {
      if (ch === quote) quote = ''
      else word += ch
    } else if (ch === '"' || ch === "'") {
      quote = ch
      inWord = true
    } else if (/[;&|(){}\r\n]/.test(ch)) {
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

// git treats a source as a local path unless it is a URL or an scp-like host:path (url_is_local_not_ssh).
function isLocalSource(source) {
  if (/[$%`]/.test(source)) return false // variables cannot be resolved here; let the command run
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(source)) return false
  if (/^[a-z]:(?:[\\/]|$)/i.test(source)) return true
  const colon = source.indexOf(':')
  const slash = source.search(/[\\/]/)
  return colon < 0 || (slash >= 0 && slash < colon)
}

// Returns the local source of a `git clone` that would hardlink objects, or null.
function hardlinkingCloneSource(command) {
  for (const words of simpleCommands(command)) {
    let i = 0
    while (i < words.length && /^[A-Za-z_]\w*=/.test(words[i])) i++ // VAR=value prefixes
    if (!/^git(?:\.exe)?$/i.test((words[i] || '').split(/[\\/]/).pop())) continue
    i++
    while (i < words.length && words[i].startsWith('-')) i += (words[i] === '-C' || words[i] === '-c') ? 2 : 1
    if (words[i] !== 'clone') continue
    const positional = []
    let copies = false
    for (i++; i < words.length; i++) {
      const word = words[i]
      if (word === '--') { positional.push(...words.slice(i + 1)); break }
      if (CLONE_NO_HARDLINK_FLAG.test(word)) copies = true
      else if (CLONE_VALUE_OPTIONS.has(word)) i++
      else if (!word.startsWith('-')) positional.push(word)
    }
    if (!copies && positional.length && isLocalSource(positional[0])) return positional[0]
  }
  return null
}

function deny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason
    }
  }))
}

export function evaluate(payload) {
  const tool = String(payload?.tool_name || '')
  const command = String(payload?.tool_input?.command || '')
  if (!command || (tool !== 'PowerShell' && tool !== 'Bash')) return null

  if (!/invoke-safe-tree-delete/i.test(command) && RECURSIVE_DELETE_PATTERNS.some(pattern => pattern.test(command))) {
    return `递归删除目录只能走受管入口 ${MANAGED_DELETE}（Plan → Apply → Purge，说明见 D:\\Codex\\.codex\\docs\\agent-guidance\\host-runbook\\safe-tree-delete.md）。` +
      '删除单个文件不受影响。如果命令里的删除写法只是文本（搜索模式、提交信息），改用 Grep 工具，或把关键词拆开写。'
  }

  if (tool === 'PowerShell') {
    const match = command.match(UNQUOTED_COMMA_LIST)
    if (match) {
      return `PowerShell 会把未加引号的逗号列表拆成多个参数：${match[1]} ${match[2]} 要写成 ${match[1]} '${match[2]}'，或先放进变量再传入（D:\\Codex\\.codex\\docs\\agent-guidance\\windows-pwsh-command-guidelines.md 第 9 条）。`
    }
  }

  const source = hardlinkingCloneSource(command)
  if (source) {
    return `git clone 的源 ${source} 是本地路径：同盘本地克隆默认把源库 .git/objects 硬链进克隆，受管 safe-tree-delete 拒绝硬链文件，克隆建成后就删不掉了。` +
      '加 --no-hardlinks 后重试（--no-local 或 file:// 源也行）。如果这只是文本（提交信息、搜索模式），改用 Grep 工具，或把关键词拆开写。'
  }
  return null
}

function main() {
  let payload
  try {
    payload = JSON.parse(readFileSync(0, 'utf8') || '{}')
  } catch {
    return
  }
  const reason = evaluate(payload)
  if (reason) deny(reason)
}

if (process.argv.includes('--self-test')) {
  const cases = [
    ['PowerShell', 'Remove-Item -Recurse -Force D:\\x', true],
    ['PowerShell', 'rm -r .\\build', true],
    ['PowerShell', 'Get-ChildItem x | Remove-Item -Recurse', true],
    ['PowerShell', 'cmd /c rmdir /s /q D:\\x', true],
    ['PowerShell', '[System.IO.Directory]::Delete($p, $true)', true],
    ['PowerShell', 'node -e "fs.rmSync(p, { recursive: true })"', true],
    ['Bash', 'rm -rf node_modules', true],
    ['Bash', 'rm -fr dist', true],
    ['Bash', 'python -c "import shutil; shutil.rmtree(p)"', true],
    ['PowerShell', 'Remove-Item -LiteralPath D:\\x\\a.txt', false],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\invoke-safe-tree-delete.ps1' -Mode Plan -TargetPaths D:\\x", false],
    ['Bash', 'rm file.txt', false],
    ['Bash', 'git rm --cached a.txt', false],
    ['PowerShell', 'git rm -r --cached .scratch/out', false],
    ['Bash', 'git rm -r --cached dist', false],
    ['PowerShell', 'gh issue list --json number,title', true],
    ['PowerShell', 'gh issue create --blocked-by 27,28', true],
    ['PowerShell', "gh issue list --json 'number,title'", false],
    ['PowerShell', 'gh issue list --json $fields', false],
    ['PowerShell', 'Select-Object Name,Length', false],
    ['Bash', 'gh issue list --json number,title', false],
    ['Read', 'Remove-Item -Recurse x', false],
    ['Bash', 'git clone /d/agents/knowledge-base /d/Codex/temp/kb', true],
    ['PowerShell', 'git clone D:\\agents\\knowledge-base D:\\agents\\tmp\\kb', true],
    ['PowerShell', "git -C D:\\agents clone --no-checkout knowledge-base 'D:\\agents\\tmp\\kb'", true],
    ['Bash', 'cd /d/agents && git clone . ../tmp/kb', true],
    ['PowerShell', "& 'C:\\Program Files\\Git\\cmd\\git.exe' clone D:\\repo D:\\tmp\\r", true],
    ['Bash', 'git clone --depth 1 -b main ./repo out', true],
    ['Bash', 'git clone -l /d/repo out', true],
    ['Bash', 'git clone --no-hardlinks /d/agents/knowledge-base /d/agents/tmp/kb', false],
    ['PowerShell', 'git clone --no-hardlinks --no-checkout D:\\agents\\knowledge-base D:\\agents\\tmp\\kb', false],
    ['Bash', 'git clone --no-local /d/repo out', false],
    ['Bash', 'git clone -s /d/repo out', false],
    ['Bash', 'git clone file:///d/agents/knowledge-base out', false],
    ['Bash', 'git clone -b main https://github.com/Baker4real/knowledge-base.git /d/x', false],
    ['Bash', 'git clone git@github.com:Baker4real/knowledge-base.git kb', false],
    ['PowerShell', 'git clone --reference D:\\agents\\knowledge-base https://example.com/r.git D:\\x', false],
    ['PowerShell', 'git clone $src $dst', false],
    ['Bash', 'git commit -m "note: git clone /d/repo out"', false],
    ['Bash', 'echo git clone /d/repo out', false]
  ]
  let failed = 0
  for (const [tool, command, shouldDeny] of cases) {
    const denied = evaluate({ tool_name: tool, tool_input: { command } }) !== null
    if (denied !== shouldDeny) {
      failed++
      console.error(`FAIL ${tool}: ${command} -> ${denied ? 'deny' : 'allow'}`)
    }
  }
  console.log(`self-test: ${cases.length - failed}/${cases.length} passed`)
  process.exit(failed ? 1 : 0)
} else {
  try {
    main()
  } catch {
    // Allow on any internal error.
  }
}
