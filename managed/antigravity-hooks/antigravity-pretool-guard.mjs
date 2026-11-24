// Antigravity PreToolUse adapter over ../claude-hooks/claude-pretool-guard.mjs.
// Translates Antigravity's camelCase PreToolUse JSON payload into Claude guard's evaluate() contract
// and emits Antigravity's { decision: "allow" | "deny", reason? } JSON on stdout.
// Any parse or internal error fails open ("allow") so a broken guard never locks out the shell.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

// Read stdin BEFORE importing claude-pretool-guard.mjs, because its top-level reads stdin on import.
const IS_MAIN = process.argv[1] && fileURLToPath(import.meta.url).toLowerCase() === process.argv[1].toLowerCase()
const SELF_TEST = process.argv.includes('--self-test')
const STDIN = IS_MAIN && !SELF_TEST ? readStdin() : ''

// Antigravity runs outside Claude Desktop's MSIX package; ensure MSIX-only rules never fire here.
delete process.env.CLAUDE_CODE_ENTRYPOINT

const { evaluate } = await import('../claude-hooks/claude-pretool-guard.mjs')

function readStdin() {
  try {
    return readFileSync(0, 'utf8')
  } catch {
    return ''
  }
}

export function translatePayload(input) {
  const call = input && typeof input === 'object' ? input.toolCall : null
  if (!call || typeof call !== 'object') return null
  const name = String(call.name || '')
  const args = call.args && typeof call.args === 'object' ? call.args : {}
  const cwd = String(args.Cwd || input.cwd || '')

  if (name === 'run_command') {
    return {
      tool_name: 'PowerShell',
      tool_input: { command: String(args.CommandLine || '') },
      cwd
    }
  }
  if (name === 'write_file') {
    return {
      tool_name: 'Write',
      tool_input: {
        file_path: String(args.Path || ''),
        content: String(args.Content || '')
      },
      cwd
    }
  }
  if (name === 'write_to_file') {
    return {
      tool_name: 'Write',
      tool_input: {
        file_path: String(args.TargetFile || ''),
        content: String(args.CodeContent || '')
      },
      cwd
    }
  }
  if (name === 'edit_file') {
    return {
      tool_name: 'Edit',
      tool_input: {
        file_path: String(args.Path || ''),
        old_string: String(args.Target || ''),
        new_string: String(args.Replacement || '')
      },
      cwd
    }
  }
  if (name === 'replace_file_content') {
    return {
      tool_name: 'Edit',
      tool_input: {
        file_path: String(args.TargetFile || ''),
        old_string: String(args.TargetContent || ''),
        new_string: String(args.ReplacementContent || '')
      },
      cwd
    }
  }
  return null
}

export function decide(input, io) {
  const translated = translatePayload(input)
  if (!translated) return { decision: 'allow' }
  const reason = io ? evaluate(translated, io) : evaluate(translated)
  if (reason) return { decision: 'deny', reason }
  return { decision: 'allow' }
}

function runSelfTest() {
  const generatedMap = new Map([
    ['c:\\users\\windows\\.gemini\\config\\agents.md', '<!-- AGENTS-SYNC:GENERATED v2 -->\n# Google Antigravity 全局规则\n'],
    ['d:\\codex\\.codex\\agents.shared.md', '# 全局 Agent 默认规则\n']
  ])
  const stubIo = {
    env: process.env,
    read: p => generatedMap.get(String(p).replace(/\//g, '\\').toLowerCase()) ?? null,
    parameterError: () => null
  }
  const cases = [
    [
      'deny rg wildcard path',
      { toolCall: { name: 'run_command', args: { CommandLine: 'rg -n foo "$env:APPDATA\\x\\*.js"' } }, cwd: 'D:\\repo' },
      'deny'
    ],
    [
      'allow rg -g glob',
      { toolCall: { name: 'run_command', args: { CommandLine: "rg -n foo D:\\agents\\projects\\home-network -g '*.js'" } }, cwd: 'D:\\repo' },
      'allow'
    ],
    [
      'deny unquoted comma list',
      { toolCall: { name: 'run_command', args: { CommandLine: 'gh issue view 1 --json number,title' } }, cwd: 'D:\\repo' },
      'deny'
    ],
    [
      'deny trailing exit',
      { toolCall: { name: 'run_command', args: { CommandLine: 'Get-ChildItem .; exit 0' } }, cwd: 'D:\\repo' },
      'deny'
    ],
    [
      'deny write_file into active skills root',
      { toolCall: { name: 'write_file', args: { Path: 'D:\\agents\\skills-manager\\skills\\retro\\SKILL.md', Content: 'x' } }, cwd: 'D:\\repo' },
      'deny'
    ],
    [
      'deny edit_file into active skills root',
      { toolCall: { name: 'edit_file', args: { Path: 'D:\\agents\\skills-manager\\skills\\retro\\SKILL.md', Target: 'a', Replacement: 'b' } }, cwd: 'D:\\repo' },
      'deny'
    ],
    [
      'deny edit_file into generated global AGENTS.md',
      { toolCall: { name: 'edit_file', args: { Path: 'C:\\Users\\WINDOWS\\.gemini\\config\\AGENTS.md', Target: 'a', Replacement: 'b' } }, cwd: 'D:\\repo' },
      'deny',
      stubIo
    ],
    [
      'allow edit_file on AGENTS.shared.md source',
      { toolCall: { name: 'edit_file', args: { Path: 'D:\\Codex\\.codex\\AGENTS.shared.md', Target: 'a', Replacement: 'b' } }, cwd: 'D:\\repo' },
      'allow',
      stubIo
    ],
    [
      'allow edit_file in normal repo',
      { toolCall: { name: 'edit_file', args: { Path: 'D:\\agents\\projects\\home-network\\AGENTS.md', Target: 'a', Replacement: 'b' } }, cwd: 'D:\\repo' },
      'allow'
    ],
    [
      'allow unknown tool',
      { toolCall: { name: 'read_file', args: { Path: 'D:\\agents\\projects\\home-network\\AGENTS.md' } }, cwd: 'D:\\repo' },
      'allow'
    ]
  ]
  let failed = 0
  for (const [label, payload, expected, customIo] of cases) {
    const out = decide(payload, customIo)
    const ok = out.decision === expected && (expected !== 'deny' || (typeof out.reason === 'string' && out.reason.length > 0))
    if (!ok) {
      failed++
      console.error(`FAIL [${label}]: got ${JSON.stringify(out)}, expected ${expected}`)
    }
  }
  console.log(`antigravity-pretool-guard self-test: ${cases.length - failed}/${cases.length} passed`)
  process.exit(failed ? 1 : 0)
}

function main() {
  try {
    const payload = JSON.parse(STDIN || '{}')
    process.stdout.write(JSON.stringify(decide(payload)))
  } catch {
    process.stdout.write(JSON.stringify({ decision: 'allow' }))
  }
}

if (IS_MAIN) {
  if (SELF_TEST) {
    runSelfTest()
  } else {
    main()
  }
}
