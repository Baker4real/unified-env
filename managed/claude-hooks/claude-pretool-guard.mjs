// Claude Code PreToolUse guard (matcher PowerShell|Bash).
// Denies mechanical mistakes before the command runs:
//   1. recursive directory deletes that bypass the managed safe-tree-delete entry;
//   2. Recycle Bin moves outside the managed recycle entry, inline or inside a .ps1/.psm1 the command runs;
//   3. emptying the Recycle Bin, which is permanent deletion and stays with the user;
//   4. PowerShell native-CLI flags followed by an unquoted comma list, which PowerShell splits into an array;
//   5. `git clone` from a local path without --no-hardlinks: git hardlinks the source's .git/objects into the
//      clone, and safe-tree-delete refuses hardlinked files, so the clone can never be deleted afterwards;
//   6. Bash commands containing two backslashes in a row: the Bash tool transport turns them into one before
//      bash runs, while this hook still sees both;
//   7. Bash payloads for pwsh/powershell/python/node/perl/ruby/psx (inline or an unquoted heredoc) in which bash
//      would substitute $VAR, $(...) or backticks before the interpreter sees them;
//   8. under Claude Desktop (CLAUDE_CODE_ENTRYPOINT starts with claude-desktop), HKCU writes and deletes, inline or
//      inside a .ps1/.psm1 the command runs: MSIX copy-on-write sends them to the package's private layer, so the
//      command succeeds and the same shell reads the change back while the real registry stays unchanged.
//   9. PowerShell `rg` path arguments containing * or ?: PowerShell passes wildcards to native commands verbatim,
//      so rg gets a literal path and fails (os error 123 on Windows);
//  10. PowerShell -like / -notlike patterns starting with ??: ? is a one-character wildcard, so '??*' matches every
//      string of two or more characters instead of the literal ?? that git status --porcelain prints.
// Allow = print nothing and exit 0. Deny = print a PreToolUse permissionDecision JSON and exit 0.
// Any internal error allows the command: the registration keeps onFailure=continue, so a broken guard
// never locks the shell.
import { readFileSync, statSync } from 'node:fs'
import { win32 } from 'node:path'

const MANAGED_DELETE = 'D:\\Codex\\.codex\\scripts\\invoke-safe-tree-delete.ps1'
const MANAGED_RECYCLE = 'D:\\Codex\\.codex\\scripts\\Invoke-ManagedRecycle.ps1'
const GUIDANCE = 'D:\\Codex\\.codex\\docs\\agent-guidance'
const TEXT_ONLY_HINT = '如果命令里的写法只是文本（搜索模式、提交信息），改用 Grep 工具，或把关键词拆开写。'
const MSIX_HKCU_PAGE = 'D:\\agents\\knowledge-base\\wiki\\concepts\\Claude Desktop 里 Claude Code 的 HKCU 与 AppData 写入被 MSIX 虚拟化.md'

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

