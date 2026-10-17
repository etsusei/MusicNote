"""Stdio MCP server that exposes Musicnote's analysis tools to Claude Code.

The tools themselves run inside the Musicnote app (same toolbox as the Codex route, so scope,
budget and the review trail are enforced there). This bridge only speaks MCP on stdin/stdout
and forwards each call over a Unix socket the app opened for this one analysis run.

Environment: MUSICNOTE_MCP_SOCKET (socket path), MUSICNOTE_MCP_TOKEN (per-run secret).
Socket protocol: one JSON object per line.
  -> {"token", "op": "list"}                         <- {"tools": [...]}
  -> {"token", "op": "call", "name", "arguments"}    <- {"text", "ok"}
Standard library only; requests are handled one at a time.
"""
import json
import os
import socket
import sys

PROTOCOL = "2025-06-18"


class App:
    def __init__(self, path, token):
        self.token = token
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.reader = self.sock.makefile("r", encoding="utf-8")

    def ask(self, msg):
        msg["token"] = self.token
        self.sock.sendall((json.dumps(msg, ensure_ascii=False) + "\n").encode("utf-8"))
        line = self.reader.readline()
        if not line:
            raise ConnectionError("Musicnote closed the tool connection")
        return json.loads(line)


def send(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    app = App(os.environ["MUSICNOTE_MCP_SOCKET"], os.environ["MUSICNOTE_MCP_TOKEN"])
    tools = app.ask({"op": "list"}).get("tools", [])
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            continue
        method, rid = req.get("method"), req.get("id")
        if rid is None:  # notification (initialized, cancelled, ...)
            continue
        params = req.get("params") or {}
        if method == "initialize":
            result = {"protocolVersion": params.get("protocolVersion", PROTOCOL),
                      "capabilities": {"tools": {"listChanged": False}},
                      "serverInfo": {"name": "musicnote", "version": "1"}}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": tools}
        elif method == "tools/call":
            try:
                r = app.ask({"op": "call", "name": params.get("name", ""), "arguments": params.get("arguments") or {}})
                result = {"content": [{"type": "text", "text": r.get("text", "")}], "isError": not r.get("ok", False)}
            except (OSError, ValueError) as e:
                result = {"content": [{"type": "text", "text": "ERROR TOOL_BRIDGE: %s" % e}], "isError": True}
        else:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found: %s" % method}})
            continue
        send({"jsonrpc": "2.0", "id": rid, "result": result})


if __name__ == "__main__":
    main()
