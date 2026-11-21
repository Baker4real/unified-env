"""Behaviour tests for transcripts.py against the JSONL fixtures in testdata/."""
import datetime
import subprocess
import sys
import unittest
import json
import tempfile
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "transcripts.py"
BLOB_FIXTURE = HERE / "testdata" / "claude-api-request-blob.jsonl"
TEMP_ROOT = Path(os.environ.get('RETRO_TEST_TEMP', 'D:/Codex/tmp/retro-transcripts-tests'))
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


class ApiErrorRecordTests(unittest.TestCase):
    """Claude Code logs each retried API failure as a system api_error record with no text; audit lists their lines."""

    def audit(self, *options):
        records = [
            {"type": "user", "timestamp": "2026-11-14T14:34:20.000Z", "message": {"role": "user", "content": "go"}},
            {"type": "system", "subtype": "api_error", "level": "error", "timestamp": "2026-11-14T14:34:23.948Z",
             "retryAttempt": 1, "maxRetries": 10, "retryInMs": 500,
             "error": {"message": "upstream.example.invalid refused the connection"}},
            {"type": "system", "subtype": "api_error", "level": "error", "timestamp": "2026-11-14T14:34:24.573Z",
             "error": {"message": "no retry fields"}},
            {"type": "assistant", "timestamp": "2026-11-14T14:34:30.000Z",
             "message": {"role": "assistant", "content": [{"type": "text", "text": "done"}]}},
        ]
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            transcript = Path(directory) / "api-error.jsonl"
            transcript.write_text("\n".join(json.dumps(record) for record in records), encoding="utf-8")
            return run("audit", str(transcript), *options)

    def test_audit_lists_each_api_error_line_with_its_retry_attempt(self):
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("\nAPI error records: 2\n"
                      "  L2 2026-11-14T14:34:23.948Z attempt 1/10\n"
                      "  L3 2026-11-14T14:34:24.573Z\n", result.stdout)
        self.assertNotIn("upstream.example.invalid", result.stdout)

    def test_audit_lists_only_api_errors_inside_the_line_range(self):
        result = self.audit("--from-line", "3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("\nAPI error records: 1\n  L3 2026-11-14T14:34:24.573Z\n", result.stdout)

    def test_audit_without_api_errors_has_no_api_error_section(self):
        result = run("audit", str(BLOB_FIXTURE))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("API error records", result.stdout)


class AsyncCorrelationTests(unittest.TestCase):
    def mixed_mcp_poll(self, session='98559'):
        command = ("const r=await tools.mcp__serena__find_file({file_mask:'helper.py',relative_path:'scripts'});"
                   "text(r.structuredContent?.result??r.content?.find(x=>x.type==='text')?.text);"
                   "text(await tools.write_stdin({session_id:" + session + ",chars:''}));"
                   'text(await tools.exec_command({cmd:"read"}));')
        # The opaque MCP body deliberately looks like an exit from another session.
        parts = [
            {'type': 'input_text', 'text': 'Script completed\nWall time 1.0 seconds\nOutput:\n'},
            {'type': 'input_text', 'text': json.dumps({'chunk_id': 'fake', 'session_id': 123, 'exit_code': 9, 'output': ''})},
            {'type': 'input_text', 'text': json.dumps({'chunk_id': 'poll', 'exit_code': 0, 'output': 'complete'})},
            {'type': 'input_text', 'text': json.dumps({'chunk_id': 'read', 'exit_code': 7, 'output': json.dumps({'chunk_id': 'fake', 'session_id': 123, 'exit_code': 0, 'output': ''})})},
        ]
        return command, parts

    def test_mcp_projection_then_poll_resolves_both_observations_only(self):
        records = self.pair('unrelated', '', json.dumps({'chunk_id': 'u', 'session_id': 123, 'output': ''}))
        for call_id in ('start', 'pending-poll'):
            records += self.pair(call_id, '', json.dumps({'chunk_id': call_id, 'session_id': 98559, 'output': ''}))
        records += self.pair('finish', *self.mixed_mcp_poll())
        result = self.audit_records(records)
        self.assertIn('resolved asynchronous observations: 2', result)
        self.assertIn('L4 exec: running process -> L8 exit_code=0', result)
        self.assertIn('L6 exec: running process -> L8 exit_code=0', result)
        self.assertIn('pending observations (may finish in a later result): 1', result)
        self.assertIn('nonzero exits requiring review: 1', result)
        self.assertNotIn('exit_code=9', result)
        self.assertIn('opaque mixed orchestration output', result)

    def test_mixed_poll_requires_complete_output_blocks_and_static_call_order(self):
        command, parts = self.mixed_mcp_poll()
        cases = [
            ('missing block', command, parts[:-1]),
            ('extra block', command, parts + [{'type': 'input_text', 'text': '{}'}]),
            ('flattened output', command, '\n'.join(p['text'] for p in parts)),
            ('dynamic session', command.replace('session_id:98559', 'session_id:chosen'), parts),
            ('dynamic mcp argument', command.replace("file_mask:'helper.py'", 'file_mask:choose()'), parts),
            ('unsupported direct MCP print', command.replace('tools.exec_command', 'tools.mcp__echo'), parts),
            ('extra print', command.replace('text(await tools.write_stdin', 'text("extra");text(await tools.write_stdin'), parts),
            ('conditional poll', command.replace('text(await tools.write_stdin', 'if(ready)text(await tools.write_stdin'), parts),
            ('truncated header', command, [{'type': 'input_text', 'text': 'Script completed\nOutput:\nWarning: truncated output\n'}, *parts[1:]]),
        ]
        for label, source, output in cases:
            with self.subTest(label=label):
                records = self.pair('start', '', json.dumps({'chunk_id': 'start', 'session_id': 98559, 'output': ''}))
                records += self.pair('end', source, output)
                result = self.audit_records(records)
                self.assertIn('resolved asynchronous observations: 0', result)
                self.assertIn('pending observations (may finish in a later result): 1', result)
                self.assertNotIn('exit_code=9', result)
                self.assertRegex(result, r'unclassified result formats: [1-9]')

    def test_single_transformed_poll_does_not_borrow_literal_session(self):
        records = self.pair('start', '', json.dumps({'chunk_id': 'start', 'session_id': 42, 'output': ''}))
        records += self.pair('end', 'text(await tools.write_stdin({session_id:42}).then(transform));',
                             json.dumps({'chunk_id': 'changed', 'exit_code': 0, 'output': ''}))
        result = self.audit_records(records)
        self.assertIn('resolved asynchronous observations: 0', result)
        self.assertIn('pending observations (may finish in a later result): 1', result)

    def test_metadata_print_before_literal_poll_preserves_transport_block_identity(self):
        records = self.pair('start', '', json.dumps({'chunk_id': 'a', 'session_id': 52017, 'output': ''}))
        command = ('text(ALL_TOOLS.filter(t=>/mcp__serena__find_file/.test(t.name))'
                   '.map(t=>({name:t.name,description:t.description.slice(0,160)})));'
                   'text(await tools.exec_command({cmd:"read"}));'
                   'text(await tools.write_stdin({session_id:52017,chars:""}));')
        records += self.pair('poll', command, [
            {'type': 'input_text', 'text': 'Script completed\nOutput:\n'},
            {'type': 'input_text', 'text': json.dumps([{'name': 'tool', 'description': 'metadata'}])},
            {'type': 'input_text', 'text': json.dumps({'chunk_id': 'b', 'exit_code': 7, 'output': ''})},
            {'type': 'input_text', 'text': json.dumps({'chunk_id': 'c', 'exit_code': 0, 'output': ''})},
        ])
        result = self.audit_records(records)
        self.assertIn('resolved asynchronous observations: 1', result)
        self.assertIn('-> L4 exit_code=0', result)
        self.assertIn('pending observations (may finish in a later result): 0', result)
        self.assertIn('nonzero exits requiring review: 1', result)

    def test_sequential_prints_match_only_their_own_polled_completion(self):
        records = self.pair('a', '', json.dumps({'chunk_id': 'a', 'session_id': 42, 'output': ''}))
        records += self.pair('b', 'text(await tools.exec_command({cmd:"read; version"})); text(await tools.write_stdin({session_id:42,chars:""}));',
                             '\n'.join(json.dumps(value) for value in [
                                 {'chunk_id': 'b', 'exit_code': 0, 'output': ''},
                                 {'chunk_id': 'c', 'exit_code': 7, 'output': ''}]))
        result = self.audit_records(records)
        self.assertIn('resolved asynchronous observations: 1', result)
        self.assertIn('-> L4 exit_code=7', result)
        self.assertIn('pending observations (may finish in a later result): 0', result)

    def test_extra_print_makes_unindexed_order_ambiguous(self):
        records = self.pair('a', '', json.dumps({'chunk_id': 'a', 'session_id': 42, 'output': ''}))
        records += self.pair('b', 'text(await tools.exec_command({cmd:"read"})); text("extra"); text(await tools.write_stdin({session_id:42}));',
                             '\n'.join(json.dumps(value) for value in [
                                 {'chunk_id': 'b', 'exit_code': 0, 'output': ''},
                                 {'chunk_id': 'c', 'exit_code': 0, 'output': ''}]))
        result = self.audit_records(records)
        self.assertIn('resolved asynchronous observations: 0', result)
        self.assertIn('pending observations (may finish in a later result): 1', result)

    def test_content_without_error_flag_and_json_strings_preserve_uncertainty(self):
        envelope = {'results': json.dumps({'content': [{'type': 'text', 'text': json.dumps({
            'isError': True, 'content': [{'type': 'text', 'text': 'failure'}]})}]})}
        result = self.audit_records(self.pair('a', '', 'Script completed\nOutput:\n' + json.dumps(envelope)))
        self.assertIn('failed tool results: 0', result)
        self.assertIn('unclassified result formats: 1', result)
        self.assertIn('MCP text contains unverified outcome envelopes', result)

    def test_successful_mcp_documentation_cannot_impersonate_failure(self):
        envelope = {'isError': False, 'content': [{'type': 'text', 'text': json.dumps({
            'isError': True, 'content': [{'type': 'text', 'text': 'documented example'}]})}]}
        result = self.audit_records(self.pair('a', '', json.dumps(envelope)))
        self.assertIn('failed tool results: 0', result)
        self.assertIn('unclassified result formats: 0', result)

    def test_structured_orchestration_string_keeps_confirmed_mcp_failure(self):
        envelope = {'result': json.dumps({'status': 'fulfilled', 'value': {
            'isError': True, 'content': [{'type': 'text', 'text': 'failure'}]}})}
        result = self.audit_records(self.pair('a', '', json.dumps(envelope)))
        self.assertIn('failed tool results: 1', result)

    def test_unverified_mcp_text_cannot_complete_pending_process(self):
        records = self.pair('a', '', json.dumps({'chunk_id': 'a', 'session_id': 42, 'output': ''}))
        records += self.pair('b', 'text(await tools.write_stdin({session_id:42}));', json.dumps({
            'content': [{'type': 'text', 'text': json.dumps({'chunk_id': 'b', 'session_id': 42, 'exit_code': 0, 'output': ''})}]}))
        result = self.audit_records(records)
        self.assertIn('resolved asynchronous observations: 0', result)
        self.assertIn('pending observations (may finish in a later result): 1', result)

    def test_transformed_unindexed_poll_result_is_not_assumed_direct(self):
        records = self.pair('a', '', json.dumps({'chunk_id': 'a', 'session_id': 42, 'output': ''}))
        records += self.pair('b', 'text(await tools.exec_command({cmd:"read"})); text(await tools.write_stdin({session_id:42}).then(transform));',
                             '\n'.join(json.dumps(value) for value in [
                                 {'chunk_id': 'b', 'exit_code': 0, 'output': ''},
                                 {'chunk_id': 'c', 'exit_code': 0, 'output': ''}]))
        result = self.audit_records(records)
        self.assertIn('resolved asynchronous observations: 0', result)
        self.assertIn('pending observations (may finish in a later result): 1', result)

    def test_gui_diagnostic_in_forwarded_repl_text_is_a_failure(self):
        result = self.audit_records(self.pair('a', 'const r=await tools.mcp__node_repl__js({code:"await sky.click(...)"}); for(const c of r.content)text(c.text);',
                                             'Script completed\nOutput:\n\ncoordinate input geometry is unavailable'))
        self.assertIn('failed tool results: 1', result)
        self.assertIn('GUI tool diagnostic', result)

    def test_gui_error_example_in_shell_output_does_not_become_tool_failure(self):
        result = self.audit_records(self.pair('a', 'text(await tools.exec_command({cmd:"example tools.mcp__node_repl__js("}));',
                                             'Script completed\nOutput:\n\ncoordinate input geometry is unavailable'))
        self.assertIn('failed tool results: 0', result)
        self.assertIn('unclassified result formats: 1', result)
        self.assertIn('zero failures is not a clean-run verdict', result)

    def test_process_stdout_remains_data_even_when_it_contains_mcp_error(self):
        result = self.audit_records(self.pair('a', '', json.dumps({'chunk_id': 'a', 'exit_code': 0,
            'output': json.dumps({'isError': True, 'content': []})})))
        self.assertIn('failed tool results: 0', result)

    def audit_records(self, records, *options):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / 'async.jsonl'
            path.write_text('\n'.join(json.dumps(r) for r in records), encoding='utf-8')
            result = run('audit', str(path), *options)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def pair(self, call_id, command, output):
        return [
            {'type': 'response_item', 'payload': {'type': 'custom_tool_call', 'name': 'exec', 'call_id': call_id, 'input': command}},
            {'type': 'response_item', 'payload': {'type': 'custom_tool_call_output', 'call_id': call_id, 'output': output}},
        ]

    def test_nested_process_completion_resolves_earlier_pending_observation(self):
        pending = {'result': {'results': [{'status': 'fulfilled', 'value': {'chunk_id': 'a', 'session_id': 42, 'output': ''}}]}}
        records = self.pair('a', 'text(await tools.exec_command({cmd:"build"}));', 'Script completed\nOutput:\n' + json.dumps(pending))
        records += self.pair('b', 'text(await tools.write_stdin({session_id:42,chars:""}));', 'Script completed\nOutput:\n' + json.dumps({'chunk_id': 'b', 'exit_code': 0, 'output': 'done'}))
        result = self.audit_records(records)
        self.assertIn('pending observations (may finish in a later result): 0', result)
        self.assertIn('resolved asynchronous observations: 1', result)
        self.assertIn('unclassified result formats: 0', result)

    def test_parallel_slots_resolve_only_the_polled_session_and_preserve_failure(self):
        records = self.pair('a', 'text(await tools.exec_command({cmd:"build"}));', json.dumps({'chunk_id': 'a', 'session_id': 42, 'output': ''}))
        records += self.pair('b', 'const js="example"; const r=await Promise.allSettled([tools.exec_command({cmd:js.replace(/\\\'/g,"x")}), tools.write_stdin({session_id:42,chars:""})]); r.forEach((v,i)=>text({i,...v}));',
                             '\n'.join(json.dumps(v) for v in [
                                 {'i': 0, 'status': 'fulfilled', 'value': {'chunk_id': 'b', 'exit_code': 0, 'output': ''}},
                                 {'i': 1, 'status': 'fulfilled', 'value': {'chunk_id': 'c', 'exit_code': 7, 'output': ''}},
                             ]))
        result = self.audit_records(records)
        self.assertIn('pending observations (may finish in a later result): 0', result)
        self.assertIn('resolved asynchronous observations: 1', result)
        self.assertIn('nonzero exits requiring review: 1', result)
        self.assertIn('-> L4 exit_code=7', result)
        bounded = self.audit_records(records, '--to-line', '2')
        self.assertIn('pending observations (may finish in a later result): 1', bounded)
        self.assertIn('resolved asynchronous observations: 0', bounded)

    def test_unrelated_completion_and_quoted_poll_examples_do_not_resolve_pending(self):
        records = self.pair('a', '', json.dumps({'chunk_id': 'a', 'session_id': 42, 'output': ''}))
        records += self.pair('b', 'text(await tools.exec_command({cmd:"tools.write_stdin({session_id:42})"}));', json.dumps({'chunk_id': 'b', 'exit_code': 0, 'output': ''}))
        result = self.audit_records(records)
        self.assertIn('pending observations (may finish in a later result): 1', result)
        self.assertIn('resolved asynchronous observations: 0', result)

    def test_parallel_success_does_not_complete_a_poll_that_is_still_running(self):
        records = self.pair('a', '', json.dumps({'chunk_id': 'a', 'session_id': 42, 'output': ''}))
        records += self.pair('b', 'const r=await Promise.allSettled([tools.exec_command({cmd:"read"}), tools.write_stdin({session_id:42})]); r.forEach((v,i)=>text({i,...v}));',
                             '\n'.join(json.dumps(v) for v in [
                                 {'i': 0, 'status': 'fulfilled', 'value': {'chunk_id': 'b', 'exit_code': 0, 'output': ''}},
                                 {'i': 1, 'status': 'fulfilled', 'value': {'chunk_id': 'c', 'session_id': 42, 'output': ''}},
                             ]))
        result = self.audit_records(records)
        self.assertIn('pending observations (may finish in a later result): 2', result)
        self.assertIn('resolved asynchronous observations: 0', result)

    def test_session_id_reuse_does_not_resolve_a_later_run(self):
        records = self.pair('a', '', json.dumps({'chunk_id': 'a', 'session_id': 42, 'output': ''}))
        records += self.pair('b', 'text(await tools.write_stdin({session_id:42}));', json.dumps({'chunk_id': 'b', 'exit_code': 0, 'output': ''}))
        records += self.pair('c', '', json.dumps({'chunk_id': 'c', 'session_id': 42, 'output': ''}))
        result = self.audit_records(records)
        self.assertIn('pending observations (may finish in a later result): 1', result)
        self.assertIn('resolved asynchronous observations: 1', result)

    def test_truncation_preserves_complete_envelopes_and_reports_missing_information(self):
        records = self.pair('a', '', 'Script completed\nOutput:\nWarning: truncated output\nTotal output lines: 3\n' + json.dumps({'chunk_id': 'x', 'exit_code': 2, 'output': ''}) + '\n{"broken":')
        result = self.audit_records(records)
        self.assertIn('nonzero exits requiring review: 1', result)
        self.assertIn('truncated orchestration output', result)
        self.assertIn('unclassified result formats: 1', result)

    def test_completed_cell_does_not_finish_its_pending_process(self):
        records = self.pair('a', '', 'Script running with cell ID c9')
        records += [
            {'type': 'response_item', 'payload': {'type': 'function_call', 'name': 'wait', 'call_id': 'b', 'arguments': json.dumps({'cell_id': 'c9'})}},
            {'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': 'b', 'output': 'Script completed\nOutput:\n' + json.dumps({'chunk_id': 'x', 'session_id': 9, 'output': ''})}},
        ]
        result = self.audit_records(records)
        self.assertIn('resolved asynchronous observations: 1', result)
        self.assertIn('pending observations (may finish in a later result): 1', result)

    def test_show_bounds_long_lines_and_marks_omissions(self):
        records = self.pair('a', '', 'A' * 20000)
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / 'show.jsonl'
            path.write_text('\n'.join(json.dumps(r) for r in records), encoding='utf-8')
            result = run('show', str(path), '2', '--max-chars', '80')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('19920 chars omitted', result.stdout)
        self.assertLess(len(result.stdout), 200)


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

    def test_wrapped_nonzero_exec_output_is_classified(self):
        result = self.audit('Chunk ID: abc\nWall time: 0.5 seconds\n'
                            'Process exited with code 1\nOriginal token count: 381\nOutput:\n'
                            'specify only one of --comments or --json')
        self.assertIn('nonzero exits requiring review: 1', result)
        self.assertIn('exit_code=1', result)
        self.assertIn('unclassified result formats: 0', result)

    def test_wrapped_success_output_is_classified(self):
        result = self.audit('Chunk ID: abc\nWall time: 0.5 seconds\n'
                            'Process exited with code 0\nOriginal token count: 381\nOutput:\nhello')
        self.assertIn('nonzero exits requiring review: 0', result)
        self.assertIn('unclassified result formats: 0', result)

    def test_wrapped_stdout_exit_text_is_not_a_transport_failure(self):
        result = self.audit('Chunk ID: abc\nWall time: 0.5 seconds\n'
                            'Process exited with code 0\nOriginal token count: 381\nOutput:\n'
                            'Process exited with code 9\nOutput:\nexample')
        self.assertIn('nonzero exits requiring review: 0', result)
        self.assertIn('unclassified result formats: 0', result)

    def test_truncated_wrapped_output_preserves_unknown_boundary(self):
        result = self.audit('Chunk ID: abc\nWall time: 0.5 seconds\n'
                            'Process exited with code 0\nOriginal token count: 381\nOutput:\n'
                            '{"chunk_id": "incomplete"\n'
                            '[CheckedPowerShell output-truncated stream=stdout path=D:/evidence/out.txt]')
        self.assertIn('nonzero exits requiring review: 0', result)
        self.assertIn('unclassified result formats: 1', result)

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


