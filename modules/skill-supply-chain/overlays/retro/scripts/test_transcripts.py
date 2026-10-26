"""Behaviour tests for transcripts.py against the JSONL fixtures in testdata/."""
import subprocess
import sys
import unittest
import json
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "transcripts.py"
BLOB_FIXTURE = HERE / "testdata" / "claude-api-request-blob.jsonl"
TEMP_ROOT = Path('D:/Codex/tmp/retro-transcripts-tests')
TEMP_ROOT.mkdir(parents=True, exist_ok=True)


def run(*args):
    return subprocess.run([sys.executable, "-X", "utf8", str(SCRIPT), *args], capture_output=True, text=True,
                          encoding="utf-8")


class ApiRequestBlobTests(unittest.TestCase):
    """Claude Code api-request-blob records copy request content; one call and its result count once."""

    def test_audit_counts_each_call_and_result_once(self):
        result = run("audit", str(BLOB_FIXTURE), "--sizes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("tool calls: Read=1\n", result.stdout)
        self.assertIn("tool result characters: 5 in 1 results", result.stdout)
        self.assertIn("files read more than once (Read tool): 0", result.stdout)

    def test_find_skips_request_copies_of_the_system_prompt(self):
        result = run("find", "SYSTEM-PROMPT-MARKER", str(BLOB_FIXTURE))
        self.assertEqual(result.returncode, 1, result.stdout)


class CodexExecTests(unittest.TestCase):
    def audit(self, output, *options, command='text(await tools.exec_command({cmd:"tool --version"}));'):
        records = [
            {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec", "call_id": "a", "input": command}},
            {"type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "a", "output": output}},
        ]
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / "session.jsonl"
            path.write_text("\n".join(json.dumps(r) for r in records), encoding="utf-8")
            result = run("audit", str(path), *options)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_transport_nonzero_is_visible_without_guessing_its_meaning(self):
        output = 'Script completed\nOutput:\n' + json.dumps({
            "chunk_id": "x", "wall_time_seconds": 0.1, "exit_code": 7, "output": "diagnostic"})
        result = self.audit(output)
        self.assertIn("nonzero exits requiring review: 1", result)
        self.assertIn("L2", result)
        self.assertIn("exit_code=7", result)
        self.assertIn("failed tool results: 0", result)

    def test_windows_envelope_line_endings_are_supported(self):
        output = 'Script completed\r\nOutput:\r\n' + json.dumps({
            'chunk_id': 'x', 'exit_code': 7, 'output': 'diagnostic'})
        self.assertIn('nonzero exits requiring review: 1', self.audit(output))

    def test_nested_mcp_error_is_a_tool_failure(self):
        output = 'Script completed\nOutput:\n' + json.dumps({
            'status': 'fulfilled', 'value': {'content': [{'type': 'text', 'text': 'error'}], 'isError': True}})
        self.assertIn('failed tool results: 1', self.audit(output))

    def test_file_content_with_exit_code_is_not_a_transport_failure(self):
        output = 'Script completed\nOutput:\n' + json.dumps({
            "chunk_id": "x", "wall_time_seconds": 0.1, "exit_code": 0,
            "output": 'Documentation example: {"exit_code": 9}\n'})
        self.assertIn("nonzero exits requiring review: 0", self.audit(output))

    def test_reported_command_failures_are_unclassified_not_hidden(self):
        report = [{"name": "cmd-probe", "exit_code": 1, "stdout": "", "stderr": "syntax error"},
                  {"name": "native-probe", "exit_code": 0, "stdout": "version", "stderr": ""}]
        output = 'Script completed\nOutput:\n{}\n' + json.dumps({
            "chunk_id": "x", "exit_code": 0, "output": json.dumps(report)})
        result = self.audit(output)
        self.assertIn("reported nonzero outcomes (unclassified): 1", result)
        self.assertIn("failed tool results: 0", result)
        self.assertIn("expected nonzero exits (operator annotations): 1", self.audit(output, "--expected-exit", "2:1"))

    def test_expected_nonzero_does_not_suppress_other_failures(self):
        output = 'Script completed\nOutput:\n' + json.dumps([
            {"status": "fulfilled", "value": {"chunk_id": "x", "exit_code": 1, "output": ""}},
            {"status": "fulfilled", "value": {"chunk_id": "y", "exit_code": 2, "output": ""}},
            {"status": "rejected", "reason": "tool rejected"}])
        result = self.audit(output, "--expected-exit", "2:1")
        self.assertIn("expected nonzero exits (operator annotations): 1", result)
        self.assertIn("nonzero exits requiring review: 1", result)
        self.assertIn("exit_code=2", result)
        self.assertIn("failed tool results: 1", result)

    def test_running_and_unknown_results_are_not_successes(self):
        pending = 'Script completed\nOutput:\n' + json.dumps({"chunk_id": "x", "session_id": 22, "output": ""})
        self.assertIn("pending observations (may finish in a later result): 1", self.audit(pending))
        self.assertIn("pending observations (may finish in a later result): 1", self.audit('Script running with cell ID 9'))
        self.assertIn("unclassified result formats: 1", self.audit('Script completed\nOutput:\n{"arbitrary":true}'))

    def test_invalid_expectation_is_rejected(self):
        result = run("audit", str(BLOB_FIXTURE), "--expected-exit", "2:0")
        self.assertNotEqual(result.returncode, 0)

    def test_exec_static_reads_are_counted_without_fabricating_per_file_bytes(self):
        command = 'text(await tools.exec_command({cmd:"Get-Content -LiteralPath \'D:/docs/a.md\' -Raw; Get-Content -LiteralPath \'D:/docs/a.md\' -Raw"}));'
        output = 'Script completed\nOutput:\n' + json.dumps({"chunk_id": "x", "exit_code": 0, "output": "both reads"})
        result = self.audit(output, "--sizes", command=command)
        self.assertIn("files read more than once (static exec reads): 1", result)
        self.assertIn("x2 D:/docs/a.md", result)
        self.assertIn("per-file result characters unavailable", result)

    def test_dynamic_reads_are_marked_unparsed(self):
        command = 'text(await tools.exec_command({cmd:buildCommand()})); // Get-Content'
        result = self.audit('Script completed', "--sizes", command=command)
        self.assertIn("exec read calls not statically parsed: 1", result)

    def test_json_document_does_not_count_as_a_reported_command(self):
        output = 'Script completed\nOutput:\n' + json.dumps({
            "chunk_id": "x", "exit_code": 0, "output": json.dumps({"name": "example", "exit_code": 8})})
        self.assertIn("reported nonzero outcomes (unclassified): 0", self.audit(output))

    def test_printed_read_example_is_not_counted_as_a_read(self):
        command = 'text(await tools.exec_command({cmd:"Write-Output \\\"Get-Content \'D:/docs/a.md\'\\\"; Write-Output \\\"Get-Content \'D:/docs/a.md\'\\\""}));'
        result = self.audit('Script completed', "--sizes", command=command)
        self.assertIn("files read more than once (static exec reads): 0", result)

    def test_expected_legacy_exit_is_not_still_reported_as_failure(self):
        result = self.audit('Process exited with code 1\nOutput:\nnot found', '--expected-exit', '2:1')
        self.assertIn('expected nonzero exits (operator annotations): 1', result)
        self.assertIn('failed tool results: 0', result)

    def test_nested_user_data_does_not_impersonate_transport(self):
        output = 'Script completed\nOutput:\n' + json.dumps({
            "chunk_id": "x", "exit_code": 0,
            "output": json.dumps({"chunk_id": "example", "exit_code": 9, "output": "example"})})
        self.assertIn('nonzero exits requiring review: 0', self.audit(output))

    def test_direct_exec_command_reads_keep_their_path(self):
        records = []
        for call_id in ('a', 'b'):
            records.extend([
                {'type':'response_item','payload':{'type':'function_call','name':'exec_command',
                 'call_id':call_id,'arguments':json.dumps({'cmd':"Get-Content -LiteralPath 'D:/docs/a.md'"})}},
                {'type':'response_item','payload':{'type':'function_call_output','call_id':call_id,
                 'output':'Process exited with code 0\nOutput:\nhello'}},
            ])
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / 'session.jsonl'
            path.write_text('\n'.join(json.dumps(row) for row in records), encoding='utf-8')
            result = run('audit', str(path), '--sizes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('x2 D:/docs/a.md', result.stdout)
        self.assertIn('nonzero exits requiring review: 0', result.stdout)

    def test_kimi_explicit_error_and_duration_still_work(self):
        records = [
            {'type':'context.append_loop_event','time':1000,'event':{'type':'tool.call','name':'Shell','toolCallId':'a','args':{'command':'example'}}},
            {'type':'context.append_loop_event','time':1001,'event':{'type':'tool.result','toolCallId':'a','result':{'isError':True,'output':'failure','durationMs':61000}}},
        ]
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / 'session.jsonl'
            path.write_text('\n'.join(json.dumps(row) for row in records), encoding='utf-8')
            result = run('audit', str(path))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('failed tool results: 1', result.stdout)
        self.assertIn('slow calls (over 60s): 1', result.stdout)


if __name__ == "__main__":
    unittest.main()
