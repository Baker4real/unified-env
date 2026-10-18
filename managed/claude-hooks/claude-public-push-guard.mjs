// Claude Code PreToolUse guard (matcher PowerShell|Bash): keeps private network addresses and personal e-mail
// addresses out of public GitHub repositories.
// For a `git push` whose remote is a github.com repository that is public, or whose visibility gh cannot read,
// it scans what the push makes public for the first time: the non-merge commits that neither the destination's
// remote-tracking refs nor those of another public GitHub remote (an upstream) reach. It streams their added lines,
// messages and author/committer e-mail, and denies the push on
//   - Tailscale/CGNAT addresses (100.64/10) and RFC 1918 addresses (10/8, 172.16/12, 192.168/16), except the
//     range bases themselves;
//   - e-mail addresses other than GitHub noreply, noreply/no-reply senders, the ssh user git@ and the reserved
//     example, invalid, test and localhost domains;
//   - a scan that does not finish within the time budget.
// The reason lists each value masked, with its fingerprint (the first 10 hex of its SHA-256) and where it is.
// A value the user approved in chat passes when the command carries `# PUSH_PRIVACY_ACK=<fp>[,<fp>...]`, and
// `# PUSH_PRIVACY_ACK=all` skips the scan.
// Allow = print nothing and exit 0. Deny = print a PreToolUse permissionDecision JSON and exit 0.
// Private, internal and non-GitHub remotes, dry runs, deletions, pushes with nothing new and any internal error
// allow the push (registration onFailure=continue, timeout 30 s).
import { execFileSync, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { win32 } from 'node:path'

const OCTET = '(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)'
const IPV4 = new RegExp(`(?<![\\w.])${OCTET}\\.${OCTET}\\.${OCTET}\\.${OCTET}(?![\\w]|\\.\\d)`, 'g')
const EMAIL = /(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/g
const EMAIL_ADDRESS = /^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/ // codex@local is a placeholder
const ALLOWED_EMAIL = /@users\.noreply\.github\.com$|^(?:no-?reply|do-?not-?reply|git)@|^cursoragent@cursor\.com$|@(?:[\w-]+\.)*(?:example\.(?:com|org|net)|example|invalid|test|localhost)$/i
const ACK = /PUSH_PRIVACY_ACK=([\w,]+)/gi
const CHANGES_DIRECTORY = /^(?:cd|chdir|pushd|sl|set-location|push-location)$/i
const PUSH_VALUE_OPTIONS = new Set(['-o', '--push-option', '--repo', '--receive-pack', '--exec'])
const LOG_ARGS = ['-c', 'core.quotePath=false', 'log', '--no-merges', '-p', '-U0', '--no-color', '--no-ext-diff', '--no-textconv',
  '--format=%x00%H%n%ae%n%ce%n%B%x00']
const BUDGET_MS = 22000 // leaves room for gh within the 30 s registration timeout
const MAX_SHOWN = 10
const EMAIL_KIND = '邮箱'

export const fingerprint = value => createHash('sha256').update(value).digest('hex').slice(0, 10)

// Built from parts so that this file, pushed to a public repository, passes its own scan.
const ip = (...octets) => octets.join('.')
const RANGE_BASES = new Set([ip(10, 0, 0, 0), ip(100, 64, 0, 0), ip(172, 16, 0, 0), ip(192, 168, 0, 0)])

function addressKind(a, b) {
  if (a === 100 && b >= 64 && b <= 127) return 'Tailscale/CGNAT 地址'
  if (a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)) return 'RFC 1918 地址'
  return null
}

// Private values in a piece of text: [{ kind, value }].
export function privateValues(text) {
  const found = []
  for (const m of text.matchAll(IPV4)) {
    const kind = addressKind(Number(m[1]), Number(m[2]))
    if (kind && !RANGE_BASES.has(m[0])) found.push({ kind, value: m[0] })
  }
  if (text.includes('@')) {
    for (const m of text.matchAll(EMAIL)) {
      if (!ALLOWED_EMAIL.test(m[0])) found.push({ kind: EMAIL_KIND, value: m[0] })
    }
  }
  return found
}

function mask(kind, value) {
  if (kind !== EMAIL_KIND) return `${value.split('.').slice(0, 2).join('.')}.*.*`
  const at = value.lastIndexOf('@')
  return `${value.slice(0, Math.min(2, at))}***${value.slice(at)}`
}

// Splits a command line into simple commands (on ; & | ( ) { } and newlines outside quotes) and each command
// into words with the quotes removed. A # that starts a word comments out the rest of the line, a backtick or
// backslash before a newline continues the line, and redirections (2>&1, >$null, > file) are dropped.
function simpleCommands(command) {
  const commands = []
  let words = []
  let word = ''
  let inWord = false
  let quote = ''
  let comment = false
  let redirect = false // the next word is a redirection target
  const endWord = () => {
    if (inWord && redirect) redirect = false
    else if (inWord) words.push(word)
    word = ''
    inWord = false
  }
  const endCommand = () => {
    endWord()
    redirect = false
    if (words.length) commands.push(words)
    words = []
  }
  for (let k = 0; k < command.length; k++) {
    const ch = command[k]
    if (comment) {
      if (ch === '\n') { comment = false; endCommand() }
    } else if (quote) {
      if (ch === quote) quote = ''
      else word += ch
    } else if ((ch === '`' || ch === '\\') && /^\r?\n/.test(command.slice(k + 1, k + 3))) {
      k += command[k + 1] === '\r' ? 2 : 1
      endWord()
    } else if (ch === '"' || ch === "'") {
      quote = ch
      inWord = true
    } else if (ch === '#' && !inWord) {
      comment = true
    } else if (ch === '>' || ch === '<') {
      if (/^[\d*]$/.test(word)) { word = ''; inWord = false } // the stream of 2> and *>
      else endWord()
      redirect = true
      while (command[k + 1] === '>' || command[k + 1] === '&') k++ // >>, >&1
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

function resolveDir(base, path) {
  const msys = path.match(/^\/([a-zA-Z])(?:\/(.*))?$/) // Git Bash /d/x
  const native = msys ? `${msys[1].toUpperCase()}:/${msys[2] || ''}` : path
  return win32.isAbsolute(native) ? win32.normalize(native) : win32.resolve(base, native)
}

// Every `git push` of a command line: { dir, args }, dir following -C and earlier cd / Set-Location.
export function pushInvocations(command, cwd) {
  const pushes = []
  let dir = cwd
  for (const words of simpleCommands(command)) {
    let i = 0
    while (i < words.length && /^[A-Za-z_]\w*=/.test(words[i])) i++ // VAR=value prefixes
    if (CHANGES_DIRECTORY.test(words[i] || '')) {
      const target = words.slice(i + 1).find(word => !word.startsWith('-'))
      if (target) dir = resolveDir(dir, target)
      continue
    }
    if (!/^git(?:\.exe)?$/i.test((words[i] || '').split(/[\\/]/).pop())) continue
    let gitDir = dir
    for (i++; i < words.length && words[i].startsWith('-'); i++) {
      if (words[i] === '-C') gitDir = resolveDir(gitDir, words[++i] || '.')
      else if (words[i] === '-c') i++
    }
    if (words[i] === 'push') pushes.push({ dir: gitDir, args: words.slice(i + 1) })
  }
  return pushes
}

export function parsePushArgs(args) {
  const push = { dryRun: false, deleteOnly: false, all: false, tags: false, mirror: false, positional: [] }
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (arg === '--') { push.positional.push(...args.slice(i + 1)); break }
    if (arg === '-n' || arg === '--dry-run') push.dryRun = true
    else if (arg === '-d' || arg === '--delete') push.deleteOnly = true
    else if (arg === '--all' || arg === '--branches') push.all = true
    else if (arg === '--tags' || arg === '--follow-tags') push.tags = true
    else if (arg === '--mirror') push.mirror = true
    else if (PUSH_VALUE_OPTIONS.has(arg)) i++
    else if (!arg.startsWith('-')) push.positional.push(arg)
  }
  return push
}

// rev-list arguments for what a push sends; [] when it only deletes.
function pushedRevisions(push) {
  if (push.mirror) return ['--all']
  const revisions = []
  if (push.all) revisions.push('--branches')
  if (push.tags) revisions.push('--tags')
  const refspecs = push.positional.slice(1)
  for (const refspec of refspecs) {
    const source = refspec.replace(/^\+/, '').split(':')[0]
    if (source) revisions.push(source)
  }
  if (!revisions.length && !refspecs.length) revisions.push('HEAD')
  return revisions
}

export function githubSlug(url) {
  const m = url.match(/^(?:https?:\/\/(?:[^@/]+@)?github\.com\/|ssh:\/\/git@github\.com\/|git@github\.com:)([\w.-]+)\/([\w.-]+?)(?:\.git)?\/?$/i)
  return m ? `${m[1]}/${m[2]}` : null
}

const isUrl = remote => /^[a-z][a-z0-9+.-]*:\/\/|^[\w.-]+@[\w.-]+:/i.test(remote)

function defaultRemote(io, dir) {
  const branch = io.gitOptional(dir, ['symbolic-ref', '--short', '-q', 'HEAD']).trim()
  const keys = branch ? [`branch.${branch}.pushRemote`, 'remote.pushDefault', `branch.${branch}.remote`] : ['remote.pushDefault']
  for (const key of keys) {
    const value = io.gitOptional(dir, ['config', '--get', key]).trim()
    if (value) return value
  }
  return 'origin'
}

// The repository's remotes that point at GitHub: [{ name, slug }], one row per distinct (name, slug).
function githubRemotes(io, dir) {
  const remotes = new Map()
  for (const line of io.gitOptional(dir, ['config', '--get-regexp', '^remote\\..+\\.(push)?url$']).split('\n')) {
    const m = line.trim().match(/^remote\.(.+)\.(?:push)?url (.+)$/)
    const slug = m && githubSlug(m[2])
    if (slug) remotes.set(`${m[1]}\n${slug.toLowerCase()}`, { name: m[1], slug })
  }
  return [...remotes.values()]
}

const rangeOf = (revisions, known) => known.length ? [...revisions, '--not', ...known.map(name => `--remotes=${name}`)] : revisions

// Incremental scanner for `git log -p --format=%x00%H%n%ae%n%ce%n%B%x00` output, fed in chunks of any size:
// push(chunk) ..., then end() returns [{ kind, value, sha, where, identity }].
export function createLogScanner() {
  const hits = []
  let header = null // text of the commit header being read, null inside a patch
  let pending = '' // patch text after the last newline
  let sha = ''
  let file = ''
  let line = 0
  let added = 0 // added lines left in the current hunk
  const endHeader = () => {
    const [id, author, committer, ...message] = header.split('\n')
    sha = id
    file = ''
    added = 0
    for (const [where, email] of [['作者邮箱', author], ['提交者邮箱', committer]]) {
      if (EMAIL_ADDRESS.test(email) && !ALLOWED_EMAIL.test(email)) hits.push({ kind: EMAIL_KIND, value: email, sha, where, identity: true })
    }
    for (const value of privateValues(message.join('\n'))) hits.push({ ...value, sha, where: '提交信息' })
  }
  const patchRow = row => {
    if (added > 0 && row.startsWith('+')) {
      for (const value of privateValues(row.slice(1))) hits.push({ ...value, sha, where: `${file}:${line}` })
      line++
      added--
      return
    }
    const hunk = row.match(/^@@ -\S+ \+(\d+)(?:,(\d+))? @@/)
    if (hunk) {
      line = Number(hunk[1])
      added = hunk[2] === undefined ? 1 : Number(hunk[2])
    } else if (row.startsWith('+++ ')) {
      file = row.slice(4).replace(/^"?b\//, '').replace(/"$/, '')
    }
  }
  return {
    push(chunk) {
      const pieces = chunk.split('\0')
      for (let i = 0; i < pieces.length; i++) {
        if (i > 0 && header === null) { // a NUL opens a header and ends the patch before it
          if (pending) patchRow(pending)
          pending = ''
          header = ''
        } else if (i > 0) { // a NUL closes the header
          endHeader()
          header = null
        }
        if (header !== null) header += pieces[i]
        else {
          const rows = (pending + pieces[i]).split('\n')
          pending = rows.pop()
          rows.forEach(patchRow)
        }
      }
    },
    end() {
      if (pending) patchRow(pending)
      pending = ''
      return hits
    }
  }
}

// Scans a revision range until the deadline: { hits, complete }.
async function scanRange(io, dir, range, deadline) {
  const scanner = createLogScanner()
  const stream = io.gitStream(dir, [...LOG_ARGS, ...range])
  for await (const chunk of stream.chunks) {
    scanner.push(chunk)
    if (Date.now() > deadline) {
      stream.stop()
      return { hits: scanner.end(), complete: false }
    }
  }
  return { hits: scanner.end(), complete: true }
}

function summarize(hits, acknowledged) {
  const byValue = new Map()
  for (const hit of hits) {
    if (acknowledged.has(fingerprint(hit.value))) continue
    const seen = byValue.get(hit.value)
    if (!seen) byValue.set(hit.value, { ...hit, count: 1 })
    else {
      seen.count++
      seen.identity ||= hit.identity
    }
  }
  return [...byValue.values()]
}

function denyReason(label, findings, unfinishedCommits) {
  const lines = []
  if (findings.length) {
    lines.push(`推送到${label}会首次公开以下私密信息：`)
    for (const f of findings.slice(0, MAX_SHOWN)) {
      lines.push(`- ${f.kind} ${mask(f.kind, f.value)}（fp=${fingerprint(f.value)}）：${f.sha.slice(0, 7)} ${f.where}` +
        (f.count > 1 ? `，共 ${f.count} 处` : ''))
    }
    if (findings.length > MAX_SHOWN) lines.push(`- 另有 ${findings.length - MAX_SHOWN} 个值未列出`)
    lines.push('把它们换成带引号的占位符（如 <tailscale-ip>）或文档保留地址（192.0.2.x），用 git commit --amend 或 git rebase 改掉这些还没推送的提交后再推。' +
      (findings.some(f => f.identity)
        ? '作者或提交者邮箱要先把 git config user.email 设成 GitHub noreply 地址，再用 git rebase --exec "git commit --amend --no-edit --reset-author" 重写这些提交。'
        : '') +
      '确实需要公开某个值时，先在对话里请用户确认，再在推送命令末尾加 # PUSH_PRIVACY_ACK=<fp>[,<fp>...]。')
  }
  if (unfinishedCommits) {
    lines.push(`推送到${label}会首次公开 ${unfinishedCommits} 个提交，${BUDGET_MS / 1000} 秒内没扫完。` +
      '先请用户确认这些提交可以公开，再在推送命令末尾加 # PUSH_PRIVACY_ACK=all。')
  }
  return lines.join('\n')
}

const defaultIo = {
  git(dir, args) {
    return execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] })
  },
  gitOptional(dir, args) {
    try { return this.git(dir, args) } catch { return '' }
  },
  gitStream(dir, args) {
    const child = spawn('git', ['-C', dir, ...args], { windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] })
    child.on('error', () => {})
    child.stdout.setEncoding('utf8')
    return { chunks: child.stdout, stop: () => child.kill() }
  },
  visibility(slug) {
    try {
      return execFileSync('gh', ['api', `repos/${slug}`, '--jq', '.visibility'], { encoding: 'utf8', timeout: 5000, windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    } catch {
      return 'unknown'
    }
  }
}

export async function evaluate(payload, io = defaultIo, budgetMs = BUDGET_MS) {
  const deadline = Date.now() + budgetMs
  const tool = String(payload?.tool_name || '')
  const command = String(payload?.tool_input?.command || '')
  if (!command || (tool !== 'PowerShell' && tool !== 'Bash') || !/\bgit\b/.test(command) || !/\bpush\b/.test(command)) return null
  const acknowledged = new Set([...command.matchAll(ACK)].flatMap(m => m[1].toLowerCase().split(',')).filter(Boolean))
  if (acknowledged.has('all')) return null
  const visibilities = new Map()
  const visibilityOf = slug => {
    const key = slug.toLowerCase()
    if (!visibilities.has(key)) visibilities.set(key, io.visibility(slug))
    return visibilities.get(key)
  }
  const reasons = []
  for (const { dir, args } of pushInvocations(command, payload?.cwd || process.cwd())) {
    const push = parsePushArgs(args)
    if (push.dryRun || push.deleteOnly) continue
    const revisions = pushedRevisions(push)
    if (!revisions.length) continue
    const remote = push.positional[0] || defaultRemote(io, dir)
    const slug = githubSlug(isUrl(remote) ? remote : io.git(dir, ['remote', 'get-url', '--push', remote]).trim())
    if (!slug) continue
    const count = known => Number(io.git(dir, ['rev-list', '--count', '--no-merges', ...rangeOf(revisions, known)]).trim())
    const remotes = githubRemotes(io, dir)
    const destination = [...new Set(remotes.filter(r => r.slug.toLowerCase() === slug.toLowerCase()).map(r => r.name))]
    if (!count(destination)) continue
    const visibility = visibilityOf(slug)
    if (visibility === 'private' || visibility === 'internal') continue
    const upstreams = remotes.filter(r => !destination.includes(r.name) && visibilityOf(r.slug) === 'public').map(r => r.name)
    const known = [...new Set([...destination, ...upstreams])]
    const commits = count(known)
    if (!commits) continue
    const { hits, complete } = await scanRange(io, dir, rangeOf(revisions, known), deadline)
    const findings = summarize(hits, acknowledged)
    if (findings.length || !complete) {
      const label = visibility === 'public' ? `公开仓库 ${slug} ` : ` ${slug}（gh 读不到可见性，按公开处理）`
      reasons.push(denyReason(label, findings, complete ? 0 : commits))
    }
  }
  return reasons.length ? reasons.join('\n\n') : null
}

async function main() {
  let payload
  try {
    payload = JSON.parse(readFileSync(0, 'utf8') || '{}')
  } catch {
    return
  }
  const reason = await evaluate(payload)
  if (reason) {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason }
    }))
  }
}

