#!/usr/bin/env python3
"""A local stand-in for the model API: logs every request and answers with valid, empty work. No paid call."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log_path, delay = sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 0
verdict = sys.argv[3] if len(sys.argv) > 3 else None
count = 0


def value(schema, key=""):
    kind = schema.get("type")
    if kind == "object":
        return {k: value(v, k) for k, v in schema.get("properties", {}).items()}
    if kind == "array":
        return []
    if kind == "boolean":
        return False
    if kind in ("integer", "number"):
        return 0
    if schema.get("enum"):
        return verdict if verdict in schema["enum"] else schema["enum"][0]
    if key in ("user_name", "detail", "note", "add_goal", "question_for_user", "connect", "task"):
        return ""
    return f"Agent{count}" if key == "name" else f"fake {key}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        global count
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        count += 1
        with open(log_path, "a") as log:
            log.write(json.dumps(body) + "\n")
        time.sleep(delay)
        message = {"content": ""}
        names = [t["function"]["name"] for t in body.get("tools", [])]
        if "finish" in names:
            message["tool_calls"] = [{"id": f"call{count}", "function": {"name": "finish", "arguments": json.dumps({"summary": "fake summary", "settled_questions": []})}}]
        elif "response_format" in body:
            message["content"] = json.dumps(value(body["response_format"]["json_schema"]["schema"]))
        reply = json.dumps({"choices": [{"message": message}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
