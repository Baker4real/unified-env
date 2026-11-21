// Claude Code PreToolUse guard (matchers PowerShell|Bash|mcp__terminal__run_in_terminal, Write|Edit and Grep|Glob;
// the handoff-status mod pipes its hand_off calls here itself, see rule 24).
// The Terminal panel tool types one line into the user's own PowerShell outside the MSIX package, so rules 8 and 11
// skip it, the PowerShell-only rules apply to it and the Bash-only rules do not.
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
//      The -ScriptPath script of Invoke-OfficeRemote.ps1 or Invoke-RemoteStep.ps1 runs on the remote PC over SSH and
//      is not checked.
//   9. PowerShell `rg` path arguments containing * or ?: PowerShell passes wildcards to native commands verbatim,
//      so rg gets a literal path and fails (os error 123 on Windows);
//  10. PowerShell -like / -notlike patterns starting with ??: ? is a one-character wildcard, so '??*' matches every
//      string of two or more characters instead of the literal ?? that git status --porcelain prints;
//  11. under Claude Desktop, installers started from the tool shell, inline or inside a .ps1/.psm1 the command runs:
//      they stay inside the MSIX package even with -Verb RunAs, so their HKCU writes land in the private layer.
//      A launch through WMI Win32_Process.Create runs outside the package and passes;
//  12. rg walks of whole roots (D:\, D:\agents, D:\agents\run-evidence, D:\Codex, D:\Codex\.codex) without
//      --max-depth: each takes minutes or times out;
//  13. stopping Explorer by name (Stop-Process or taskkill naming explorer, Get-Process explorer | Stop-Process,
//      .Kill() or WMI Terminate on it), inline or inside a .ps1/.psm1 the command runs, remote ones included: it
//      skips the folder-window and file-operation checks of Restart-ExplorerShell.ps1, which is exempt;
//  14. PowerShell commands starting with a bare `bash` or `bash.exe`: it resolves to C:\WINDOWS\system32\bash.exe, the
//      WSL launcher, where the script's D:/ paths do not exist. Full paths and `wsl bash` pass.
//  15. Grep and Glob tool searches rooted at D:\agents\projects or a rule 12 root (tool_input.path, else the session
//      cwd): the tools stop ripgrep after 20 seconds and report a timeout or nothing found.
//  16. single-file deletes typed as a command (Remove-Item and its aliases, cmd del/erase, POSIX rm, [IO.File]::Delete)
//      outside the managed recycle entry: deleting files is permanent, cleanup goes through Invoke-ManagedRecycle.ps1.
//      Only command positions count, so text that names the cmdlet passes; non-file provider paths (Env:, Function:,
//      Variable:, Alias:, registry, Cert:, WSMan:) and -WhatIf pass. Scripts the command runs are not scanned.
//  17. PowerShell tool commands whose last statement is `exit` (`exit 0`, `exit $LASTEXITCODE`): the tool captures
//      the output, and exit drops object output not rendered yet together with everything printed after it, with no
//      error, although every statement ran. A closing $global:LASTEXITCODE = 0 clears the failure flag without that
//      loss. A quoted -Command payload, an exit inside braces and the Terminal panel pass.
//  18. Write and Edit tool calls whose file_path resolves into the active skills root; relative paths use the
//      session cwd and realpath follows skills-root junctions. Guarded installs run through the shell instead.
//  19. PowerShell -and, -or and -xor mixed inside one statement at one bracket depth: they share one precedence and
//      bind left to right, so `A -and B -or C -and D` runs as `((A -and B) -or C) -and D` and returns a wrong result
//      without an error. Quoted strings, here-strings and comments are text; a bracket starts a new depth.
//  20. under Set-StrictMode -Version 2 or later, `$x = <command, function or statement output>` and then $x.Count, inline
//      in a PowerShell or Terminal panel command, inside a .ps1/.psm1 the command runs, or in a .ps1/.psm1 that a Write
//      or Edit would leave behind (only traps the file did not have before): $x is $null for no output and that object
//      for one, and .Count on $null or a single string, number, file or process object throws. [array] and other
//      collection constraints or casts do not help. @(...), literals, member access, method calls, .Where()/.ForEach(),
//      Measure-Object, New-Object, hyphenated commands defined in other files and same-file functions that return one
//      dictionary, [pscustomobject] or comma-wrapped list pass; strings and comments are text.
//  21. a .ps1 the command runs (remote -ScriptPath ones included) in which a built-in cmdlet call fails parameter
//      binding: an AmbiguousParameterSet such as Split-Path -LiteralPath $p -Parent, or a NamedParameterNotFound. Each
//      script gets the -CheckOnly pre-check of Invoke-CheckedPowerShell.ps1 (StaticParameterBinder), and only its
//      parameter-error lines deny. The checks share one time budget and allow when they cannot finish; a .psm1, the
//      checked entry itself and the -ScriptPath scripts handed to it (it runs the same check first) are not checked,
//      and neither is the command text.
//  22. DeepSeek Harness.exe invoked from the PowerShell or Bash tool, inline or inside a .ps1/.psm1 the command runs
//      locally, while neither that command nor that script sets ELECTRON_RUN_AS_NODE to 1: the Electron binary then
//      starts the desktop GUI whatever the arguments (--version included), and a GUI started from the tool shell lands in
//      Claude's MSIX private layer. Invocations are the call operator or a bare path as the command, Start-Process with
//      the exe as -FilePath or first positional argument, a variable assigned text naming the exe and then invoked, a
//      pwsh -Command payload, and in Bash a command word ending in the exe name. Text that only names the exe passes,
//      as do a -ScriptPath script that Invoke-CheckedPowerShell.ps1 -CheckOnly only checks and the Terminal panel,
//      whose shell runs outside the package.
//  23. `reg delete` with a -f switch in a PowerShell, Bash or Terminal panel command: reg delete only takes /f, in Git
//      Bash //f. The rule and its fix are the Stop hook's rule 8 (claude-stop-handoff-lint.mjs).
//  24. hand_off (kind "run") commands that the shell running them cannot run: the Stop hook's rules for commands handed
//      to the user. A command starting with ! runs in Git Bash from the input box; otherwise `shell` decides, and a
//      missing one means the Terminal panel's PowerShell 7. Bash rules apply for ! or a shell naming bash, PowerShell
//      rules for a shell naming PowerShell or none, and only the rules that fail in every shell for any other shell.
//      No settings registration can reach it: the engine runs settings PreToolUse hooks in its core, beneath the
//      mods' tool.call hooks, and the handoff-status mod answers hand_off without calling next (2026-11-16). The mod
//      (0.5.1 on) pipes { tool_name, tool_input } to this script before it adds an item and refuses it on a deny.
//  25. rg with a literal .asar archive as a search path: rg reads the archive as one file, so a match is a line of
//      minified JS that names no packed file; asar_extract.py grep names the file of each match.
// The Stop hook file is imported for rules 23 and 24 after stdin is read; if it fails to load or lacks the exports,
// those two allow and the rest still run.
// Each rule's scope, workarounds and live checks are documented in
// D:\Codex\.codex\docs\agent-guidance\host-runbook\claude-code-host-hooks.md; change that page along with the rule.
// Allow = print nothing and exit 0. Deny = print a PreToolUse permissionDecision JSON and exit 0.
// Any internal error allows the command: the registration keeps onFailure=continue, so a broken guard
// never locks the shell.
import { spawnSync } from 'node:child_process'
import { readFileSync, realpathSync, statSync } from 'node:fs'
import { win32 } from 'node:path'

// The hook's payload is read before the Stop hook file is imported: a copy of that file from before 2026-11-16 runs its
// own main() on import and would read stdin first, leaving this guard an empty payload that allows everything.
const STDIN = process.argv.includes('--self-test') ? '' : readStdin()

// Rules 23 and 24 reuse the Stop hook's rules for commands handed to the user. A Stop hook file that fails to load or
// lacks one of these exports costs only those two rules here.
const lintModule = await import('./claude-stop-handoff-lint.mjs').catch(() => null)
const handoffLint = ['lintCommand', 'formatFindings', 'regDeleteForce'].every(name => typeof lintModule?.[name] === 'function')
  ? lintModule
  : null

function readStdin() {
  try {
    return readFileSync(0, 'utf8')
  } catch {
    return ''
  }
}

const MANAGED_DELETE = 'D:\\Codex\\.codex\\scripts\\invoke-safe-tree-delete.ps1'
const MANAGED_RECYCLE = 'D:\\Codex\\.codex\\scripts\\Invoke-ManagedRecycle.ps1'
const GUIDANCE = 'D:\\Codex\\.codex\\docs\\agent-guidance'
const TEXT_ONLY_HINT = '如果命令里的写法只是文本（搜索模式、提交信息），改用 Grep 工具，或把关键词拆开写。'
const MSIX_HKCU_PAGE = 'D:\\agents\\knowledge-base\\wiki\\concepts\\Claude Desktop 里 Claude Code 的 HKCU 与 AppData 写入被 MSIX 虚拟化.md'
const RESTART_EXPLORER = 'D:\\Codex\\.codex\\scripts\\Restart-ExplorerShell.ps1'
const TERMINAL_TOOL = 'mcp__terminal__run_in_terminal'
const HAND_OFF_TOOL = 'mcp__handoff-status__hand_off'

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