async function selfTest() {
  let failed = 0
  let total = 0
  const check = (ok, label) => {
    total++
    if (!ok) {
      failed++
      console.error(`FAIL ${label}`)
    }
  }
  // Sample private values are built from parts, like RANGE_BASES.
  const tailscale = ip(100, 101, 2, 3)
  const personal = ['alice.private', 'outlook.com'].join('@')
  const rfcA = ip(10, 1, 2, 3)
  const rfcB = ip(192, 168, 7, 8)
  const kinds = text => privateValues(text).map(v => v.kind[0])
  check(kinds(`ssh 14224@${tailscale}`).join() === 'T', 'Tailscale address')
  check(kinds('100.63.0.1 100.128.0.1').length === 0, 'outside 100.64/10')
  check(kinds([ip(10, 0, 0, 1), ip(172, 16, 5, 4), ip(192, 168, 1, 20)].join(' ')).join() === 'R,R,R', 'RFC 1918 addresses')
  check(kinds([...RANGE_BASES].map(base => `${base}/8`).join(' ')).length === 0, 'range bases')
  check(kinds('172.15.0.1 172.32.0.1 8.8.8.8 192.0.2.10 127.0.0.1').length === 0, 'public, loopback and documentation addresses')
  check(kinds('Windows 10.0.22621.2861, version 1.2.3.4, 10.0.0.1.5').length === 0, 'version numbers')
  check(kinds('Co-Authored-By: C <noreply@anthropic.com>, 1+B@users.noreply.github.com, git@github.com:o/r, a@example.com, b@x.test').length === 0, 'allowed addresses')
  check(kinds(`Signed-off-by: A <${personal}>`).join() === '邮', 'personal e-mail')
  check(kinds('lodash@4.17.21 @types/node').length === 0, 'package specs')
  const started = Date.now()
  privateValues(`${'a'.repeat(200000)} ${'b.'.repeat(100000)}@`)
  check(Date.now() - started < 1000, `long runs scan in linear time (${Date.now() - started} ms)`)
  check(mask(EMAIL_KIND, personal) === 'al***@outlook.com' && mask('T', tailscale) === '100.101.*.*', 'masks')

  const sha = 'a'.repeat(40)
  const noreply = '1+B@users.noreply.github.com'
  const header = (body, author = noreply) => `\0${sha}\n${author}\n${noreply}\n${body}\n\0\n`
  const log = header(`fix: docs\n\nmail me at ${personal}`) +
    `diff --git a/docs/hosts.md b/docs/hosts.md\n--- a/docs/hosts.md\n+++ b/docs/hosts.md\n@@ -3,0 +4,3 @@\n+- node: ${tailscale}\n+++ not a header ${rfcA}\n+- ok\n` +
    header('second') + `diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+${rfcB}`
  const scan = (text, size) => {
    const scanner = createLogScanner()
    for (let i = 0; i < text.length; i += size) scanner.push(text.slice(i, i + size))
    return scanner.end()
  }
  const where = hits => hits.map(h => h.where).join('|')
  const expected = '提交信息|docs/hosts.md:4|docs/hosts.md:5|x:1'
  check(where(scan(log, log.length)) === expected, `scanner locations ${where(scan(log, log.length))}`)
  check([1, 2, 3, 7].every(size => where(scan(log, size)) === expected), 'chunk boundaries do not change hits')
  const identityHits = scan(header('clean', personal), 5)
  check(identityHits.length === 1 && identityHits[0].identity && identityHits[0].where === '作者邮箱', `identity e-mail ${JSON.stringify(identityHits)}`)
  check(scan(header('Co-authored-by: Cursor Agent <cursoragent@cursor.com>', 'codex@local'), 64).length === 0, 'agent placeholder identity and co-author')

  const fakeIo = ({ visibility = { 'o/r': 'public' }, remotes = { origin: 'https://github.com/o/r.git' }, commits = 1, logText = log } = {}) => {
    const calls = []
    return {
      calls,
      git(dir, args) {
        calls.push([dir, ...args])
        if (args[0] === 'remote') return `${remotes[args[3]]}\n`
        if (args[0] === 'rev-list') return `${commits}\n`
        throw new Error(`unexpected git ${args.join(' ')}`)
      },
      gitOptional(dir, args) {
        calls.push([dir, ...args])
        if (args[0] === 'symbolic-ref') return 'main\n'
        if (args[2] === 'branch.main.remote') return 'origin\n'
        if (args[1] === '--get-regexp') return Object.entries(remotes).map(([name, url]) => `remote.${name}.url ${url}\n`).join('')
        return ''
      },
      gitStream(dir, args) {
        calls.push([dir, ...args])
        return { chunks: [logText.slice(0, 50), logText.slice(50)], stop() { calls.push(['stop']) } }
      },
      visibility(slug) {
        calls.push(['gh', slug])
        return visibility[slug] || 'unknown'
      }
    }
  }
  const run = (command, io, tool = 'Bash', budget) => evaluate({ tool_name: tool, tool_input: { command }, cwd: 'D:/repo' }, io, budget)
  const revList = io => io.calls.filter(call => call[1] === 'rev-list').map(call => call.slice(4).join(' '))
  const tailscaleFp = fingerprint(tailscale)
  const all = [tailscale, personal, rfcA, rfcB].map(fingerprint)

  check(await run('git status', fakeIo()) === null, 'not a push')
  check(await run('git push --dry-run origin main', fakeIo()) === null, 'dry run')
  check(await run('git push origin --delete old', fakeIo()) === null, 'deletion')
  check(await run('git push origin :old', fakeIo()) === null, 'deletion refspec')
  const denied = await run('git push origin main', fakeIo())
  check(denied !== null && denied.includes('公开仓库 o/r') && denied.includes(tailscaleFp) && denied.includes('100.101.*.*') && !denied.includes(tailscale),
    `public push denied with masked value: ${denied}`)
  check(await run(`git push origin main # PUSH_PRIVACY_ACK=${all.join(',')}`, fakeIo()) === null, 'acknowledged values pass')
  check((await run(`git push origin main # PUSH_PRIVACY_ACK=${tailscaleFp}`, fakeIo()))?.includes(all[1]) === true, 'unacknowledged value still denies')
  check(await run('git push origin main', fakeIo({ visibility: { 'o/r': 'private' } })) === null, 'private repository')
  check((await run('git push', fakeIo({ visibility: {} })))?.includes('按公开处理') === true, 'unknown visibility scans as public')
  check(await run('git push', fakeIo({ remotes: { origin: 'D:/bare/r.git' } })) === null, 'local remote')
  check(await run('git push', fakeIo({ remotes: { origin: 'https://gitlab.com/o/r.git' } })) === null, 'non-GitHub remote')
  const noop = fakeIo({ commits: 0 })
  check(await run('git push origin main', noop) === null && !noop.calls.some(call => call[0] === 'gh'), 'nothing new: no gh call')
  check(await run('git push origin main', fakeIo({ logText: header('clean') })) === null, 'clean commits')
  const slow = fakeIo({ logText: header('clean') })
  check((await run('git push origin main', slow, 'Bash', -1))?.includes('PUSH_PRIVACY_ACK=all') === true && slow.calls.some(call => call[0] === 'stop'),
    'an unfinished scan denies and stops git')
  check(await run('git push origin main # PUSH_PRIVACY_ACK=all', fakeIo(), 'Bash', -1) === null, 'all acknowledged')
  check((await run('git push origin main', fakeIo({ logText: header('clean', personal) })))?.includes('--reset-author') === true,
    'identity e-mail denies with the re-author hint')
  check(await run('git push https://github.com/o/r.git main', fakeIo()) !== null, 'URL destination')

  const upstream = fakeIo({
    remotes: { origin: 'https://github.com/up/r.git', private: 'https://github.com/o/r.git', backup: 'https://github.com/o/old.git' },
    visibility: { 'o/r': 'public', 'up/r': 'public', 'o/old': 'private' }
  })
  await run('git push private main', upstream)
  check(revList(upstream).join('|') === 'main --not --remotes=private|main --not --remotes=private --remotes=origin',
    `public upstream refs count as published, private backup refs do not: ${JSON.stringify(revList(upstream))}`)

  const redirected = fakeIo()
  check(await run('git push origin main 2>&1 | Out-String', redirected, 'PowerShell') !== null && revList(redirected)[0] === 'main --not --remotes=origin',
    `2>&1 is not a refspec: ${JSON.stringify(revList(redirected))}`)
  const continued = fakeIo()
  check(await run('git push origin `\n  main >$null', continued, 'PowerShell') !== null && revList(continued)[0] === 'main --not --remotes=origin',
    `backtick continuation: ${JSON.stringify(revList(continued))}`)
  const located = fakeIo()
  await run('cd /d/agents/x && git push origin HEAD:refs/heads/topic', located)
  check(located.calls.some(call => call[0] === 'D:\\agents\\x' && call[1] === 'rev-list' && call.includes('HEAD')), `cd sets the repository: ${JSON.stringify(located.calls)}`)
  const flagged = fakeIo()
  await run("Set-Location -LiteralPath 'D:/a'; git -C sub push", flagged, 'PowerShell')
  check(flagged.calls.some(call => call[0] === 'D:\\a\\sub'), `-C resolves against Set-Location: ${JSON.stringify(flagged.calls)}`)
  check(githubSlug('git@github.com:Baker4real/clock-countdown.git') === 'Baker4real/clock-countdown', 'ssh slug')
  check(githubSlug('https://github.com/Baker4real/codex-account-switch-local-patches-public') === 'Baker4real/codex-account-switch-local-patches-public', 'https slug')
  check(githubSlug('https://example.com/o/r.git') === null, 'non-GitHub slug')
  check(await evaluate({ tool_name: 'Read', tool_input: { command: 'git push' } }) === null, 'other tools')

  console.log(`self-test: ${total - failed}/${total} passed`)
  process.exitCode = failed ? 1 : 0
}

if (process.argv.includes('--self-test')) {
  await selfTest()
} else {
  try {
    await main()
  } catch {
    // Allow the push on any internal error.
  }
}
