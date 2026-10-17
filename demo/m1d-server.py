#!/usr/bin/env python3
"""
M1-D demo loopback server: scripted 10-step coding dialogue.
Listens on 127.0.0.1:0 (ephemeral), prints PORT:<port> to stdout,
captures every request body to --capture file, and responds with
paced SSE chunks.
"""
import argparse, json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
import socket

# Scripted responses: each request index maps to a SSE body
def sse_event(obj):
    return f"data: {json.dumps(obj, separators=(',', ':'))}\n\n"

def sse_done():
    return "data: [DONE]\n\n"

# Predefined tool calls and results for verification
TOOL_CALLS = [
    # Request 1 -> read
    {
        "id": "call-read-1",
        "name": "read",
        "arguments": json.dumps({"path": "src/main.py"}, separators=(',', ':'))
    },
    # Request 2 -> edit
    {
        "id": "call-edit-1",
        "name": "edit",
        "arguments": json.dumps({"path": "src/main.py", "old": "old", "new": "new"}, separators=(',', ':'))
    },
    # Request 3 -> exec (pytest)
    {
        "id": "call-exec-1",
        "name": "exec",
        "arguments": json.dumps({"command": "pytest"}, separators=(',', ':'))
    },
    # Request 4 -> repair edit
    {
        "id": "call-edit-2",
        "name": "edit",
        "arguments": json.dumps({"path": "src/main.py", "old": "bad", "new": "fixed"}, separators=(',', ':'))
    },
]