class LineRangeTests(unittest.TestCase):
    """--from-line/--to-line count only records in range; a result in range still names its earlier call."""

    def audit(self, *options):
        def call(stamp, call_id, name, data):
            return {"type": "assistant", "timestamp": stamp, "message": {"role": "assistant", "content": [
                {"type": "tool_use", "id": call_id, "name": name, "input": data}]}}

        def result(stamp, call_id, text, failed=False):
            return {"type": "user", "timestamp": stamp, "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": call_id, "content": text, "is_error": failed}]}}

        records = [
            call("2026-10-29T08:00:00Z", "a", "Bash", {"command": "early"}),
            result("2026-10-29T08:00:01Z", "a", "ok"),
            call("2026-10-29T08:00:02Z", "b", "Read", {"file_path": "D:/docs/a.md"}),
            result("2026-10-29T08:01:40Z", "b", "denied", failed=True),
            call("2026-10-29T08:01:41Z", "c", "Grep", {"pattern": "late"}),
            result("2026-10-29T08:01:42Z", "c", "after range"),
        ]
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / "session.jsonl"
            path.write_text("\n".join(json.dumps(r) for r in records), encoding="utf-8")
            return run("audit", str(path), *options)

    def test_range_counts_only_its_records_and_names_earlier_calls(self):
        result = self.audit("--from-line", "4", "--to-line", "5")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("lines: L4..L5 of L1..L6\n", result.stdout)
        self.assertIn("span: 2026-10-29T08:01:40+00:00 .. 2026-10-29T08:01:41+00:00", result.stdout)
        self.assertIn("blocks: tool_call=1, tool_result=1\n", result.stdout)
        self.assertIn("tool calls: Grep=1\n", result.stdout)
        self.assertIn("L4 2026-10-29T08:01:40Z Read [D:/docs/a.md] denied", result.stdout)
        self.assertIn("L3      98s Read [D:/docs/a.md]", result.stdout)

    def test_open_range_runs_to_the_end(self):
        result = self.audit("--from-line", "3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("lines: L3..L6 of L1..L6\n", result.stdout)
        self.assertIn("tool calls: Read=1, Grep=1\n", result.stdout)

    def test_audit_without_a_range_reports_the_last_line(self):
        # The last line is what a later --from-line or --to-line is chosen from, without counting the raw log.
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("lines: L1..L6\n", result.stdout)

    def test_reversed_range_is_rejected(self):
        result = self.audit("--from-line", "5", "--to-line", "4")
        self.assertEqual(result.returncode, 2)
        self.assertIn("--to-line 4 is before --from-line 5", result.stderr)

    def test_find_reports_only_hits_inside_the_range(self):
        records = [
            {"type": "user", "timestamp": f"2026-10-29T08:00:0{index}Z",
             "message": {"role": "user", "content": f"needle {word}"}}
            for index, word in enumerate(("early", "middle", "late"))
        ]
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / "session.jsonl"
            path.write_text("\n".join(json.dumps(r) for r in records), encoding="utf-8")
            middle = run("find", "needle", str(path), "--from-line", "2", "--to-line", "2")
            tail = run("find", "needle", str(path), "--from-line", "3")
            reversed_range = run("find", "needle", str(path), "--from-line", "3", "--to-line", "2")
        self.assertEqual(middle.returncode, 0, middle.stderr)
        self.assertIn(", 3 lines, 1 hits", middle.stdout)
        self.assertIn("needle middle", middle.stdout)
        self.assertNotIn("needle early", middle.stdout)
        self.assertNotIn("needle late", middle.stdout)
        self.assertIn("needle late", tail.stdout)
        self.assertNotIn("needle middle", tail.stdout)
        self.assertEqual(reversed_range.returncode, 2)
        self.assertIn("--to-line 2 is before --from-line 3", reversed_range.stderr)



class UnknownReplDetailsTests(unittest.TestCase):
    def pair(self, call_id, code, output, name="mcp__node_repl.js"):
        return [
            {"type": "response_item", "payload": {
                "type": "function_call", "name": name, "call_id": call_id,
                "arguments": json.dumps({"code": code})}},
            {"type": "response_item", "payload": {
                "type": "function_call_output", "call_id": call_id, "output": output}},
        ]

    def audit(self, records, *options):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            transcript = Path(directory) / "unknown.jsonl"
            transcript.write_text("\n".join(json.dumps(record) for record in records), encoding="utf-8")
            return run("audit", str(transcript), *options)

    def test_unknown_repl_details_pair_call_and_result_without_reclassifying(self):
        records = self.pair("read-1", "nodeRepl.write(workspaceData);",
                            "Wall time: 0.0119 seconds\nOutput:\nworkspaceData is not defined")
        normal = self.audit(records)
        details = self.audit(records, "--unknown-details")
        self.assertEqual(normal.returncode, 0, normal.stderr)
        self.assertNotIn("unclassified REPL details:", normal.stdout)
        self.assertEqual(details.returncode, 0, details.stderr)
        self.assertIn("failed tool results: 0", details.stdout)
        self.assertIn("unclassified result formats: 1", details.stdout)
        self.assertIn("unclassified REPL details: 1", details.stdout)
        self.assertIn("L1 -> L2 mcp__node_repl.js", details.stdout)
        self.assertIn("call: code: nodeRepl.write(workspaceData);", details.stdout)
        self.assertIn("result: workspaceData is not defined", details.stdout)

    def test_detail_summary_preserves_document_context_before_an_output_example(self):
        records = self.pair("example", 'nodeRepl.write(document);',
                            "Documentation example\nOutput:\nworkspaceData is not defined")
        result = self.audit(records, "--unknown-details")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("result: Documentation example Output: workspaceData is not defined", result.stdout)
        self.assertIn("failed tool results: 0", result.stdout)

    def test_detail_limits_bound_pairs_and_both_summaries_and_mark_omissions(self):
        records = []
        for index in range(8):
            records += self.pair(str(index), "A" * 2000, "B" * 3000)
        result = self.audit(records, "--unknown-details", "--unknown-max", "2", "--unknown-width", "20", "--max", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        details = result.stdout.split("unclassified REPL details: 8\n", 1)[1]
        self.assertEqual(details.count(" -> L"), 2)
        self.assertIn("call: code: " + "A" * 14 + "... [1986 chars omitted]", details)
        self.assertIn("result: " + "B" * 20 + "... [2980 chars omitted]", details)
        self.assertIn("... 6 more (raise --unknown-max)", details)
        self.assertNotIn("L5 -> L6", details)
        self.assertLess(len(details), 500)
        default = self.audit(records, "--unknown-details")
        self.assertEqual(default.returncode, 0, default.stderr)
        default_details = default.stdout.split("unclassified REPL details: 8\n", 1)[1]
        self.assertEqual(default_details.count(" -> L"), 5)
        self.assertIn("... 3 more (raise --unknown-max)", default_details)
        self.assertNotIn("A" * 171, default_details)

    def test_detail_limits_reject_invalid_or_unbounded_values(self):
        records = self.pair("test", "x", "opaque")
        for option, values in (("--unknown-max", ("0", "-1", "41", "all")),
                               ("--unknown-width", ("0", "-1", "401", "all"))):
            for value in values:
                with self.subTest(option=option, value=value):
                    result = self.audit(records, "--unknown-details", option, value)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("expected an integer from 1 to", result.stderr)

    def test_details_find_the_call_before_from_line_and_exclude_later_results(self):
        records = self.pair("first", "firstCall();", "first result")
        records += self.pair("later", "laterCall();", "later result")
        result = self.audit(records, "--unknown-details", "--from-line", "2", "--to-line", "3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("unclassified REPL details: 1", result.stdout)
        self.assertIn("L1 -> L2 mcp__node_repl.js", result.stdout)
        self.assertIn("call: code: firstCall();", result.stdout)
        self.assertNotIn("result: later result", result.stdout)

    def test_details_keep_examples_unknown_and_do_not_repeat_trusted_outcomes(self):
        records = self.pair("exec", "example", "workspaceData is not defined", name="exec_command")
        records += self.pair("doc", "nodeRepl.write(document);",
                             "Documentation: workspaceData is not defined is an example error")
        records += self.pair("failed", "fails();", json.dumps({
            "isError": True, "content": [{"type": "text", "text": "actual failure"}]}))
        records += self.pair("ok", "works();", json.dumps({
            "isError": False, "content": [{"type": "text", "text": "example failure"}]}))
        result = self.audit(records, "--unknown-details")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("failed tool results: 1", result.stdout)
        self.assertIn("unclassified result formats: 2", result.stdout)
        self.assertIn("unclassified REPL details: 1", result.stdout)
        details = result.stdout.split("unclassified REPL details: 1\n", 1)[1]
        self.assertIn("L3 -> L4 mcp__node_repl.js", details)
        self.assertIn("result: Documentation:", details)
        self.assertNotIn("exec_command", details)
        self.assertNotIn("L5 -> L6", details)
        self.assertNotIn("L7 -> L8", details)

    def test_details_do_not_invent_pairs_for_empty_or_unmatched_call_ids(self):
        records = self.pair("", "unidentified();", "unidentified output")
        records += self.pair("call-only", "another();", "orphan output")
        records[-1]["payload"]["call_id"] = "no-such-call"
        result = self.audit(records, "--unknown-details")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("unclassified REPL details: 0", result.stdout)
        self.assertNotIn(" -> L", result.stdout)

    def test_multiple_unknown_observations_in_one_result_have_one_pair(self):
        opaque = {"content": [{"type": "text", "text": json.dumps({
            "chunk_id": "example", "exit_code": 7, "output": "documented envelope"})}]}
        records = self.pair("mixed", "nodeRepl.write(document);", json.dumps([opaque, opaque]))
        result = self.audit(records, "--unknown-details")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("unclassified result formats: 2", result.stdout)
        self.assertIn("unclassified REPL details: 1", result.stdout)
        self.assertEqual(result.stdout.count("L1 -> L2"), 1)


class ToolSearchTests(unittest.TestCase):
    def test_tool_search_call_and_parse_failure_are_visible(self):
        records = [
            {"type": "response_item", "payload": {
                "type": "tool_search_call", "call_id": "search-1",
                "arguments": {"query": "automation_update", "limit": 5}}},
            {"type": "response_item", "payload": {
                "type": "function_call_output", "call_id": "",
                "output": "failed to parse tool_search arguments: invalid number"}},
        ]
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            transcript = Path(directory) / "session.jsonl"
            transcript.write_text("\n".join(json.dumps(record) for record in records), encoding="utf-8")
            found = run("find", "tool_search", str(transcript), "--kind", "tool_call")
            audited = run("audit", str(transcript))
        self.assertEqual(found.returncode, 0, found.stderr)
        self.assertIn("L1", found.stdout)
        self.assertIn("automation_update", found.stdout)
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn("tool_search=1", audited.stdout)
        self.assertIn("failed tool results: 1", audited.stdout)
        self.assertIn("L2  tool_search [automation_update]", audited.stdout)


class DshSessionTests(unittest.TestCase):
    def cli(self, records, command, *options):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            transcript = Path(directory) / 'session.v4.jsonl'
            transcript.write_text('\n'.join(json.dumps(record) for record in records), encoding='utf-8')
            args = (options[0], str(transcript), *options[1:]) if command == 'find' else (str(transcript), *options)
            return run(command, *args)

    def test_nested_assistant_text_is_searchable_and_showable_without_promoting_copied_tools(self):
        copied = {'type': 'tool/call', 'data': {'callId': 'quoted', 'name': 'read',
                  'arguments': {'file_path': 'D:/docs/example.md'}}}
        records = [
            {'type': 'assistant/message', 'data': {'message': {'role': 'assistant', 'content': [
                {'type': 'text', 'text': 'NESTED-ASSISTANT-MARKER'},
                {'type': 'text', 'text': json.dumps(copied)},
            ]}}},
            {'type': 'assistant/message', 'data': {'content': 'LEGACY-ASSISTANT-MARKER'}},
        ]
        found = self.cli(records, 'find', 'NESTED-ASSISTANT-MARKER', '--kind', 'assistant')
        self.assertEqual(found.returncode, 0, found.stderr + found.stdout)
        self.assertIn('L1', found.stdout)
        shown = self.cli(records, 'show', '1', '--max-chars', '80')
        self.assertEqual(shown.returncode, 0, shown.stderr)
        self.assertIn('NESTED-ASSISTANT-MARKER', shown.stdout)
        self.assertIn('chars omitted]', shown.stdout)
        legacy = self.cli(records, 'find', 'LEGACY-ASSISTANT-MARKER', '--kind', 'assistant')
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        quoted = self.cli(records, 'find', 'example.md', '--kind', 'tool_call')
        self.assertEqual(quoted.returncode, 1, quoted.stdout)
        audited = self.cli(records, 'audit')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('blocks: assistant=2\n', audited.stdout)
        self.assertIn('tool calls: \n', audited.stdout)

    def call(self, call_id, name='skill', arguments=None, time=1794215934000):
        return {'type': 'tool/call', 'time': time, 'data': {
            'name': name, 'callId': call_id, 'arguments': arguments or {'name': 'synthetic-skill'}}}

    def result(self, call_id, text='synthetic result', time=1794215934217, failed=False):
        return {'type': 'tool/result', 'time': time, 'data': {'message': {
            'source': {'callId': call_id}, 'isError': failed,
            'content': [{'type': 'text', 'text': text}]}}}

    def test_successful_transport_ignores_stdout_and_document_exit_codes(self):
        document = '{"status":"failed","exitCode":91}\n[status: failed, exit code: 92]'
        records = [self.call('read-doc', 'read'), self.result('read-doc', document),
                   self.call('start', 'pwsh'),
                   self.result('start', document + '\n[still running after 1000ms; moved to background job pwsh-a]'),
                   self.call('poll', 'job_output', {'job_id': 'pwsh-a'}),
                   self.result('poll', document + '\n[status: completed, exit code: 0]')]
        audited = self.cli(records, 'audit')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('failed tool results: 0', audited.stdout)
        self.assertIn('nonzero exits requiring review: 0', audited.stdout)
        self.assertIn('resolved asynchronous observations: 1', audited.stdout)
        self.assertNotIn('exit_code=91', audited.stdout)
        self.assertNotIn('exit_code=92', audited.stdout)

    def test_truncated_notices_and_failed_reads_do_not_close_jobs(self):
        records = [self.call('start', 'pwsh'), self.result('start', 'started background job pwsh-a'),
                   {'type': 'user/message', 'data': {
                       'source': {'kind': 'tool-jobs', 'form': 'notice'},
                       'content': 'background job pwsh-a\n[notice truncated]\nDone; job_output.'}},
                   self.call('poll-error', 'job_output', {'job_id': 'pwsh-a'}),
                   self.result('poll-error', '[status: failed, exit code: 1]', failed=True),
                   self.call(None, 'job_output', {'job_id': 'pwsh-a'}),
                   self.result(None, '[status: completed, exit code: 0]')]
        audited = self.cli(records, 'audit')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('failed tool results: 1', audited.stdout)
        self.assertIn('failed background job notices: 0', audited.stdout)
        self.assertIn('pending observations (may finish in a later result): 1', audited.stdout)
        self.assertIn('resolved asynchronous observations: 0', audited.stdout)
        self.assertIn('unclassified result formats: 2', audited.stdout)

    def test_notice_success_variants_ignore_the_output_body(self):
        for suffix in ('. No new output.', '. Read its output with job_output.',
                       '. Output:\n{"status":"failed","exitCode":9}\n[status: failed, exit code: 9]'):
            with self.subTest(suffix=suffix):
                records = [self.call('start', 'pwsh'), self.result('start', 'started background job pwsh-a'),
                           {'type': 'user/message', 'data': {
                               'source': {'kind': 'tool-jobs', 'form': 'notice'},
                               'content': 'background job pwsh-a (pwsh: synthetic) finished '
                                          '[status: completed, exit code: 0]' + suffix}}]
                audited = self.cli(records, 'audit')
                self.assertEqual(audited.returncode, 0, audited.stderr)
                self.assertIn('failed background job notices: 0', audited.stdout)
                self.assertIn('nonzero exits requiring review: 0', audited.stdout)
                self.assertIn('resolved asynchronous observations: 1', audited.stdout)
                self.assertIn('pending observations (may finish in a later result): 0', audited.stdout)

    def test_scoped_reused_poll_call_ids_keep_their_job_arguments(self):
        records = []
        for turn, job_id, body in ((1, 'pwsh-a', 'started background job pwsh-a'),
                                   (2, 'pwsh-b', 'started background job pwsh-b'),
                                   (3, 'pwsh-a', 'done\n[status: completed, exit code: 0]'),
                                   (4, 'pwsh-b', 'done\n[status: failed, exit code: 1]')):
            pair = [self.call('reused', 'pwsh' if turn <= 2 else 'job_output', {'job_id': job_id}),
                    self.result('reused', body)]
            for record in pair:
                record['data'].update(turn=turn, step=1)
            records.extend(pair)
        audited = self.cli(records, 'audit')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('failed tool results: 1', audited.stdout)
        self.assertIn('pending observations (may finish in a later result): 0', audited.stdout)
        self.assertIn('resolved asynchronous observations: 2', audited.stdout)
        self.assertIn('pwsh-a status=running -> L6 status=completed exit_code=0', audited.stdout)
        self.assertIn('pwsh-b status=running -> L8 status=failed exit_code=1', audited.stdout)

    def test_historical_notice_replacement_is_not_a_new_completion(self):
        notice = {'type': 'user/message', 'surfaceOp': {'op': 'append'}, 'data': {
            'id': 'notice-one', 'source': {'kind': 'tool-jobs', 'form': 'notice'},
            'content': 'background job pwsh-a (pwsh: synthetic) finished '
                       '[status: completed, exit code: 0]. No new output.'}}
        replacement = json.loads(json.dumps(notice))
        replacement['surfaceOp'] = {'op': 'replace', 'startSeq': 3, 'endSeq': 3}
        replacement['data']['content'] = replacement['data']['content'].replace('code: 0', 'code: 1')
        records = [self.call('start', 'pwsh'), self.result('start', 'started background job pwsh-a'),
                   notice, replacement]
        audited = self.cli(records, 'audit')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('failed background job notices: 0', audited.stdout)
        self.assertIn('resolved asynchronous observations: 1', audited.stdout)
        ranged = self.cli(records, 'audit', '--from-line', '4')
        self.assertIn('failed background job notices: 0', ranged.stdout)
        self.assertIn('resolved asynchronous observations: 0', ranged.stdout)
        # Changed append observations are still new evidence, as for tool results.
        replacement['surfaceOp'] = {'op': 'append'}
        changed = self.cli(records, 'audit')
        self.assertIn('failed background job notices: 1', changed.stdout)

    def test_background_notice_requires_protocol_source_and_known_job(self):
        for source, job_id, trusted in (
                ({'kind': 'tool-jobs', 'form': 'notice'}, 'pwsh-a', True),
                ({'kind': 'user', 'form': 'notice'}, 'pwsh-a', False),
                ({'kind': 'tool-jobs', 'form': 'text'}, 'pwsh-a', False),
                (None, 'pwsh-a', False),
                ({'kind': 'tool-jobs', 'form': 'notice'}, 'unrelated', False)):
            with self.subTest(source=source, job_id=job_id):
                notice = {'type': 'user/message', 'data': {'id': 'notice-one', 'role': 'user',
                    'content': f'background job {job_id} (pwsh: synthetic) finished '
                               '[status: completed, exit code: 1]. Output:\n{"exitCode":0}'}}
                if source is not None:
                    notice['data']['source'] = source
                records = [self.call('start', 'pwsh'), self.result('start', 'started background job pwsh-a'),
                           notice, notice]
                audited = self.cli(records, 'audit')
                self.assertEqual(audited.returncode, 0, audited.stderr)
                self.assertIn(f'resolved asynchronous observations: {int(trusted)}', audited.stdout)
                self.assertIn(f'pending observations (may finish in a later result): {int(not trusted)}', audited.stdout)
                self.assertIn(f'failed background job notices: {int(trusted)}', audited.stdout)
                self.assertIn('failed tool results: 0', audited.stdout)
                if trusted:
                    self.assertIn('L2 pwsh: DSH job pwsh-a status=running -> L3 status=completed exit_code=1', audited.stdout)
                    ranged = self.cli(records, 'audit', '--from-line', '3')
                    self.assertIn('failed background job notices: 1', ranged.stdout)
                    self.assertIn('resolved asynchronous observations: 0', ranged.stdout)
                elif job_id == 'unrelated':
                    self.assertIn('unclassified result formats: 1', audited.stdout)

    def test_untrusted_job_results_stay_unknown_and_keep_pending(self):
        mismatched = {'text': '', 'job': {'id': 'different-job', 'kind': 'pwsh', 'label': '',
                      'status': 'completed', 'detail': 'exit code: 1', 'startedAt': 1}}
        for body, arguments in (
                ('{"status":"failed","exitCode":1,"output":""}', {'job_id': 'pwsh-a'}),
                ('Documentation: [status: failed, exit code: 1]', {'job_id': 'pwsh-a'}),
                ('[status: failed, exit code: 1]\nquoted example continues', {'job_id': 'pwsh-a'}),
                ('[status: completed, exit co', {'job_id': 'pwsh-a'}),
                (json.dumps(mismatched), {'job_id': 'pwsh-a'}),
                ('[status: completed, exit code: 1]', {'job_id': ''}),
                ('[status: completed, exit code: 1]', {'job_id': 42})):
            with self.subTest(body=body, arguments=arguments):
                records = [self.call('start', 'pwsh'), self.result('start', 'started background job pwsh-a'),
                           self.call('poll', 'job_output', arguments), self.result('poll', body)]
                audited = self.cli(records, 'audit')
                self.assertEqual(audited.returncode, 0, audited.stderr)
                self.assertIn('failed tool results: 0', audited.stdout)
                self.assertIn('pending observations (may finish in a later result): 1', audited.stdout)
                self.assertIn('resolved asynchronous observations: 0', audited.stdout)
                self.assertIn('unclassified result formats: 1', audited.stdout)

    def test_job_output_structured_transport_keeps_stdout_as_data(self):
        for state, detail, failures, pending in (
                ('completed', 'exit code: 1', 1, 0),
                ('completed', 'exit code: 0', 0, 0),
                ('failed', 'worker failed', 1, 0),
                ('killed', 'cancelled by caller', 1, 0),
                ('running', 'exit code: 7', 0, 2)):
            with self.subTest(state=state, detail=detail):
                envelope = {'text': '{"status":"failed","exitCode":99}', 'job': {
                    'id': 'pwsh-a', 'kind': 'pwsh', 'label': 'synthetic command',
                    'status': state, 'detail': detail, 'startedAt': 1794215934000}}
                records = [self.call('start', 'pwsh'), self.result('start', 'started background job pwsh-a'),
                           self.call('poll', 'job_output', {'job_id': 'pwsh-a'}),
                           self.result('poll', json.dumps(envelope))]
                audited = self.cli(records, 'audit')
                self.assertEqual(audited.returncode, 0, audited.stderr)
                self.assertIn(f'failed tool results: {failures}', audited.stdout)
                self.assertIn(f'pending observations (may finish in a later result): {pending}', audited.stdout)
                self.assertIn(f'resolved asynchronous observations: {int(pending == 0)}', audited.stdout)
                self.assertNotIn('exit_code=99', audited.stdout)
                self.assertNotIn('exit_code=7', audited.stdout)

    def test_job_ids_reconcile_only_matching_pending_observations(self):
        records = [self.call('start-a', 'pwsh'),
                   self.result('start-a', '[still running after 1000ms; moved to background job pwsh-a]'),
                   self.call('start-b', 'pwsh'), self.result('start-b', 'started background job pwsh-b'),
                   self.call('poll-a', 'job_output', {'job_id': 'pwsh-a'}),
                   self.result('poll-a', '(no new output)\n[status: running]'),
                   self.call('poll-b', 'job_output', {'job_id': 'pwsh-b'}),
                   self.result('poll-b', 'done\n[status: completed, exit code: 1]')]
        records.append(records[-1])
        audited = self.cli(records, 'audit', '--sizes')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('pending observations (may finish in a later result): 2', audited.stdout)
        self.assertIn('resolved asynchronous observations: 1', audited.stdout)
        self.assertIn('L4 pwsh: DSH job pwsh-b status=running -> L8 status=completed exit_code=1', audited.stdout)
        self.assertIn('failed tool results: 1', audited.stdout)
        self.assertIn('blocks: tool_call=4, tool_result=4', audited.stdout)
        bounded = self.cli(records, 'audit', '--to-line', '6')
        self.assertIn('pending observations (may finish in a later result): 3', bounded.stdout)
        self.assertIn('resolved asynchronous observations: 0', bounded.stdout)
        ranged = self.cli(records, 'audit', '--from-line', '8')
        self.assertIn('failed tool results: 1', ranged.stdout)
        self.assertIn('pending observations (may finish in a later result): 0', ranged.stdout)
        self.assertIn('resolved asynchronous observations: 0', ranged.stdout)

    def test_job_output_terminal_trailer_reports_failure(self):
        records = [self.call('poll', 'job_output', {'job_id': 'pwsh-one'}),
                   self.result('poll', '{"exitCode":0}\n[status: completed, exit code: 1]')]
        audited = self.cli(records, 'audit')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('failed tool results: 1', audited.stdout)
        self.assertIn('L2 job_output: DSH job pwsh-one status=completed exit_code=1', audited.stdout)

    def test_replayed_results_do_not_inflate_duration_sizes_or_failure_counts(self):
        records = [self.call('skill-1'), self.result('skill-1'),
                   self.result('skill-1', time=1794225535151)]
        audited = self.cli(records, 'audit', '--sizes')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('blocks: tool_call=1, tool_result=1\n', audited.stdout)
        self.assertIn('slow calls (over 60s): 0', audited.stdout)
        self.assertIn('tool result characters: 16 in 1 results', audited.stdout)
        # Even outside the selected range, the first observation identifies a later replay.
        ranged = self.cli(records, 'audit', '--sizes', '--from-line', '3')
        self.assertEqual(ranged.returncode, 0, ranged.stderr)
        self.assertIn('tool result characters: 0 in 0 results', ranged.stdout)
        self.assertIn('slow calls (over 60s): 0', ranged.stdout)
        # A copied call must not move the original start time either.
        records = [self.call('failed', 'pwsh'),
                   self.call('failed', 'pwsh', time=1794215934500),
                   self.result('failed', '[exit code: 1]', time=1794215995000),
                   self.result('failed', '[exit code: 1]', time=1794225535151)]
        failed = self.cli(records, 'audit', '--sizes')
        self.assertEqual(failed.returncode, 0, failed.stderr)
        self.assertIn('tool calls: pwsh=1\n', failed.stdout)
        self.assertIn('failed tool results: 1', failed.stdout)
        self.assertIn('slow calls (over 60s): 1', failed.stdout)
        self.assertIn('L1      61s pwsh', failed.stdout)
        self.assertIn('tool result characters: 14 in 1 results', failed.stdout)

    def test_same_call_id_in_different_turns_or_steps_keeps_each_execution_and_duration(self):
        for second_scope in ((2, 1), (1, 2)):
            with self.subTest(second_scope=second_scope):
                records = [self.call('reused'),
                           self.result('reused', time=1794215995000),
                           self.call('reused', time=1794216034000),
                           self.result('reused', time=1794216096000),
                           self.result('reused', time=1794225535151)]
                for index, scope in enumerate(((1, 1), (1, 1), second_scope, second_scope, (1, 1))):
                    records[index]['seq'] = index + 1
                    records[index]['data'].update(turn=scope[0], step=scope[1])
                for index, message_id in ((1, 'observation-one'), (3, 'observation-two'), (4, 'observation-one')):
                    records[index]['data']['message']['id'] = message_id
                records[1]['surfaceOp'] = {'op': 'append'}
                records[4]['surfaceOp'] = {'op': 'replace', 'startSeq': 2, 'endSeq': 2}
                audited = self.cli(records, 'audit', '--sizes')
                self.assertEqual(audited.returncode, 0, audited.stderr)
                self.assertIn('tool calls: skill=2\n', audited.stdout)
                self.assertIn('blocks: tool_call=2, tool_result=2\n', audited.stdout)
                self.assertIn('tool result characters: 32 in 2 results', audited.stdout)
                self.assertIn('slow calls (over 60s): 2', audited.stdout)
                self.assertIn('L1      61s skill', audited.stdout)
                self.assertIn('L3      62s skill', audited.stdout)
                self.assertNotIn('9601s', audited.stdout)
                found = self.cli(records, 'find', 'synthetic result', '--kind', 'tool_result')
                self.assertEqual(found.returncode, 0, found.stderr)
                self.assertIn('3 hits', found.stdout)
                shown = self.cli(records, 'show', '5')
                self.assertEqual(shown.returncode, 0, shown.stderr)
                self.assertIn('synthetic result', shown.stdout)

    def test_historical_replace_with_shorter_body_is_not_a_new_timed_result(self):
        records = [self.call('history-1'), self.result('history-1', 'A' * 300),
                   self.result('history-1', 'short', time=1794225535151)]
        for index, record in enumerate(records):
            record['seq'] = index + 1
            record['data'].update(turn=1, step=1)
        for record in records[1:]:
            record['data']['message']['id'] = 'same-result-identity'
        records[1]['surfaceOp'] = {'op': 'append'}
        records[2]['surfaceOp'] = {'op': 'replace', 'startSeq': 2, 'endSeq': 2}
        audited = self.cli(records, 'audit', '--sizes')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('blocks: tool_call=1, tool_result=1\n', audited.stdout)
        self.assertIn('tool result characters: 300 in 1 results', audited.stdout)
        self.assertIn('slow calls (over 60s): 0', audited.stdout)
        self.assertNotIn('9601s', audited.stdout)
        ranged = self.cli(records, 'audit', '--sizes', '--from-line', '3')
        self.assertEqual(ranged.returncode, 0, ranged.stderr)
        self.assertIn('tool result characters: 0 in 0 results', ranged.stdout)
        # An append update is new execution evidence even when it retains the message ID.
        appended = self.result('history-1', '[exit code: 7]', time=1794215995000, failed=True)
        appended['data'].update(turn=1, step=1)
        appended['data']['message']['id'] = 'same-result-identity'
        appended['surfaceOp'] = {'op': 'append'}
        changed = self.cli([*records, appended], 'audit', '--sizes')
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertIn('blocks: tool_call=1, tool_result=2\n', changed.stdout)
        self.assertIn('tool result characters: 314 in 2 results', changed.stdout)
        self.assertIn('failed tool results: 1', changed.stdout)
        self.assertIn('slow calls (over 60s): 1', changed.stdout)
        self.assertIn('L1      61s skill', changed.stdout)
        shown = self.cli(records, 'show', '3')
        self.assertEqual(shown.returncode, 0, shown.stderr)
        self.assertIn('short', shown.stdout)

    def test_different_message_ids_preserve_identical_results_in_one_scope(self):
        records = [self.call('reused'), self.result('reused'), self.result('reused')]
        for record in records:
            record['data'].update(turn=1, step=1)
        records[1]['data']['message']['id'] = 'observation-one'
        records[2]['data']['message']['id'] = 'observation-two'
        audited = self.cli(records, 'audit', '--sizes')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('blocks: tool_call=1, tool_result=2\n', audited.stdout)
        self.assertIn('tool result characters: 32 in 2 results', audited.stdout)

    def test_lowercase_read_counts_real_repeats_but_not_replayed_results(self):
        records = [self.call('read-1', 'read', {'file_path': 'D:/docs/repeated.md'}),
                   self.result('read-1', 'hello'),
                   self.result('read-1', 'hello', time=1794225535151),
                   self.call('read-2', 'read', {'file_path': 'D:/docs/repeated.md'}),
                   self.result('read-2', 'hello')]
        audited = self.cli(records, 'audit', '--sizes')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('tool calls: read=2\n', audited.stdout)
        self.assertIn('files read more than once (Read tool): 1', audited.stdout)
        self.assertIn('10 x2 D:/docs/repeated.md  L2..L5', audited.stdout)
        self.assertIn('tool result characters: 10 in 2 results', audited.stdout)
        self.assertIn('slow calls (over 60s): 0', audited.stdout)

    def test_changed_async_results_and_error_status_survive_replay_filter(self):
        records = [self.call('async-1', 'pwsh'),
                   self.result('async-1', 'pending job synthetic-job'),
                   self.result('async-1', 'pending job synthetic-job', time=1794215964000),
                   self.result('async-1', 'completed\n[exit code: 7]', time=1794215995000),
                   self.result('async-1', 'completed\n[exit code: 7]', time=1794225535151)]
        audited = self.cli(records, 'audit', '--sizes')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('blocks: tool_call=1, tool_result=2\n', audited.stdout)
        self.assertIn('failed tool results: 1', audited.stdout)
        self.assertIn('L4 ', audited.stdout)
        self.assertIn('[exit code: 7]', audited.stdout)
        self.assertIn('slow calls (over 60s): 1', audited.stdout)
        self.assertIn('L1      61s pwsh', audited.stdout)
        self.assertIn('tool result characters: 49 in 2 results', audited.stdout)
        # Identical text with a changed explicit error flag is also new evidence.
        changed = [self.call('status-1', 'read'), self.result('status-1', 'same body'),
                   self.result('status-1', 'same body', failed=True)]
        status = self.cli(changed, 'audit', '--sizes')
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn('failed tool results: 1', status.stdout)
        self.assertIn('tool result characters: 18 in 2 results', status.stdout)
        # Results without a trustworthy ID cannot safely be called replays.
        orphaned = [self.result(None, 'same body'), self.result(None, 'same body')]
        orphans = self.cli(orphaned, 'audit', '--sizes')
        self.assertEqual(orphans.returncode, 0, orphans.stderr)
        self.assertIn('tool result characters: 18 in 2 results', orphans.stdout)

    def test_assistant_output_copies_stay_data_and_do_not_add_calls_or_results(self):
        call = self.call('read-copy', 'read', {'file_path': 'D:/docs/copied.md'})
        result = self.result('read-copy', 'COPIED-RESULT-MARKER')
        records = [
            {'type': 'assistant/message', 'data': {'message': {'role': 'assistant', 'content': [
                {'type': 'text', 'text': 'SYNTHETIC-OUTPUT'},
                {'type': 'tool-call', 'toolCallId': 'read-copy', 'toolName': 'read',
                 'input': call['data']['arguments']},
                {'type': 'tool-result', 'toolCallId': 'read-copy', 'toolName': 'read',
                 'output': result['data']['message']['content']},
            ]}}},
            call, result,
        ]
        audited = self.cli(records, 'audit', '--sizes')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('blocks: assistant=1, tool_call=1, tool_result=1\n', audited.stdout)
        self.assertIn('tool calls: read=1\n', audited.stdout)
        self.assertIn('tool result characters: 20 in 1 results', audited.stdout)
        self.assertIn('files read more than once (Read tool): 0', audited.stdout)
        found = self.cli(records, 'find', 'COPIED-RESULT-MARKER', '--kind', 'tool_result')
        self.assertEqual(found.returncode, 0, found.stderr)
        self.assertIn('1 hits', found.stdout)
        self.assertIn('L3 ', found.stdout)
        self.assertNotIn('L1 ', found.stdout)

    def records(self):
        return [
            {"type": "user/message", "time": 1794188611494, "data": {"role": "user", "content": "install the plugin"}},
            {"type": "user/message", "time": 1794188611495, "data": {"role": "user", "content": "<system-reminder>\ncontext"}},
            {"type": "tool/call", "time": 1794188611496, "data": {
                "name": "plugin_manager", "callId": "call-1",
                "arguments": {"action": "install_bundle", "target": "dsh-gpt-image-playground@0.2.8"}}},
            {"type": "tool/result", "time": 1794188611497, "data": {"message": {
                "toolCallId": "call-1", "isError": False,
                "content": [{"type": "text", "text": "[ERR_PNPM_UNEXPECTED_STORE] Unexpected store location"}]}}},
            {"type": "step/start", "time": 1794188611498, "data": {"step": 1}},
        ]

    def test_find_and_audit_read_dsh_jsonl_and_zstd(self):
        import compression.zstd as zstd
        body = "\n".join(json.dumps(record) for record in self.records()).encode()
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            plain = Path(directory) / "session.v4.jsonl"
            packed = Path(directory) / "session.v4.jsonl.zstd"
            plain.write_bytes(body)
            packed.write_bytes(zstd.compress(body))
            found = run("find", "ERR_PNPM_UNEXPECTED_STORE", str(packed), "--kind", "tool_result")
            audited = run("audit", str(plain), "--sizes")
            shown = run("show", str(packed), "3")
        self.assertEqual(found.returncode, 0, found.stderr)
        self.assertIn("(dsh,", found.stdout)
        self.assertIn("L4", found.stdout)
        self.assertNotIn("system-reminder", found.stdout)
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn("tool calls: plugin_manager=1", audited.stdout)
        self.assertIn("failed tool results: 1", audited.stdout)
        self.assertIn("dsh-gpt-image-playground@0.2.8", audited.stdout)
        self.assertNotIn("step/start", audited.stdout)
        self.assertEqual(shown.returncode, 0, shown.stderr)
        self.assertIn("install_bundle", shown.stdout)

    SILENT = 'turns that ended without a final assistant reply (explicit turn/start..turn/end): '
    MESSAGE = 'message=<26 chars>'  # len('synthetic upstream failure')

    def turn_start(self, turn):
        return {'type': 'turn/start', 'data': {'turn': turn}}

    def turn_end(self, turn, reason):
        return {'type': 'turn/end', 'data': {'turn': turn, 'reason': reason}}

    def user(self, text='synthetic request'):
        return {'type': 'user/message', 'data': {'role': 'user', 'content': [{'type': 'text', 'text': text}],
                                                 'source': {'kind': 'user'}}}

    def notice(self):
        return {'type': 'user/message', 'data': {'role': 'user', 'source': {'kind': 'tool-jobs', 'form': 'notice'},
                'content': [{'type': 'text', 'text': 'background job pwsh-x (synthetic) finished '
                                                     '[status: completed, exit code: 0]. No new output.'}]}}

    def reply(self, *content):
        return {'type': 'assistant/message', 'data': {'turn': 1, 'message': {'role': 'assistant', 'content': list(content)}}}

    def text(self, value='Working.'):
        return self.reply({'type': 'text', 'text': value})

    def attempt(self, *stream):
        return {'type': 'assistant/attempt', 'data': {'turn': 1, 'step': 1, 'stream': list(stream)}}

    def failed_attempt(self, code='SYNTHETIC_CODE', message='synthetic upstream failure'):
        return self.attempt(
            {'type': 'chunk', 'chunk': {'type': 'usage', 'usage': {'inputTokens': 0, 'outputTokens': 0, 'totalTokens': 0}}},
            {'type': 'chunk', 'chunk': {'type': 'finish', 'reason': {'kind': 'error', 'failure': {'message': message, 'code': code}}}})

    def error_end(self, turn, code='SYNTHETIC_CODE', message='synthetic upstream failure'):
        return self.turn_end(turn, {'kind': 'error', 'error': {'message': message, 'code': code}})

    def aborted_end(self, turn):
        return self.turn_end(turn, {'kind': 'aborted', 'reason': {'kind': 'user'}})

    def test_turn_ending_without_assistant_text_lists_its_last_attempt_status(self):
        records = [
            self.turn_start(1), self.user(),
            self.reply({'type': 'text', 'text': 'Checking now.'}, {'type': 'tool-call', 'id': 'c1', 'name': 'read'}),
            self.call('c1', 'read'), self.result('c1'),
            # Reasoning and tool calls after the last result are not a reply the user can read.
            self.reply({'type': 'reasoning', 'text': 'thinking'}, {'type': 'tool-call', 'id': 'c2', 'name': 'read'}),
            self.call('c2', 'read'), self.result('c2'),
            self.failed_attempt(), self.error_end(1),
            self.turn_start(2), self.user(), self.attempt(), self.aborted_end(2),
            self.turn_start(3), self.user(), self.turn_end(3, {'kind': 'completed'}),
        ]
        audited = self.cli(records, 'audit')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn(self.SILENT + '3\n', audited.stdout)
        self.assertIn(f'  L1..L10 turn 1 end=error code=SYNTHETIC_CODE {self.MESSAGE}; '
                      'last text L3, last result/message L8\n'
                      f'    last attempt L9: finish=error code=SYNTHETIC_CODE {self.MESSAGE}; '
                      'tokens in=0 out=0 total=0; stream items=2\n', audited.stdout)
        self.assertIn('  L11..L14 turn 2 end=aborted(user); last text missing, last result/message L12\n'
                      '    last attempt L13: finish=missing; tokens=missing; stream items=0\n', audited.stdout)
        self.assertIn('  L15..L17 turn 3 end=completed; last text missing, last result/message L16\n'
                      '    last attempt: missing (no assistant/attempt in turn)\n', audited.stdout)
        self.assertIn('  unpaired turns not judged: 0 ', audited.stdout)
        self.assertIn('read a whole record with: show FILE LINE', audited.stdout)
        self.assertIn('failed tool results: 0', audited.stdout)

    def test_turn_with_final_assistant_text_is_not_listed(self):
        records = [
            self.turn_start(1), self.user(),
            self.call('c1', 'read'), self.result('c1'),
            self.reply({'type': 'text', 'text': 'Done.'}),
            # A later rewrite of an older result is history, not a new result awaiting a reply.
            dict(self.result('c1', 'rewritten'), surfaceOp={'op': 'replace', 'startSeq': 3, 'endSeq': 3}),
            self.turn_end(1, {'kind': 'completed'}),
            self.turn_start(2), self.user(),
            {'type': 'assistant/message', 'data': {'content': 'legacy text reply'}},
            self.turn_end(2, {'kind': 'completed'}),
        ]
        audited = self.cli(records, 'audit')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn(self.SILENT + '0\n  unpaired turns not judged: 0 ', audited.stdout)
        self.assertNotIn('show FILE LINE', audited.stdout)
        unbounded = self.cli([self.user(), self.call('c1', 'read'), self.result('c1')], 'audit')
        self.assertEqual(unbounded.returncode, 0, unbounded.stderr)
        self.assertNotIn('final assistant reply', unbounded.stdout)
        self.assertNotIn('unpaired turns', unbounded.stdout)

    def test_line_range_lists_turns_ending_in_range_judged_on_whole_turn(self):
        records = [
            self.turn_start(1), self.user(), self.error_end(1),
            self.turn_start(2), self.user(), self.text(),
            self.call('c1', 'read'), self.result('c1'), self.failed_attempt('IN_RANGE'), self.error_end(2, 'IN_RANGE'),
            self.turn_start(3), self.user(), self.text('Answer.'), self.turn_end(3, {'kind': 'completed'}),
            self.turn_start(4), self.user(), self.error_end(4, 'AFTER_RANGE'),
        ]
        audited = self.cli(records, 'audit', '--from-line', '9', '--to-line', '16')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn(self.SILENT + '1\n', audited.stdout)
        self.assertIn('  L4..L10 turn 2 end=error code=IN_RANGE', audited.stdout)
        self.assertIn('    last attempt L9: finish=error code=IN_RANGE', audited.stdout)
        self.assertNotIn('L1..L3', audited.stdout)
        self.assertNotIn('AFTER_RANGE', audited.stdout)
        # Turn 4 has no turn/end by --to-line, so it is counted, not judged.
        self.assertIn('  unpaired turns not judged: 1 ', audited.stdout)
        # Turn 3's reply sits before --from-line but still belongs to the turn that ends in range.
        text_before_range = self.cli(records, 'audit', '--from-line', '14', '--to-line', '14')
        self.assertEqual(text_before_range.returncode, 0, text_before_range.stderr)
        self.assertIn(self.SILENT + '0\n  unpaired turns not judged: 0 ', text_before_range.stdout)

    def test_turns_ending_abnormally_after_earlier_text_are_listed(self):
        records = [
            # B1: text and a tool call, then the user aborts before the tool result.
            self.turn_start(1), self.user(),
            self.reply({'type': 'text', 'text': 'Starting.'}, {'type': 'tool-call', 'id': 'c1', 'name': 'read'}),
            self.call('c1', 'read'), self.aborted_end(1),
            # B2: text, then the next attempt fails.
            self.turn_start(2), self.user(), self.text(), self.failed_attempt('B2'), self.error_end(2, 'B2'),
            # E: text, then a background-job notice, then a failed attempt.
            self.turn_start(3), self.user(), self.text(), self.notice(), self.failed_attempt('E'), self.error_end(3, 'E'),
            # A completed turn whose last text precedes a notice has no final reply either.
            self.turn_start(4), self.user(), self.text(), self.notice(), self.turn_end(4, {'kind': 'completed'}),
        ]
        audited = self.cli(records, 'audit')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn(self.SILENT + '4\n', audited.stdout)
        self.assertIn('  L1..L5 turn 1 end=aborted(user); last text L3, last result/message L2\n'
                      '    last attempt: missing', audited.stdout)
        self.assertIn(f'  L6..L10 turn 2 end=error code=B2 {self.MESSAGE}; last text L8, last result/message L7\n'
                      f'    last attempt L9: finish=error code=B2 {self.MESSAGE}', audited.stdout)
        self.assertIn(f'  L11..L16 turn 3 end=error code=E {self.MESSAGE}; last text L13, last result/message L14\n'
                      f'    last attempt L15: finish=error code=E {self.MESSAGE}', audited.stdout)
        self.assertIn('  L17..L21 turn 4 end=completed; last text L19, last result/message L20\n', audited.stdout)

    def test_turn_and_attempt_messages_print_only_their_length(self):
        secret = 'sk-FAKEPREFIX0000 rejected by https://relay.example.invalid/v1 via 203.0.113.7:8443'
        records = [self.turn_start(1), self.user(), self.failed_attempt('LEAK', secret),
                   self.error_end(1, 'LEAK', secret)]
        for options in ((), ('--width', '400')):
            audited = self.cli(records, 'audit', *options)
            self.assertEqual(audited.returncode, 0, audited.stderr)
            self.assertIn(f'end=error code=LEAK message=<{len(secret)} chars>', audited.stdout)
            self.assertIn(f'finish=error code=LEAK message=<{len(secret)} chars>', audited.stdout)
            for fragment in ('sk-FAKE', 'relay.example.invalid', '203.0.113.7', '8443'):
                self.assertNotIn(fragment, audited.stdout)

    def test_attempt_before_the_last_result_is_marked_stale(self):
        records = [
            self.turn_start(1), self.user(), self.failed_attempt('STALE'),
            self.reply({'type': 'text', 'text': 'Retried.'}, {'type': 'tool-call', 'id': 'c1', 'name': 'read'}),
            self.call('c1', 'read'), self.result('c1'), self.aborted_end(1),
        ]
        audited = self.cli(records, 'audit')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn('  L1..L7 turn 1 end=aborted(user); last text L4, last result/message L6\n'
                      '    last attempt L3 (stale: before L6): finish=error code=STALE', audited.stdout)

    def test_unpaired_turns_are_counted_and_error_without_failure_prints_missing(self):
        no_failure = self.attempt({'type': 'chunk', 'chunk': {'type': 'finish', 'reason': {'kind': 'error'}}})
        records = [
            self.turn_start(1), self.user(),                            # overwritten by the next turn/start
            self.turn_start(2), self.user(), no_failure, self.turn_end(2, {'kind': 'error'}),
            self.turn_end(3, {'kind': 'completed'}),                    # turn/end without turn/start
            self.turn_start(4), self.user(), self.turn_end(6, {'kind': 'completed'}),  # mismatch: 4 and 6
            self.turn_start(7), self.user(),                            # still open at the end
        ]
        audited = self.cli(records, 'audit')
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn(self.SILENT + '1\n', audited.stdout)
        self.assertIn('  L3..L6 turn 2 end=error code=missing message=missing; last text missing, '
                      'last result/message L4\n'
                      '    last attempt L5: finish=error code=missing message=missing; tokens=missing; stream items=1\n',
                      audited.stdout)
        self.assertIn('  unpaired turns not judged: 5 ', audited.stdout)
        start_only = self.cli([self.turn_start(1), self.user()], 'audit')
        self.assertEqual(start_only.returncode, 0, start_only.stderr)
        self.assertIn(self.SILENT + '0\n  unpaired turns not judged: 1 ', start_only.stdout)

    def test_dsh_read_result_quoting_errors_is_not_a_failure(self):
        records = [
            {"type": "tool/call", "time": 1794188611496, "data": {
                "name": "read", "callId": "read-1",
                "arguments": {"file_path": "D:/docs/plugin-install.md"}}},
            {"type": "tool/result", "time": 1794188611497, "data": {"message": {
                "toolCallId": "read-1", "isError": False,
                "content": [{"type": "text", "text": (
                    "Documentation: ERR_PNPM_UNEXPECTED_STORE is a failure example. "
                    "A killed process settles as [exit code: 1]."
                )}]}}},
        ]
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            transcript = Path(directory) / "session.v4.jsonl"
            transcript.write_text("\n".join(json.dumps(record) for record in records), encoding="utf-8")
            audited = run("audit", str(transcript))
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn("tool calls: read=1", audited.stdout)
        self.assertIn("failed tool results: 0", audited.stdout)
        self.assertNotIn("read [D:/docs/plugin-install.md]", audited.stdout)


class BridgeTests(unittest.TestCase):
    """Magpie bridge backend copies are skipped unless asked for; headers show record times."""

    @staticmethod
    def write(path, stamps):
        path.parent.mkdir(parents=True, exist_ok=True)
        records = [{"type": "user", "timestamp": stamp, "message": {"role": "user", "content": "bridge-needle"}}
                   for stamp in stamps]
        path.write_text("\n".join(json.dumps(r) for r in records), encoding="utf-8")

    @staticmethod
    def local(stamp, pattern):
        moment = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone()
        return moment.strftime(pattern)

    def test_walk_skips_bridge_copies_and_reports_them(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            projects = Path(directory) / "projects"
            bridge = projects / "D--Codex-temp-magpie-claude-work" / "copy.jsonl"
            own = projects / "D--agents-projects-misc" / "own.jsonl"
            self.write(bridge, ["2026-11-11T07:51:17Z"])
            self.write(own, ["2026-11-11T07:00:00Z"])
            default = run("find", "bridge-needle", str(projects))
            included = run("find", "bridge-needle", str(projects), "--bridge")
            direct = run("find", "bridge-needle", str(bridge))
        self.assertEqual(default.returncode, 0, default.stderr)
        self.assertIn("own.jsonl", default.stdout)
        self.assertNotIn("copy.jsonl", default.stdout)
        self.assertIn("1 of 1 transcripts matched; 1 Magpie bridge backend copies not searched (add --bridge)",
                      default.stdout)
        self.assertIn("copy.jsonl  (claude bridge,", included.stdout)
        self.assertIn("2 of 2 transcripts matched\n", included.stdout)
        self.assertIn("copy.jsonl  (claude bridge,", direct.stdout)
        self.assertNotIn("not searched", direct.stdout)

    def test_header_shows_first_and_last_record_times(self):
        first, last = "2026-11-11T07:51:17Z", "2026-11-11T07:56:21Z"
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / "session.jsonl"
            self.write(path, [first, "2026-11-11T07:53:00Z", last])
            found = run("find", "bridge-needle", str(path))
        expected = (f"records {self.local(first, '%Y-%m-%d %H:%M')}..{self.local(last, '%H:%M')}, 3 lines, 3 hits")
        self.assertEqual(found.returncode, 0, found.stderr)
        self.assertIn(expected, found.stdout)


class AntigravityTranscriptTests(unittest.TestCase):
    """Google Antigravity transcript.jsonl records pair FIFO calls/results, timing, exits, tasks and walks."""

    @staticmethod
    def sample_records():
        return [
            {"step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "status": "DONE",
             "created_at": "2026-11-21T00:00:00Z", "content": "please inspect repo"},
            {"step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
             "created_at": "2026-11-21T00:00:01Z", "thinking": "check files first",
             "tool_calls": [
                 {"name": "read_file", "args": {"Path": json.dumps("D:/work/app.js")}},
                 {"name": "run_command", "args": {"CommandLine": json.dumps("gh issue list"), "toolSummary": json.dumps("List issues")}},
             ]},
            {"step_index": 2, "source": "MODEL", "type": "GENERIC", "status": "DONE",
             "created_at": "2026-11-21T00:00:02Z",
             "content": "Created At: 2026-11-21T08:00:02+08:00\nCompleted At: 2026-11-21T08:00:03+08:00\nCommand exited with code 9.\nexample doc text"},
            {"step_index": 3, "source": "MODEL", "type": "GENERIC", "status": "DONE",
             "created_at": "2026-11-21T00:00:02Z",
             "content": "Created At: 2026-11-21T08:00:02+08:00\nCompleted At: 2026-11-21T08:01:15+08:00\nCommand exited with code 1.\n\nCommand output:\nproxy error"},
            {"step_index": 4, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
             "created_at": "2026-11-21T00:01:16Z",
             "tool_calls": [
                 {"name": "read_file", "args": {"Path": json.dumps("D:/work/app.js")}},
                 {"name": "run_command", "args": {"CommandLine": json.dumps("npm run verify")}},
                 {"name": "edit_file", "args": {"Path": json.dumps("D:/work/missing.js")}},
             ]},
            {"step_index": 5, "source": "MODEL", "type": "GENERIC", "status": "DONE",
             "created_at": "2026-11-21T00:01:17Z",
             "content": "Created At: 2026-11-21T08:01:17+08:00\nCompleted At: 2026-11-21T08:01:17+08:00\nsecond read"},
            {"step_index": 6, "source": "MODEL", "type": "GENERIC", "status": "RUNNING",
             "created_at": "2026-11-21T00:01:17Z",
             "content": "Created At: 2026-11-21T08:01:17+08:00\nTool is running as a background task with task id: conv-1/task-6"},
            {"step_index": 7, "source": "MODEL", "type": "GENERIC", "status": "ERROR", "error": "file does not exist",
             "created_at": "2026-11-21T00:01:18Z",
             "content": "Created At: 2026-11-21T08:01:18+08:00\nCompleted At: 2026-11-21T08:01:18+08:00\nEncountered error: file does not exist"},
            {"step_index": 8, "source": "SYSTEM", "type": "SYSTEM_MESSAGE", "status": "DONE",
             "created_at": "2026-11-21T00:01:30Z",
             "content": '<SYSTEM_MESSAGE>\n[Message] content=Task id "conv-1/task-6" finished with result:\nCommand exited with code 0.\n</SYSTEM_MESSAGE>'},
            {"step_index": 9, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
             "created_at": "2026-11-21T00:01:31Z", "content": "all done"},
        ]

    def test_audit_pairs_calls_exits_slow_reads_and_background_tasks(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / "transcript.jsonl"
            path.write_text("\n".join(json.dumps(r) for r in self.sample_records()), encoding="utf-8")
            audited = run("audit", str(path), "--sizes")
            expected = run("audit", str(path), "--expected-exit", "4:1")
            ranged = run("audit", str(path), "--from-line", "4", "--to-line", "4")
        self.assertEqual(audited.returncode, 0, audited.stderr)
        self.assertIn("span: 2026-11-21T00:00:00+00:00 .. 2026-11-21T00:01:31+00:00", audited.stdout)
        self.assertIn("tool calls: read_file=2, run_command=2, edit_file=1", audited.stdout)
        self.assertIn("failed tool results: 1", audited.stdout)
        self.assertIn("L8 2026-11-21T00:01:18Z edit_file [D:/work/missing.js]", audited.stdout)
        self.assertIn("nonzero exits requiring review: 1", audited.stdout)
        self.assertIn("L4 run_command: exit_code=1 [gh issue list]", audited.stdout)
        self.assertNotIn("exit_code=9", audited.stdout)
        self.assertIn("slow calls (over 60s): 1", audited.stdout)
        self.assertIn("L2      73s run_command [gh issue list]", audited.stdout)
        self.assertIn("pending observations (may finish in a later result): 0", audited.stdout)
        self.assertIn("resolved asynchronous observations: 1", audited.stdout)
        self.assertIn("L7 run_command: background task conv-1/task-6 -> L9 exit_code=0", audited.stdout)
        self.assertIn("files read more than once (Read tool): 1", audited.stdout)
        self.assertIn("x2 D:/work/app.js  L3..L6", audited.stdout)
        self.assertIn("expected nonzero exits (operator annotations): 1", expected.stdout)
        self.assertIn("nonzero exits requiring review: 0", expected.stdout)
        self.assertEqual(ranged.returncode, 0, ranged.stderr)
        self.assertIn("L4 run_command: exit_code=1 [gh issue list]", ranged.stdout)

    def test_find_walks_logs_without_chunks_or_full_duplicates_and_show_decodes_args(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            logs = Path(directory) / "conv-1" / ".system_generated" / "logs"
            (logs / "chunks" / "transcript").mkdir(parents=True)
            text = "\n".join(json.dumps(r) for r in self.sample_records())
            compact = logs / "transcript.jsonl"
            full = logs / "transcript_full.jsonl"
            chunk = logs / "chunks" / "transcript" / "00000000.jsonl"
            compact.write_text(text, encoding="utf-8")
            full.write_text(text, encoding="utf-8")
            chunk.write_text(text, encoding="utf-8")
            found = run("find", "gh issue list", directory)
            direct_full = run("find", "gh issue list", str(full))
            shown = run("show", str(compact), "2")
        self.assertEqual(found.returncode, 0, found.stderr)
        self.assertIn("(antigravity,", found.stdout)
        self.assertIn("1 of 1 transcripts matched", found.stdout)
        self.assertNotIn("transcript_full.jsonl", found.stdout)
        self.assertNotIn("00000000.jsonl", found.stdout)
        self.assertEqual(direct_full.returncode, 0, direct_full.stderr)
        self.assertIn("transcript_full.jsonl", direct_full.stdout)
        self.assertEqual(shown.returncode, 0, shown.stderr)
        self.assertIn("Path: D:/work/app.js", shown.stdout)
        self.assertIn("CommandLine: gh issue list", shown.stdout)

    def test_find_regex_alternation_ignore_case_and_invalid_pattern(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / "transcript.jsonl"
            path.write_text("\n".join(json.dumps(r) for r in self.sample_records()) + "\n", encoding="utf-8")
            literal = run("find", "gh issue list|missing.js", str(path))
            matched = run("find", "gh issue list|missing\\.js", str(path), "--regex", "--kind", "tool_call")
            folded = run("find", "GH ISSUE|MISSING\\.JS", str(path), "--regex", "-i", "--kind", "tool_call")
            invalid = run("find", "[unclosed", str(path), "--regex")
        self.assertEqual(literal.returncode, 1, literal.stderr)
        self.assertIn("0 of 1 transcripts matched", literal.stdout)
        self.assertEqual(matched.returncode, 0, matched.stderr)
        self.assertIn("1 of 1 transcripts matched", matched.stdout)
        self.assertIn("L2 ", matched.stdout)
        self.assertIn("L5 ", matched.stdout)
        self.assertEqual(folded.returncode, 0, folded.stderr)
        self.assertIn("1 of 1 transcripts matched", folded.stdout)
        self.assertEqual(invalid.returncode, 2)
        self.assertIn("invalid --regex", invalid.stderr)


if __name__ == "__main__":
    unittest.main()
