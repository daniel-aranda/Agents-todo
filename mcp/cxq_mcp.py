#!/usr/bin/env python3
"""cxq MCP server: stdio JSON-RPC wrapper around the cxq CLI.

Speaks the Model Context Protocol over stdio using newline-delimited
JSON-RPC 2.0, exposing seven tools: list_tasks, add_task, claim_task,
update_task, note, board, stats.

Design note (why it shells out to the CLI):
  The server does NOT talk to the SQLite database directly. Every tool
  call runs one `cxq` CLI invocation and returns its output. The CLI
  already owns all business rules (status transitions, id validation,
  locking, schema migrations), so a second implementation in this file
  would drift from it. The cost is one process spawn per tool call,
  which is fine for an interactive assistant client.

  Because it shells out, the server inherits the CLI's queue
  resolution: run it from the directory of the repo whose queue you
  want (the CLI finds the project-local `.cxq/tasks.db` from the
  current working directory, exactly as if you had typed the command
  there). The server's own working directory is passed through to
  every CLI invocation, along with its environment.

Resolving the cxq CLI:
  `CXQ_BIN` (explicit path, or a bare name looked up on PATH) wins.
  Otherwise the server resolves `bin/cxq` relative to the repo root,
  which is the parent of the directory holding this file (`mcp/` sits
  next to `bin/`). This works no matter which directory the server is
  launched from.

Python 3 standard library only (json, sys, os, subprocess), same rule
as server/cxq_server.py. No network, no telemetry, no background
threads or daemons. The server reads requests from stdin until EOF,
then exits 0. Malformed input never crashes it: a line that is not
valid JSON gets a -32700 parse error and the server keeps reading.

Usage (point an MCP client at it, e.g. Claude Code / Claude Desktop):

    python3 /path/to/cxq/mcp/cxq_mcp.py

Or, after `install.sh`, the copy at `<prefix>/lib/cxq/cxq_mcp.py`.
"""

import json
import os
import subprocess
import sys

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "cxq-mcp"

# Task statuses accepted by `cxq list --status` / `cxq edit --status`.
STATUSES = [
    "inbox",
    "ready",
    "claimed",
    "blocked",
    "review",
    "done",
    "wontfix",
    "trashed",
]