def tool_call_body(tc, finish="tool_calls"):
    id_ = tc.get("id") or "call-1"
    name = tc.get("name")
    arguments = tc.get("arguments") or "{}"
    body = sse_event({"id":"chatcmpl-neg","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":id_,"function":{"name":name,"arguments":arguments}}]},"finish_reason":None}]})
    body += sse_event({"id":"chatcmpl-neg","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{},"finish_reason":finish}]})
    body += sse_done()
    return body

def final_text_body(text):
    body = sse_event({"id":"chatcmpl-neg","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{"role":"assistant","content":text},"finish_reason":None}]})
    body += sse_event({"id":"chatcmpl-neg","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]})
    body += sse_event({"id":"chatcmpl-neg","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}})
    body += sse_done()
    return body

def slow_delta_body():
    parts = []
    for word in ("first ", "second ", "third "):
        parts.append(sse_event({"id":"chatcmpl-neg","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{"role":"assistant","content":word},"finish_reason":None}]}))
    return "".join(parts)

def response_for_request(idx, mode):
    """Return SSE body string for request idx (0-based) and failure mode."""
    if mode == "demo":
        return demo_response(idx)
    if mode == "deny-edit":
        if idx == 0:
            tc = TOOL_CALLS[1]
            return tool_call_body(tc, finish="tool_calls")
        return final_text_body("denial acknowledged; stop")
    if mode == "approval-exec":
        tc = TOOL_CALLS[2]
        return tool_call_body(tc, finish="tool_calls")
    if mode == "malformed-args":
        tc = {"id": "call-bad-1", "name": "read", "arguments": "not-json"}
        return tool_call_body(tc, finish="tool_calls")
    if mode == "incomplete" or mode == "bad-sse":
        if mode == "bad-sse":
            return "data: {not-json}\n\n"
        return sse_event({"id":"chatcmpl-neg","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{"content":"incomplete answer"},"finish_reason":None}]})
    if mode == "sealed":
        tc = TOOL_CALLS[0]
        return tool_call_body(tc, finish="tool_calls")
    if mode == "exhaust":
        tc = TOOL_CALLS[0]
        return tool_call_body(tc, finish="tool_calls")
    if mode == "abort":
        return sse_event({"id":"chatcmpl-neg","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{"content":"partial then abort"},"finish_reason":None}]})
    if mode == "slow-delta":
        return slow_delta_body()
    if mode == "secret-control":
        canary = "credential-canary-zzz"
        text = canary + "\\u001b"
        return (sse_event({"id":"chatcmpl-neg","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{"role":"assistant","content":text},"finish_reason":None}]})
                + sse_event({"id":"chatcmpl-neg","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]})
                + sse_event({"id":"chatcmpl-neg","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}})
                + sse_done())
    return demo_response(idx)

def demo_response(idx):
    """Original M1-D demo loopback behavior."""
    if idx == 0:
        # read
        tc = TOOL_CALLS[0]
        body =  sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":tc["id"],"function":{"name":tc["name"],"arguments":tc["arguments"]}}]},"finish_reason":None}]})
        body += sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]})
        body += sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}})
        body += sse_done()
        return body
    elif idx == 1:
        tc = TOOL_CALLS[1]
        body =  sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":tc["id"],"function":{"name":tc["name"],"arguments":tc["arguments"]}}]},"finish_reason":None}]})
        body += sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]})
        body += sse_done()
        return body
    elif idx == 2:
        tc = TOOL_CALLS[2]
        body =  sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":tc["id"],"function":{"name":tc["name"],"arguments":tc["arguments"]}}]},"finish_reason":None}]})
        body += sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]})
        body += sse_done()
        return body
    elif idx == 3:
        tc = TOOL_CALLS[3]
        body =  sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":tc["id"],"function":{"name":tc["name"],"arguments":tc["arguments"]}}]},"finish_reason":None}]})
        body += sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]})
        body += sse_done()
        return body
    elif idx == 4:
        # final answer
        body =  sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{"role":"assistant","content":"All done - bug fixed and tests pass"},"finish_reason":None}]})
        body += sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]})
        body += sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[],"usage":{"prompt_tokens":50,"completion_tokens":10}})
        body += sse_done()
        return body
    else:
        # Should not happen
        body = sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{"content":"unexpected"},"finish_reason":None}]})
        body += sse_event({"id":"chatcmpl-demo","object":"chat.completion.chunk","created":1,"model":"demo-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]})
        body += sse_done()
        return body

# Reusable negative-demo modes (single synthetic endpoint, no per-test
# server implementation): demo plus the ten bounded failure modes.
SERVER_MODE = "demo"

class DemoHandler(BaseHTTPRequestHandler):
    request_count = 0
    capture_path = None

    def do_POST(self):
        if self.path != "/chat/completions":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length) if length > 0 else b''
        # Capture
        if DemoHandler.capture_path:
            with open(DemoHandler.capture_path, 'a') as f:
                f.write(json.dumps({"request_index": DemoHandler.request_count, "body": body.decode('utf-8', errors='replace')}) + "\n")
        idx = DemoHandler.request_count
        DemoHandler.request_count += 1
        mode = getattr(self.server, "mode", SERVER_MODE)
        resp_body = response_for_request(idx, mode)
        # Send as SSE with paced chunks (simulate network chunking)
        resp_bytes = resp_body.encode('utf-8')

        if mode == "abort":
            # FIN vs preSend: first content byte arrived, then the socket
            # dies (postContent). Never re-dial.
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                self.wfile.write(resp_bytes[:64])
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True
            try:
                self.connection.close()
            except OSError:
                pass
            return

        if mode == "slow-delta":
            # Cancellation / closed consumer: emit one observable delta, then
            # hold the stream open without an authoritative completion.
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                self.wfile.write(resp_bytes[:64])
                self.wfile.flush()
                time.sleep(0.2)
                for i in range(64, len(resp_bytes), 64):
                    self.wfile.write(resp_bytes[i:i+64])
                    self.wfile.flush()
                    time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError):
                pass
            time.sleep(8.0)
            self.close_connection = True
            return

        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(resp_bytes)))
        self.send_header('Connection', 'close')
        self.end_headers()
        # Paced: send in small chunks with delay
        chunk_size = 64
        for i in range(0, len(resp_bytes), chunk_size):
            chunk = resp_bytes[i:i+chunk_size]
            try:
                self.wfile.write(chunk)
                self.wfile.flush()
            except BrokenPipeError:
                break
            time.sleep(0.02)  # 20ms per chunk

    def log_message(self, format, *args):
        pass  # suppress

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--capture', required=True, help='File to append captured requests')
    parser.add_argument('--port', type=int, default=0, help='Port to listen (0 for ephemeral)')
    parser.add_argument('--mode', default='demo', choices=['demo','deny-edit','approval-exec','malformed-args','incomplete','bad-sse','sealed','exhaust','abort','slow-delta','secret-control'], help='Scripted endpoint mode')
    args = parser.parse_args()
    DemoHandler.capture_path = args.capture
    # Clear capture file
    open(args.capture, 'w').close()
    server = HTTPServer(('127.0.0.1', args.port), DemoHandler)
    server.mode = args.mode
    port = server.server_address[1]
    print(f"PORT:{port}", flush=True)
    print(f"Demo server listening on 127.0.0.1:{port} in {args.mode} mode, capturing to {args.capture}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == '__main__':
    main()