// Recycle Bin moves, matched in call form so prose that only names an API (help text, comments) passes.
// VB FileSystem.DeleteDirectory is either a recursive delete or a recycle, so every call form is denied.
const RECYCLE_PATTERNS = [
  /\bSHFileOperation[AW]?\s*\(/i,
  /\bFileSystem\]?(?:::|\.)DeleteDirectory\s*\(/i,
  /\b(?:SendToRecycleBin|RecycleOption)\b/i,
  /\.InvokeVerb(?:Ex)?\s*\(\s*['"]delete['"]/i,
  /\bNamespace\s*\(\s*(?:10|0x0?a)\s*\)[\s\S]*?\.MoveHere\s*\(/i,
  /\b(?:from|import)\s+send2trash\b|\bsend2trash\s*\(/i
]
const EMPTY_BIN_PATTERNS = [/\bClear-RecycleBin\b/i, /\bSHEmptyRecycleBin[AW]?\s*\(/i]
// Deleting inside $Recycle.Bin is emptying it by hand.
const RECYCLE_BIN_PATH = /\$Recycle\.Bin/i
const DELETE_VERB = /\b(?:remove-item|ri|rm|del|erase|rd|rmdir|unlink)\b|\bdelete\s*\(/i

// .ps1/.psm1 files the command runs or dot-sources: single-quoted, double-quoted or bare.
const SCRIPT_REFERENCE = /'([^'\r\n]+?\.psm?1)'|"([^"\r\n]+?\.psm?1)"|([^\s'"`;|&(){}<>]+?\.psm?1)(?![\w.])/gi
const MAX_SCRIPT_BYTES = 1024 * 1024
const MAX_SCRIPTS = 5

const defaultIo = {
  env: process.env,
  read(path) {
    try {
      const stat = statSync(path)
      return stat.isFile() && stat.size <= MAX_SCRIPT_BYTES ? readFileSync(path, 'utf8') : null
    } catch {
      return null
    }
  }
}

// Absolute paths of up to MAX_SCRIPTS referenced scripts; Git Bash /d/x becomes D:/x, relative paths use cwd.
function referencedScripts(command, cwd) {
  const paths = []
  for (const match of command.matchAll(SCRIPT_REFERENCE)) {
    const raw = (match[1] || match[2] || match[3]).replace(/^\/([a-z])(?=\/)/i, (_, drive) => `${drive}:`)
    const path = win32.resolve(cwd || '.', raw)
    if (!paths.some(seen => seen.toLowerCase() === path.toLowerCase())) paths.push(path)
    if (paths.length === MAX_SCRIPTS) break
  }
  return paths
}

function recycleReason(where) {
  return `${where}回收站移动只能走受管入口 ${MANAGED_RECYCLE}：先 -Mode Plan，用户在本任务里明确授权后再 -Mode Apply` +
    `（说明见 ${GUIDANCE}\\host-runbook\\safe-tree-delete.md 的受管回收一节）。${TEXT_ONLY_HINT}`
}

function emptyBinReason(where) {
  return `${where}清空回收站或删除 $Recycle.Bin 里的内容是永久删除，Agent 不执行；请用户自己清空回收站。${TEXT_ONLY_HINT}`
}

// Returns a deny reason when the command, or a script it references, recycles or empties the bin.
function recycleDecision(command, cwd, io) {
  if (EMPTY_BIN_PATTERNS.some(pattern => pattern.test(command)) ||
    (RECYCLE_BIN_PATH.test(command) && DELETE_VERB.test(command))) return emptyBinReason('')
  if (RECYCLE_PATTERNS.some(pattern => pattern.test(command))) return recycleReason('')
  for (const script of referencedScripts(command, cwd)) {
    if (win32.basename(script).toLowerCase() === 'invoke-managedrecycle.ps1') continue
    const text = io.read(script)
    if (!text) continue
    if (EMPTY_BIN_PATTERNS.some(pattern => pattern.test(text))) return emptyBinReason(`脚本 ${script} 里：`)
    if (RECYCLE_PATTERNS.some(pattern => pattern.test(text))) return recycleReason(`脚本 ${script} 里调用了回收站 API。`)
  }
  return null
}

// Rule 8. *-ItemProperty and .NET writes count when an HKCU reference appears anywhere in the same text, because
// scripts keep the key path in a variable (docker_off.ps1: $runKey = 'HKCU:\...', then Remove-ItemProperty $runKey).
// Item verbs need the HKCU path in the same statement, so `Remove-Item $tmp; Get-ItemProperty HKCU:\x` passes.
const HKCU_PATH = /\bHKCU:|\bHKEY_CURRENT_USER\b|\bRegistry::HKCU\b/i
const HKCU_WRITE_PATTERNS = [
  /\b(?:New-Item|Remove-Item|Set-Item|Copy-Item|Move-Item|Rename-Item|Clear-Item|ni|ri|rm|del|erase|rd|rmdir)\b[^\n;|&]*?(?:\bHKCU:|\bHKEY_CURRENT_USER\b|\bRegistry::HKCU\b)/i,
  /\breg(?:\.exe)?['"]?\s+(?:add|delete|copy|restore|load|unload)\b[^\n;|&]*?\b(?:HKCU|HKEY_CURRENT_USER)\b/i,
  // A .reg file names its hives inside the file; any HKCU section in it lands in the private layer.
  /\breg(?:\.exe)?['"]?\s+import\b/i,
  /SetEnvironmentVariable\s*\([^)]*(?:['"]User['"]|EnvironmentVariableTarget\]?::User)/i,
  /(?:^|[\s;&|(])setx(?:\.exe)?\s/i
]
const HKCU_PROPERTY_VERB = /\b(?:Set|New|Remove|Rename|Clear|Copy|Move)-ItemProperty\b/i
const DOTNET_CURRENT_USER = /\bRegistry(?:Hive)?\]?(?:::|\.)CurrentUser\b/i
const DOTNET_REGISTRY_WRITE = /\.(?:SetValue|CreateSubKey|DeleteSubKey|DeleteSubKeyTree|DeleteValue)\s*\(/i

function writesHkcu(text) {
  return HKCU_WRITE_PATTERNS.some(pattern => pattern.test(text)) ||
    (HKCU_PROPERTY_VERB.test(text) && HKCU_PATH.test(text)) ||
    (DOTNET_CURRENT_USER.test(text) && DOTNET_REGISTRY_WRITE.test(text))
}

function hkcuReason(where) {
  return `${where}Claude Desktop 里工具 shell 对 HKCU 的写入和删除只进 MSIX 包私有层：命令照样成功，同一个 shell 读回也对，真实注册表和资源管理器看不到。` +
    '改用 WMI StdRegProv 写（Invoke-CimMethod -Namespace root/default -ClassName StdRegProv，HKCU 的 hDefKey 是 [uint32]2147483649），写完也用 StdRegProv 读回；' +
    `要用户本人执行的，请用户在 Claude Desktop 的 Terminal 面板里跑。说明见 ${MSIX_HKCU_PAGE}。${TEXT_ONLY_HINT}`
}

// Returns a deny reason when, under Claude Desktop, the command or a script it references writes HKCU.
function hkcuDecision(command, cwd, io) {
  if (!/^claude-desktop/i.test(String(io.env?.CLAUDE_CODE_ENTRYPOINT || ''))) return null
  if (writesHkcu(command)) return hkcuReason('')
  for (const script of referencedScripts(command, cwd)) {
    const text = io.read(script)
    if (text && writesHkcu(text)) return hkcuReason(`脚本 ${script} 里：`)
  }
  return null
}

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

// Rule 9. rg options that take a separate value, so the value is not read as a path.
const RG_VALUE_SHORT = 'ABCdEefgjMmrTt'
const RG_VALUE_LONG = new Set([
  '--after-context', '--before-context', '--context', '--max-depth', '--encoding', '--regexp', '--file', '--glob',
  '--iglob', '--threads', '--max-columns', '--max-count', '--replace', '--type', '--type-not', '--type-add',
  '--type-clear', '--sort', '--sortr', '--max-filesize', '--path-separator', '--pre', '--pre-glob', '--colors',
  '--color', '--context-separator', '--field-context-separator', '--field-match-separator', '--dfa-size-limit',
  '--regex-size-limit', '--engine', '--ignore-file', '--hostname-bin', '--hyperlink-format', '--generate'
])

// Returns the first rg path argument containing * or ?, or null. The first positional word is the pattern unless
// -e/--regexp or -f/--file supplies the patterns, or --files needs none.
function rgWildcardPath(command) {
  for (const words of simpleCommands(command)) {
    if ((words[0] || '').split(/[\\/]/).pop().replace(/\.exe$/i, '').toLowerCase() !== 'rg') continue
    const positional = []
    let patternGiven = false
    for (let i = 1; i < words.length; i++) {
      const word = words[i]
      if (word === '--') { positional.push(...words.slice(i + 1)); break }
      if (word.includes('>')) continue // redirections such as *>$null and 2>$null
      if (word.startsWith('--')) {
        const name = word.split('=')[0]
        if (name === '--regexp' || name === '--file' || name === '--files') patternGiven = true
        if (!word.includes('=') && RG_VALUE_LONG.has(name)) i++
      } else if (word.length > 1 && word.startsWith('-')) {
        // In a short cluster such as -nA3 or -nA 3, the first value-taking letter takes the rest or the next word.
        for (let k = 1; k < word.length; k++) {
          if (!RG_VALUE_SHORT.includes(word[k])) continue
          if (word[k] === 'e' || word[k] === 'f') patternGiven = true
          if (k === word.length - 1) i++
          break
        }
      } else positional.push(word)
    }
    const path = positional.slice(patternGiven ? 0 : 1).find(word => /[*?]/.test(word))
    if (path) return path
  }
  return null
}

function rgWildcardReason(path) {
  const wildcard = path.search(/[*?]/)
  const sep = Math.max(path.lastIndexOf('\\', wildcard), path.lastIndexOf('/', wildcard))
  const prefix = path.slice(0, sep + 1)
  const dir = sep < 0 ? '.' : /^(?:[a-z]:)?[\\/]$/i.test(prefix) ? prefix : prefix.slice(0, -1)
  return `PowerShell 不替原生命令展开通配符：rg 收到的是字面路径 ${path}，在 Windows 上报 os error 123（文件名、目录名或卷标语法不正确）。` +
    `目录作路径参数、通配部分改用 -g：rg <模式> ${dir} -g '${path.slice(sep + 1).replace(/\\/g, '/')}'（只搜这一层再加 --max-depth 1），` +
    `或先用 Get-ChildItem 展开成真实路径（${GUIDANCE}\\windows-pwsh-command-guidelines.md 第 6 条）。`
}

// Rule 10. In -like, ? matches any one character: '??*' matches every string of two or more characters.
const LIKE_DOUBLE_QUESTION = /-[ic]?(?:not)?like\s+['"]\?\?/i

// Characters after `$` that make bash substitute: a name, ${...}, $(...), a digit or a special parameter.
const EXPANSION_START = /[A-Za-z_{(0-9?!#@*$-]/

// Index just past the `)` or `}` that closes s[i], or past the backtick that closes the one at s[i].
function skipSubstitution(s, i) {
  const open = s[i]
  const close = open === '(' ? ')' : open === '{' ? '}' : '`'
  let depth = 0
  for (let j = i; j < s.length; j++) {
    const ch = s[j]
    if (ch === '\\') j++
    else if (open === '`') { if (j > i && ch === '`') return j + 1 }
    else if (ch === "'" || ch === '"') {
      let k = j + 1
      while (k < s.length && s[k] !== ch) k += ch === '"' && s[k] === '\\' ? 2 : 1
      j = k
    } else if (ch === open) depth++
    else if (ch === close && --depth === 0) return j + 1
  }
  return s.length
}

function hasExpansion(text) {
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '\\') i++
    else if (text[i] === '`' || (text[i] === '$' && EXPANSION_START.test(text[i + 1] || ''))) return true
  }
  return false
}

// Reads the bodies of pending heredocs, which start at s[i]; returns the index after the last delimiter line.
function readHeredocBodies(s, i, pending) {
  while (pending.length && i < s.length) {
    const doc = pending.shift()
    let body = ''
    while (i < s.length) {
      let end = s.indexOf('\n', i)
      if (end < 0) end = s.length
      const line = s.slice(i, end).replace(/\r$/, '')
      i = end + 1
      if ((doc.stripTabs ? line.replace(/^\t+/, '') : line) === doc.delimiter) break
      body += line + '\n'
    }
    doc.expands = !doc.quoted && hasExpansion(body)
  }
  return Math.min(i, s.length)
}

// A bash model for rule 7: simple commands of words { text, expands }, plus the heredocs each command opens.
// `expands` marks an unescaped $-substitution or backtick outside single quotes, which bash replaces before
// the program sees the word.
function bashCommands(s) {
  const commands = []
  const pending = []
  let words = []
  let heredocs = []
  let word = null
  const add = (text, expands = false) => {
    if (!word) word = { text: '', expands: false }
    word.text += text
    if (expands) word.expands = true
  }
  const endWord = () => { if (word) words.push(word); word = null }
  const endCommand = () => {
    endWord()
    if (words.length || heredocs.length) commands.push({ words, heredocs })
    words = []
    heredocs = []
  }
  const substitution = start => {
    const end = s[start] === '`' ? skipSubstitution(s, start)
      : s[start + 1] === '(' || s[start + 1] === '{' ? skipSubstitution(s, start + 1) : start + 2
    add(s.slice(start, end), true)
    return end
  }
  let i = 0
  while (i < s.length) {
    const ch = s[i]
    if (ch === '\\') {
      if (s[i + 1] !== '\n') add(s[i + 1] || '') // backslash-newline continues the line
      i += 2
    } else if (ch === "'") {
      const end = s.indexOf("'", i + 1)
      const stop = end < 0 ? s.length : end
      add(s.slice(i + 1, stop))
      i = stop + 1
    } else if (ch === '$' && s[i + 1] === "'") { // ANSI-C quoting substitutes nothing
      let j = i + 2
      while (j < s.length && s[j] !== "'") j += s[j] === '\\' ? 2 : 1
      add(s.slice(i + 2, j))
      i = j + 1
    } else if (ch === '"') {
      add('')
      let j = i + 1
      while (j < s.length && s[j] !== '"') {
        const c = s[j]
        if (c === '\\') {
          add('$`"\\\n'.includes(s[j + 1]) ? s[j + 1] : c + (s[j + 1] || ''))
          j += 2
        } else if (c === '`' || (c === '$' && EXPANSION_START.test(s[j + 1] || ''))) j = substitution(j)
        else { add(c); j++ }
      }
      i = j + 1
    } else if (ch === '`' || (ch === '$' && EXPANSION_START.test(s[i + 1] || ''))) {
      i = substitution(i)
    } else if (ch === '#' && !word) {
      while (i < s.length && s[i] !== '\n') i++
    } else if (ch === '\n') {
      endCommand()
      i = readHeredocBodies(s, i + 1, pending)
    } else if (ch === '<' && s[i + 1] === '<' && s[i + 2] !== '<') {
      endWord()
      let j = i + 2
      const stripTabs = s[j] === '-'
      if (stripTabs) j++
      while (s[j] === ' ' || s[j] === '\t') j++
      let delimiter = ''
      let quoted = false
      while (j < s.length && !/[\s;&|()<>]/.test(s[j])) {
        if (s[j] === "'" || s[j] === '"') {
          const end = s.indexOf(s[j], j + 1)
          const stop = end < 0 ? s.length : end
          delimiter += s.slice(j + 1, stop)
          quoted = true
          j = stop + 1
        } else if (s[j] === '\\') {
          delimiter += s[j + 1] || ''
          quoted = true
          j += 2
        } else delimiter += s[j++]
      }
      const doc = { delimiter, quoted, stripTabs, expands: false }
      heredocs.push(doc)
      pending.push(doc)
      i = j
    } else if (ch === '<' || ch === '>' || (ch === '&' && s[i + 1] === '>')) {
      endWord() // redirection operators, including <<<, >>, &>, 2>&1 and >&2
      i++
      while (s[i] === '<' || s[i] === '>' || s[i] === '&' || s[i] === '|') i++
    } else if (/[;&|()]/.test(ch)) {
      endCommand()
      i++
    } else if (/\s/.test(ch)) {
      endWord()
      i++
    } else {
      add(ch)
      i++
    }
  }
  endCommand()
  return commands
}

const INTERPRETERS = new Set(['pwsh', 'powershell', 'python', 'python3', 'py', 'node', 'perl', 'ruby', 'psx'])
const SCRIPT_FILE = /\.(?:ps1|psm1|py|js|mjs|cjs)$/i
// pwsh / Windows PowerShell options that take the next word as their value.
const PWSH_VALUE_OPTION = /^-(?:config(?:urationname)?|configurationfile|custompipename|e(?:c|ncodedcommand)?|e[xp]|executionpolicy|inp|if|inputformat|o(?:f|utputformat)?|settings(?:file)?|w(?:indowstyle)?|wd|workingdirectory|psconsolefile|version)$/i

// The argument words an interpreter runs as code: everything after -Command, or the word after -c / -e.
function payloadWords(interpreter, args) {
  if (interpreter === 'psx') return args
  if (interpreter === 'pwsh' || interpreter === 'powershell') {
    for (let i = 0; i < args.length; i++) {
      const text = args[i].text
      if (/^-c(?:o(?:m(?:m(?:a(?:n(?:d)?)?)?)?)?)?$/i.test(text)) return args.slice(i + 1)
      if (/^-(?:cwa|commandwithargs)$/i.test(text)) return args.slice(i + 1, i + 2)
      if (/^-f(?:ile)?$/i.test(text)) return []
      if (PWSH_VALUE_OPTION.test(text)) i++
      else if (!text.startsWith('-')) return interpreter === 'powershell' ? args.slice(i) : [] // 5.1 runs it as a command
    }
    return []
  }
  const code = {
    python: /^-[A-Za-z]*c$/, python3: /^-[A-Za-z]*c$/, py: /^-[A-Za-z]*c$/,
    node: /^(?:-e|--eval|-p|--print|-pe)$/, perl: /^-[A-Za-z]*[eE]$/, ruby: /^-[A-Za-z]*e$/
  }[interpreter]
  for (let i = 0; i < args.length; i++) {
    const text = args[i].text
    if (code.test(text)) return args.slice(i + 1, i + 2)
    if (interpreter === 'node' && /^--(?:eval|print)=/.test(text)) return [args[i]]
    if (/^(?:-[XWr]|--require|--import|--loader)$/.test(text)) i++
    else if (!text.startsWith('-') || text === '-' || text === '--') return []
  }
  return []
}

// Returns { target, text } for the first payload bash would rewrite before the interpreter or file gets it.
function expandingPayload(command) {
  for (const { words, heredocs } of bashCommands(command)) {
    let i = 0
    while (i < words.length && (/^[A-Za-z_]\w*=/.test(words[i].text) || /^(?:env|exec|command|time|nohup)$/.test(words[i].text))) i++
    const name = (words[i] ? words[i].text : '').split(/[\\/]/).pop().replace(/\.exe$/i, '').toLowerCase()
    const interpreter = INTERPRETERS.has(name) ? name : ''
    if (interpreter) {
      const payload = payloadWords(interpreter, words.slice(i + 1)).find(w => w.expands)
      if (payload) return { target: interpreter, text: payload.text }
    }
    const doc = heredocs.find(d => d.expands)
    if (doc && (interpreter || words.some(w => SCRIPT_FILE.test(w.text)))) {
      return { target: interpreter || '写入的脚本文件', text: `<<${doc.delimiter} heredoc` }
    }
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

export function evaluate(payload, io = defaultIo) {
  const tool = String(payload?.tool_name || '')
  const command = String(payload?.tool_input?.command || '')
  if (!command || (tool !== 'PowerShell' && tool !== 'Bash')) return null

  // First, so `Remove-Item HKCU:\x -Recurse` gets the registry reason rather than the safe-tree-delete one.
  const hkcu = hkcuDecision(command, payload?.cwd, io)
  if (hkcu) return hkcu

  if (!/invoke-safe-tree-delete/i.test(command) && RECURSIVE_DELETE_PATTERNS.some(pattern => pattern.test(command))) {
    return `递归删除目录只能走受管入口 ${MANAGED_DELETE}（Plan → Apply → Purge，说明见 ${GUIDANCE}\\host-runbook\\safe-tree-delete.md）。` +
      '删除单个文件不受影响。如果命令里的删除写法只是文本（搜索模式、提交信息），改用 Grep 工具，或把关键词拆开写。'
  }

  const recycle = recycleDecision(command, payload?.cwd, io)
  if (recycle) return recycle

  if (tool === 'Bash' && command.includes('\\\\')) {
    return 'Bash 工具在命令进 bash 之前会把两个连续反斜杠吞成一个（单引号、双引号、带引号的 heredoc 都一样），实际执行的命令和写的不一样。' +
      `路径改用正斜杠（/d/...）；必须带反斜杠的正则、Windows 路径或 payload 改用 PowerShell 工具，或写成文件再执行（${GUIDANCE}\\windows-pwsh-command-guidelines.md「从 Git Bash 调用 PowerShell」）。`
  }

  if (tool === 'Bash') {
    const payloadHit = expandingPayload(command)
    if (payloadHit) {
      return `Bash 会先替换双引号、未加引号文本和不带引号 heredoc 里的 $变量、$(...) 和反引号，${payloadHit.target} 收到的已经不是原文（${payloadHit.text.slice(0, 80)}）。` +
        `把代码放进单引号或带引号的 heredoc（<<'EOF'），写成文件再执行，或改用 PowerShell 工具（${GUIDANCE}\\windows-pwsh-command-guidelines.md「从 Git Bash 调用 PowerShell」）。`
    }
  }

  if (tool === 'PowerShell') {
    const match = command.match(UNQUOTED_COMMA_LIST)
    if (match) {
      return `PowerShell 会把未加引号的逗号列表拆成多个参数：${match[1]} ${match[2]} 要写成 ${match[1]} '${match[2]}'，或先放进变量再传入（D:\\Codex\\.codex\\docs\\agent-guidance\\windows-pwsh-command-guidelines.md 第 9 条）。`
    }
    const wildPath = rgWildcardPath(command)
    if (wildPath) return rgWildcardReason(wildPath)
    if (LIKE_DOUBLE_QUESTION.test(command)) {
      return "-like 里的 ? 是单字符通配符：'??*' 匹配任何至少两个字符的字符串，筛不出 git status --porcelain 的未跟踪行（字面 ??）。" +
        "改用 .StartsWith('??')，或在模式里转义成 '`?`?*'。" + TEXT_ONLY_HINT
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
  // Rule 8 only runs under Claude Desktop; a case's fourth element is the environment it sees.
  const desktop = { CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' }
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
    ['Bash', 'echo git clone /d/repo out', false],
    // Recycle Bin moves and emptying the bin, inline and in referenced scripts (stubbed below, cwd D:\repo).
    ['PowerShell', "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin')", true],
    ['PowerShell', "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)", true],
    ['PowerShell', "(New-Object -ComObject Shell.Application).Namespace('D:\\x').ParseName('a.txt').InvokeVerb('delete')", true],
    ['PowerShell', "(New-Object -ComObject Shell.Application).Namespace(10).MoveHere('D:\\x\\a.txt')", true],
    ['PowerShell', 'Add-Type -TypeDefinition $src; [Native]::SHFileOperationW([ref]$op)', true],
    ['Bash', 'python -c "from send2trash import send2trash; send2trash(p)"', true],
    ['PowerShell', 'Clear-RecycleBin -DriveLetter D -Force', true],
    ['PowerShell', "Remove-Item -LiteralPath 'D:\\$Recycle.Bin\\S-1-5-21-1\\$RABC123.txt' -Force", true],
    ['PowerShell', "pwsh -NoProfile -File 'D:\\repo\\tools\\recycle.ps1'", true],
    ['Bash', 'pwsh -NoProfile -File /d/repo/tools/empty-bin.ps1', true],
    ['PowerShell', '. .\\lib\\shell.ps1', true],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-ManagedRecycle.ps1' -Mode Plan -TargetPath D:\\x -Purpose cache -Authorization 'user said yes'", false],
    ['PowerShell', "Get-ChildItem -LiteralPath 'D:\\$Recycle.Bin' -Force", false],
    ['PowerShell', "pwsh -File 'D:\\repo\\tools\\harmless.ps1'", false],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-CheckedPowerShell.ps1' -ScriptPath D:\\repo\\tools\\harmless.ps1", false],
    ['Bash', 'git commit -m "docs: name SHFileOperationW in the help text"', false],
    // Two backslashes in a row reach bash as one.
    ['Bash', String.raw`grep -E 'a\\.b' notes.txt`, true],
    ['Bash', String.raw`ls 'D:\\agents'`, true],
    ['Bash', "cat > x.txt <<'EOF'\n" + String.raw`C:\\x` + '\nEOF', true],
    ['PowerShell', String.raw`Get-ChildItem 'D:\\agents'`, false],
    ['Bash', String.raw`printf 'a\nb'`, false],
    ['Bash', 'ls /d/agents', false],
    // Bash would substitute $ or backticks inside an interpreter payload.
    ['Bash', 'pwsh -NoProfile -Command "Get-Item $env:TEMP"', true],
    ['Bash', 'powershell -c "Write-Output a`tb"', true],
    ['Bash', 'pwsh -c "$x = 1; $x"', true],
    ['Bash', 'python -c "print($HOME)"', true],
    ['Bash', 'node -e "console.log(${x})"', true],
    ['Bash', 'perl -e "print $0"', true],
    ['Bash', 'pwsh -Command - <<EOF\nGet-Item $env:TEMP\nEOF', true],
    ['Bash', 'cat > x.ps1 <<EOF\n$a = 1\nEOF', true],
    ['Bash', 'pwsh -cwa "Write-Output $args" x', true],
    ['Bash', 'psx "Get-Item $env:TEMP"', true],
    ['Bash', 'cd /d/x && pwsh -c Get-Item $env:TEMP', true],
    ['Bash', 'pwsh -File ./x.ps1 "$HOME"', false],
    ['Bash', 'powershell -ExecutionPolicy Bypass -File x.ps1 "$HOME"', false],
    ['Bash', 'echo "$HOME"', false],
    ['Bash', "pwsh -c 'Get-Item $env:TEMP'", false],
    ['Bash', 'pwsh -c "Get-Item \\$env:TEMP"', false],
    ['Bash', "pwsh -Command - <<'EOF'\nGet-Item $env:TEMP\nEOF", false],
    ['Bash', 'python -c "import sys; print(sys.argv[1])" "$VAR"', false],
    ['Bash', 'pwsh -cwa "Write-Output hi" "$HOME"', false],
    ['Bash', 'git commit -m "fix: $x"', false],
    ['Bash', 'cat > notes.txt <<EOF\n$x\nEOF', false],
    ['Bash', 'pwsh -c "Get-Date" # costs $5', false],
    ['PowerShell', 'pwsh -c "Get-Item $env:TEMP"', false],
    // PowerShell hands rg its wildcards verbatim; in -like, ? is a one-character wildcard.
    ['PowerShell', 'rg -n "Invoke-Guard" D:\\agents\\x\\*.ps1', true],
    ['PowerShell', 'rg foo src/*.cs', true],
    ['PowerShell', "& 'C:\\tools\\rg.exe' -l foo tools\\*.psm1", true],
    ['PowerShell', "rg -e 'a.*b' 'D:\\x\\*.md'", true],
    ['PowerShell', 'rg --files D:\\x\\*.json', true],
    ['PowerShell', 'rg -nA 3 foo src\\**\\*.cs', true],
    ['PowerShell', 'rg -n x -- *.ps1', true],
    ['PowerShell', 'Get-ChildItem | ForEach-Object { rg -l foo $_\\*.txt }', true],
    ['PowerShell', "rg -n 'foo.*bar?' D:\\agents\\x", false],
    ['PowerShell', "rg -n foo D:\\agents\\x -g '*.ps1'", false],
    ['PowerShell', 'rg -n foo -g *.ps1 --iglob !*.min.js D:\\x', false],
    ['PowerShell', 'rg --glob=*.ps1 -nA3 "a*" src', false],
    ['PowerShell', "rg -e 'x*' -e 'y?' src *>$null", false],
    ['PowerShell', "git ls-files | rg '\\.ps1$'", false],
    ['PowerShell', "Write-Output 'rg foo *.ps1'", false],
    ['Bash', 'rg foo src/*.cs', false],
    ['PowerShell', "git status --porcelain | Where-Object { $_ -like '??*' }", true],
    ['PowerShell', "@($s | Where-Object { $_ -notlike '??*' }).Count", true],
    ['PowerShell', 'Where-Object { $_ -clike "?? *" }', true],
    ['PowerShell', "$s | Where-Object { $_.StartsWith('??') }", false],
    ['PowerShell', "$s | Where-Object { $_ -like '`?`?*' }", false],
    ['PowerShell', "Get-ChildItem | Where-Object Name -like '?.txt'", false],
    ['Bash', "grep -c -- \"-like '??\" notes.txt", false],
    // HKCU writes under Claude Desktop land in the MSIX private layer, inline and in referenced scripts.
    ['PowerShell', "Set-ItemProperty -LiteralPath 'HKCU:\\Software\\X' -Name a -Value 1", true, desktop],
    ['PowerShell', "$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\\Classes\\CLSID\\X\\DefaultIcon', $true); $k.SetValue('', 'D:\\a.exe,0')", true, desktop],
    ['PowerShell', "$cu = [Microsoft.Win32.Registry]::CurrentUser\n$k = $cu.CreateSubKey('Software\\X')", true, desktop],
    ['PowerShell', 'reg add HKCU\\Software\\X /v a /d 1 /f', true, desktop],
    ['PowerShell', "& 'C:\\Windows\\System32\\reg.exe' delete 'HKCU\\Software\\X' /f", true, desktop],
    ['PowerShell', 'reg import D:\\backup\\before-clsid.reg', true, desktop],
    ['PowerShell', "Remove-Item -LiteralPath 'HKCU:\\Software\\X'", true, desktop],
    ['PowerShell', 'Remove-Item -Path HKCU:\\Software\\X -Recurse', true, desktop],
    ['PowerShell', "[Environment]::SetEnvironmentVariable('DOTNET_ROOT', $null, 'User')", true, desktop],
    ['PowerShell', 'setx DOTNET_ROOT ""', true, desktop],
    ['Bash', "MSYS_NO_PATHCONV=1 reg delete 'HKCU\\Software\\X' /f", true, desktop],
    ['PowerShell', "pwsh -NoProfile -File 'D:\\repo\\tools\\docker_off.ps1'", true, desktop],
    ['PowerShell', "Get-ItemProperty -LiteralPath 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'", false, desktop],
    ['PowerShell', "Invoke-CimMethod -Namespace root/default -ClassName StdRegProv -MethodName SetStringValue -Arguments @{ hDefKey = [uint32]2147483649; sSubKeyName = 'Software\\X'; sValueName = 'a'; sValue = '1' }", false, desktop],
    ['PowerShell', 'reg query HKCU\\Software\\X', false, desktop],
    ['PowerShell', "Remove-Item -LiteralPath D:\\x\\a.txt; Get-ItemProperty -LiteralPath 'HKCU:\\Console'", false, desktop],
    ['PowerShell', "[Environment]::SetEnvironmentVariable('CI', $Ci)", false, desktop],
    ['Bash', "grep -nE 'Set-ItemProperty|New-ItemProperty|HKCU|HKLM' tools/x.ps1", false, desktop],
    ['PowerShell', "pwsh -File 'D:\\repo\\tools\\harmless.ps1'", false, desktop],
    ['PowerShell', "Set-ItemProperty -LiteralPath 'HKCU:\\Software\\X' -Name a -Value 1", false, { CLAUDE_CODE_ENTRYPOINT: 'cli' }],
    ['PowerShell', "Set-ItemProperty -LiteralPath 'HKCU:\\Software\\X' -Name a -Value 1", false]
  ]
  const scripts = new Map(Object.entries({
    'D:\\repo\\tools\\recycle.ps1': 'Add-Type -TypeDefinition $src\n[Native]::SHFileOperationW([ref]$op)',
    'D:\\repo\\tools\\empty-bin.ps1': 'Clear-RecycleBin -DriveLetter D -Force',
    'D:\\repo\\lib\\shell.ps1': '$shell = New-Object -ComObject Shell.Application\n$shell.Namespace(10).MoveHere($path)',
    'D:\\repo\\tools\\harmless.ps1': 'Get-ChildItem -LiteralPath $PSScriptRoot',
    'D:\\repo\\tools\\docker_off.ps1': "$runKey = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'\nif ($null -ne $runVal) { Remove-ItemProperty -LiteralPath $runKey -Name $name }",
    'D:\\Codex\\.codex\\scripts\\Invoke-ManagedRecycle.ps1': 'code = SHFileOperationW(ref op);',
    'D:\\Codex\\.codex\\scripts\\Invoke-CheckedPowerShell.ps1': 'STA (SHFileOperationW) works here.'
  }).map(([path, text]) => [path.toLowerCase(), text]))
  const io = { read: path => scripts.get(win32.normalize(path).toLowerCase()) ?? null }
  let failed = 0
  for (const [tool, command, shouldDeny, env] of cases) {
    const denied = evaluate({ tool_name: tool, tool_input: { command }, cwd: 'D:\\repo' }, env ? { ...io, env } : io) !== null
    if (denied !== shouldDeny) {
      failed++
      console.error(`FAIL ${tool}${env ? ` [${env.CLAUDE_CODE_ENTRYPOINT}]` : ''}: ${command} -> ${denied ? 'deny' : 'allow'}`)
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