// Rule 16: a delete verb in command position (start, after ; | & { ( or a line break, or right after cmd /c),
// with the rest of its statement captured for the provider and -WhatIf checks.
const FILE_DELETE_COMMAND = /(?:^|[;|&{(\n]|\bcmd(?:\.exe)?\s+\/[ck]\s+["']?)\s*(?:remove-item|ri|rm|del|erase)\b([^\n;|&}]*)/gi
const FILE_DELETE_CALL = /\[(?:system\.)?io\.file\]::delete\s*\(/i
const NON_FILE_PROVIDER = /(?:^|[\s'"])(?:env|function|variable|alias|hkcu|hklm|registry|cert|wsman):/i
// Deleting inside $Recycle.Bin is emptying it by hand.
const RECYCLE_BIN_PATH = /\$Recycle\.Bin/i
const DELETE_VERB = /\b(?:remove-item|ri|rm|del|erase|rd|rmdir|unlink)\b|\bdelete\s*\(/i

// .ps1/.psm1 files the command names: single-quoted, double-quoted or bare. Rules 2, 8, 11 and 13 read the ones it runs.
const SCRIPT_REFERENCE = /'([^'\r\n]+?\.psm?1)'|"([^"\r\n]+?\.psm?1)"|([^\s'"`;|&(){}<>]+?\.psm?1)(?![\w.])/gi
const MAX_SCRIPT_BYTES = 1024 * 1024
const MAX_SCRIPTS = 5

// A command that evaluates text, pipes text into pwsh, or runs a variable or an expression may run any script it
// names, so then every reference counts.
const RUNS_UNKNOWN = [
  /\b(?:Invoke-Expression|iex)\b|\[scriptblock\]::Create\b|\.(?:AddScript|AddCommand|InvokeScript)\s*\(/i,
  /\|\s*(?:&\s*)?['"]?(?:[^\s|;'"]*[\\/])?(?:pwsh|powershell)(?:\.exe)?\b/i,
  /(?:^|[\s;|{(])[&.]\s*[$(]/,
  /(?:^|\s)-(?:f|fi|fil|file|filepath|scriptpath)['"]?\s*[,:]?\s*['"]?\$/i,
  /\b(?:Import-Module|ipmo|pwsh|powershell)(?:\.exe)?['"]?(?:\s+-\w+)*\s+['"]?\$/i
]
// Commands that read, hash, search, list, copy, move, write or delete a file without running it.
const NON_RUNNING_COMMANDS = new Set([
  'get-content', 'gc', 'cat', 'type', 'get-filehash', 'get-item', 'gi', 'get-childitem', 'gci', 'ls', 'dir',
  'test-path', 'select-string', 'sls', 'get-authenticodesignature', 'format-hex', 'fhx', 'get-command', 'gcm',
  'resolve-path', 'rvpa', 'split-path', 'join-path', 'compare-object', 'where-object', 'select-object',
  'write-output', 'write-host', 'echo', 'copy-item', 'cp', 'copy', 'cpi', 'move-item', 'mv', 'move', 'mi',
  'rename-item', 'ren', 'rni', 'set-content', 'add-content', 'ac', 'out-file', 'new-item', 'ni', 'remove-item', 'ri',
  'rm', 'del', 'erase', 'git', 'rg', 'grep', 'findstr', 'diff', 'head', 'tail', 'wc', 'sha256sum', 'md5sum',
  'certutil', 'code', 'notepad'
])
const SCRIPT_FLAG = /^-(?:f|fi|fil|file|filepath|scriptpath)[,:]?$/i
const COMMAND_FLAG = /^-(?:c|co|com|comm|comma|comman|command|cwa|commandwithargs|e|ec|en|enc|encodedcommand)$/i
const METHOD_ARGUMENT = /(?:::|\.)\w+\s*\([^()]*$/
const ASSIGNMENT = /^\s*(?:\$[\w:]+|[A-Za-z_]\w*)\s*\+?=\s*$/

// The words of the last simple command in a text, without VAR=value prefixes, and a command word's lower-case name.
function commandWords(text) {
  const words = simpleCommands(text).at(-1) || []
  const first = words.findIndex(word => !/^[A-Za-z_]\w*=/.test(word))
  return first < 0 ? [] : words.slice(first)
}

function commandName(word) {
  return (word || '').split(/[\\/]/).pop().replace(/\.exe$/i, '').toLowerCase()
}

// True when the reference right after `text` (its simple command so far) is what runs: it opens the command, follows
// & or ., follows -File (or a prefix), -FilePath or -ScriptPath, follows Import-Module, or is pwsh/powershell's script.
function runsHere(text) {
  if (!text.trim() || /(?:^|[\s;|{(])[&.]\s*$/.test(text)) return true
  const words = commandWords(text)
  if (SCRIPT_FLAG.test(words.at(-1) || '')) return true
  const name = commandName(words[0])
  if (name === 'import-module' || name === 'ipmo') return true
  return (name === 'pwsh' || name === 'powershell') && !words.slice(1).some(word => COMMAND_FLAG.test(word))
}

function readsOnly(text) {
  return NON_RUNNING_COMMANDS.has(commandName(commandWords(text)[0]))
}

// Splits the text before `index` at ; | newlines { } && and grouping parens outside quotes; a paren right after a
// name or ] opens a method call and does not split. Returns the simple command up to the reference and, when the
// reference sits inside a longer quoted string, that string's own text up to it.
function referenceContext(command, index) {
  let start = 0
  let quote = ''
  let quoteStart = -1
  let innerStart = -1
  for (let i = 0; i < index; i++) {
    const ch = command[i]
    if (quote && ch === quote) { quote = ''; continue }
    if (!quote && (ch === '"' || ch === "'")) { quote = ch; quoteStart = i; innerStart = i + 1; continue }
    const doubled = ch === '&' && command[i + 1] === '&'
    if (/[;|\r\n{}]/.test(ch) || doubled || (ch === '(' && !/[\w\]]/.test(command[i - 1] || ''))) {
      if (doubled) i++
      if (quote) innerStart = i + 1
      else start = i + 1
    }
  }
  return quote ? { outer: command.slice(start, quoteStart), inner: command.slice(innerStart, index) }
    : { outer: command.slice(start, index), inner: null }
}

// A reference counts unless it only names the file: an argument of a command that reads, copies, writes or searches
// it (Get-FileHash x.ps1, git diff -- x.ps1), a value being assigned, or a .NET method argument such as
// [Parser]::ParseFile('x.ps1', ...). Inside a longer quoted string, a string that opens the statement or belongs to
// such a reading command is text (git commit -m "..."); any other string is a payload (pwsh -Command "...",
// bash -c '...', CommandLine = '...') and the reference is judged inside it.
function runsScriptAt(command, index) {
  const { outer, inner } = referenceContext(command, index)
  const runs = text => runsHere(text) || !(METHOD_ARGUMENT.test(text) || ASSIGNMENT.test(text) || readsOnly(text))
  if (inner === null) return runs(outer)
  if (!outer.trim() || (!runsHere(outer) && readsOnly(outer))) return false
  return runs(inner)
}

const defaultIo = {
  env: process.env,
  read(path) {
    try {
      const stat = statSync(path)
      return stat.isFile() && stat.size <= MAX_SCRIPT_BYTES ? readFileSync(path, 'utf8') : null
    } catch {
      return null
    }
  },
  // Rule 21: the parameter-error line that the checked entry's -CheckOnly prints for a script; null when the script
  // passes, fails another check first, or the entry cannot start or finish within `timeout` ms.
  parameterError(path, timeout) {
    const result = spawnSync(PWSH, ['-NoProfile', '-NonInteractive', '-File', CHECKED_POWERSHELL, '-ScriptPath', path, '-CheckOnly'],
      { encoding: 'utf8', windowsHide: true, timeout, stdio: ['ignore', 'ignore', 'pipe'] })
    if (result.status !== 2) return null
    return String(result.stderr || '').split(/\r?\n/).find(line => line.startsWith('CheckedPowerShell parameter-error ')) || null
  }
}

// Absolute paths of up to MAX_SCRIPTS scripts the command runs; Git Bash /d/x becomes D:/x, relative paths use cwd.
// A run script that cannot be read may be a copy the command makes first, so then every named script counts.
function referencedScripts(command, cwd, io) {
  const every = RUNS_UNKNOWN.some(pattern => pattern.test(command))
  const named = []
  for (const match of command.matchAll(SCRIPT_REFERENCE)) {
    const raw = (match[1] || match[2] || match[3]).replace(/^\/([a-z])(?=\/)/i, (_, drive) => `${drive}:`)
    const path = win32.resolve(cwd || '.', raw)
    const runs = every || runsScriptAt(command, match.index)
    const seen = named.find(script => script.path.toLowerCase() === path.toLowerCase())
    if (seen) seen.runs ||= runs
    else named.push({ path, runs })
  }
  const run = named.filter(script => script.runs)
  return (run.some(script => io.read(script.path) === null) ? named : run).slice(0, MAX_SCRIPTS).map(script => script.path)
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
  for (const script of referencedScripts(command, cwd, io)) {
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
    `要用户本人执行的，请用户在 Claude Desktop 的 Terminal 面板里跑。说明见 ${MSIX_HKCU_PAGE}。` +
    '要改的条目只在私有层时（StdRegProv 读回说它不存在，Claude Desktop 却还读得到），StdRegProv 和 Terminal 面板都只碰真实 hive，改不到它，按这一页「只在私有层的条目」一节处理。' +
    TEXT_ONLY_HINT
}

// Invoke-OfficeRemote.ps1 sends its -ScriptPath script to the office or study PC over SSH; HKCU there is the real hive.
// Invoke-RemoteStep.ps1 only accepts -Target office|study and hands its -ScriptPath script to Invoke-OfficeRemote.ps1.
const REMOTE_RUNNER = /\binvoke-(?:officeremote|remotestep)\.ps1\b/i
const REMOTE_SCRIPT_ARG = /-ScriptPath\s+(?:'([^'\r\n]+)'|"([^"\r\n]+)"|([^\s'"`;|&(){}<>]+))/gi

function remoteScripts(command, cwd) {
  if (!REMOTE_RUNNER.test(command)) return []
  return [...command.matchAll(REMOTE_SCRIPT_ARG)].map(match =>
    win32.resolve(cwd || '.', (match[1] || match[2] || match[3]).replace(/^\/([a-z])(?=\/)/i, (_, drive) => `${drive}:`)).toLowerCase())
}

function isDesktop(io) {
  return /^claude-desktop/i.test(String(io.env?.CLAUDE_CODE_ENTRYPOINT || ''))
}

// Returns a reason from reasonFor when the command, or a script it runs locally, matches the test; the -ScriptPath
// script of a REMOTE_RUNNER runs on the remote PC and is skipped.
function localTextDecision(command, cwd, io, test, reasonFor) {
  if (test(command)) return reasonFor('')
  const remote = remoteScripts(command, cwd)
  for (const script of referencedScripts(command, cwd, io)) {
    if (remote.includes(script.toLowerCase())) continue
    const text = io.read(script)
    if (text && test(text)) return reasonFor(`脚本 ${script} 里：`)
  }
  return null
}

// Returns a deny reason when, under Claude Desktop, the command or a script it runs locally writes HKCU.
function hkcuDecision(command, cwd, io) {
  return isDesktop(io) ? localTextDecision(command, cwd, io, writesHkcu, hkcuReason) : null
}

// Rule 11. NSIS /D=, Inno /SILENT and /VERYSILENT, and msiexec with an install verb name an installer on their own.
// A bare uppercase /S only counts next to an installer-looking file name, because robocopy, findstr and dir take /S
// too; winget names downloads <id>_<version>_<scope>_<arch>_<type>_<locale>.exe. Uninstallers match as well: they
// rewrite the same HKCU keys. A text with Win32_Process and Create on one line launches through WMI and passes.
const INSTALLER_SIGNALS = [
  /(?:^|[\s'"(,])\/D=/,
  /(?:^|[\s'"(,])\/(?:VERY)?SILENT(?=$|[\s'",)])/i,
  /\bmsiexec(?:\.exe)?\b[^\n;|]*?[\s'"(,]\/(?:i|x|a|package|uninstall|update)(?=$|[\s'",)])/i
]
const NSIS_SILENT = /(?:^|[\s'"(,])\/S(?=$|[\s'",)])/
const INSTALLER_NAME = /(?:setup|install|_nullsoft_|_inno_|_burn_|_wix_|_exe_)[^\\/'"\s]*\.exe\b|\.msi\b/i
const WMI_CREATE = /\bWin32_Process\b[^\n]*\bCreate\b|\bCreate\b[^\n]*\bWin32_Process\b/i

function launchesInstaller(text) {
  if (WMI_CREATE.test(text)) return false
  return INSTALLER_SIGNALS.some(pattern => pattern.test(text)) || (NSIS_SILENT.test(text) && INSTALLER_NAME.test(text))
}

function installerReason(where) {
  return `${where}Claude Desktop 里工具 shell 启动的安装器（-Verb RunAs 提权的也一样）仍在 MSIX 包里：它写的 HKCU（卸载项、协议、安装目录）只进包私有层，退出码 0、shell 读回也对，真实注册表看不到。` +
    "改用 WMI 在包外启动：Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '\"<安装包>\" /S /D=<目录>' }，" +
    `要管理员权限就在提权的 pwsh 里调用；装完用 StdRegProv 从包外读回 HKCU 核对。说明见 ${MSIX_HKCU_PAGE}。${TEXT_ONLY_HINT}`
}

// Returns a deny reason when, under Claude Desktop, the command or a script it runs locally starts an installer.
function installerDecision(command, cwd, io) {
  return isDesktop(io) ? localTextDecision(command, cwd, io, launchesInstaller, installerReason) : null
}

// Rule 13. One statement must name both a kill verb and the explorer process, so `Start-Process explorer.exe` and
// `Stop-Process -Id $id; Start-Process explorer.exe` pass. Statements split on newlines and ;, after joining lines
// that a pipe or backtick continues; ExplorerShell and ExplorerPatcher are other words.
const PROCESS_KILL = /\b(?:Stop-Process|spps|kill|taskkill|tskill|pskill)\b|\.Kill\s*\(|\bTerminate\b/i
const EXPLORER_PROCESS = /\bexplorer(?:\.exe)?\b/i
const EXPLORER_EXEMPT = new Set(['restart-explorershell.ps1'])

function killsExplorer(text) {
  return text.replace(/[|`][ \t]*\r?\n|\r?\n[ \t]*\|/g, ' | ').split(/[\r\n;]+/)
    .some(statement => PROCESS_KILL.test(statement) && EXPLORER_PROCESS.test(statement))
}

function explorerReason(where) {
  return `${where}按名结束 explorer.exe 会连同文件夹窗口和进行中的复制、移动一起结束，壳没自动起来时任务栏就没了。` +
    `改用受管入口：& '${RESTART_EXPLORER}' -Mode Plan -PlanPath '<plan.json>'，120 秒内用同一 -PlanPath 跑 -Mode Apply` +
    `（要 PowerShell 7.5+，Apply 先核对身份、窗口和固定项）；只看现状用 Get-TaskbarSnapshot.ps1。说明见 ${GUIDANCE}\\host-runbook\\host-diagnostics.md。${TEXT_ONLY_HINT}`
}

// Returns a deny reason when the command, or a script it runs (a REMOTE_RUNNER -ScriptPath included: Explorer on the
// remote PC is just as live), stops Explorer by name.
function explorerDecision(command, cwd, io) {
  if (killsExplorer(command)) return explorerReason('')
  for (const script of referencedScripts(command, cwd, io)) {
    if (EXPLORER_EXEMPT.has(win32.basename(script).toLowerCase())) continue
    const text = io.read(script)
    if (text && killsExplorer(text)) return explorerReason(`脚本 ${script} 里：`)
  }
  return null
}

// A double-dash flag followed by a bare token containing a comma: PowerShell turns a,b into two argv items.
// Quoted values, variables ($x), subexpressions and splats are skipped. The value stops at a paren, so the array
// comma between subexpressions, as in `-f (git ... --short HEAD), (...)`, is not part of it.
const UNQUOTED_COMMA_LIST = /(?:^|\s)(--[a-z][\w-]*)\s+(?!['"$@({])([^\s'"`()]*,[^\s'"`]*)/i

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

// The path words of an rg simple command and whether --max-depth bounds the walk, or null when the command is not
// rg. The first positional word is the pattern unless -e/--regexp or -f/--file supplies the patterns, or --files
// needs none.
function rgArgs(words) {
  if ((words[0] || '').split(/[\\/]/).pop().replace(/\.exe$/i, '').toLowerCase() !== 'rg') return null
  const positional = []
  let patternGiven = false
  let bounded = false
  for (let i = 1; i < words.length; i++) {
    const word = words[i]
    if (word === '--') { positional.push(...words.slice(i + 1)); break }
    if (word.includes('>')) continue // redirections such as *>$null and 2>$null
    if (word.startsWith('--')) {
      const name = word.split('=')[0]
      if (name === '--regexp' || name === '--file' || name === '--files') patternGiven = true
      if (name === '--max-depth') bounded = true
      if (!word.includes('=') && RG_VALUE_LONG.has(name)) i++
    } else if (word.length > 1 && word.startsWith('-')) {
      // In a short cluster such as -nA3 or -nA 3, the first value-taking letter takes the rest or the next word.
      for (let k = 1; k < word.length; k++) {
        if (!RG_VALUE_SHORT.includes(word[k])) continue
        if (word[k] === 'e' || word[k] === 'f') patternGiven = true
        if (word[k] === 'd') bounded = true
        if (k === word.length - 1) i++
        break
      }
    } else positional.push(word)
  }
  return { paths: positional.slice(patternGiven ? 0 : 1), bounded }
}

// Returns the first rg path argument containing * or ?, or null.
function rgWildcardPath(command) {
  for (const words of simpleCommands(command)) {
    const path = rgArgs(words)?.paths.find(word => /[*?]/.test(word))
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

// Rule 12. Roots whose full walk takes minutes: D:\agents\run-evidence alone holds about 570k files, and
// D:\Codex\.codex keeps backups, session logs and a 1 GB sqlite. Git Bash /d/x becomes D:/x, relative paths use cwd,
// and words with variables or splats cannot be resolved here, so they pass.
const BROAD_ROOTS = new Set(['d:', 'd:\\agents', 'd:\\agents\\run-evidence', 'd:\\codex', 'd:\\codex\\.codex'])

function isBroadRoot(word, cwd, roots = BROAD_ROOTS) {
  if (/[$@%`]/.test(word)) return false
  const path = word.replace(/^\/([a-z])(?=\/)/i, (_, drive) => `${drive}:`).replace(/^\/([a-z])$/i, (_, drive) => `${drive}:\\`)
  return roots.has(win32.resolve(cwd || '.', path).replace(/[\\/]+$/, '').toLowerCase())
}

// Returns the first rg path argument that walks a whole broad root, or null.
function rgBroadRoot(command, cwd) {
  for (const words of simpleCommands(command)) {
    const args = rgArgs(words)
    const path = args && !args.bounded && args.paths.find(word => isBroadRoot(word, cwd))
    if (path) return path
  }
  return null
}

function rgBroadRootReason(path) {
  return `rg 要把 ${path} 整棵树走一遍：D:\\agents\\run-evidence 约 57 万个文件，D:\\Codex\\.codex 还有备份、会话记录和约 1 GB 的 sqlite，一次要几分钟甚至超时。` +
    `查谁引用某个路径用 ${GUIDANCE}\\document-retrieval.md「路径引用检索」那段脚本（约 4 秒）；查证据只搜 run-evidence 下对应的子目录；` +
    '确实要从这一层找，加 --max-depth 限深。'
}

// Rule 25. An rg path argument naming an Electron .asar archive (2026-11-15: `rg -a -o -i '.{0,260}wsl\.exe.{0,260}'` on
// app.asar returned 12,792 characters; asar_extract.py grep gave the needed part in 4,252). A directory searched with
// -g '*.asar' and app.asar.unpacked pass.
function rgAsarPath(command) {
  for (const words of simpleCommands(command)) {
    const path = rgArgs(words)?.paths.find(word => /\.asar$/i.test(word))
    if (path) return path
  }
  return null
}

function rgAsarReason(path) {
  return `rg 把 ${path} 当成一个文件整个搜：命中是一整行压缩 JS，看不出在包里哪个文件，带上下文时输出动辄上万字符。` +
    '改用 python -B -I D:\\Codex\\tools\\asar-extract\\asar_extract.py grep <asar> <正则>，每条命中带包内文件名和偏移；' +
    "--paths <正则> 只搜部分文件（如 '^out/' 跳过 node_modules），--context N 改两侧字符数。" +
    '要读整段代码时，用同一脚本的 list <asar> --grep <正则> 找文件，extract <asar> <包内路径> --out <空目录> 解到 scratchpad，再对解出的文件用 rg' +
    `（${GUIDANCE}\\windows-pwsh-command-guidelines\\rg-and-grep-tool.md）。`
}

// Rule 23. reg delete with -f fails in every shell. The Stop hook's rule 8 test runs on this guard's quote-aware split,
// so a commit message or here-string that only mentions it passes; <# #> comments are dropped, and a second pass joins
// lines continued with ` or \ (a PowerShell line can also end in a path's backslash, so the first pass keeps lines).
function regDeleteForceWords(command) {
  if (!handoffLint) return null
  const text = command.replace(/<#[\s\S]*?#>/g, ' ')
  for (const variant of new Set([text, text.replace(/[`\\]\r?\n/g, ' ')])) {
    const words = simpleCommands(variant).find(handoffLint.regDeleteForce)
    if (words) return words
  }
  return null
}

function regDeleteReason(command) {
  const words = regDeleteForceWords(command)
  return words ? `这条命令跑不通：\n${handoffLint.formatFindings([{ rule: 'regDeleteForce', line: words.join(' ') }])}\n${TEXT_ONLY_HINT}` : null
}

// Rule 24. A hand_off (kind "run") command gets the Stop hook's rules for the shell that will run it: `!` is the input
// box's Git Bash, otherwise `shell` names it, and none means the Terminal panel's PowerShell 7. A shell naming neither
// bash nor PowerShell gets only the rules that fail in every shell.
function handoffReason(input) {
  if (!handoffLint || input?.kind !== 'run' || typeof input.command !== 'string') return null
  const shell = typeof input.shell === 'string' ? input.shell.trim() : ''
  const bang = /^\s*!/.test(input.command)
  const shells = { bash: bang || /bash/i.test(shell), powershell: !bang && (!shell || /powershell|pwsh/i.test(shell)) }
  const findings = handoffLint.lintCommand(bang ? input.command.replace(/^\s*!/, '') : input.command, shells)
  if (!findings.length) return null
  const checked = bang ? '以 ! 开头，按输入框的 Git Bash 检查' : !shell ? '没写 shell，按 Terminal 面板的 PowerShell 7 检查'
    : shells.bash || shells.powershell ? `按 shell「${shell}」检查` : `shell「${shell}」不是 bash 或 PowerShell，只查哪种 shell 都跑不通的写法`
  return `hand_off 交给用户的命令（${checked}）有 ${findings.length} 处跑不通：\n${handoffLint.formatFindings(findings)}\n` +
    '改好后重新调用 hand_off；回复里给出的同一条命令也一并改掉。确属误判（比如 bash 里的 /tmp 被当成开关）时不用 hand_off，' +
    '直接在回复里给出这条命令并说明。'
}

// Rule 14. A simple command whose first word is a bare bash or bash.exe; a full path and `wsl bash` are deliberate.
function bareBash(command) {
  for (const words of simpleCommands(command)) {
    if (/^bash(?:\.exe)?$/i.test(words[0] || '')) return words[0]
  }
  return null
}

function bareBashReason(word) {
  return `PowerShell 里裸写的 ${word} 解析到 C:\\WINDOWS\\system32\\bash.exe（WSL），脚本里的 D:/ 路径在 WSL 里不存在，askpass 这类入口直接报 No such file or directory。` +
    "改用 Git Bash 全路径：& 'C:/Program Files/Git/bin/bash.exe' scripts/x.sh '参数'；PowerShell 没有 < 重定向，要喂文件给 stdin 就交给 bash：" +
    "& 'C:/Program Files/Git/bin/bash.exe' -c 'scripts/x.sh sh -s < 本地脚本'。确实要进 WSL 就写 wsl。" +
    `（${GUIDANCE}\\windows-pwsh-command-guidelines.md 第 18 条）`
}

// Rule 17. The PowerShell tool captures the command's output; an exit as the last statement drops object output not
// rendered yet and everything after it, silently (2026-11-09, pwsh 7.6.9). Only a top-level exit counts: one inside a
// quoted -Command payload or inside braces leaves the command ending in a quote or a brace.
const TRAILING_EXIT = /(?:^|[;\r\n]|&&|\|\|)\s*exit(?:\s+(?:-?\d+|\$[\w:]+))?\s*;?\s*$/i

function trailingExitReason() {
  return 'PowerShell 工具捕获输出时，命令末尾的 exit 会让还没渲染的对象输出连同它之后的全部输出消失，不报错，命令里的语句其实都执行了' +
    "（2026-11-09 pwsh 7.6.9 实测：[pscustomobject]@{k='v'}; 'x'; exit 0 什么都不显示）。" +
    '改成以 $global:LASTEXITCODE = 0 收尾：工具只在结束时 $LASTEXITCODE 非零才把命令标成失败；要区分命中与否就把 $LASTEXITCODE 写进输出。' +
    `（${GUIDANCE}\\windows-pwsh-command-guidelines.md 第 21 条）`
}

// Rule 19. PowerShell's -and, -or and -xor share one precedence and bind left to right (2026-11-13: a Where-Object
// filter for two CI watchers written as `A -and B -or C -and D` matched only one, and the wait reported both done).
// Two different ones inside one statement at one bracket depth need parentheses. Strings, here-strings, "$(...)"
// and comments are skipped as text; ; | && || and line breaks end a statement, so a condition broken across lines
// inside parentheses is not checked.
const LOGICAL_WORD = /^-(and|or|xor)(?![\w-])/i
const SINGLE_QUOTES = new Set(["'", '‘', '’', '‚', '‛'])
const DOUBLE_QUOTES = new Set(['"', '“', '”', '„'])
const CLOSER_OF = { '(': ')', '{': '}', '[': ']' }

// Index just past the `)` that closes the `$(` at s[i], strings inside skipped.
function skipSubexpressionText(s, i) {
  let depth = 0
  for (let j = i + 1; j < s.length; j++) {
    const end = skipQuotedText(s, j)
    if (end !== j) { j = end - 1; continue }
    if (s[j] === '`') { j++; continue }
    if (s[j] === '(') depth++
    else if (s[j] === ')' && --depth === 0) return j + 1
  }
  return s.length
}

// Index just past the string or here-string that starts at s[i]; the end of a comment's line; i when neither starts.
function skipQuotedText(s, i) {
  const c = s[i]
  if (c === '@' && (SINGLE_QUOTES.has(s[i + 1]) || DOUBLE_QUOTES.has(s[i + 1]))) {
    const open = /^[ \t]*\r?\n/.exec(s.slice(i + 2))
    if (open) {
      const body = i + 2 + open[0].length
      const close = (SINGLE_QUOTES.has(s[i + 1]) ? /\n['‘’‚‛]@/ : /\n["“”„]@/).exec(s.slice(body))
      return close ? body + close.index + close[0].length : s.length
    }
  }
  if (SINGLE_QUOTES.has(c)) {
    for (let j = i + 1; j < s.length; j++) {
      if (!SINGLE_QUOTES.has(s[j])) continue
      if (SINGLE_QUOTES.has(s[j + 1])) { j++; continue }
      return j + 1
    }
    return s.length
  }
  if (DOUBLE_QUOTES.has(c)) {
    for (let j = i + 1; j < s.length; j++) {
      if (s[j] === '`') { j++; continue }
      if (s[j] === '$' && s[j + 1] === '(') { j = skipSubexpressionText(s, j) - 1; continue }
      if (!DOUBLE_QUOTES.has(s[j])) continue
      if (DOUBLE_QUOTES.has(s[j + 1])) { j++; continue }
      return j + 1
    }
    return s.length
  }
  if (c === '<' && s[i + 1] === '#') {
    const end = s.indexOf('#>', i + 2)
    return end < 0 ? s.length : end + 2
  }
  if (c === '#' && (i === 0 || /[\s;|&(){}]/.test(s[i - 1]))) {
    const end = s.indexOf('\n', i)
    return end < 0 ? s.length : end
  }
  return i
}

// The statement in which two different logical operators meet at one depth, shortened; null when there is none.
export function mixedLogicalOperators(command) {
  const s = String(command)
  const frames = [{ closer: null, seen: null, start: 0 }]
  for (let i = 0; i < s.length;) {
    const end = skipQuotedText(s, i)
    if (end !== i) { i = end; continue }
    const c = s[i]
    const frame = frames[frames.length - 1]
    if (c === '`') { i += 2; continue }
    if (CLOSER_OF[c]) { frames.push({ closer: CLOSER_OF[c], seen: null, start: i + 1 }); i++; continue }
    if (c === frame.closer) { frames.pop(); i++; continue }
    const pair = s.slice(i, i + 2)
    if (c === ';' || c === '\n' || c === '|' || pair === '&&') {
      const width = pair === '&&' || pair === '||' ? 2 : 1
      frame.seen = null
      frame.start = i + width
      i += width
      continue
    }
    const word = c === '-' && (i === 0 || /[\s(){}[\];|,]/.test(s[i - 1])) ? LOGICAL_WORD.exec(s.slice(i, i + 6)) : null
    if (word) {
      const operator = word[1].toLowerCase()
      if (frame.seen && frame.seen !== operator) {
        const text = s.slice(frame.start, i + word[0].length + 40).replace(/\s+/g, ' ').trim()
        return text.length > 160 ? `${text.slice(0, 160)}…` : text
      }
      frame.seen = operator
      i += word[0].length
      continue
    }
    i++
  }
  return null
}

function mixedLogicalReason(statement) {
  return 'PowerShell 的 -and、-or、-xor 优先级相同、从左到右结合：A -and B -or C -and D 实际按 ((A -and B) -or C) -and D 求值，' +
    '不报错，只给错结果（2026-11-13 一条按命令行找两个 CI watcher PID 的 Where-Object 这样写，只匹配到一个，等待却报告两个都结束了）。' +
    `同一条语句、同一层括号里混用时给每组加括号，如 (A -and B) -or (C -and D)。命中的语句：${statement}。` + TEXT_ONLY_HINT
}

// Rule 20. Under Set-StrictMode -Version 2 or later, .Count on $null, and on a single string, number, file or process
// object, throws "The property 'Count' cannot be found on this object"; a [pscustomobject] or CIM instance gives 1
// (2026-11-14, pwsh 7.6.9). A variable that takes a command's output directly is $null when the command writes
// nothing and that object when it writes one, and [array] or other collection constraints and casts leave $null as
// $null (2026-11-13: an installer died in its backup step on `$keys = Get-SecretLikeKeys $src` then `$keys.Count`).
// Only code counts: string bodies and comments are blanked, while the $( ) inside double-quoted strings stays code.
const CONTINUES = '\x01'

// The text with string bodies and comments blanked to spaces, line breaks kept. Quotes stay, so a string still reads
// as an expression; a backtick escape becomes spaces and a backtick that continues the line becomes CONTINUES.
function powerShellCode(s) {
  const out = s.split('')
  const blank = (from, to) => { for (let k = from; k < to; k++) if (out[k] !== '\n' && out[k] !== '\r') out[k] = ' ' }
  const expandable = (from, to) => {
    for (let j = from; j < to;) {
      if (s[j] === '`') { blank(j, Math.min(j + 2, to)); j += 2 }
      else if (s[j] === '$' && s[j + 1] === '(') {
        const end = Math.min(skipSubexpressionText(s, j), to)
        code(j + 2, end - 1)
        j = end
      } else { blank(j, j + 1); j++ }
    }
  }
  const code = (from, to) => {
    for (let i = from; i < to;) {
      const c = s[i]
      if (c === '`') {
        if (s[i + 1] === '\n' || (s[i + 1] === '\r' && s[i + 2] === '\n')) { out[i] = CONTINUES; i++ }
        else { blank(i, Math.min(i + 2, to)); i += 2 }
        continue
      }
      const end = Math.min(skipQuotedText(s, i), to)
      if (end === i) { i++; continue }
      if (c === '@') {
        let body = i + 2
        while (s[body] === ' ' || s[body] === '\t') body++
        body += s[body] === '\r' ? 2 : 1
        const bodyEnd = Math.max(body, s[end - 1] === '@' && s[end - 3] === '\n' ? end - 2 : end)
        if (DOUBLE_QUOTES.has(s[i + 1])) expandable(body, bodyEnd)
        else blank(body, bodyEnd)
      } else if (SINGLE_QUOTES.has(c) || DOUBLE_QUOTES.has(c)) {
        const quotes = SINGLE_QUOTES.has(c) ? SINGLE_QUOTES : DOUBLE_QUOTES
        const bodyEnd = end - 1 > i && quotes.has(s[end - 1]) ? end - 1 : end
        if (quotes === DOUBLE_QUOTES) expandable(i + 1, bodyEnd)
        else blank(i + 1, bodyEnd)
      } else blank(i, end)
      i = end
    }
  }
  code(0, s.length)
  return out.join('')
}

const STRICT_MODE_CALL = /\bSet-StrictMode\b/gi
const STRICT_MODE_VERSION = /^[^\n;|}]*?[ \t]-v(?:e(?:r(?:s(?:i(?:o(?:n)?)?)?)?)?)?(?:[ \t]*:[ \t]*|[ \t]+)['"]?(latest|\d+(?:\.\d+)*)\b/i

// The -Version of the first Set-StrictMode in code that turns on property checks: 2 or later, or Latest. 1 and -Off
// leave .Count working on $null and single objects.
function strictModeVersion(s, code) {
  for (const match of s.matchAll(STRICT_MODE_CALL)) {
    if (code[match.index] !== s[match.index]) continue
    const version = STRICT_MODE_VERSION.exec(s.slice(match.index + match[0].length, match.index + 200))
    if (version && (/^latest$/i.test(version[1]) || parseFloat(version[1]) >= 2)) return version[1]
  }
  return null
}

// $name, $script:name or ${name}: groups 1 and 3 hold the scope, 2 and 4 the name.
const VARIABLE = String.raw`\$(?:\{(?:(script|global|local|private):)?([^{}:\r\n]+)\}|(?:(script|global|local|private):)?((?:[A-Za-z_]|[^\x00-\x7F])(?:\w|[^\x00-\x7F])*))`
const ASSIGNMENT_TARGET = new RegExp(VARIABLE + String.raw`[ \t]*=(?!=)`, 'gi')
const COUNT_READ = new RegExp(VARIABLE + String.raw`\.count(?![\w-])`, 'gi')
const LOOP_VARIABLE = new RegExp(String.raw`\bforeach[ \t]*\([ \t]*` + VARIABLE + String.raw`[ \t]+in\b`, 'gi')
const PARAMETER_LIST = /\bparam[ \t]*\(|\b(?:function|filter)[ \t]+[\w:.-]+[ \t]*\(/gi
const PARAMETER = /\$(?:(?:script|global|local|private):)?(\w+)/g
const variableName = match => (match[2] ?? match[4]).toLowerCase()
const variableScope = match => (match[1] ?? match[3] ?? '').toLowerCase()

// Words before `{` that open a block sharing the enclosing scope. Function bodies and other scriptblocks get their
// own: ForEach-Object, Where-Object, .ForEach(), .Where() and . { } assign the caller's variables, & { } and functions
// do not (2026-11-14, pwsh 7.6.9).
const SAME_SCOPE_BEFORE_BLOCK = new Set(['else', 'try', 'finally', 'do', 'begin', 'process', 'end', 'dynamicparam',
  'clean', 'catch', 'trap', 'default', 'foreach', 'foreach-object', 'where', 'where-object', '-process', '-begin',
  '-end', '-filterscript'])
const STATEMENT_BEFORE_PAREN = new Set(['if', 'elseif', 'foreach', 'for', 'while', 'switch', 'until'])
const DEFINITION = new Set(['function', 'filter', 'workflow', 'configuration'])

function skipBack(code, j, newlines) {
  while (j >= 0 && (code[j] === ' ' || code[j] === '\t' || code[j] === '\r' ||
    (newlines && (code[j] === '\n' || code[j] === CONTINUES)))) j--
  return j
}

function wordEndingAt(code, j) {
  let k = j
  while (k >= 0 && /[\w-]/.test(code[k])) k--
  return [code.slice(k + 1, j + 1), k + 1]
}

function openerBefore(code, j, open, close) {
  let depth = 0
  for (let k = j; k >= 0; k--) {
    if (code[k] === close) depth++
    else if (code[k] === open && --depth === 0) return k
  }
  return -1
}

function closerAfter(text, i, open, close) {
  let depth = 0
  for (let k = i; k < text.length; k++) {
    if (text[k] === open) depth++
    else if (text[k] === close && --depth === 0) return k
  }
  return -1
}

// 'hash' for @{, 'block' for a block that shares the enclosing scope, 'scope' for a function or scriptblock body;
// a `function Name` body also carries the lower-case name.
function blockKind(code, i) {
  const j = skipBack(code, i - 1, true)
  const c = code[j] || ''
  if (c === '@') return { kind: 'hash' }
  if (/[\].(%?}'"‘’‚‛“”„]/.test(c)) return { kind: 'block' }
  let word = ''
  let start = j + 1
  if (c === ')') {
    ;[word, start] = wordEndingAt(code, skipBack(code, openerBefore(code, j, '(', ')') - 1, false))
    while (word.startsWith('-')) [word, start] = wordEndingAt(code, skipBack(code, start - 1, false))
    if (STATEMENT_BEFORE_PAREN.has(word.toLowerCase())) return { kind: 'block' }
  } else if (/[\w-]/.test(c)) {
    ;[word, start] = wordEndingAt(code, j)
    if (SAME_SCOPE_BEFORE_BLOCK.has(word.toLowerCase())) return { kind: 'block' }
  }
  const [before] = wordEndingAt(code, skipBack(code, start - 1, false))
  return word && DEFINITION.has(before.toLowerCase()) ? { kind: 'scope', name: word.toLowerCase() } : { kind: 'scope' }
}

// Index where the target at `index` starts, [type] constraints included, when it opens a statement; -1 otherwise.
function statementTarget(code, index) {
  let start = index
  let j = skipBack(code, index - 1, false)
  while (code[j] === ']') {
    start = openerBefore(code, j, '[', ']')
    if (start < 0) return -1
    j = skipBack(code, start - 1, false)
  }
  if (j < 0) return start
  const c = code[j]
  if (c === ';' || c === '{' || c === '(') return start
  if (c === '&' || c === '|') return code[j - 1] === c ? start : -1
  if (c !== '\n') return -1
  const previous = code[skipBack(code, j - 1, false)]
  return previous !== CONTINUES && previous !== '|' ? start : -1
}

// Index where the statement starting at `from` ends: ; or a line break outside brackets, or the bracket that closes
// an enclosing group. A trailing or leading pipe, a backtick and a value on the next line continue it.
function statementEnd(code, from) {
  let depth = 0
  let i = from
  for (; i < code.length; i++) {
    const c = code[i]
    if (c === '(' || c === '{' || c === '[') depth++
    else if (c === ')' || c === '}' || c === ']') { if (depth === 0) break; depth-- }
    else if (depth === 0 && c === ';') break
    else if (depth === 0 && c === '\n') {
      const before = code.slice(from, i).replace(/[\s\x01]+$/, tail => tail.includes(CONTINUES) ? CONTINUES : '')
      if (!before.trim() || before.endsWith('|') || before.endsWith(CONTINUES)) continue
      if (/^[ \t\r\n]*\|(?!\|)/.test(code.slice(i + 1, i + 400))) continue
      break
    }
  }
  return i
}

function pipelineElements(text) {
  const parts = []
  let depth = 0
  let start = 0
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (c === '(' || c === '{' || c === '[') depth++
    else if (c === ')' || c === '}' || c === ']') depth--
    else if (depth === 0 && c === '|') {
      parts.push(text.slice(start, i))
      if (text[i + 1] === '|') i++
      start = i + 1
    }
  }
  parts.push(text.slice(start))
  return parts
}

// Statements at depth 0 of a function body, each cut at its line end.
function topLevelStatements(body) {
  const statements = []
  let depth = 0
  let atStart = true
  for (let i = 0; i < body.length; i++) {
    const c = body[i]
    if (atStart && !/\s/.test(c)) {
      const end = body.indexOf('\n', i)
      statements.push(body.slice(i, end < 0 ? body.length : end).trim())
      atStart = false
    }
    if (c === '(' || c === '{' || c === '[') depth++
    else if (c === ')' || c === '}' || c === ']') depth--
    else if (depth === 0 && (c === ';' || c === '\n')) atStart = true
  }
  return statements
}

const OUTPUT_STATEMENT = /^(?:if|switch|foreach|for|while|do|try)(?![\w-])/i
const NO_OUTPUT_KEYWORD = /^(?:function|filter|param|return|throw|exit|break|continue|class|enum|using|data|begin|process|end|trap)$/
// Commands that write one object whatever their input, so .Count reads that object's own Count.
const SINGLE_OBJECT_COMMAND = /^(?:new-object|measure-object|measure|convertfrom-stringdata|import-powershelldatafile)$/
// Built-in and inbox cmdlets that write what they find one object at a time. A hyphenated name that is neither in
// this list nor defined in the same text may be a function from another file that returns one dictionary or a
// comma-wrapped list, so it passes; a name without a hyphen is a native program or an alias.
const WRITES_ITEMS = new Set([
  'get-childitem', 'get-item', 'get-itemproperty', 'get-itempropertyvalue', 'get-content', 'get-process',
  'get-service', 'get-ciminstance', 'get-cimassociatedinstance', 'invoke-cimmethod', 'get-wmiobject', 'get-psdrive',
  'get-clipboard', 'get-hotfix', 'resolve-path', 'convert-path', 'select-object', 'where-object', 'foreach-object',
  'sort-object', 'group-object', 'compare-object', 'select-string', 'select-xml', 'get-unique', 'get-member',
  'get-random', 'get-variable', 'get-alias', 'get-filehash', 'get-pscallstack', 'get-event', 'get-error',
  'import-csv', 'convertfrom-csv', 'convertto-csv', 'convertfrom-json', 'import-clixml', 'invoke-restmethod',
  'invoke-expression', 'invoke-command', 'tee-object', 'write-output', 'get-command', 'get-module', 'get-job',
  'receive-job', 'wait-job', 'get-history', 'get-acl', 'get-authenticodesignature', 'get-winevent', 'get-counter',
  'get-scheduledtask', 'get-netadapter', 'get-netipaddress', 'get-netipconfiguration', 'get-nettcpconnection',
  'get-netudpendpoint', 'get-netroute', 'get-netfirewallrule', 'get-dnsclientserveraddress', 'get-disk',
  'get-partition', 'get-volume', 'get-physicaldisk', 'get-appxpackage', 'get-appxprovisionedpackage',
  'get-windowsoptionalfeature', 'get-pnpdevice', 'get-pnpdeviceproperty', 'get-smbshare', 'get-smbmapping',
  'get-localuser', 'get-localgroup', 'get-localgroupmember', 'get-printer', 'get-package', 'get-installedmodule',
  'find-module', 'get-pssession'
])

// True when one pipeline element writes its results one at a time; `functions` maps each function of the text to
// whether it does.
function writesItems(element, functions) {
  const text = element.trim()
  if (/^[&.](?=[\s'"‘’‚‛“”„$({])/.test(text)) return true
  if (/(?:^|\s)-NoEnumerate\b/i.test(text)) return false
  const name = (/^[^\s(){}[\];|,]+/.exec(text)?.[0] || '').split('\\').pop().toLowerCase()
  if (!/^[a-z_]/.test(name) || NO_OUTPUT_KEYWORD.test(name) || SINGLE_OBJECT_COMMAND.test(name)) return false
  if (functions.has(name)) return functions.get(name)
  if (name === 'convertfrom-json' && /\s-AsHashtable\b/i.test(text)) return false
  return WRITES_ITEMS.has(name) || !name.includes('-')
}

// True when an assignment's right side (code text) passes on what a command, script, function or statement writes.
// @(...), literals, hashtables, member access, method calls, [Type]::new() and .Where()/.ForEach() keep their own
// shape; a cast such as [array](cmd) does not.
function outputTrap(rhs, functions) {
  const text = rhs.replace(/\x01/g, ' ').trim()
  if (!text) return false
  const elements = pipelineElements(text)
  if (elements.length > 1) return writesItems(elements.at(-1), functions)
  if (/^@[({'"‘’‚‛“”„]/.test(text)) return false
  if (OUTPUT_STATEMENT.test(text)) return true
  let rest = text
  while (rest[0] === '[') {
    const close = closerAfter(rest, 0, '[', ']')
    if (close < 0) return false
    rest = rest.slice(close + 1).trimStart()
    if (!/^(?:\[|\$?\()/.test(rest)) return false
  }
  if (/^\$?\(/.test(rest)) {
    const open = rest.indexOf('(')
    const close = closerAfter(rest, open, '(', ')')
    if (close < 0 || rest.slice(close + 1).trim()) return false
    return outputTrap(rest.slice(open + 1, close), functions)
  }
  return writesItems(rest, functions)
}

const ONE_OBJECT_RETURN = /\breturn[ \t]*(?:,|(?:\[[^\]\n]*\][ \t]*)*(?:@\{|New-Object\b))|-NoEnumerate\b|\bWrite-Output[ \t]+,/i
const ONE_OBJECT_STATEMENT = /^(?:,|(?:\[[^\]\n]*\][ \t]*)*@\{|New-Object\b)/i
const DICTIONARY_VALUE = /^(?:(?:\[[^\]\n]*\][ \t]*)*@\{|\[[^\n]*?(?:Dictionary|Hashtable)[^\n]*?\]::new\(|New-Object[ \t]+(?:-TypeName[ \t]+)?[\w.]*(?:Dictionary|Hashtable|PSObject)\b)/i

// True when a function body writes one object that keeps its Count: return ,$x, -NoEnumerate, a hashtable or
// [pscustomobject] literal, New-Object, or a variable holding a dictionary, returned or written at its top level.
function returnsOneObject(body) {
  if (ONE_OBJECT_RETURN.test(body)) return true
  const dictionaries = new Set()
  for (const match of body.matchAll(/\$(?:(?:script|global|local|private):)?(\w+)[ \t]*=(?!=)[ \t]*([^\n;]*)/gi)) {
    if (DICTIONARY_VALUE.test(match[2])) dictionaries.add(match[1].toLowerCase())
  }
  const holdsDictionary = text => {
    const variable = /^\$(?:(?:script|global|local|private):)?(\w+)[ \t]*$/i.exec(text.trim())
    return Boolean(variable && dictionaries.has(variable[1].toLowerCase()))
  }
  for (const match of body.matchAll(/\breturn\b([^\n;}]*)/gi)) if (holdsDictionary(match[1])) return true
  return topLevelStatements(body).some(statement => ONE_OBJECT_STATEMENT.test(statement) || holdsDictionary(statement))
}

const lineOf = (s, index) => s.slice(0, index).split('\n').length

// Every `$x.Count` read of a strict-mode text whose value may come straight from command output. A read sees the
// assignments to its name that end before it, except those inside another function or scriptblock body (unless
// written as $script: or $global:); parameters and foreach variables count as neutral assignments. The last of them
// in a block that encloses the read always runs; it and every later one (in a branch, loop or catch) may supply the
// value, and the read counts when any of these is command output.
export function strictCountTraps(text) {
  const s = String(text)
  if (!/set-strictmode/i.test(s) || !/\.count\b/i.test(s)) return []
  const code = powerShellCode(s)
  const version = strictModeVersion(s, code)
  if (!version) return []
  const reads = [...code.matchAll(COUNT_READ)]
  if (!reads.length) return []
  const targets = [...code.matchAll(ASSIGNMENT_TARGET)]
  const loops = [...code.matchAll(LOOP_VARIABLE)]
  const parameters = []
  for (const match of code.matchAll(PARAMETER_LIST)) {
    const open = match.index + match[0].length - 1
    const close = closerAfter(code, open, '(', ')')
    if (close < 0) continue
    let at = open
    if (!/^param/i.test(match[0])) {
      let k = close + 1
      while (/[\s\x01]/.test(code[k] || '')) k++
      if (code[k] !== '{') continue
      at = k + 1
    }
    for (const parameter of code.slice(open, close).matchAll(PARAMETER)) parameters.push({ name: parameter[1].toLowerCase(), at })
  }
  const wanted = new Set([...reads, ...targets, ...loops].map(match => match.index).concat(parameters.map(p => p.at)))
  const snapshots = new Map()
  const definitions = []
  const stack = []
  for (let i = 0; i < code.length; i++) {
    if (wanted.has(i)) snapshots.set(i, stack.slice())
    const c = code[i]
    if (c === '{') {
      const entry = { ch: c, ...blockKind(code, i), start: i, end: code.length }
      if (entry.name) definitions.push(entry)
      stack.push(entry)
    } else if (c === '(' || c === '[') stack.push({ ch: c })
    else if (c === '}' || c === ')' || c === ']') {
      const open = c === '}' ? '{' : c === ')' ? '(' : '['
      for (let k = stack.length - 1; k >= 0; k--) {
        if (stack[k].ch !== open) continue
        stack[k].end = i
        stack.length = k
        break
      }
    }
  }
  const view = index => {
    const open = snapshots.get(index) || []
    const chain = open.filter(entry => entry.ch === '{' && entry.kind !== 'hash')
    return {
      chain,
      block: chain.at(-1) || null,
      scope: chain.findLast(entry => entry.kind === 'scope') || null,
      inHash: open.at(-1)?.kind === 'hash'
    }
  }
  const functions = new Map()
  for (const definition of definitions) {
    functions.set(definition.name, !returnsOneObject(code.slice(definition.start + 1, definition.end)))
  }
  const assignments = new Map()
  const add = (name, entry) => {
    if (!assignments.has(name)) assignments.set(name, [])
    assignments.get(name).push(entry)
  }
  for (const match of targets) {
    const where = view(match.index)
    const targetStart = where.inHash ? -1 : statementTarget(code, match.index)
    if (targetStart < 0) continue
    const rhsStart = match.index + match[0].length
    const end = statementEnd(code, rhsStart)
    const outer = variableScope(match) === 'script' || variableScope(match) === 'global'
    add(variableName(match), {
      end, block: where.block, scope: outer ? null : where.scope, index: match.index, targetStart, rhsStart,
      trap: outputTrap(code.slice(rhsStart, end), functions), variable: match[0].replace(/[ \t]*=$/, '')
    })
  }
  for (const match of loops) {
    const where = view(match.index)
    add(variableName(match), { end: match.index + match[0].length, block: where.block, scope: where.scope, trap: false })
  }
  for (const parameter of parameters) {
    const where = view(parameter.at)
    add(parameter.name, { end: parameter.at, block: where.block, scope: where.scope, trap: false })
  }
  for (const list of assignments.values()) list.sort((a, b) => a.end - b.end)
  const hits = []
  for (const read of reads) {
    const where = view(read.index)
    const relevant = (assignments.get(variableName(read)) || [])
      .filter(a => a.end <= read.index && (a.scope === null || where.chain.includes(a.scope)))
    const first = relevant.findLastIndex(a => a.block === null || where.chain.includes(a.block))
    const trap = relevant.slice(Math.max(first, 0)).findLast(a => a.trap)
    if (!trap) continue
    const value = s.slice(trap.rhsStart, trap.rhsStart + code.slice(trap.rhsStart, trap.end).trimEnd().length)
      .replace(/\s+/g, ' ').trim()
    const rhs = value.length > 80 ? `${value.slice(0, 80)}…` : value
    const readLine = lineOf(s, read.index)
    hits.push({
      version,
      variable: trap.variable,
      assignment: `${s.slice(trap.targetStart, trap.rhsStart).trim()} ${rhs}`,
      rhs,
      assignLine: lineOf(s, trap.index),
      readLine,
      signature: [variableName(read), value, s.split('\n')[readLine - 1].trim()].join('\n')
    })
  }
  return hits
}

function strictCountReason(where, hit) {
  return `${where}开了 Set-StrictMode -Version ${hit.version}，第 ${hit.assignLine} 行 ${hit.assignment} 让变量直接接住命令输出，` +
    `第 ${hit.readLine} 行又取 ${hit.variable}.Count。命令没有输出时变量是 $null，只输出一项时就是那一项；` +
    "严格模式下对 $null 和单个字符串、数字、文件或进程对象取 .Count 都抛 The property 'Count' cannot be found on this object，" +
    '[array]、[string[]] 这类类型约束或转换也挡不住空输出（2026-11-14 pwsh 7.6.9 实测）。' +
    `在赋值处包 @(...)：${hit.variable} = @(${hit.rhs})。只给接住命令或函数输出的变量这样包，成员访问不要包：` +
    '$x.Prop 为 $null 时 @($x.Prop).Count 是 1。' +
    `（${GUIDANCE}\\windows-pwsh-command-guidelines.md 第 5 条「集合、空值与解析的常见陷阱」第一项，第 56 行；成员访问的反例在第 62 行）`
}

// Returns a deny reason when a PowerShell command, or a script the command runs (a remote -ScriptPath one included:
// the trap is the same there), reads .Count of a variable that took command output under strict mode.
function strictCountDecision(command, tool, cwd, io) {
  if (tool === 'PowerShell' || tool === TERMINAL_TOOL) {
    const hit = strictCountTraps(command)[0]
    if (hit) return strictCountReason('', hit)
  }
  for (const script of referencedScripts(command, cwd, io)) {
    const text = io.read(script)
    const hit = text ? strictCountTraps(text)[0] : null
    if (hit) return strictCountReason(`脚本 ${script} 里：`, hit)
  }
  return null
}

// Write and Edit of a .ps1/.psm1: the file as it would be after the call, denied for traps the file did not already
// have, so an unrelated edit to a script with an old trap passes and the run-time check above still covers it.
function strictCountWriteReason(tool, payload, io) {
  const input = payload?.tool_input || {}
  const filePath = String(input.file_path || '')
  if (!/\.psm?1$/i.test(filePath)) return null
  const path = win32.resolve(String(payload?.cwd || ''), filePath)
  const lf = text => String(text ?? '').replace(/\r\n/g, '\n')
  const before = io.read(path)
  let after
  if (tool === 'Write') after = lf(input.content)
  else {
    const current = lf(before)
    const oldText = lf(input.old_string)
    if (before === null || !oldText || !current.includes(oldText)) return null
    const newText = lf(input.new_string)
    after = input.replace_all ? current.split(oldText).join(newText) : current.replace(oldText, () => newText)
  }
  if (after.length > MAX_SCRIPT_BYTES) return null
  const known = new Set(before === null ? [] : strictCountTraps(lf(before)).map(hit => hit.signature))
  const hit = strictCountTraps(after).find(trap => !known.has(trap.signature))
  return hit ? strictCountReason(`${tool} 要写入的 ${path} 里：`, hit) : null
}

// Rule 18. Write and Edit tool calls that target the active skills root must go through the guarded install entry.
const SKILLS_ROOT = 'D:\\agents\\skills-manager\\skills'

function skillsRootWriteReason(tool, payload) {
  const filePath = String(payload?.tool_input?.file_path || '')
  if (!filePath) return null
  const absolute = win32.resolve(String(payload?.cwd || ''), filePath)
  let resolved = absolute
  try { resolved = realpathSync(absolute) } catch {
    // A new write target does not exist yet; its parent still resolves a skills-root junction.
    try { resolved = win32.join(realpathSync(win32.dirname(absolute)), win32.basename(absolute)) } catch {}
  }
  const normalized = resolved.replace(/\//g, '\\')
  if (!normalized.toLowerCase().startsWith(SKILLS_ROOT.toLowerCase() + '\\')) return null
  return `${tool} 要直接改现役 skills 根（${SKILLS_ROOT}）。skill 的安装、更新和重写只能走受管入口 ` +
    'D:\\Codex\\.codex\\scripts\\install-skill-guarded.ps1（先 --dry-run 再 apply）。' +
    '请先在候选目录里改好，再用受管入口安装。'
}

// Rule 15. The Grep and Glob tools stop ripgrep after 20 seconds and then report a timeout or "No files found", so a
// walk of D:\agents\projects (every project's node_modules, .venv and build output) fails as the rule 12 roots do.
// PowerShell rg has no such limit, which is why rule 12 lets it walk D:\agents\projects. The search root is
// tool_input.path, else the session cwd.
const SEARCH_TOOL_ROOTS = new Set([...BROAD_ROOTS, 'd:\\agents\\projects'])

function searchToolReason(tool, payload) {
  const path = String(payload?.tool_input?.path || '')
  const root = path || String(payload?.cwd || '')
  if (!root || !isBroadRoot(root, payload?.cwd, SEARCH_TOOL_ROOTS)) return null
  return `${tool} 工具要把 ${root}${path ? ' ' : '（没给 path，默认搜会话目录）'}整棵树走一遍，内置 ripgrep 20 秒就停，只回超时或 No files found。` +
    "按名字找项目先列目录名：Get-ChildItem -LiteralPath 'D:/agents/projects' -Directory -Name（约 2 秒）；" +
    '知道在哪个项目就把 path 指到那个项目目录；确实要跨项目搜内容，改用 PowerShell 里的 rg，它没有 20 秒上限' +
    '（整个 D:\\agents\\projects 约 45 秒；D:\\agents 及更上层的根要加 --max-depth，否则同样被拦）。'
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

// Inside a quoted string a delete verb is text when the string opens its statement or belongs to a command that only
// reads or prints it (rg -n '...|rm)', git commit -m '...; rm x'), and a payload in any other string (bash -c '...',
// cmd /c "..."); $( runs its contents even inside double quotes.
function deletesAt(command, match) {
  const [whole, rest] = match
  if (/\s-whatif\b/i.test(rest) || NON_FILE_PROVIDER.test(rest)) return false
  if (command[match.index] === '(' && command[match.index - 1] === '$') return true
  const { outer, inner } = referenceContext(command, match.index + whole.length - rest.length)
  const text = inner !== null && (!outer.trim() || (!runsHere(outer) && readsOnly(outer)))
  return !text
}

function fileDeleteDecision(command) {
  if (/invoke-managedrecycle|invoke-safe-tree-delete/i.test(command)) return null
  const typed = FILE_DELETE_CALL.test(command) || [...command.matchAll(FILE_DELETE_COMMAND)].some(match => deletesAt(command, match))
  if (!typed) return null
  return `删除文件是永久删除，只走受管回收 ${MANAGED_RECYCLE}（Plan → Apply，说明见 ${GUIDANCE}\\host-runbook\\managed-recycle.md）。` +
    '临时文件放会话 scratchpad，用完不必删；要清理的散文件先移进一个子目录，再整目录回收。Env:、Function:、Variable: 等非文件路径和 -WhatIf 放行。' +
    TEXT_ONLY_HINT
}

// Rule 21. A built-in cmdlet call whose parameter set cannot be resolved (Split-Path -LiteralPath $p -Parent) or that
// names a missing parameter fails only when the script reaches it, after the statements before it ran (2026-11-15: a
// cleanup script run with pwsh -File died on Split-Path -LiteralPath $link.FullName -Parent). Each .ps1 the command runs
// gets the checked entry's -CheckOnly, which binds the cmdlets of the modules that ship with pwsh through
// StaticParameterBinder. The entry stops at its first failing check, so a syntax, regex or native-argument error earlier
// in the same script hides a parameter error; only parameter-error lines deny here. The entry reads .ps1 files only, and
// the command text itself is not checked because one pwsh start costs about half a second.
const PWSH = 'D:\\Codex\\tools\\PowerShell\\7.6.9\\pwsh.exe'
const CHECKED_POWERSHELL = 'D:\\Codex\\.codex\\scripts\\Invoke-CheckedPowerShell.ps1'
const PARAMETER_CHECK_BUDGET_MS = 6000
const PARAMETER_CHECK_MIN_MS = 1000
// Invoke-CheckedPowerShell.ps1 as a word of a simple command, run directly or as pwsh's -File.
const CHECKED_ENTRY = /(?:^|[\\/])invoke-checkedpowershell\.ps1$/i

// Lower-case resolved paths of the -ScriptPath scripts that commands hand to Invoke-CheckedPowerShell.ps1; with
// checkOnly, only those of calls that pass -CheckOnly. The entry runs rule 21's check on such a script before it runs
// it, and with -CheckOnly does not run it at all. A path held in a variable or an expression is not matched.
function checkedEntryScripts(command, cwd, checkOnly) {
  if (!/invoke-checkedpowershell\.ps1/i.test(command)) return []
  const scripts = []
  for (const words of powerShellWords(command)) {
    const entry = words.findIndex(word => CHECKED_ENTRY.test(word.value.trim()))
    if (entry < 0) continue
    const rest = words.slice(entry + 1)
    if (checkOnly && !rest.some(word => /^-CheckOnly(?::\$true)?$/i.test(word.raw))) continue
    const flag = rest.findIndex(word => /^-ScriptPath(?::|$)/i.test(word.raw))
    if (flag < 0) continue
    const value = /^-ScriptPath:/i.test(rest[flag].raw) ? rest[flag].value.slice('-ScriptPath:'.length) : rest[flag + 1]?.value
    if (!value || /[$`(]/.test(value)) continue
    scripts.push(win32.resolve(cwd || '.', value.replace(/^\/([a-z])(?=\/)/i, (_, drive) => `${drive}:`)).toLowerCase())
  }
  return scripts
}

function parameterReason(script, diagnostic) {
  return `脚本 ${script} 没过参数预检：${diagnostic}（行列指这个脚本）。这类错误要运行到那一行才报，前面的语句已经执行了。` +
    '参数集定不下来（AmbiguousParameterSet）常见于 Split-Path -LiteralPath $p -Parent 或 -Leaf：-LiteralPath 只能单用，' +
    '取父目录、文件名改用 [IO.Path]::GetDirectoryName($p)、[IO.Path]::GetFileName($p) 或 -Path；参数名不存在（NamedParameterNotFound）就改成该 cmdlet 真有的参数。' +
    `改完用 & '${CHECKED_POWERSHELL}' -ScriptPath '${script}' -CheckOnly 复查（${GUIDANCE}\\windows-pwsh-command-guidelines.md「受检执行入口」的参数预检段）。`
}

// Returns a deny reason when a .ps1 the command runs fails the parameter pre-check. The checks of one command share a
// time budget; a script the budget no longer covers, and one whose check cannot finish, is allowed. Scripts handed to
// the checked entry's -ScriptPath are left to the entry.
function parameterDecision(command, cwd, io) {
  const deadline = Date.now() + PARAMETER_CHECK_BUDGET_MS
  const checked = checkedEntryScripts(command, cwd, false)
  for (const script of referencedScripts(command, cwd, io)) {
    if (!/\.ps1$/i.test(script) || win32.basename(script).toLowerCase() === 'invoke-checkedpowershell.ps1') continue
    if (checked.includes(script.toLowerCase()) || io.read(script) === null) continue
    const remaining = deadline - Date.now()
    if (remaining < PARAMETER_CHECK_MIN_MS) break
    const diagnostic = io.parameterError?.(script, remaining)
    if (diagnostic) return parameterReason(script, diagnostic)
  }
  return null
}

// Rule 22. DeepSeek Harness.exe is an Electron binary: unless ELECTRON_RUN_AS_NODE is 1 it starts the desktop GUI
// whatever the arguments (2026-11-14: a `& '<install>\DeepSeek Harness.exe' --version` preflight opened it), and a GUI
// started from the tool shell lands in Claude's MSIX private layer. Only invocations count, so filters, Test-Path, rg
// patterns and strings that name the exe pass. Setting ELECTRON_RUN_AS_NODE to 1 anywhere in the same command or
// script passes as well; a command's setting also reaches the scripts it runs.
const DSH_EXE = /deepseek harness\.exe$/i
const DSH_EXE_NAMED = /deepseek harness\.exe/i
const DSH_PAGE = 'D:\\agents\\knowledge-base\\wiki\\entities\\DeepSeek Harness.md'
// $env:X = '1', ${env:X} = 1, @{ X = '1' }, $psi.Environment['X'] = '1', SetEnvironmentVariable('X', '1'),
// Set-Item Env:X 1 or -Value 1, and X=1 in front of a bash command, export X=1 or cmd's set X=1.
const ELECTRON_NODE_MODE = /\bELECTRON_RUN_AS_NODE\b['"\]}]*(?:[ \t]*[=,:][ \t]*|[ \t]+(?:-Value[ \t]+)?)['"]?1(?![\w.])/i
const DSH_VARIABLE = /\$(?:(?:script|global|local|private):)?(\w+)[ \t]*=(?!=)([^\n;]*)/gi
const ASSIGNED_VARIABLE = /^(?:\[[^\]]*\])*\$[\w:]+$/
const EXPRESSION_START = /^['"‘’‚‛“”„$(@[]/
const START_PROCESS = new Set(['start-process', 'saps', 'start'])
const START_PROCESS_FILE = /^(?:f(?:i(?:l(?:e(?:p(?:a(?:t(?:h)?)?)?)?)?)?)?|pspath|path)$/i
const START_PROCESS_SWITCHES = ['loaduserprofile', 'lup', 'nonewwindow', 'nnw', 'passthru', 'wait', 'usenewenvironment',
  'verbose', 'vb', 'debug', 'db', 'whatif', 'wi', 'confirm', 'cf']

// The body of a string or here-string token without its quotes.
function unquote(raw) {
  if (raw[0] === '@') return raw.slice(2).replace(/^[ \t]*\r?\n/, '').replace(/\r?\n.@$/, '')
  const quotes = SINGLE_QUOTES.has(raw[0]) ? SINGLE_QUOTES : DOUBLE_QUOTES
  return raw.slice(1, raw.length > 1 && quotes.has(raw.at(-1)) ? -1 : raw.length)
}

// Index of the bracket that closes the ( or { at s[i] before `to`, strings, comments and escapes skipped; -1 if none.
function groupCloser(s, i, to) {
  let depth = 0
  for (let j = i; j < to; j++) {
    const end = skipQuotedText(s, j)
    if (end !== j) { j = end - 1; continue }
    if (s[j] === '`') { j++; continue }
    if (s[j] === '(' || s[j] === '{') depth++
    else if ((s[j] === ')' || s[j] === '}') && --depth === 0) return j
  }
  return -1
}

// The words of each simple command in PowerShell text, as { raw, value } with value's quotes taken off. Commands end at
// ; | && || ) } and line breaks outside strings; a ( ) or { } group stays inside its word, and its inside is read as
// commands too. Comments are dropped, a backtick escapes the next character, and one at a line end joins the lines.
function powerShellWords(s, from = 0, to = s.length, commands = []) {
  let words = []
  let word = null
  const add = (raw, value) => { word = word ? { raw: word.raw + raw, value: word.value + value } : { raw, value } }
  const endWord = () => { if (word) words.push(word); word = null }
  const endCommand = () => { endWord(); if (words.length) commands.push(words); words = [] }
  for (let i = from; i < to;) {
    const c = s[i]
    if (c === '`') {
      const continued = /^`\r?\n/.exec(s.slice(i, i + 3))
      if (continued) endWord()
      else add(s.slice(i, i + 2), s[i + 1] || '')
      i += continued ? continued[0].length : 2
      continue
    }
    const end = Math.min(skipQuotedText(s, i), to)
    if (end !== i) {
      if (c !== '#' && c !== '<') add(s.slice(i, end), unquote(s.slice(i, end)))
      i = end
      continue
    }
    const open = c === '(' || c === '{' ? i : (c === '$' || c === '@') && (s[i + 1] === '(' || s[i + 1] === '{') ? i + 1 : -1
    if (open >= 0) {
      const close = groupCloser(s, open, to)
      const stop = close < 0 ? to : close + 1
      add(s.slice(i, stop), s.slice(i, stop))
      powerShellWords(s, open + 1, close < 0 ? to : close, commands)
      i = stop
      continue
    }
    if (c === '&' && s[i + 1] === '&') { endCommand(); i += 2; continue }
    if (c === '&' && !word?.raw.endsWith('>')) { endWord(); words.push({ raw: '&', value: '&' }); i++; continue }
    if (/[;|\n)}]/.test(c)) endCommand()
    else if (/\s/.test(c)) endWord()
    else add(c, c)
    i++
  }
  endCommand()
  return commands
}

// The word Start-Process takes as -FilePath: the value of -FilePath (a prefix, -PSPath or -Path), else the first
// positional argument. Other parameters take the next word unless they are switches.
function startProcessFile(words) {
  for (let i = 1; i < words.length; i++) {
    const parameter = /^-([A-Za-z]+)(:?)/.exec(words[i].raw)
    if (!parameter) return words[i]
    const name = parameter[1].toLowerCase()
    const inline = parameter[2]
      ? { raw: words[i].raw.slice(parameter[0].length), value: words[i].value.slice(parameter[0].length) } : null
    if (START_PROCESS_FILE.test(name)) return inline || words[i + 1] || null
    if (!inline && !START_PROCESS_SWITCHES.some(full => full.startsWith(name))) i++
  }
  return null
}

// The words of PowerShell text that invoke DeepSeek Harness.exe: the call operator or a bare path as the command (a
// quoted path that opens a statement is an expression), Start-Process with the exe as -FilePath or first positional
// argument, a variable assigned text that names the exe and then invoked, and invocations in a pwsh -Command payload.
function dshInvocations(text) {
  if (!DSH_EXE_NAMED.test(text)) return []
  const named = new Set([...text.matchAll(DSH_VARIABLE)].filter(match => DSH_EXE_NAMED.test(match[2]))
    .map(match => match[1].toLowerCase()))
  const variable = word => /^\$(?:(?:script|global|local|private):)?(\w+)$/i.exec(word.raw)?.[1].toLowerCase()
  const invokes = word => Boolean(word) && (DSH_EXE.test(word.value.trim()) || named.has(variable(word)) ||
    (/^\$?\(/.test(word.raw) && DSH_EXE_NAMED.test(word.raw)))
  const hits = []
  for (let words of powerShellWords(text)) {
    // The right side of an assignment is a pipeline of its own: $v = & '<exe>' --version.
    if (ASSIGNED_VARIABLE.test(words[0].raw) && /^[+*\/%-]?=$/.test(words[1]?.raw || '')) words = words.slice(2)
    const called = words[0]?.raw === '&' || words[0]?.raw === '.'
    if (called) words = words.slice(1)
    const first = words[0]
    if (!first || (!called && EXPRESSION_START.test(first.raw))) continue
    const name = commandName(first.value)
    if (called ? invokes(first) : DSH_EXE.test(first.value)) hits.push(first)
    else if (START_PROCESS.has(name)) {
      const file = startProcessFile(words)
      if (invokes(file)) hits.push(file)
    } else if (name === 'pwsh' || name === 'powershell') {
      const payload = payloadWords(name, words.slice(1).map(word => ({ text: word.value })))
      hits.push(...dshInvocations(payload.map(word => word.text).join(' ')))
    }
  }
  return hits
}

// The text of a Bash command word that runs DeepSeek Harness.exe: a command word ending in the exe name after VAR=value
// prefixes and env or exec, or an invocation inside a pwsh -Command payload.
function bashDshInvocation(command) {
  if (!DSH_EXE_NAMED.test(command)) return null
  for (const { words } of bashCommands(command)) {
    let i = 0
    while (i < words.length && (/^[A-Za-z_]\w*=/.test(words[i].text) || /^(?:env|exec|command|time|nohup)$/.test(words[i].text))) i++
    if (!words[i]) continue
    if (DSH_EXE.test(words[i].text)) return words[i].text
    const name = commandName(words[i].text)
    if (name !== 'pwsh' && name !== 'powershell') continue
    const hit = dshInvocations(payloadWords(name, words.slice(i + 1)).map(word => word.text).join(' '))[0]
    if (hit) return hit.value
  }
  return null
}

function dshGuiReason(where, invoked) {
  const path = invoked.trim().replace(/^\/([a-z])(?=\/)/i, (_, drive) => `${drive}:`)
  const install = /^[a-z]:[\\/]/i.test(path) && !/[$`(]/.test(path) ? win32.dirname(win32.normalize(path)) : '<安装目录>'
  return `${where}${invoked} 没设 ELECTRON_RUN_AS_NODE=1：DeepSeek Harness.exe 是 Electron 程序，不设它时带什么参数都会启动桌面 GUI（--version 也一样），` +
    `从 Claude 的工具 shell 拉起的 GUI 还会落进 Claude 的 MSIX 包私有层（见 ${DSH_PAGE}）。` +
    `要跑 Node 脚本或查 Node 版本，用安装目录自带的 Node：& '${install}\\resources\\runtime\\primary-runtime\\dependencies\\node\\bin\\node.exe' <脚本>；` +
    `查 DSH 或包的版本用 node D:/agents/projects/dsh-plugins/dsh-compaction-256k/scripts/dsh-desktop.mjs manifest --resources '${install.replace(/\\/g, '/')}/resources' --package <包名>，` +
    "输出 JSON 的 dshVersion 就是 DSH 版本。确实要用它的 Node 模式，就在同一条命令或脚本里先设 $env:ELECTRON_RUN_AS_NODE = '1'" +
    '（Bash 写 ELECTRON_RUN_AS_NODE=1 前缀）；要开 GUI 就从开始菜单启动。' + TEXT_ONLY_HINT
}

// Returns a deny reason when the command, or a .ps1/.psm1 it runs locally, invokes DeepSeek Harness.exe while neither
// that command nor that script sets ELECTRON_RUN_AS_NODE to 1. Invoke-CheckedPowerShell.ps1 -CheckOnly does not run
// its -ScriptPath script.
function dshGuiDecision(command, tool, cwd, io) {
  if (ELECTRON_NODE_MODE.test(command)) return null
  const inline = tool === 'Bash' ? bashDshInvocation(command) : dshInvocations(command)[0]?.value
  if (inline) return dshGuiReason('', inline)
  const skipped = [...remoteScripts(command, cwd), ...checkedEntryScripts(command, cwd, true)]
  for (const script of referencedScripts(command, cwd, io)) {
    if (skipped.includes(script.toLowerCase())) continue
    const text = io.read(script)
    const hit = text && !ELECTRON_NODE_MODE.test(text) ? dshInvocations(text)[0] : null
    if (hit) return dshGuiReason(`脚本 ${script} 里：`, hit.value)
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
  if (tool === 'Grep' || tool === 'Glob') return searchToolReason(tool, payload)
  // Rule 18: direct writes to the active skills root must go through the guarded install entry; rule 20 for scripts.
  if (tool === 'Write' || tool === 'Edit') return skillsRootWriteReason(tool, payload) || strictCountWriteReason(tool, payload, io)
  if (tool === HAND_OFF_TOOL) return handoffReason(payload?.tool_input)
  const command = String(payload?.tool_input?.command || '')
  const terminal = tool === TERMINAL_TOOL
  if (!command || (tool !== 'PowerShell' && tool !== 'Bash' && !terminal)) return null

  // First, so `Remove-Item HKCU:\x -Recurse` gets the registry reason rather than the safe-tree-delete one.
  // The Terminal panel's shell runs outside the MSIX package, where HKCU writes and installers are real.
  if (!terminal) {
    const hkcu = hkcuDecision(command, payload?.cwd, io)
    if (hkcu) return hkcu
    const installer = installerDecision(command, payload?.cwd, io)
    if (installer) return installer
  }

  if (!/invoke-safe-tree-delete/i.test(command) && RECURSIVE_DELETE_PATTERNS.some(pattern => pattern.test(command))) {
    return `递归删除目录只能走受管入口 ${MANAGED_DELETE}（Plan → Apply → Purge，说明见 ${GUIDANCE}\\host-runbook\\safe-tree-delete.md）。` +
      '如果命令里的删除写法只是文本（搜索模式、提交信息），改用 Grep 工具，或把关键词拆开写。'
  }

  const recycle = recycleDecision(command, payload?.cwd, io)
  if (recycle) return recycle
  const explorer = explorerDecision(command, payload?.cwd, io)
  if (explorer) return explorer
  // Rule 22. The Terminal panel's shell runs outside the MSIX package, where a GUI it starts is a normal launch.
  const dshGui = terminal ? null : dshGuiDecision(command, tool, payload?.cwd, io)
  if (dshGui) return dshGui
  const fileDelete = fileDeleteDecision(command)
  if (fileDelete) return fileDelete

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

  if (tool === 'PowerShell' || terminal) {
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
    const bash = bareBash(command)
    if (bash) return bareBashReason(bash)
    const mixed = mixedLogicalOperators(command)
    if (mixed) return mixedLogicalReason(mixed)
    if (!terminal && TRAILING_EXIT.test(command)) return trailingExitReason()
  }

  const regDelete = regDeleteReason(command)
  if (regDelete) return regDelete
  const broad = rgBroadRoot(command, payload?.cwd)
  if (broad) return rgBroadRootReason(broad)
  const asar = rgAsarPath(command)
  if (asar) return rgAsarReason(asar)

  const source = hardlinkingCloneSource(command)
  if (source) {
    return `git clone 的源 ${source} 是本地路径：同盘本地克隆默认把源库 .git/objects 硬链进克隆，受管 safe-tree-delete 拒绝硬链文件，克隆建成后就删不掉了。` +
      '加 --no-hardlinks 后重试（--no-local 或 file:// 源也行）。如果这只是文本（提交信息、搜索模式），改用 Grep 工具，或把关键词拆开写。'
  }
  // Rule 21 goes last: it starts pwsh, so every cheaper rule answers first.
  return strictCountDecision(command, tool, payload?.cwd, io) || parameterDecision(command, payload?.cwd, io)
}

function main() {
  let payload
  try {
    payload = JSON.parse(STDIN || '{}')
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
    ['PowerShell', 'Remove-Item -LiteralPath D:\\x\\a.txt', true],
    ['PowerShell', "foreach ($ref in 'a', 'b') { $tmp = New-TemporaryFile; Remove-Item -LiteralPath $tmp.FullName -Confirm:$false }", true],
    ['PowerShell', 'Get-ChildItem D:\\x -Filter *.tmp | Remove-Item', true],
    ['PowerShell', 'cmd /c del D:\\x\\a.txt', true],
    ['PowerShell', 'cmd.exe /c "del D:\\x\\a.txt"', true],
    ['Bash', 'test -f a.txt && rm a.txt', true],
    ['Bash', 'git rm --cached a.txt', false],
    ['PowerShell', "git log --oneline --grep 'rm stale'", false],
    ['PowerShell', '[System.IO.File]::Delete($p)', true],
    ['mcp__terminal__run_in_terminal', 'Remove-Item D:\\x\\a.txt', true],
    ['PowerShell', 'Remove-Item Env:IMPECCABLE_BIN', false],
    ['PowerShell', "Remove-Item -LiteralPath 'Function:\\Get-Foo'", false],
    ['PowerShell', 'Remove-Item D:\\x\\a.txt -WhatIf', false],
    ['PowerShell', "Write-Output 'Remove-Item D:\\x\\a.txt'", false],
    ['PowerShell', `rg -n 'git(_text)?\\(repo, "(ls-tree|update-index|add|rm)"' 'D:\\x\\helper.py'`, false],
    ['Bash', "rg -n '(rm|del)' notes.txt", false],
    ['PowerShell', "git commit -m 'drop the scratch copy; rm is no longer needed'", false],
    ['PowerShell', '(Get-ChildItem D:\\x -Filter *.tmp | rm)', true],
    ['PowerShell', 'Get-ChildItem D:\\x | Remove-Item; Write-Output done', true],
    ['Bash', "bash -c 'cd /d/x; rm a.txt'", true],
    ['PowerShell', 'pwsh -NoProfile -Command "Get-ChildItem D:\\x | Remove-Item"', true],
    ['PowerShell', 'Write-Output "$(Remove-Item D:\\x\\a.txt)"', true],
    ['PowerShell', 'Remove-ItemProperty -LiteralPath HKLM:\\Software\\X -Name y', false],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-ManagedRecycle.ps1' -Mode Plan -TargetPath D:\\x\\a.txt", false],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\invoke-safe-tree-delete.ps1' -Mode Plan -TargetPaths D:\\x", false],
    ['Bash', 'rm file.txt', true],
    ['Bash', 'git rm --cached a.txt', false],
    ['PowerShell', 'git rm -r --cached .scratch/out', false],
    ['Bash', 'git rm -r --cached dist', false],
    ['PowerShell', 'gh issue list --json number,title', true],
    ['PowerShell', 'gh issue create --blocked-by 27,28', true],
    ['PowerShell', "gh issue list --json 'number,title'", false],
    ['PowerShell', 'gh issue list --json $fields', false],
    ['PowerShell', 'Select-Object Name,Length', false],
    ['PowerShell', '"{0} {1}" -f (git -C a rev-parse --short HEAD), (git -C b rev-parse --short HEAD)', false],
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
    ['PowerShell', "Remove-Item -LiteralPath D:\\x\\a.txt -WhatIf; Get-ItemProperty -LiteralPath 'HKCU:\\Console'", false, desktop],
    ['PowerShell', "[Environment]::SetEnvironmentVariable('CI', $Ci)", false, desktop],
    ['Bash', "grep -nE 'Set-ItemProperty|New-ItemProperty|HKCU|HKLM' tools/x.ps1", false, desktop],
    ['PowerShell', "pwsh -File 'D:\\repo\\tools\\harmless.ps1'", false, desktop],
    // Invoke-OfficeRemote.ps1 runs its -ScriptPath script on the remote PC; scripts run locally are still checked,
    // and the Recycle Bin rule still applies to the remote script.
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-OfficeRemote.ps1' -ScriptPath 'D:\\repo\\tools\\docker_off.ps1'", false, desktop],
    ['PowerShell', "& 'D:/Codex/.codex/scripts/Invoke-OfficeRemote.ps1' -Target study -ScriptPath D:/repo/tools/docker_off.ps1 -TimeoutSeconds 120", false, desktop],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-OfficeRemote.ps1' -ScriptPath 'D:\\repo\\tools\\harmless.ps1'; pwsh -File 'D:\\repo\\tools\\docker_off.ps1'", true, desktop],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-OfficeRemote.ps1' -ScriptPath 'D:\\repo\\tools\\recycle.ps1'", true],
    // Invoke-RemoteStep.ps1 hands -ScriptPath to Invoke-OfficeRemote.ps1, so the same split applies.
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-RemoteStep.ps1' -Target office -ScriptPath 'D:\\repo\\tools\\docker_off.ps1' -WriteOperation -IncludeOutput", false, desktop],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-RemoteStep.ps1' -Target study -ScriptPath 'D:\\repo\\tools\\recycle.ps1' -WriteOperation", true],
    ['PowerShell', "Set-ItemProperty -LiteralPath 'HKCU:\\Software\\X' -Name a -Value 1", false, { CLAUDE_CODE_ENTRYPOINT: 'cli' }],
    ['PowerShell', "Set-ItemProperty -LiteralPath 'HKCU:\\Software\\X' -Name a -Value 1", false],
    // Only scripts the command runs are read; naming one to hash, copy, search, parse, assign or quote it is text.
    ['PowerShell', "Get-FileHash -LiteralPath 'D:\\repo\\tools\\docker_off.ps1'", false, desktop],
    ['PowerShell', "Copy-Item -LiteralPath 'D:\\repo\\tools\\docker_off.ps1' -Destination 'D:\\x\\copy.ps1'", false, desktop],
    ['PowerShell', "$p = 'D:\\repo\\tools\\docker_off.ps1'; (Get-Item -LiteralPath $p).Length", false, desktop],
    ['PowerShell', "[System.Management.Automation.Language.Parser]::ParseFile('D:\\repo\\tools\\docker_off.ps1', [ref]$null, [ref]$e)", false, desktop],
    ['PowerShell', "git diff -- tools/docker_off.ps1; rg -n 'HKCU' tools\\docker_off.ps1", false, desktop],
    ['PowerShell', 'pwsh -NoProfile -Command "Get-FileHash \'D:\\repo\\tools\\docker_off.ps1\'"', false, desktop],
    ['PowerShell', 'git commit -m "fix: tools/docker_off.ps1 keeps the flag"', false, desktop],
    ['PowerShell', "Get-Content 'D:\\repo\\tools\\recycle.ps1'; Get-FileHash D:\\repo\\tools\\restart-explorer.ps1", false],
    ['Bash', 'sha256sum /d/repo/tools/recycle.ps1 && cp /d/repo/tools/recycle.ps1 /d/x/', false],
    ['PowerShell', "& 'D:\\repo\\tools\\docker_off.ps1'", true, desktop],
    ['PowerShell', 'D:\\repo\\tools\\docker_off.ps1 -Apply', true, desktop],
    ['PowerShell', 'cd D:\\repo && .\\tools\\docker_off.ps1', true, desktop],
    ['PowerShell', "$r = & 'D:\\repo\\tools\\docker_off.ps1'", true, desktop],
    ['PowerShell', 'pwsh -NoProfile -Command "& \'D:\\repo\\tools\\docker_off.ps1\'"', true, desktop],
    ['PowerShell', 'pwsh -NoProfile D:\\repo\\tools\\docker_off.ps1', true, desktop],
    ['PowerShell', "Start-Process pwsh -ArgumentList '-NoProfile', '-File', 'D:\\repo\\tools\\docker_off.ps1' -Wait", true, desktop],
    ['PowerShell', 'Invoke-Command -FilePath D:\\repo\\tools\\docker_off.ps1', true, desktop],
    ['PowerShell', "Import-Module -Force 'D:\\repo\\tools\\docker_off.ps1'", true, desktop],
    ['PowerShell', "Invoke-Expression (Get-Content -Raw 'D:\\repo\\tools\\docker_off.ps1')", true, desktop],
    ['PowerShell', "Get-Content 'D:\\repo\\tools\\docker_off.ps1' -Raw | pwsh -Command -", true, desktop],
    ['PowerShell', "$s = 'D:\\repo\\tools\\docker_off.ps1'; & $s", true, desktop],
    ['PowerShell', "Get-FileHash 'D:\\repo\\tools\\harmless.ps1'; pwsh -File 'D:\\repo\\tools\\docker_off.ps1'", true, desktop],
    ['PowerShell', "Copy-Item 'D:\\repo\\tools\\docker_off.ps1' 'D:\\t\\off.ps1'; & 'D:\\t\\off.ps1'", true, desktop],
    ['Bash', "pwsh -NoProfile -c \"& '/d/repo/tools/recycle.ps1'\"", true],
    // Installers the tool shell starts under Claude Desktop stay in the package, elevated or not; WMI launches pass.
    ['PowerShell', "Start-Process -FilePath 'D:\\x\\UU_4.44.1.3978_User_X64_nullsoft_en-US.exe' -ArgumentList '/S','/D=D:\\Program Files\\Netease' -Verb RunAs -Wait", true, desktop],
    ['PowerShell', "& 'D:\\x\\Grok_Bot_0.77.0_Setup.exe' /S", true, desktop],
    ['PowerShell', 'msiexec /i D:\\x\\a.msi /qn', true, desktop],
    ['PowerShell', "Start-Process msiexec -ArgumentList '/i', $msi, '/qn' -Wait", true, desktop],
    ['PowerShell', '& $setup /VERYSILENT /SUPPRESSMSGBOXES', true, desktop],
    ['PowerShell', "& 'D:\\x\\GameViewer\\Uninstall.exe' /S", true, desktop],
    ['PowerShell', "pwsh -NoProfile -File 'D:\\repo\\tools\\install.ps1'", true, desktop],
    ['PowerShell', "Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '\"D:\\x\\a_Setup.exe\" /S /D=D:\\y' }", false, desktop],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-CheckedPowerShell.ps1' -ScriptPath 'D:\\repo\\tools\\install-wmi.ps1'", false, desktop],
    ['PowerShell', 'robocopy D:\\a D:\\b /S /E', false, desktop],
    ['PowerShell', 'findstr /S /I setup *.txt', false, desktop],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-OfficeRemote.ps1' -ScriptPath 'D:\\repo\\tools\\install.ps1'", false, desktop],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-RemoteStep.ps1' -Target office -ScriptPath 'D:\\repo\\tools\\install.ps1' -WriteOperation -IncludeOutput", false, desktop],
    ['PowerShell', "& 'D:\\x\\Grok_Bot_0.77.0_Setup.exe' /S", false, { CLAUDE_CODE_ENTRYPOINT: 'cli' }],
    // rg walks of whole roots take minutes; narrower paths, --max-depth and unresolvable variables pass.
    ['PowerShell', "rg -l -i -F 'NetEase.UURemote' D:/agents D:/Codex/.codex/docs", true],
    ['PowerShell', 'rg -n foo D:\\agents\\run-evidence', true],
    ['PowerShell', "rg -n foo 'D:\\agents\\'", true],
    ['PowerShell', 'rg --files D:\\Codex\\.codex', true],
    ['PowerShell', 'rg -l foo D:\\', true],
    ['Bash', 'rg -n foo /d/agents', true],
    ['PowerShell', 'rg -n foo D:\\agents\\projects', false],
    ['PowerShell', 'rg -n foo D:\\agents\\run-evidence\\sn580', false],
    ['PowerShell', 'rg --max-depth 2 --files D:\\agents', false],
    ['PowerShell', 'rg -d 1 -l foo D:\\agents', false],
    ['PowerShell', 'rg -F -l $name -- @roots', false],
    ['Bash', 'rg -n foo /d/agents/knowledge-base', false],
    // Stopping Explorer by name, inline and in referenced scripts; the managed restart entry and other words pass.
    ['PowerShell', 'Stop-Process -Name explorer -Force', true],
    ['PowerShell', 'Get-Process explorer | Stop-Process', true],
    ['PowerShell', 'Get-Process -Name explorer |\n    Stop-Process -Force', true],
    ['PowerShell', '(Get-Process explorer).Kill()', true],
    ['PowerShell', 'spps -n explorer', true],
    ['PowerShell', 'taskkill /f /im explorer.exe', true],
    ['Bash', 'taskkill //F //IM explorer.exe', true],
    ['PowerShell', "Get-CimInstance Win32_Process -Filter \"Name='explorer.exe'\" | Invoke-CimMethod -MethodName Terminate", true],
    ['PowerShell', "pwsh -NoProfile -File 'D:\\repo\\tools\\restart-explorer.ps1'", true],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-OfficeRemote.ps1' -ScriptPath 'D:\\repo\\tools\\restart-explorer.ps1'", true],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-RemoteStep.ps1' -Target office -ScriptPath 'D:\\repo\\tools\\restart-explorer.ps1' -WriteOperation", true],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Restart-ExplorerShell.ps1' -Mode Apply -PlanPath 'D:\\agents\\run-evidence\\taskbar-plan.json'", false],
    ['PowerShell', "Start-Process explorer.exe 'D:\\x'", false],
    ['PowerShell', 'Get-Process explorer | Select-Object Id, StartTime', false],
    ['PowerShell', 'Stop-Process -Id $child.Id; Start-Process explorer.exe', false],
    ['PowerShell', 'Stop-Process -Name ExplorerPatcher', false],
    // A bare bash in PowerShell starts WSL; full paths, wsl and text pass, and the Bash tool's bash is Git Bash.
    ['PowerShell', "bash scripts/rssh.sh 'uptime'", true],
    ['PowerShell', 'bash.exe -n scripts/bessh.sh', true],
    ['PowerShell', "Get-Date; bash -c 'ls'", true],
    ['PowerShell', '& bash scripts/x.sh', true],
    ['PowerShell', 'Get-Content x.sh | bash', true],
    ['PowerShell', "& 'C:/Program Files/Git/bin/bash.exe' scripts/rssh.sh 'uptime'", false],
    ['PowerShell', "& 'C:/Program Files/Git/bin/bash.exe' -c 'scripts/rssh.sh sh -s < D:/x/r1.sh'", false],
    ['PowerShell', '(Get-Command bash).Source', false],
    ['PowerShell', "rg -n 'bash ' AGENTS.md", false],
    ['PowerShell', "Write-Output 'bash scripts/x.sh'", false],
    ['PowerShell', 'wsl bash -c ls', false],
    ['Bash', 'bash scripts/x.sh', false],
    // A PowerShell tool command ending in exit loses output; quoted payloads, braces and the Terminal panel pass.
    ['PowerShell', 'Get-Item x | Select-Object Name; exit 0', true],
    ['PowerShell', 'rg -n foo D:\\x\nexit 0', true],
    ['PowerShell', "& 'D:\\x\\run.ps1'; exit $LASTEXITCODE", true],
    ['PowerShell', 'Get-Date && exit', true],
    ['PowerShell', 'exit 1;', true],
    ['PowerShell', 'rg -n foo D:\\x; $global:LASTEXITCODE = 0', false],
    ['PowerShell', "pwsh -NoProfile -Command \"& 'D:\\x\\run.ps1'; exit $LASTEXITCODE\"", false],
    ['PowerShell', 'if ($bad) { exit 1 }', false],
    ['PowerShell', "Write-Output 'exit 0'", false],
    ['PowerShell', '$exitCode = 0', false],
    [TERMINAL_TOOL, 'Get-ChildItem; exit 0', false],
    // The Terminal panel: shared and PowerShell-only rules apply; MSIX-only and Bash-only rules do not.
    [TERMINAL_TOOL, 'Remove-Item -Recurse -Force D:\\x', true],
    [TERMINAL_TOOL, 'Stop-Process -Name explorer -Force', true],
    [TERMINAL_TOOL, "& 'D:\\repo\\tools\\restart-explorer.ps1'", true],
    [TERMINAL_TOOL, "pwsh -NoProfile -File 'D:\\repo\\tools\\recycle.ps1'", true],
    [TERMINAL_TOOL, "Get-FileHash -LiteralPath 'D:\\repo\\tools\\restart-explorer.ps1'", false],
    [TERMINAL_TOOL, 'gh issue list --json number,title', true],
    [TERMINAL_TOOL, 'rg -l foo D:\\', true],
    [TERMINAL_TOOL, 'bash scripts/be_wan_redial.sh', true],
    [TERMINAL_TOOL, "Set-ItemProperty -LiteralPath 'HKCU:\\Software\\X' -Name a -Value 1", false, desktop],
    [TERMINAL_TOOL, "pwsh -NoProfile -File 'D:\\repo\\tools\\docker_off.ps1'", false, desktop],
    [TERMINAL_TOOL, "& 'D:\\x\\Grok_Bot_0.77.0_Setup.exe' /S", false, desktop],
    [TERMINAL_TOOL, String.raw`Get-ChildItem 'D:\\agents'`, false],
    [TERMINAL_TOOL, 'Get-ChildItem D:\\x', false],
    // Rule 19: -and, -or and -xor share one precedence, so a mix inside one statement at one depth needs parentheses.
    ['PowerShell', "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'Wait-CiRun' -and $_.Name -eq 'pwsh.exe' -or $_.CommandLine -match 'run watch' -and $_.Name -eq 'gh.exe' }", true],
    ['PowerShell', 'if ($a -or $b -and $c) { 1 }', true],
    ['PowerShell', '$ok = $x -AND $y -Xor $z', true],
    ['PowerShell', 'if ($a -and\n  $b) { 1 }; $c -or $d -and $e', true],
    [TERMINAL_TOOL, 'if ($a -and $b -or $c) { 1 }', true],
    ['PowerShell', 'Where-Object { ($_.A -and $_.B) -or ($_.C -and $_.D) }', false],
    ['PowerShell', 'for ($i = 0; $i -lt 5 -and $n -lt 2; $i++) { if ($done -or $failed) { break } }', false],
    ['PowerShell', 'if ($a -and $b) { 1 }; if ($c -or $d) { 2 }', false],
    ['PowerShell', '$a -and $b | ForEach-Object { $_ -or $c }', false],
    ['PowerShell', 'rg -n "x -and y -or z" D:\\x', false],
    ['PowerShell', "Write-Output 'x -and y -or z'", false],
    ['PowerShell', "Write-Output \"$(Get-Date -Format 'x -and y -or z')\"", false],
    ['PowerShell', "git commit -m @'\nfix: x -and y -or z\n'@", false],
    ['PowerShell', '# x -and y -or z\nGet-Date', false],
    ['Bash', 'find . -name a -and -name b -or -name c', false],
    // Grep and Glob stop ripgrep after 20 seconds; the root is path, else the session cwd (D:\repo unless given).
    ['Grep', { pattern: 'magpie-codex-model-filter', path: 'D:\\agents\\projects' }, true],
    ['Glob', { pattern: '*magpie*', path: 'D:\\agents\\projects\\' }, true],
    ['Glob', { pattern: '**/*.md', path: 'D:/agents' }, true],
    ['Grep', { pattern: 'foo', path: '..', cwd: 'D:\\agents\\projects\\misc' }, true],
    ['Grep', { pattern: 'foo', cwd: 'D:\\agents\\projects' }, true],
    ['Grep', { pattern: 'foo', path: 'D:\\agents\\projects\\misc' }, false],
    ['Glob', { pattern: '*magpie*', path: 'D:\\agents\\run-evidence\\sn580' }, false],
    ['Glob', { pattern: '*magpie*' }, false],
    // Write and Edit must use the guarded install entry for the active skills root, including junction aliases.
    ['Write', { file_path: 'D:\\agents\\skills-manager\\skills\\retro\\SKILL.md' }, true],
    ['Edit', { file_path: 'D:/agents/skills-manager/skills/retro/SKILL.md' }, true],
    ['Write', { file_path: 'D:\\Codex\\.codex\\skills\\retro\\new-file.tmp' }, true],
    ['Edit', { file_path: 'skills\\retro\\SKILL.md', cwd: 'D:\\agents\\skills-manager' }, true],
    ['Write', { file_path: 'D:\\agents\\skills-manager\\skills-backup\\SKILL.md' }, false],
    ['Edit', { file_path: 'D:\\agents\\run-evidence\\outside.md' }, false],
    // Rule 20: under strict mode a variable takes command output directly, then its .Count is read; inline, in a
    // script the command runs (stubbed below), or in the .ps1 a Write or Edit would leave behind.
    ['PowerShell', "pwsh -NoProfile -File 'D:\\repo\\tools\\install-dsh.ps1' -CheckOnly", true],
    [TERMINAL_TOOL, 'pwsh -NoProfile -File D:\\repo\\tools\\install-dsh.ps1 && Write-Output done', true],
    ['Bash', 'pwsh -NoProfile -File /d/repo/tools/install-dsh.ps1', true],
    ['PowerShell', "& 'D:\\repo\\tools\\restart-app.ps1'", true],
    ['PowerShell', "pwsh -File 'D:\\repo\\tools\\count-typed.ps1'", true],
    ['PowerShell', 'Set-StrictMode -Version Latest; $files = Get-ChildItem D:\\x; $files.Count', true],
    ['PowerShell', 'Set-StrictMode -Version Latest; $x = if ($a) { @(Get-ChildItem D:\\x) } else { @() }; "n=$($x.Count)"', true],
    ['PowerShell', 'Set-StrictMode -Version Latest; try { $rows = Import-Csv D:\\x\\a.csv } catch { $rows = @() }; $rows.Count', true],
    ['PowerShell', "pwsh -File 'D:\\repo\\tools\\install-dsh-fixed.ps1'", false],
    ['PowerShell', "pwsh -File 'D:\\repo\\tools\\count-ok.ps1'", false],
    ['PowerShell', "pwsh -File 'D:\\repo\\tools\\no-strict.ps1'", false],
    ['PowerShell', "Get-FileHash -LiteralPath 'D:\\repo\\tools\\install-dsh.ps1'", false],
    ['PowerShell', 'Set-StrictMode -Version Latest; $files = @(Get-ChildItem D:\\x); $files.Count', false],
    ['PowerShell', 'Set-StrictMode -Version 1; $files = Get-ChildItem D:\\x; $files.Count', false],
    ['PowerShell', '$files = Get-ChildItem D:\\x; $files.Count', false],
    ['PowerShell', "rg -n 'Set-StrictMode -Version Latest|$keys = Get-Foo|$keys.Count' D:\\x", false],
    ['PowerShell', 'Set-StrictMode -Version Latest\n$lines = git status --porcelain\n$lines.Count', true],
    ['PowerShell', 'Set-StrictMode -Version Latest\n$ok = $rows | Where-Object { $_.ok }\n$ok.Count', true],
    ['PowerShell', 'Set-StrictMode -Version Latest\nfunction Get-Map { $m = [System.Collections.Generic.Dictionary[string, int]]::new(); return $m }\n$m = Get-Map\n$m.Count', false],
    ['PowerShell', 'Set-StrictMode -Version Latest\nfunction Get-Info { [pscustomobject]@{ count = 1 } }\n$info = Get-Info\n$info.Count', false],
    ['PowerShell', 'Set-StrictMode -Version Latest\n$items = Get-ChildItem\nfunction Show([object[]]$items) { $items.Count }', false],
    ['PowerShell', 'Set-StrictMode -Version Latest\n$map = ConvertTo-CrossFileMap -Plan $plan\n$map.Count', false],
    ['Write', { file_path: 'D:\\repo\\tools\\new.ps1', content: 'Set-StrictMode -Version Latest\n$rows = Import-Csv $path\nif ($rows.Count -eq 0) { return }' }, true],
    ['Write', { file_path: 'D:\\repo\\tools\\new.ps1', content: 'Set-StrictMode -Version Latest\n$rows = @(Import-Csv $path)\nif ($rows.Count -eq 0) { return }' }, false],
    ['Write', { file_path: 'D:\\repo\\notes.md', content: 'Set-StrictMode -Version Latest\n$rows = Import-Csv $path\n$rows.Count' }, false],
    ['Edit', { file_path: 'D:\\repo\\tools\\existing-clean.ps1', old_string: '$files = @(Get-ChildItem $root)', new_string: '$files = Get-ChildItem $root' }, true],
    ['Edit', { file_path: 'D:\\repo\\tools\\no-strict.ps1', old_string: "$ErrorActionPreference = 'Stop'", new_string: "Set-StrictMode -Version Latest\n$ErrorActionPreference = 'Stop'" }, true],
    ['Edit', { file_path: 'D:\\repo\\tools\\existing-trap.ps1', old_string: "Write-Output 'start'", new_string: "Write-Output 'begin'" }, false],
    ['Edit', { file_path: 'D:\\repo\\tools\\existing-trap.ps1', old_string: '$files = Get-ChildItem $root', new_string: '$files = @(Get-ChildItem $root)' }, false],
    // Rule 21: a .ps1 the command runs gets the checked entry's parameter pre-check (stubbed below); a script that is
    // only read, a .psm1 and the command text itself are not checked.
    ['PowerShell', "pwsh -NoProfile -File 'D:\\repo\\tools\\split-parent.ps1'", true],
    ['PowerShell', "& 'D:\\repo\\tools\\split-parent.ps1'", true],
    [TERMINAL_TOOL, 'pwsh -File D:\\repo\\tools\\split-parent.ps1', true],
    ['Bash', 'pwsh -NoProfile -File /d/repo/tools/split-parent.ps1', true],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-OfficeRemote.ps1' -Target office -ScriptPath 'D:\\repo\\tools\\split-parent.ps1'", true],
    ['PowerShell', "Get-FileHash -LiteralPath 'D:\\repo\\tools\\split-parent.ps1'; pwsh -File 'D:\\repo\\tools\\harmless.ps1'", false],
    ['PowerShell', "Import-Module 'D:\\repo\\tools\\split-parent.psm1'", false],
    ['PowerShell', '$p = Get-Item .; Split-Path -LiteralPath $p.FullName -Parent', false],
    // The checked entry runs the same check on its -ScriptPath script before running it.
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-CheckedPowerShell.ps1' -ScriptPath 'D:\\repo\\tools\\split-parent.ps1' -CheckOnly", false],
    ['PowerShell', 'pwsh -NoProfile -File D:\\Codex\\.codex\\scripts\\Invoke-CheckedPowerShell.ps1 -ScriptPath:D:\\repo\\tools\\split-parent.ps1', false],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-CheckedPowerShell.ps1' -ScriptPath D:\\repo\\tools\\harmless.ps1; pwsh -File D:\\repo\\tools\\split-parent.ps1", true],
    // Rule 22: DeepSeek Harness.exe without ELECTRON_RUN_AS_NODE=1 starts its GUI; node mode, text that names the exe
    // and the Terminal panel pass.
    ['PowerShell', "& 'D:/x/DeepSeek Harness/DeepSeek Harness.exe' --version", true],
    ['PowerShell', "Start-Process -FilePath 'D:\\x\\DeepSeek Harness\\DeepSeek Harness.exe'", true],
    ['PowerShell', "Start-Process -Wait 'D:\\x\\DeepSeek Harness\\DeepSeek Harness.exe' -ArgumentList '--version'", true],
    ['PowerShell', "saps -FilePath:'D:\\x\\DeepSeek Harness\\DeepSeek Harness.exe'", true],
    ['PowerShell', "D:\\x\\'DeepSeek Harness'\\'DeepSeek Harness.exe' --version", true],
    ['PowerShell', '$v = & "$env:LOCALAPPDATA\\Programs\\DeepSeek Harness\\DeepSeek Harness.exe" --version', true],
    ['PowerShell', "$exe = Join-Path $install 'DeepSeek Harness.exe'\nif (Test-Path -LiteralPath $exe) { & $exe --version }", true],
    ['PowerShell', "Start-Process -FilePath (Join-Path $install 'DeepSeek Harness.exe')", true],
    ['PowerShell', "pwsh -NoProfile -Command \"& 'D:\\x\\DeepSeek Harness\\DeepSeek Harness.exe' --version\"", true],
    ['PowerShell', "pwsh -NoProfile -File 'D:\\repo\\tools\\dsh-version.ps1'", true],
    ['PowerShell', "& 'D:\\repo\\tools\\dsh-launch.ps1'", true],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-CheckedPowerShell.ps1' -ScriptPath 'D:\\repo\\tools\\dsh-version.ps1'", true],
    ['PowerShell', "& 'D:\\Codex\\.codex\\scripts\\Invoke-CheckedPowerShell.ps1' -ScriptPath 'D:\\repo\\tools\\dsh-version.ps1' -CheckOnly", false],
    ['Bash', "'/d/x/DeepSeek Harness/DeepSeek Harness.exe' --version", true],
    ['Bash', "pwsh -c \"& 'D:/x/DeepSeek Harness/DeepSeek Harness.exe' --version\"", true],
    ['PowerShell', "$env:ELECTRON_RUN_AS_NODE = '1'; & 'D:/x/DeepSeek Harness/DeepSeek Harness.exe' D:\\x\\probe.mjs", false],
    ['PowerShell', "Start-Process -FilePath 'D:\\x\\DeepSeek Harness\\DeepSeek Harness.exe' -ArgumentList 'D:\\x\\probe.mjs' -Environment @{ ELECTRON_RUN_AS_NODE = '1' } -Wait -NoNewWindow", false],
    ['PowerShell', "$env:ELECTRON_RUN_AS_NODE = '1'; pwsh -NoProfile -File 'D:\\repo\\tools\\dsh-version.ps1'", false],
    ['PowerShell', "pwsh -NoProfile -File 'D:\\repo\\tools\\dsh-node.ps1'", false],
    ['PowerShell', "pwsh -NoProfile -File 'D:\\repo\\tools\\dsh-restart.ps1' -ResultPath D:\\x\\r.json", false],
    ['PowerShell', "Get-CimInstance Win32_Process -Filter \"Name = 'DeepSeek Harness.exe'\"", false],
    ['PowerShell', "Get-Process -Name 'DeepSeek Harness' -ErrorAction Ignore | Select-Object Id, Path", false],
    ['PowerShell', "Test-Path -LiteralPath 'D:\\x\\DeepSeek Harness\\DeepSeek Harness.exe'", false],
    ['PowerShell', "$exe = 'D:\\x\\DeepSeek Harness\\DeepSeek Harness.exe'; (Get-Item -LiteralPath $exe).VersionInfo.FileVersion", false],
    ['PowerShell', "rg -n 'DeepSeek Harness.exe' D:\\x; Write-Output \"& 'DeepSeek Harness.exe'\"", false],
    ['PowerShell', "'D:\\x\\DeepSeek Harness\\DeepSeek Harness.exe'", false],
    ['PowerShell', "git commit -m \"fix: & 'DeepSeek Harness.exe' --version opened the GUI\"", false],
    ['Bash', "ELECTRON_RUN_AS_NODE=1 '/d/x/DeepSeek Harness/DeepSeek Harness.exe' /d/x/probe.mjs", false],
    ['Bash', "grep -n 'DeepSeek Harness.exe' notes.txt; echo \"DeepSeek Harness.exe\"", false],
    [TERMINAL_TOOL, "& 'D:/x/DeepSeek Harness/DeepSeek Harness.exe'", false],
    // Rule 23: reg delete takes /f only (//f in Git Bash), from every shell tool; the Stop hook supplies the rule.
    ['PowerShell', "if ($false) { reg delete 'HKLM\\SOFTWARE\\X' -f }", true],
    [TERMINAL_TOOL, "reg delete 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss' -f", true],
    [TERMINAL_TOOL, "reg delete 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss' -f", true, desktop],
    ['PowerShell', "& 'C:\\Windows\\System32\\reg.exe' delete 'HKLM\\SOFTWARE\\X' -v a -f", true],
    ['Bash', "reg delete 'HKLM\\SOFTWARE\\X' -f", true],
    ['PowerShell', "if ($false) { reg delete 'HKLM\\SOFTWARE\\X' /f }", false],
    [TERMINAL_TOOL, "reg delete 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss' /f", false, desktop],
    ['Bash', "reg delete 'HKLM\\SOFTWARE\\X' //f", false],
    ['PowerShell', "reg query 'HKCU\\Environment' -v MAGPIE_MIRRORS", false],
    ['PowerShell', "Write-Output 'reg delete HKLM\\SOFTWARE\\X -f'", false],
    ['PowerShell', "'{0}' -f (reg query 'HKLM\\SOFTWARE\\X')", false],
    // Text that only mentions it (2026-11-16 review): a here-string or multi-line commit message, a <# #> comment.
    ['PowerShell', "git -C 'D:/x' commit -m @'\nclaude hooks: rule 23 (reg delete with -f), rule 25 (rg on .asar)\n'@", false],
    ['PowerShell', 'git commit -m "fix:\nreg delete -f fails in PowerShell 7"', false],
    ['PowerShell', "<#\nreg delete 'HKLM\\SOFTWARE\\X' -f\n#>\nGet-Date", false],
    ['PowerShell', "reg delete 'HKLM\\SOFTWARE\\X' /f # -f fails", false],
    // A continued line, and a line after one that ends in a path's backslash.
    ['PowerShell', "reg delete 'HKLM\\SOFTWARE\\X' -va `\n  -f", true],
    ['PowerShell', "Set-Location D:\\\nreg delete 'HKLM\\SOFTWARE\\X' -f", true],
    // Rule 24: a hand_off (kind "run") command gets the Stop hook's rules for the shell that runs it.
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "reg delete 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss' -f", shell: 'PowerShell 7（Terminal 面板）' }, true],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "reg delete 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss' /f", shell: 'PowerShell 7（Terminal 面板）' }, false],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "! reg delete 'HKCU\\Software\\X' /f" }, true],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "!reg delete 'HKCU\\Software\\X' //f" }, false],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "reg query 'HKCU\\Environment' /v X", shell: 'Git Bash' }, true],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "reg query 'HKCU\\Environment' /v X", shell: 'pwsh' }, false],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "'D:/x/run.cmd' --dry-run" }, true],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "'D:/x/run.cmd' --dry-run", shell: 'bash' }, false],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: 'for f in a b; do echo $f; done', shell: 'PowerShell 7' }, true],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: '! for f in a b; do echo $f; done', shell: 'PowerShell 7' }, false],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: 'git push origin main', shell: 'PowerShell 7' }, true],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "git -C 'D:/agents/projects/x' push origin main", shell: 'PowerShell 7' }, false],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "reg delete 'HKLM\\SOFTWARE\\X' -f", shell: 'cmd（管理员）' }, true],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "'D:/x/run.cmd' --dry-run", shell: 'cmd（管理员）' }, false],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "D:/Codex/.codex/scripts/install-skill-guarded.ps1 --candidate 'D:/x' --update", shell: 'PowerShell 7（Terminal 面板）' }, false],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x', command: "pwsh -NoProfile -File D:/Codex/.codex/scripts/install-skill-guarded.ps1 --candidate 'D:/x' --update", shell: 'PowerShell 7（Terminal 面板）' }, false],
    [HAND_OFF_TOOL, { kind: 'authorize', title: 'x', target: "reg delete 'HKCU\\Software\\X' -f" }, false],
    [HAND_OFF_TOOL, { kind: 'run', title: 'x' }, false],
    // Rule 25: rg on a literal .asar archive; asar_extract.py grep names the packed file of each match.
    ['PowerShell', "rg -a -o -i '.{0,260}wsl\\.exe.{0,260}' 'D:\\x\\resources\\app.asar'", true],
    [TERMINAL_TOOL, 'rg -a -c Lxss "$env:LOCALAPPDATA\\AnthropicClaude\\app-1.0.0\\resources\\app.asar"', true],
    ['Bash', "rg -a -o 'wsl.exe' /c/x/resources/app.asar", true],
    ['PowerShell', 'rg -n wsl D:\\x\\resources\\app.asar.unpacked', false],
    ['PowerShell', "rg --files D:\\x\\resources -g '*.asar'", false],
    ['PowerShell', "python -B -I D:\\Codex\\tools\\asar-extract\\asar_extract.py grep 'D:\\x\\resources\\app.asar' 'wsl\\.exe' --paths '^out/' --context 120", false],
    ['PowerShell', "rg -n 'app\\.asar' D:\\x\\notes.md", false]
  ]
  const scripts = new Map(Object.entries({
    'D:\\repo\\tools\\recycle.ps1': 'Add-Type -TypeDefinition $src\n[Native]::SHFileOperationW([ref]$op)',
    'D:\\repo\\tools\\empty-bin.ps1': 'Clear-RecycleBin -DriveLetter D -Force',
    'D:\\repo\\lib\\shell.ps1': '$shell = New-Object -ComObject Shell.Application\n$shell.Namespace(10).MoveHere($path)',
    'D:\\repo\\tools\\harmless.ps1': 'Get-ChildItem -LiteralPath $PSScriptRoot',
    'D:\\repo\\tools\\docker_off.ps1': "$runKey = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'\nif ($null -ne $runVal) { Remove-ItemProperty -LiteralPath $runKey -Name $name }",
    'D:\\repo\\tools\\install.ps1': "$exe = Join-Path $PSScriptRoot 'Foo_Setup.exe'\nStart-Process -FilePath $exe -ArgumentList '/S' -Verb RunAs -Wait\nGet-CimInstance Win32_Process | Select-Object -First 1",
    'D:\\repo\\tools\\install-wmi.ps1': "$cmd = '\"' + $exe + '\" /S /D=D:\\y'\nInvoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }",
    'D:\\repo\\tools\\restart-explorer.ps1': "$old = @(Get-Process -Name explorer)\nStop-Process -Name explorer -Force",
    'D:\\Codex\\.codex\\scripts\\Restart-ExplorerShell.ps1': 'Stop-Process -Name explorer -Force',
    'D:\\Codex\\.codex\\scripts\\Invoke-ManagedRecycle.ps1': 'code = SHFileOperationW(ref op);',
    'D:\\Codex\\.codex\\scripts\\Invoke-CheckedPowerShell.ps1': 'STA (SHFileOperationW) works here.',
    // Rule 20: the 2026-11-13 installer before and after its fix (a function-local $keys from a pipeline, then the
    // script's own $keys), a restart script of the same shape, and the shapes that keep their Count.
    'D:\\repo\\tools\\install-dsh.ps1': [
      'param([switch]$CheckOnly)', 'Set-StrictMode -Version 3.0',
      'function Get-SecretLikeKeys([string]$Path) {',
      "    $keys = [regex]::Matches((Get-Content -LiteralPath $Path -Raw), 'key') | ForEach-Object { $_.Value }",
      '    return @($keys | Sort-Object -Unique)', '}',
      "foreach ($name in 'settings.yaml', 'AGENTS.md') {",
      '    $src = Join-Path $dshHome $name', '    $keys = Get-SecretLikeKeys $src',
      '    if ($keys.Count -gt 0) { continue }', '}'
    ].join('\n'),
    'D:\\repo\\tools\\install-dsh-fixed.ps1': [
      'Set-StrictMode -Version 3.0',
      'function Get-Holders { $rows = [Collections.Generic.List[object]]::new(); [pscustomobject]@{ holders = $rows } }',
      'function Get-SecretLikeKeys([string]$Path) {',
      "    $keys = [regex]::Matches((Get-Content -LiteralPath $Path -Raw), 'key') | ForEach-Object { $_.Value }",
      '    return @($keys | Sort-Object -Unique)', '}',
      '$gate = Get-Holders', 'if ($gate.holders.Count -gt 0) { exit 2 }',
      "foreach ($name in 'settings.yaml', 'AGENTS.md') {",
      '    # was: $keys = Get-SecretLikeKeys $src, then $keys.Count',
      '    $keys = @(Get-SecretLikeKeys (Join-Path $dshHome $name))',
      '    if ($keys.Count -gt 0) { continue }', '}'
    ].join('\n'),
    'D:\\repo\\tools\\restart-app.ps1': [
      'Set-StrictMode -Version Latest', "$ErrorActionPreference = 'Stop'",
      'function Get-AppProcess { Get-Process -Name app -ErrorAction SilentlyContinue }',
      '$before = Get-AppProcess', '$before | Stop-Process -Force', "Start-Process 'D:\\x\\app.exe'",
      '$after = Get-AppProcess', "if ($after.Count -ne 1) { throw 'app did not restart' }"
    ].join('\n'),
    'D:\\repo\\tools\\count-typed.ps1': "Set-StrictMode -Version Latest\n[array]$logs = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.log'\nWrite-Output \"logs: $($logs.Count)\"",
    'D:\\repo\\tools\\count-ok.ps1': [
      'Set-StrictMode -Version Latest',
      '$files = @(Get-ChildItem -LiteralPath $PSScriptRoot)', '[array]$more = @(Get-ChildItem -LiteralPath $PSScriptRoot)',
      '$map = @{ a = 1 }', '$pair = 1, 2', '$list = [System.Collections.Generic.List[string]]::new()',
      '$big = (Get-ChildItem -LiteralPath $PSScriptRoot).Where({ $_.Length -gt 0 })',
      '$stats = Get-ChildItem -LiteralPath $PSScriptRoot | Measure-Object',
      '$late = Get-ChildItem -LiteralPath $PSScriptRoot', '$late = @($late)',
      "Write-Output 'no $late.Count here' # nor $files.Count here", 'Write-Output "files $files.Count"',
      'Write-Output ($files.Count + $more.Count + $map.Count + $pair.Count + $list.Count + $big.Count + $stats.Count + $late.Count)'
    ].join('\n'),
    'D:\\repo\\tools\\no-strict.ps1': "$ErrorActionPreference = 'Stop'\n$files = Get-ChildItem -LiteralPath $PSScriptRoot\nWrite-Output $files.Count",
    'D:\\repo\\tools\\existing-trap.ps1': "Set-StrictMode -Version Latest\nWrite-Output 'start'\n$files = Get-ChildItem $root\nWrite-Output $files.Count",
    'D:\\repo\\tools\\existing-clean.ps1': 'Set-StrictMode -Version Latest\n$files = @(Get-ChildItem $root)\nWrite-Output $files.Count',
    // Rule 21: the 2026-11-15 cleanup script's call, and a module with the same call.
    'D:\\repo\\tools\\split-parent.ps1': '$link = Get-Item -LiteralPath $PSScriptRoot\nSplit-Path -LiteralPath $link.FullName -Parent',
    'D:\\repo\\tools\\split-parent.psm1': 'function Get-Parent($p) { Split-Path -LiteralPath $p -Parent }',
    // Rule 22: a version probe, a launch through a variable, node mode, and Restart-Dsh.ps1's shape (explorer opens
    // the Start menu shortcut; the exe path is only read).
    'D:\\repo\\tools\\dsh-version.ps1': "& 'D:\\x\\DeepSeek Harness\\DeepSeek Harness.exe' --version",
    'D:\\repo\\tools\\dsh-launch.ps1': "$exe = Join-Path $install 'DeepSeek Harness.exe'\nStart-Process -FilePath $exe",
    'D:\\repo\\tools\\dsh-node.ps1': "$env:ELECTRON_RUN_AS_NODE = '1'\n& 'D:\\x\\DeepSeek Harness\\DeepSeek Harness.exe' D:\\x\\probe.mjs",
    'D:\\repo\\tools\\dsh-restart.ps1': [
      "param([string]$ResultPath, [string]$Exe = 'D:\\x\\DeepSeek Harness\\DeepSeek Harness.exe')",
      "function Get-Dsh { Get-CimInstance Win32_Process -Filter \"Name='DeepSeek Harness.exe'\" }",
      'Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction Ignore',
      "Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList \"`\"$Shortcut`\"\"",
      '$version = (Get-Item -LiteralPath $Exe).VersionInfo.FileVersion'
    ].join('\n')
  }).map(([path, text]) => [path.toLowerCase(), text]))
  // Rule 21: what Invoke-CheckedPowerShell.ps1 -CheckOnly reports for a script; the .psm1 must never be asked.
  const parameterErrors = new Map(Object.entries({
    'D:\\repo\\tools\\split-parent.ps1': 'CheckedPowerShell parameter-error id=AmbiguousParameterSet command=Split-Path line=2 column=1',
    'D:\\repo\\tools\\split-parent.psm1': 'CheckedPowerShell parameter-error id=AmbiguousParameterSet command=Split-Path line=1 column=27'
  }).map(([path, line]) => [path.toLowerCase(), line]))
  const io = {
    read: path => scripts.get(win32.normalize(path).toLowerCase()) ?? null,
    parameterError: path => parameterErrors.get(win32.normalize(path).toLowerCase()) ?? null
  }
  let failed = 0
  // A case's second element is the shell command, or for Grep and Glob the tool input plus an optional cwd.
  for (const [tool, input, shouldDeny, env] of cases) {
    const { cwd = 'D:\\repo', ...toolInput } = typeof input === 'string' ? { command: input } : input
    const denied = evaluate({ tool_name: tool, tool_input: toolInput, cwd }, env ? { ...io, env } : io) !== null
    if (denied !== shouldDeny) {
      failed++
      const shown = typeof input === 'string' ? input : JSON.stringify(input)
      console.error(`FAIL ${tool}${env ? ` [${env.CLAUDE_CODE_ENTRYPOINT}]` : ''}: ${shown} -> ${denied ? 'deny' : 'allow'}`)
    }
  }
  const reason = (tool, command, env) => evaluate({ tool_name: tool, tool_input: { command }, cwd: 'D:\\repo' }, env ? { ...io, env } : io) || ''
  const checks = [
    [handoffLint !== null, 'claude-stop-handoff-lint.mjs loads, so rules 23 and 24 run'],
    [reason('PowerShell', "Set-ItemProperty -LiteralPath 'HKCU:\\Software\\X' -Name a -Value 1", desktop).includes('「只在私有层的条目」'),
      'the HKCU reason points to the private-layer section'],
    [reason(TERMINAL_TOOL, "reg delete 'HKLM\\SOFTWARE\\X' -f").includes('//f'), 'the reg delete reason carries the Stop hook fix'],
    [reason('PowerShell', "rg -a x 'D:\\x\\app.asar'").includes('asar_extract.py grep <asar> <正则>'), 'the asar reason names asar_extract.py grep'],
    [(evaluate({ tool_name: 'Write', tool_input: { file_path: 'D:\\agents\\skills-manager\\skills\\retro\\SKILL.md' }, cwd: 'D:\\repo' }, io) || '').includes('D:\\Codex\\.codex\\scripts\\install-skill-guarded.ps1'),
      'the skills-root write reason names install-skill-guarded.ps1']
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
    // Allow on any internal error.
  }
}