# Each tool maps to one CLI invocation. `args` is a function taking the
# validated arguments dict and returning the argv tail for `cxq`.
TOOLS = [
    {
        "name": "list_tasks",
        "description": "List tasks in the queue (cxq list --format json).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "status": {
                    "type": "string",
                    "enum": STATUSES,
                    "description": "Only tasks in this status.",
                },
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "add_task",
        "description": "Add a task to the queue (cxq add).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "Task title."},
                "body": {"type": "string", "description": "Extra task body."},
                "priority": {
                    "type": "integer",
                    "description": "Priority 0-100 (default 50).",
                },
                "tags": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Tags for the task.",
                },
            },
            "required": ["title"],
            "additionalProperties": False,
        },
    },
    {
        "name": "claim_task",
        "description": "Claim a task (cxq claim).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "integer", "description": "Task id."},
                "agent": {
                    "type": "string",
                    "description": "Agent name (default 'mcp').",
                },
            },
            "required": ["id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "update_task",
        "description": "Edit a task (cxq edit). At least one change field is required.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "integer", "description": "Task id."},
                "title": {"type": "string", "description": "New title."},
                "body": {"type": "string", "description": "New body."},
                "priority": {
                    "type": "integer",
                    "description": "New priority 0-100.",
                },
                "status": {
                    "type": "string",
                    "enum": STATUSES,
                    "description": "New status.",
                },
            },
            "required": ["id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "note",
        "description": "Append a note to a task (cxq note).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "integer", "description": "Task id."},
                "text": {"type": "string", "description": "Note text."},
            },
            "required": ["id", "text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "board",
        "description": "Show the kanban board grouped by status (cxq board).",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
    {
        "name": "stats",
        "description": "Show queue statistics (cxq stats).",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
]


def resolve_cxq_bin():
    """Find the cxq CLI: CXQ_BIN wins, else bin/cxq next to this file."""
    override = os.environ.get("CXQ_BIN")
    if override:
        return override
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(repo_root, "bin", "cxq")


def server_version(cxq_bin):
    """Read CXQ_VERSION from the CLI file; fall back to a dev version."""
    try:
        with open(cxq_bin, "r", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith('CXQ_VERSION="'):
                    return line.strip()[len('CXQ_VERSION="') : -1]
    except OSError:
        pass
    return "0.0.0-dev"


def run_cli(cxq_bin, argv):
    """Run one cxq invocation; return (stdout, stderr, returncode)."""
    try:
        proc = subprocess.run(
            [cxq_bin] + argv,
            capture_output=True,
            text=True,
            timeout=60,
        )
        return proc.stdout, proc.stderr, proc.returncode
    except FileNotFoundError:
        return "", "cxq CLI not found: %s" % cxq_bin, 1
    except subprocess.TimeoutExpired:
        return "", "cxq command timed out after 60s: %s" % " ".join(argv), 1
    except OSError as exc:
        return "", "failed to run cxq CLI: %s" % exc, 1


def tool_error(message):
    """A tool result reporting failure (isError), never a crash."""
    return {"content": [{"type": "text", "text": message}], "isError": True}


def tool_ok(text):
    return {"content": [{"type": "text", "text": text}]}


def _require_int(args, key):
    value = args.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        return None, "%s must be an integer." % key
    return value, None


def dispatch_tool(cxq_bin, name, args):
    """Map one tools/call to one CLI invocation. Returns a tool result."""
    if not isinstance(args, dict):
        return tool_error("tools/call arguments must be an object.")

    if name == "list_tasks":
        argv = ["list", "--format", "json"]
        if "status" in args:
            if args["status"] not in STATUSES:
                return tool_error("unknown status: %s" % args["status"])
            argv += ["--status", args["status"]]
    elif name == "add_task":
        title = args.get("title")
        if not isinstance(title, str) or not title:
            return tool_error("add_task requires a non-empty string 'title'.")
        argv = ["add", title]
        if "body" in args:
            argv += ["--body", str(args["body"])]
        if "priority" in args:
            priority, err = _require_int(args, "priority")
            if err:
                return tool_error(err)
            argv += ["--priority", str(priority)]
        if "tags" in args:
            tags = args["tags"]
            if not isinstance(tags, list) or not all(
                isinstance(t, str) for t in tags
            ):
                return tool_error("tags must be an array of strings.")
            for tag in tags:
                argv += ["--tag", tag]
    elif name == "claim_task":
        task_id, err = _require_int(args, "id")
        if err:
            return tool_error(err)
        argv = ["claim", str(task_id), "--agent", str(args.get("agent", "mcp"))]
    elif name == "update_task":
        task_id, err = _require_int(args, "id")
        if err:
            return tool_error(err)
        argv = ["edit", str(task_id)]
        if "title" in args:
            argv += ["--title", str(args["title"])]
        if "body" in args:
            argv += ["--body", str(args["body"])]
        if "priority" in args:
            priority, err = _require_int(args, "priority")
            if err:
                return tool_error(err)
            argv += ["--priority", str(priority)]
        if "status" in args:
            if args["status"] not in STATUSES:
                return tool_error("unknown status: %s" % args["status"])
            argv += ["--status", str(args["status"])]
        if len(argv) == 2:
            return tool_error(
                "update_task requires at least one of title, body, "
                "priority, status."
            )
    elif name == "note":
        task_id, err = _require_int(args, "id")
        if err:
            return tool_error(err)
        text = args.get("text")
        if not isinstance(text, str) or not text:
            return tool_error("note requires a non-empty string 'text'.")
        argv = ["note", str(task_id), text]
    elif name == "board":
        argv = ["board"]
    elif name == "stats":
        argv = ["stats"]
    else:
        return tool_error("unknown tool: %s" % name)

    stdout, stderr, returncode = run_cli(cxq_bin, argv)
    if returncode != 0:
        detail = (stderr or stdout).strip()
        return tool_error(
            "cxq %s failed: %s" % (" ".join(argv), detail or "exit %d" % returncode)
        )
    return tool_ok(stdout)


def handle_request(cxq_bin, request):
    """Handle one parsed JSON-RPC request. Returns a response dict or None
    (None = notification, no reply)."""
    if not isinstance(request, dict):
        return {
            "jsonrpc": "2.0",
            "id": None,
            "error": {"code": -32600, "message": "Invalid Request"},
        }
    method = request.get("method")
    req_id = request.get("id")
    is_notification = "id" not in request

    if not isinstance(method, str):
        if is_notification:
            return None
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32600, "message": "Invalid Request"},
        }

    # Notifications never get a reply.
    if method == "notifications/initialized":
        return None

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {
                    "name": SERVER_NAME,
                    "version": server_version(cxq_bin),
                },
            },
        }
    if method == "ping":
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}
    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": TOOLS},
        }
    if method == "tools/call":
        params = request.get("params")
        if not isinstance(params, dict):
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32602, "message": "Invalid params"},
            }
        result = dispatch_tool(cxq_bin, params.get("name"), params.get("arguments", {}))
        return {"jsonrpc": "2.0", "id": req_id, "result": result}

    if is_notification:
        return None
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": -32601, "message": "Method not found: %s" % method},
    }


def main():
    cxq_bin = resolve_cxq_bin()
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError:
            out.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": None,
                        "error": {"code": -32700, "message": "Parse error"},
                    }
                )
                + "\n"
            )
            out.flush()
            continue
        try:
            response = handle_request(cxq_bin, request)
        except Exception as exc:  # never crash on a bad request
            response = {
                "jsonrpc": "2.0",
                "id": request.get("id") if isinstance(request, dict) else None,
                "error": {"code": -32603, "message": "Internal error: %s" % exc},
            }
        if response is not None:
            out.write(json.dumps(response) + "\n")
            out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
