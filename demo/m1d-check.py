#!/usr/bin/env python3
"""
M1-D demo checker: verifies every captured HTTP request contains
the expected ordered conversation, exact call IDs, arguments, and
tool-result pairing, plus JSONL trace.
"""
import json, sys, pathlib

def check_capture(capture_path):
    lines = open(capture_path).read().strip().split('\n') if open(capture_path).read().strip() else []
    if not lines or lines == ['']:
        print("FAIL: no captured requests")
        sys.exit(1)
    requests = []
    for line in lines:
        if not line.strip():
            continue
        obj = json.loads(line)
        body = json.loads(obj["body"])
        requests.append(body)

    print(f"Captured {len(requests)} requests")
    if len(requests) != 5:
        print(f"FAIL: expected 5 requests, got {len(requests)}")
        sys.exit(1)

    # Expected tool calls in order
    expected_calls = [
        ("call-read-1", "read", {"path": "src/main.py"}),
        ("call-edit-1", "edit", {"path": "src/main.py", "old": "old", "new": "new"}),
        ("call-exec-1", "exec", {"command": "pytest"}),
        ("call-edit-2", "edit", {"path": "src/main.py", "old": "bad", "new": "fixed"}),
    ]
    # Check each request's messages are ordered and contain expected history
    for idx, req in enumerate(requests):
        msgs = req["messages"]
        print(f"\nRequest {idx+1}: {len(msgs)} messages")
        for m in msgs:
            content = m.get('content') or ''
            print(f"  {m['role']}: {str(content)[:50]!r} {m.get('tool_calls','')!r} {m.get('tool_call_id','')!r}")

        # Request 1: only user prompt
        if idx == 0:
            assert len(msgs) == 1 and msgs[0]["role"] == "user", f"req1 should be single user, got {msgs}"
        # Request 2: user + assistant with read call + tool response
        elif idx == 1:
            assert msgs[0]["role"] == "user"
            assert msgs[1]["role"] == "assistant" and "tool_calls" in msgs[1], "req2 missing assistant tool_calls"
            assert msgs[1]["tool_calls"][0]["id"] == "call-read-1", f"wrong id {msgs[1]['tool_calls'][0]['id']}"
            assert msgs[1]["tool_calls"][0]["function"]["name"] == "read"
            # Arguments may be stringified JSON, check parsed
            args = json.loads(msgs[1]["tool_calls"][0]["function"]["arguments"])
            assert args == {"path": "src/main.py"}, f"wrong args {args}"
            assert msgs[2]["role"] == "tool" and msgs[2]["tool_call_id"] == "call-read-1", "tool response pairing"
        # Request 3: should have previous plus edit call and its response
        elif idx == 2:
            # user, assistant read, tool read, assistant edit, tool edit response
            assert len(msgs) == 5, f"req3 should have 5 msgs, got {len(msgs)}"
            assert msgs[3]["role"] == "assistant" and msgs[3]["tool_calls"][0]["id"] == "call-edit-1"
            assert msgs[4]["role"] == "tool" and msgs[4]["tool_call_id"] == "call-edit-1"
        # Request 4: should have exec call and its failure response
        elif idx == 3:
            assert len(msgs) == 7, f"req4 should have 7 msgs, got {len(msgs)}"
            assert any(m.get("tool_calls") and m["tool_calls"][0]["id"] == "call-exec-1" for m in msgs), "req4 missing exec"
            # Last two should be exec call and its tool failure
            assert msgs[5]["role"] == "assistant" and msgs[5]["tool_calls"][0]["id"] == "call-exec-1"
            assert msgs[6]["role"] == "tool" and msgs[6]["tool_call_id"] == "call-exec-1"
        # Request 5: should have all previous plus final
        elif idx == 4:
            # Should contain all 4 tool calls and their responses in order, plus final user? Actually no new user, just previous history
            # Check that all expected call IDs appear in order in assistant messages
            all_ids = []
            for m in msgs:
                if "tool_calls" in m:
                    for tc in m["tool_calls"]:
                        all_ids.append(tc["id"])
            assert all_ids == ["call-read-1", "call-edit-1", "call-exec-1", "call-edit-2"], f"wrong ordered ids {all_ids}"
            # Check tool responses are paired in order
            tool_responses = [m["tool_call_id"] for m in msgs if m["role"] == "tool"]
            assert tool_responses == ["call-read-1", "call-edit-1", "call-exec-1", "call-edit-2"], f"wrong tool response order {tool_responses}"

    print("\nAll request transcript checks passed!")
    return requests

def check_jsonl(trace_path):
    if not pathlib.Path(trace_path).exists():
        print(f"FAIL: trace {trace_path} not found")
        sys.exit(1)
    lines = open(trace_path).read().strip().split('\n')
    print(f"\nJSONL trace: {len(lines)} lines")
    seqs = []
    kinds = []
    for line in lines:
        if not line.strip():
            continue
        obj = json.loads(line)
        assert "format_version" in obj and obj["format_version"] == 1
        assert "session_id" in obj
        assert "seq" in obj
        assert "kind" in obj
        seqs.append(obj["seq"])
        kinds.append(obj["kind"])
        # Check no raw control bytes in payload
        payload_str = json.dumps(obj["payload"])
        assert "\x1b" not in payload_str, "control byte in payload"
    # Check seq monotonic
    assert seqs == sorted(seqs), f"seq not monotonic {seqs}"
    assert "run_finished" in kinds, "missing run_finished"
    print(f"kinds: {kinds}")
    print("JSONL checks passed!")

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("usage: m1d-check.py <capture> <trace>")
        sys.exit(2)
    check_capture(sys.argv[1])
    check_jsonl(sys.argv[2])
    print("\nDEMO CHECK PASSED")
