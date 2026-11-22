#!/usr/bin/env python3
"""cxq server: shared SQLite queue for agents, over HTTP.

Zero external dependencies: Python 3 standard library only
(http.server + sqlite3). The server owns ONE SQLite file in WAL mode and
serializes writes with a lock. Agents must NEVER point sqlite3 at a shared
file over NFS/SSHFS; they talk to this server (see `cxq serve` and
`CXQ_REMOTE_URL`).

Auth: every /api/v1/* endpoint except /health requires
`Authorization: Bearer $CXQ_TOKEN`. The dashboard page (GET /) is served
without auth because it contains no data; it prompts for the token once and
keeps it in localStorage, sending it as a Bearer header on API calls.

Per-agent tokens (see `cxq tokens`): the server also accepts Bearer tokens
from the `api_tokens` table in the same SQLite file, one per agent. A request
authenticated with a per-agent token records that agent's name as the actor
on every event it writes. The `CXQ_TOKEN` legacy token keeps working exactly
as before and records the previous actor behaviour (the `X-CXQ-Actor`
header, a body `actor`, or "remote"). Revoked per-agent tokens are rejected
with 401, same as unknown tokens.

Run:  cxq serve --port 8080 --db /path/to/tasks.db [--generate-token]
       (CXQ_TOKEN must be set, or pass --generate-token to `cxq serve`.)
"""
import argparse
import calendar
import datetime as dt
import json
import os
import re
import sqlite3
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = "0.5.0-dev"
SCHEMA_VERSION = 6
STATUSES = ["inbox", "ready", "claimed", "blocked", "review", "done", "wontfix"]

# Same single source of truth as `cxq status-transitions` in bin/cxq.
TRANSITIONS = {
    ("inbox", "ready"), ("inbox", "claimed"),
    ("ready", "claimed"), ("ready", "blocked"),
    ("claimed", "ready"), ("claimed", "blocked"),
    ("claimed", "review"), ("claimed", "done"),
    ("blocked", "ready"), ("blocked", "inbox"),
    ("review", "ready"), ("review", "inbox"), ("review", "blocked"), ("review", "done"),
    ("done", "ready"), ("done", "inbox"),
    ("wontfix", "ready"), ("wontfix", "inbox"),
}

# The tasks table definition, shared by SCHEMA_SQL (fresh installs) and
# ensure_schema() (table rebuild when migrating a pre-v5 database whose
# CHECK lacks 'trashed' — SQLite cannot ALTER a CHECK constraint).
# Keep in sync with tasks_table_sql() in bin/cxq.
TASKS_TABLE_SQL = """
CREATE TABLE tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'inbox'
    CHECK (status IN ('inbox','ready','claimed','blocked','review','done','wontfix','trashed')),
  priority INTEGER NOT NULL DEFAULT 50,
  due_date TEXT,
  recurs TEXT,
  trashed_from_status TEXT,
  trashed_at TEXT,
  repo_path TEXT NOT NULL,
  branch TEXT,
  allowed_paths_json TEXT NOT NULL DEFAULT '[]',
  tags_json TEXT NOT NULL DEFAULT '[]',
  deps_json TEXT NOT NULL DEFAULT '[]',
  acceptance TEXT NOT NULL DEFAULT '',
  verify_command TEXT NOT NULL DEFAULT '',
  claimed_by TEXT,
  claimed_at TEXT,
  lease_until TEXT,
  result_summary TEXT NOT NULL DEFAULT '',
  transcript_path TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
"""

SCHEMA_SQL = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

""" + TASKS_TABLE_SQL.replace(
    "CREATE TABLE tasks (", "CREATE TABLE IF NOT EXISTS tasks (", 1) + """
CREATE INDEX IF NOT EXISTS idx_tasks_status_priority ON tasks(status, priority DESC, created_at ASC);
CREATE INDEX IF NOT EXISTS idx_tasks_repo_status ON tasks(repo_path, status);
CREATE INDEX IF NOT EXISTS idx_tasks_due ON tasks(due_date);

CREATE TABLE IF NOT EXISTS task_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  actor TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  data_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_task_events_task_created ON task_events(task_id, created_at);

CREATE TABLE IF NOT EXISTS task_dependencies (
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  blocker_task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (task_id, blocker_task_id),
  CHECK (task_id <> blocker_task_id)
);
CREATE INDEX IF NOT EXISTS idx_task_dependencies_blocker ON task_dependencies(blocker_task_id);

CREATE TABLE IF NOT EXISTS task_findings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  severity TEXT NOT NULL DEFAULT 'medium' CHECK (severity IN ('low','medium','high','critical')),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','accepted','resolved')),
  note TEXT NOT NULL DEFAULT '',
  followup_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_task_findings_task_status ON task_findings(task_id, status);

CREATE TABLE IF NOT EXISTS cxq_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT OR IGNORE INTO cxq_meta (key, value) VALUES ('schema_version', '6');
UPDATE cxq_meta SET value = '6' WHERE key = 'schema_version' AND CAST(value AS INTEGER) < 6;

-- Per-agent API tokens (managed with `cxq tokens` on the server host).
-- One row per agent; the full token is stored, same trust model as the
-- single CXQ_TOKEN. A revoked row stays revoked and is never reused:
-- rotate issues a new token value and clears the revoked flag.
-- last_used_at is refreshed (at most once a minute) on authenticated
-- requests. No schema-version bump: the table is additive and created
-- idempotently by ensure_schema().
CREATE TABLE IF NOT EXISTS api_tokens (
  agent TEXT PRIMARY KEY,
  token TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  last_used_at TEXT,
  revoked INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0, 1))
);
CREATE INDEX IF NOT EXISTS idx_api_tokens_token ON api_tokens(token);

CREATE TRIGGER IF NOT EXISTS trg_tasks_updated_at
AFTER UPDATE ON tasks FOR EACH ROW BEGIN
  UPDATE tasks SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = OLD.id;
END;
CREATE TRIGGER IF NOT EXISTS trg_task_findings_updated_at
AFTER UPDATE ON task_findings FOR EACH ROW BEGIN
  UPDATE task_findings SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = OLD.id;
END;
"""

WRITE_LOCK = threading.Lock()
DB_PATH = ""
TOKEN = ""


def now_iso():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + \
        "%03dZ" % (dt.datetime.now(dt.timezone.utc).microsecond // 1000)


def connect():
    conn = sqlite3.connect(DB_PATH, timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA busy_timeout = 5000")
    return conn


def ensure_schema(conn):
    # Add columns before applying the schema: the schema creates an index
    # on due_date, which fails on a v3 table that lacks the column.
    # Mirrors migrate_db() in bin/cxq: v5 adds the 'trashed' status, which
    # needs a new CHECK constraint, and SQLite cannot ALTER a CHECK, so a
    # pre-v5 tasks table is rebuilt in place (same ids, same rows).
    cols = [r[1] for r in conn.execute("PRAGMA table_info(tasks)")]
    for col, ddl in (("due_date", "ALTER TABLE tasks ADD COLUMN due_date TEXT"),
                     ("recurs", "ALTER TABLE tasks ADD COLUMN recurs TEXT"),
                     ("trashed_from_status",
                      "ALTER TABLE tasks ADD COLUMN trashed_from_status TEXT"),
                     ("trashed_at", "ALTER TABLE tasks ADD COLUMN trashed_at TEXT")):
        if cols and col not in cols:
            conn.execute(ddl)
    if cols:
        table_sql = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'tasks'"
        ).fetchone()[0] or ""
        # Match the quoted CHECK literal: the bare word also appears in
        # the trashed_from_status / trashed_at column names added above,
        # which must NOT count as a migrated CHECK.
        if "'trashed'" not in table_sql:
            conn.execute("DROP TRIGGER IF EXISTS trg_tasks_updated_at")
            conn.execute("ALTER TABLE tasks RENAME TO tasks_migrate_old")
            conn.execute(TASKS_TABLE_SQL)
            conn.execute(
                "INSERT INTO tasks (id, title, body, status, priority, due_date,"
                " recurs, repo_path, branch, allowed_paths_json, tags_json,"
                " deps_json, acceptance, verify_command, claimed_by, claimed_at,"
                " lease_until, result_summary, transcript_path, created_at,"
                " updated_at, trashed_from_status, trashed_at)"
                " SELECT id, title, body, status, priority, due_date, recurs,"
                " repo_path, branch, allowed_paths_json, tags_json, deps_json,"
                " acceptance, verify_command, claimed_by, claimed_at, lease_until,"
                " result_summary, transcript_path, created_at, updated_at,"
                " NULL, NULL FROM tasks_migrate_old")
            conn.execute("DROP TABLE tasks_migrate_old")
    conn.executescript(SCHEMA_SQL)
    conn.commit()


def valid_due_date(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return False
    try:
        dt.date.fromisoformat(value)
        return True
    except ValueError:
        return False


def valid_recurs(value):
    return value in ("daily", "weekly", "monthly")


def next_due_date(due, recurs):
    # Next due date for a recurring task, advanced from its current due
    # date. Monthly clamps to the last day of the target month
    # (2026-01-31 -> 2026-02-28). Mirrors advance_due_date in bin/cxq.
    d = dt.date.fromisoformat(due)
    if recurs == "daily":
        return (d + dt.timedelta(days=1)).isoformat()
    if recurs == "weekly":
        return (d + dt.timedelta(days=7)).isoformat()
    year, month = d.year, d.month + 1
    if month > 12:
        year, month = year + 1, 1
    day = min(d.day, calendar.monthrange(year, month)[1])
    return dt.date(year, month, day).isoformat()


def parse_id(value):
    try:
        n = int(value)
    except (TypeError, ValueError):
        return None
    return n if n > 0 else None


def json_list(text):
    try:
        v = json.loads(text or "[]")
        return v if isinstance(v, list) else []
    except (ValueError, TypeError):
        return []


def log_event(conn, task_id, event_type, actor, note="", data=None):
    conn.execute(
        "INSERT INTO task_events (task_id, event_type, actor, note, data_json)"
        " VALUES (?, ?, ?, ?, ?)",
        (task_id, event_type, actor, note, json.dumps(data or {})),
    )


def create_next_occurrence(conn, row, actor):
    # When a recurring task is marked done, create its next occurrence as
    # a fresh task: same title/body/priority/tags/files/acceptance, due
    # date advanced from the OLD due date, same recurs value, status
    # ready. The claim is never inherited, and neither are dependencies
    # or the result summary. row may be a sqlite3.Row or a plain dict of
    # the completed task. Returns (new_id, next_due) or (None, None).
    # Mirrors maybe_create_next_occurrence in bin/cxq. Callers must only
    # call this on a real transition into done, so a second done cannot
    # spawn a duplicate.
    recurs = row["recurs"]
    due = row["due_date"]
    if not recurs or not due:
        return None, None
    nxt = next_due_date(due, recurs)
    cur = conn.execute(
        "INSERT INTO tasks (title, body, status, priority, due_date, recurs,"
        " repo_path, branch, allowed_paths_json, tags_json, acceptance,"
        " verify_command) VALUES (?, ?, 'ready', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (row["title"], row["body"], row["priority"], nxt, recurs,
         row["repo_path"], row["branch"], row["allowed_paths_json"],
         row["tags_json"], row["acceptance"], row["verify_command"]))
    new_id = cur.lastrowid
    log_event(conn, new_id, "created", actor, row["title"])
    log_event(conn, row["id"], "recurrence", actor,
              "next occurrence #%s (due %s, recurs %s)" % (new_id, nxt, recurs))
    return new_id, nxt


def task_dict(row, conn=None, include_events=False):
    d = dict(row)
    d["allowed_paths"] = json_list(d.pop("allowed_paths_json", "[]"))
    d["tags"] = json_list(d.pop("tags_json", "[]"))
    d.pop("deps_json", None)
    if conn is not None:
        # UTC date, matching the CLI (sqlite date('now')) and the tests.
        today = dt.datetime.now(dt.timezone.utc).date().isoformat()
        d["overdue"] = bool(
            d.get("due_date") and d["due_date"] < today
            and d.get("status") not in ("done", "wontfix", "trashed"))
        d["lease_expired"] = bool(
            d.get("status") == "claimed" and d.get("lease_until")
            and d["lease_until"] < now_iso())
    if include_events and conn is not None:
        d["events"] = [dict(r) for r in conn.execute(
            "SELECT id, task_id, event_type, actor, note, created_at"
            " FROM task_events WHERE task_id = ? ORDER BY created_at ASC, id ASC",
            (d["id"],))]
    return d


def get_task(conn, task_id, include_events=False):
    row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    if row is None:
        return None
    return task_dict(row, conn, include_events)


def has_open_blockers(conn, task_id):
    n = conn.execute(
        "SELECT COUNT(*) FROM task_dependencies td JOIN tasks b"
        " ON b.id = td.blocker_task_id"
        " WHERE td.task_id = ? AND b.status <> 'done'", (task_id,)).fetchone()[0]
    return n != 0


def dependency_would_cycle(conn, task_id, blocker_id):
    n = conn.execute(
        "WITH RECURSIVE chain(id) AS ("
        "  SELECT blocker_task_id FROM task_dependencies WHERE task_id = ?"
        "  UNION SELECT td.blocker_task_id FROM task_dependencies td"
        "  JOIN chain c ON td.task_id = c.id)"
        " SELECT COUNT(*) FROM chain WHERE id = ?",
        (blocker_id, task_id)).fetchone()[0]
    return n != 0


def lease_modifier(lease):
    m = re.fullmatch(r"(\d+)([mhd])", lease or "")
    if not m:
        raise ValueError("lease must look like 30m, 2h, or 1d.")
    n, unit = int(m.group(1)), m.group(2)
    delta = {"m": dt.timedelta(minutes=n), "h": dt.timedelta(hours=n),
             "d": dt.timedelta(days=n)}[unit]
    until = dt.datetime.now(dt.timezone.utc) + delta
    return until.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (until.microsecond // 1000)


def board_data(conn):
    rows = conn.execute(
        "SELECT * FROM tasks ORDER BY"
        " CASE status WHEN 'ready' THEN 0 WHEN 'claimed' THEN 1 WHEN 'review' THEN 2"
        " WHEN 'blocked' THEN 3 WHEN 'inbox' THEN 4 ELSE 5 END,"
        " priority DESC, created_at ASC").fetchall()
    columns = {s: [] for s in STATUSES}
    for r in rows:
        # Trashed tasks are not a board column: skip them instead of
        # KeyErroring (a trashed task used to 500 the whole board).
        if r["status"] in columns:
            columns[r["status"]].append(task_dict(r, conn))
    return {"columns": columns,
            "counts": {s: len(columns[s]) for s in STATUSES}}


def stats_data(conn):
    # by_status covers the board statuses plus trashed (mirrors the CLI's
    # `status_trashed` count); unknown statuses are ignored instead of
    # KeyErroring, the same way board_data skips trashed rows.
    by_status = {s: 0 for s in STATUSES + ["trashed"]}
    for r in conn.execute("SELECT status, COUNT(*) n FROM tasks GROUP BY status"):
        if r["status"] in by_status:
            by_status[r["status"]] = r["n"]
    today = dt.datetime.now(dt.timezone.utc).date().isoformat()
    overdue = conn.execute(
        "SELECT COUNT(*) FROM tasks WHERE due_date IS NOT NULL"
        " AND due_date < ? AND status NOT IN ('done','wontfix','trashed')", (today,)).fetchone()[0]
    stale = conn.execute(
        "SELECT COUNT(*) FROM tasks WHERE status = 'review'"
        " AND updated_at < strftime('%Y-%m-%dT%H:%M:%fZ','now','-24 hours')").fetchone()[0]
    oldest = conn.execute(
        "SELECT * FROM tasks WHERE status = 'ready' ORDER BY created_at ASC LIMIT 1").fetchone()
    done7 = conn.execute(
        "SELECT COUNT(*) FROM tasks WHERE status = 'done'"
        " AND updated_at >= strftime('%Y-%m-%dT%H:%M:%fZ','now','-7 days')").fetchone()[0]
    blockers = [dict(r) for r in conn.execute(
        "SELECT t.id, t.title, COUNT(*) AS blocks FROM task_dependencies td"
        " JOIN tasks t ON t.id = td.blocker_task_id"
        " GROUP BY t.id ORDER BY COUNT(*) DESC, t.id ASC LIMIT 5")]
    return {
        "tasks_total": sum(by_status.values()),
        "by_status": by_status,
        "overdue": overdue,
        "stale_reviews": stale,
        "oldest_ready": (("#%s %s" % (oldest["id"], oldest["title"]))
                         if oldest else None),
        "done_last_7d": done7,
        "top_blockers": blockers,
    }


def due_data(conn):
    # Same groups as `cxq due`: overdue, due today, due tomorrow.
    # "Today" is the UTC date, matching the overdue flag in
    # task_dict and the overdue count in stats_data.
    today = dt.datetime.now(dt.timezone.utc).date()
    tomorrow = (today + dt.timedelta(days=1)).isoformat()
    today = today.isoformat()
    groups = {}
    for key, where, params in (
        ("overdue",
         "due_date IS NOT NULL AND due_date < ?"
         " AND status NOT IN ('done','wontfix','trashed')", (today,)),
        ("today",
         "due_date = ? AND status NOT IN ('done','wontfix','trashed')", (today,)),
        ("tomorrow",
         "due_date = ? AND status NOT IN ('done','wontfix','trashed')", (tomorrow,)),
    ):
        rows = conn.execute(
            "SELECT * FROM tasks WHERE " + where +
            " ORDER BY due_date ASC, priority DESC, created_at ASC",
            params).fetchall()
        groups[key] = [task_dict(r, conn) for r in rows]
    return groups


PENDING_WORDS = ("pending", "pendiente", "still needs", "still missing",
                 "not implemented", "no implementado", "sin terminar",
                 "left over", "leftover", "follow-up", "followup", "falta")


def summary_mentions_pending(summary):
    if "TODO" in (summary or ""):
        return True
    low = (summary or "").lower()
    return any(w in low for w in PENDING_WORDS)


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def actor_from(handler, body):
    # A per-agent token names its actor: the token's agent wins over the
    # X-CXQ-Actor header / body actor. The legacy CXQ_TOKEN leaves
    # auth_agent unset, so its events keep the previous behaviour.
    return (getattr(handler, "auth_agent", None)
            or handler.headers.get("X-CXQ-Actor")
            or (body or {}).get("actor") or "remote")


def touch_token_last_used(conn, agent):
    # Refresh last_used_at at most once a minute: the dashboard polls
    # every 5s, and a write per poll would churn the WAL for no benefit.
    cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=60))
    cutoff_iso = cutoff.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (cutoff.microsecond // 1000)
    conn.execute(
        "UPDATE api_tokens SET last_used_at = ? WHERE agent = ?"
        " AND (last_used_at IS NULL OR last_used_at < ?)",
        (now_iso(), agent, cutoff_iso))
    conn.commit()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # Agent name from the per-agent token that authenticated this request,
    # or None for the legacy CXQ_TOKEN (see actor_from).
    auth_agent = None

    def log_message(self, fmt, *args):  # keep stdout clean
        sys.stderr.write("cxq-server: %s - %s\n" % (self.address_string(), fmt % args))

    # -- plumbing ---------------------------------------------------------
    def send_json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_text(self, status, text, ctype="text/plain; charset=utf-8"):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw.decode())
        except (ValueError, UnicodeDecodeError):
            raise ApiError(400, "request body must be valid JSON.")
        if not isinstance(body, dict):
            raise ApiError(400, "request body must be a JSON object.")
        return body

    def authenticate_token(self, presented):
        """Return the agent name for a per-agent token, or None.

        Unknown and revoked tokens both return None (401, indistinguishable
        by design). A DB error also fails closed to None.
        """
        try:
            with connect() as c:
                row = c.execute(
                    "SELECT agent, revoked FROM api_tokens WHERE token = ?",
                    (presented,)).fetchone()
                if row is None or row["revoked"]:
                    return None
                touch_token_last_used(c, row["agent"])
                return row["agent"]
        except sqlite3.Error:
            return None

    def require_auth(self):
        if self.path.startswith("/api/v1/health") or self.path == "/":
            return
        auth = self.headers.get("Authorization") or ""
        if not auth.startswith("Bearer ") or not auth[7:]:
            raise ApiError(401, "missing or invalid Bearer token.")
        presented = auth[7:]
        if presented == TOKEN:
            # Legacy single token: keep the previous actor behaviour.
            self.auth_agent = None
            return
        agent = self.authenticate_token(presented)
        if agent is None:
            raise ApiError(401, "missing or invalid Bearer token.")
        self.auth_agent = agent

    def handle_all(self, method):
        try:
            self.require_auth()
            parsed = urlparse(self.path)
            path, qs = parsed.path, parse_qs(parsed.query)
            if method == "GET" and path == "/":
                return self.send_text(200, DASHBOARD_HTML, "text/html; charset=utf-8")
            if not path.startswith("/api/v1/"):
                raise ApiError(404, "not found.")
            body = self.read_json() if method in ("POST", "PATCH", "DELETE") else {}
            result = self.route(method, path, qs, body)
            if isinstance(result, tuple):
                status, payload, ctype = result
                if ctype == "text":
                    return self.send_text(status, payload)
                return self.send_json(status, payload)
            return self.send_json(200, result)
        except ApiError as e:
            self.send_json(e.status, {"error": e.message})
        except Exception as e:  # never leak a stack trace as a 500 with no body
            self.send_json(500, {"error": "server error: %s" % e})

    def do_GET(self):
        self.handle_all("GET")

    def do_POST(self):
        self.handle_all("POST")

    def do_PATCH(self):
        self.handle_all("PATCH")

    def do_DELETE(self):
        self.handle_all("DELETE")

    # -- routing ----------------------------------------------------------
    def route(self, method, path, qs, body):
        if method == "GET" and path == "/api/v1/health":
            return {"status": "ok", "version": VERSION, "schema_version": SCHEMA_VERSION}
        if path == "/api/v1/tasks" and method == "GET":
            return self.list_tasks(qs)
        if path == "/api/v1/tasks" and method == "POST":
            return self.create_task(body)
        if path == "/api/v1/claim-next" and method == "POST":
            return self.claim_next(body)
        if path == "/api/v1/next" and method == "GET":
            return self.next_task()
        if path == "/api/v1/board" and method == "GET":
            with connect() as c:
                return board_data(c)
        if path == "/api/v1/stats" and method == "GET":
            with connect() as c:
                return stats_data(c)
        if path == "/api/v1/due" and method == "GET":
            with connect() as c:
                return due_data(c)
        if path == "/api/v1/digest" and method == "GET":
            with connect() as c:
                groups = due_data(c)
                return {"generated_at": now_iso(),
                        "date": dt.datetime.now(dt.timezone.utc).date().isoformat(),
                        "overdue_count": len(groups["overdue"]),
                        "today_count": len(groups["today"]),
                        "tomorrow_count": len(groups["tomorrow"]),
                        "overdue": groups["overdue"],
                        "today": groups["today"],
                        "tomorrow": groups["tomorrow"]}
        if path == "/api/v1/trash" and method == "GET":
            with connect() as c:
                rows = c.execute(
                    "SELECT id, priority, title, trashed_from_status,"
                    " trashed_at FROM tasks WHERE status = 'trashed'"
                    " ORDER BY trashed_at ASC, id ASC").fetchall()
                return {"tasks": [dict(r) for r in rows]}
        if path == "/api/v1/trash/purge" and method == "POST":
            return self.purge_trash(body)
        if path == "/api/v1/activity" and method == "GET":
            return self.activity(qs)
        if path == "/api/v1/stale" and method == "GET":
            with connect() as c:
                rows = c.execute(
                    "SELECT * FROM tasks WHERE status = 'claimed' AND lease_until IS NOT NULL"
                    " AND lease_until < strftime('%Y-%m-%dT%H:%M:%fZ','now')"
                    " ORDER BY lease_until ASC").fetchall()
                return {"tasks": [task_dict(r, c) for r in rows]}
        if path == "/api/v1/export" and method == "GET":
            return self.export(qs)
        if path == "/api/v1/export-md" and method == "GET":
            return self.export_md()

        m = re.fullmatch(r"/api/v1/tasks/(\d+)(?:/(.+))?", path)
        if m:
            task_id = int(m.group(1))
            sub = m.group(2) or ""
            if method == "GET" and sub == "":
                return self.show_task(task_id)
            if method == "PATCH" and sub == "":
                return self.edit_task(task_id, body)
            if method == "DELETE" and sub == "":
                return self.delete_task(task_id, qs)
            if method == "GET" and sub == "prompt":
                return {"prompt": self.task_prompt(task_id)}
            if method == "GET" and sub == "deps":
                return self.task_deps(task_id)
            if method == "GET" and sub == "findings":
                return self.list_findings(task_id)
            if method == "POST" and sub == "findings":
                return self.add_finding(task_id, body)
            if method == "POST" and sub in ("claim", "release", "review", "done",
                                            "note", "reopen", "block", "unblock",
                                            "restore", "undo"):
                return getattr(self, "task_" + sub)(task_id, body)

        m = re.fullmatch(r"/api/v1/findings/(\d+)/resolve", path)
        if m and method == "POST":
            return self.resolve_finding(int(m.group(1)), body)

        raise ApiError(404, "not found.")

    # -- tasks ------------------------------------------------------------
    def list_tasks(self, qs):
        with connect() as c:
            where, params = ["1 = 1"], []
            view = qs.get("view", [""])[0]
            if view == "needs-action":
                where.append(
                    "(status IN ('ready','blocked') OR (status = 'review' AND EXISTS"
                    " (SELECT 1 FROM task_findings f WHERE f.task_id = tasks.id"
                    " AND f.status = 'open')))")
            elif view == "questions":
                rows = c.execute(
                    "SELECT t.* FROM tasks t JOIN task_events e ON e.task_id = t.id"
                    " WHERE e.event_type = 'note' AND (e.note LIKE 'DUDA:%' OR e.note LIKE 'BLOCKER:%')"
                    " AND t.status NOT IN ('done','wontfix','trashed')"
                    " ORDER BY e.id ASC").fetchall()
                return {"tasks": [task_dict(r, c) for r in rows]}
            if qs.get("status"):
                if qs["status"][0] not in STATUSES:
                    raise ApiError(400, "invalid status: %s" % qs["status"][0])
                where.append("status = ?")
                params.append(qs["status"][0])
            elif qs.get("all", [""])[0] != "1":
                # Default listing hides finished and trashed tasks, like the CLI.
                where.append("status NOT IN ('done','wontfix','trashed')")
            if qs.get("tag"):
                where.append("EXISTS (SELECT 1 FROM json_each(tags_json) WHERE value = ?)")
                params.append(qs["tag"][0])
            if qs.get("agent"):
                where.append("claimed_by = ?")
                params.append(qs["agent"][0])
            if qs.get("priority_min"):
                try:
                    params.append(int(qs["priority_min"][0]))
                except ValueError:
                    raise ApiError(400, "priority_min must be an integer.")
                where.append("priority >= ?")
            if qs.get("search"):
                q = "%" + qs["search"][0].replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
                where.append("(title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\' OR tags_json LIKE ? ESCAPE '\\')")
                params += [q, q, q]
            if qs.get("overdue", [""])[0] == "1":
                where.append("due_date IS NOT NULL AND due_date < date('now')"
                             " AND status NOT IN ('done','wontfix','trashed')")
            if qs.get("due_before"):
                if not valid_due_date(qs["due_before"][0]):
                    raise ApiError(400, "due_before must be a valid YYYY-MM-DD date.")
                where.append("due_date IS NOT NULL AND due_date < ?")
                params.append(qs["due_before"][0])
            rows = c.execute(
                "SELECT * FROM tasks WHERE " + " AND ".join(where) +
                " ORDER BY CASE status WHEN 'ready' THEN 0 WHEN 'claimed' THEN 1"
                " WHEN 'review' THEN 2 WHEN 'blocked' THEN 3 WHEN 'inbox' THEN 4 ELSE 5 END,"
                " priority DESC, created_at ASC", params).fetchall()
            return {"tasks": [task_dict(r, c) for r in rows]}

    def create_task(self, body):
        title = (body.get("title") or "").strip()
        if not title:
            raise ApiError(400, "task title is required.")
        status = body.get("status", "ready")
        if status not in STATUSES:
            raise ApiError(400, "invalid status: %s" % status)
        try:
            priority = int(body.get("priority", 50))
        except (TypeError, ValueError):
            raise ApiError(400, "priority must be an integer.")
        due = body.get("due_date")
        if due is not None and not valid_due_date(due):
            raise ApiError(400, "due date must be a valid YYYY-MM-DD date.")
        recurs = body.get("recurs")
        if recurs is not None and not valid_recurs(recurs):
            raise ApiError(400, "invalid recurrence: %s (expected daily, weekly, monthly)." % recurs)
        if recurs and not due:
            raise ApiError(400, "recurring tasks require a due date.")
        for key in ("allowed_paths", "tags"):
            if key in body and not isinstance(body[key], list):
                raise ApiError(400, "%s must be a JSON array." % key)
        with WRITE_LOCK:
            with connect() as c:
                cur = c.execute(
                    "INSERT INTO tasks (title, body, status, priority, due_date, recurs,"
                    " repo_path, branch, allowed_paths_json, tags_json, acceptance,"
                    " verify_command) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (title, body.get("body", ""), status, priority, due, recurs,
                     body.get("repo_path", ""), body.get("branch"),
                     json.dumps(body.get("allowed_paths", [])),
                     json.dumps(body.get("tags", [])),
                     body.get("acceptance", ""), body.get("verify_command", "")))
                task_id = cur.lastrowid
                log_event(c, task_id, "created", actor_from(self, body), title)
                c.commit()
                return get_task(c, task_id, include_events=True)

    def show_task(self, task_id):
        with connect() as c:
            task = get_task(c, task_id, include_events=True)
            if task is None:
                raise ApiError(404, "task not found: %s" % task_id)
            return task

    def edit_task(self, task_id, body):
        with WRITE_LOCK:
            with connect() as c:
                row = c.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                if row is None:
                    raise ApiError(404, "task not found: %s" % task_id)
                old = dict(row)
                sets, diffs = {}, []
                # Undo data: previous values of exactly the fields this edit
                # changes, stored in the 'edited' event so the undo endpoint
                # can revert it. Same keys/format as `cxq edit` (task #7):
                # strings verbatim, priority a number, nullable fields null
                # when empty, allowed_paths/tags as JSON arrays.
                prev = {}

                def change(field, column, new):
                    if new is None or new == old[column]:
                        return
                    disp_old = old[column] if old[column] not in (None, "") else "(empty)"
                    disp_new = new if new not in (None, "") else "(empty)"
                    diffs.append("%s: %s -> %s" % (field, disp_old, disp_new))
                    sets[column] = new
                    prev[column] = old[column]

                if "title" in body:
                    change("title", "title", body["title"])
                if "body" in body:
                    change("body", "body", body["body"])
                if "priority" in body:
                    try:
                        change("priority", "priority", int(body["priority"]))
                    except (TypeError, ValueError):
                        raise ApiError(400, "priority must be an integer.")
                if "acceptance" in body:
                    change("acceptance", "acceptance", body["acceptance"])
                if "verify_command" in body:
                    change("verify_command", "verify_command", body["verify_command"])
                if "branch" in body:
                    change("branch", "branch", body["branch"])
                if "due_date" in body:
                    due = body["due_date"]
                    if due is not None and not valid_due_date(due):
                        raise ApiError(400, "due date must be a valid YYYY-MM-DD date.")
                    change("due_date", "due_date", due)
                if "recurs" in body:
                    r = body["recurs"]
                    if r is not None and not valid_recurs(r):
                        raise ApiError(400, "invalid recurrence: %s (expected daily, weekly, monthly)." % r)
                    if r is None:
                        if old["recurs"] is not None:
                            diffs.append("recurs: %s -> (empty)" % old["recurs"])
                            sets["recurs"] = None
                            prev["recurs"] = old["recurs"]
                    else:
                        change("recurs", "recurs", r)
                # A recurring task must always have a due date (effective
                # values after this edit): covers setting recurs on a
                # dateless task and clearing the due date of a recurring one.
                eff_recurs = body.get("recurs", old["recurs"]) if "recurs" in body else old["recurs"]
                eff_due = body.get("due_date", old["due_date"]) if "due_date" in body else old["due_date"]
                if eff_recurs and not eff_due:
                    raise ApiError(400, "recurring tasks require a due date.")
                # files / tags: set, add, remove
                files = json_list(old["allowed_paths_json"])
                tags = json_list(old["tags_json"])
                if "allowed_paths" in body:
                    if not isinstance(body["allowed_paths"], list):
                        raise ApiError(400, "allowed_paths must be a JSON array.")
                    files = body["allowed_paths"]
                if "tags" in body:
                    if not isinstance(body["tags"], list):
                        raise ApiError(400, "tags must be a JSON array.")
                    tags = body["tags"]
                def _as_list(value):
                    if value is None:
                        return []
                    if isinstance(value, str):
                        return [value]
                    return list(value) if isinstance(value, list) else []
                for key, lst in (("files_add", files), ("tags_add", tags)):
                    for v in _as_list(body.get(key)):
                        for part in v.split(","):
                            part = part.strip()
                            if part and part not in lst:
                                lst.append(part)
                for key, lst in (("files_remove", files), ("tags_remove", tags)):
                    for v in _as_list(body.get(key)):
                        for part in v.split(","):
                            part = part.strip()
                            if part in lst:
                                lst.remove(part)
                if files != json_list(old["allowed_paths_json"]):
                    diffs.append("allowed_paths: %s -> %s" % (
                        ",".join(json_list(old["allowed_paths_json"])) or "(empty)",
                        ",".join(files) or "(empty)"))
                    sets["allowed_paths_json"] = json.dumps(files)
                    prev["allowed_paths"] = json_list(old["allowed_paths_json"])
                if tags != json_list(old["tags_json"]):
                    diffs.append("tags: %s -> %s" % (
                        ",".join(json_list(old["tags_json"])) or "(empty)",
                        ",".join(tags) or "(empty)"))
                    sets["tags_json"] = json.dumps(tags)
                    prev["tags"] = json_list(old["tags_json"])
                # status last: validated against the transitions table.
                if "status" in body and body["status"] != old["status"]:
                    new_status = body["status"]
                    if new_status not in STATUSES:
                        raise ApiError(400, "invalid status: %s" % new_status)
                    if new_status == "claimed":
                        raise ApiError(400, "use the claim endpoint to claim a task.")
                    if (old["status"], new_status) not in TRANSITIONS:
                        raise ApiError(400, "cannot move task %s from %s to %s."
                                       % (task_id, old["status"], new_status))
                    if old["status"] in ("review", "done") and not body.get("reason"):
                        raise ApiError(400, "moving a task out of %s requires a reason."
                                       % old["status"])
                    diffs.append("status: %s -> %s" % (old["status"], new_status))
                    if body.get("reason"):
                        diffs[-1] += " (reason: %s)" % body["reason"]
                    sets["status"] = new_status
                    prev["status"] = old["status"]
                    prev["claimed_by"] = old["claimed_by"]
                    prev["claimed_at"] = old["claimed_at"]
                    prev["lease_until"] = old["lease_until"]
                    if new_status in ("ready", "inbox", "blocked", "done"):
                        sets["claimed_by"] = None
                        sets["claimed_at"] = None
                        sets["lease_until"] = None
                if not diffs and not sets:
                    raise ApiError(400, "edit made no changes to task %s." % task_id)
                if sets:
                    sql = "UPDATE tasks SET " + ", ".join(
                        "%s = ?" % k for k in sets) + " WHERE id = ?"
                    c.execute(sql, list(sets.values()) + [task_id])
                diff_text = "; ".join(diffs)
                log_event(c, task_id, "edited", actor_from(self, body), diff_text,
                          prev if prev else None)
                next_id, next_due = None, None
                if sets.get("status") == "done" and old["status"] != "done":
                    eff = dict(old)
                    eff.update(sets)
                    next_id, next_due = create_next_occurrence(c, eff, actor_from(self, body))
                c.commit()
                return {"task": get_task(c, task_id, include_events=True), "diff": diff_text,
                        "next_occurrence_id": next_id, "next_occurrence_due": next_due}

    def delete_task(self, task_id, qs):
        # Delete moves the task to trash instead of removing the row, so it
        # can be restored — same as `cxq delete` (task #7). Permanent
        # removal is purge_trash() only.
        if qs.get("force", [""])[0] != "1":
            raise ApiError(400, "deleting a task requires force=1.")
        with WRITE_LOCK:
            with connect() as c:
                row = c.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                if row is None:
                    raise ApiError(404, "task not found: %s" % task_id)
                if row["status"] == "trashed":
                    raise ApiError(400, "task %s is already trashed; purge the trash"
                                   " to delete it permanently." % task_id)
                c.execute(
                    "UPDATE tasks SET status = 'trashed',"
                    " trashed_from_status = ?, trashed_at = ?,"
                    " claimed_by = NULL, claimed_at = NULL, lease_until = NULL"
                    " WHERE id = ?",
                    (row["status"], now_iso(), task_id))
                log_event(c, task_id, "trashed", actor_from(self, {}),
                          "trashed from %s; restore with 'cxq restore %s'"
                          % (row["status"], task_id))
                c.commit()
                return {"trashed": task_id, "was": row["status"]}

    def task_restore(self, task_id, body):
        # Mirror `cxq restore`: back to the pre-trash status; a trashed
        # claim lost its agent and lease, so it lands on 'ready'.
        with WRITE_LOCK:
            with connect() as c:
                row = c.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                if row is None:
                    raise ApiError(404, "task not found: %s" % task_id)
                if row["status"] != "trashed":
                    raise ApiError(400, "task %s is not trashed (status: %s)."
                                   % (task_id, row["status"]))
                dest = row["trashed_from_status"] or "ready"
                if dest == "claimed":
                    dest = "ready"
                c.execute(
                    "UPDATE tasks SET status = ?, trashed_from_status = NULL,"
                    " trashed_at = NULL WHERE id = ?",
                    (dest, task_id))
                log_event(c, task_id, "restored", actor_from(self, body),
                          "restored to %s" % dest)
                c.commit()
                return {"task": get_task(c, task_id, include_events=True),
                        "restored_to": dest}

    def task_undo(self, task_id, body):
        # Mirror `cxq undo`: revert the most recent 'edited' event that has
        # not been undone yet, using the previous values stored in its
        # data_json (recorded by edit_task). One call reverts one edit.
        with WRITE_LOCK:
            with connect() as c:
                row = c.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                if row is None:
                    raise ApiError(404, "task not found: %s" % task_id)
                if row["status"] == "trashed":
                    raise ApiError(400, "task %s is trashed; restore it first with"
                                   " 'cxq restore %s'." % (task_id, task_id))
                edit = c.execute(
                    "SELECT id, data_json FROM task_events e WHERE e.task_id = ?"
                    " AND e.event_type = 'edited' AND NOT EXISTS ("
                    "  SELECT 1 FROM task_events u WHERE u.task_id = ?"
                    "  AND u.event_type = 'undone'"
                    "  AND CAST(json_extract(u.data_json, '$.undid_edit_id') AS INTEGER)"
                    "    = e.id)"
                    " ORDER BY e.id DESC LIMIT 1",
                    (task_id, task_id)).fetchone()
                if edit is None:
                    raise ApiError(400, "task %s has nothing to undo." % task_id)
                try:
                    prev = json.loads(edit["data_json"] or "{}")
                except ValueError:
                    prev = {}
                if not isinstance(prev, dict) or not prev:
                    raise ApiError(400, "the last edit of task %s cannot be undone"
                                   " (no previous values recorded)." % task_id)
                columns = {"title": "title", "body": "body", "priority": "priority",
                           "status": "status", "acceptance": "acceptance",
                           "verify_command": "verify_command", "branch": "branch",
                           "due_date": "due_date", "recurs": "recurs",
                           "allowed_paths": "allowed_paths_json",
                           "tags": "tags_json", "claimed_by": "claimed_by",
                           "claimed_at": "claimed_at", "lease_until": "lease_until"}
                sets, values, reverted = {}, [], []
                for key, value in prev.items():
                    if key not in columns:
                        continue
                    if key == "priority":
                        if not isinstance(value, int) or isinstance(value, bool):
                            raise ApiError(400, "cannot undo task %s: stored priority"
                                           " is not an integer." % task_id)
                    if key == "status" and value not in STATUSES:
                        raise ApiError(400, "cannot undo task %s: stored status"
                                       " is not valid." % task_id)
                    sets[columns[key]] = value
                    values.append(value)
                    reverted.append(key)
                if not sets:
                    raise ApiError(400, "the last edit of task %s cannot be undone"
                                   " (no previous values recorded)." % task_id)
                sql = "UPDATE tasks SET " + ", ".join(
                    "%s = ?" % k for k in sets) + " WHERE id = ?"
                c.execute(sql, values + [task_id])
                log_event(c, task_id, "undone", actor_from(self, body),
                          "undid edit: %s" % ", ".join(reverted),
                          {"undid_edit_id": edit["id"]})
                c.commit()
                return {"task": get_task(c, task_id, include_events=True),
                        "reverted": reverted}

    def purge_trash(self, body):
        # Mirror `cxq trash purge`: permanently delete trashed tasks older
        # than N days (default 30), or all of them with {"all": true}.
        # Purged tasks are gone for real: row, events, findings, deps.
        days = body.get("days", 30)
        all_flag = body.get("all", False)
        if not all_flag:
            if isinstance(days, bool) or not isinstance(days, int) or days < 0:
                raise ApiError(400, "--days must be a non-negative integer.")
        with WRITE_LOCK:
            with connect() as c:
                if all_flag:
                    where = "status = 'trashed'"
                    params = []
                else:
                    where = ("status = 'trashed' AND trashed_at <"
                             " strftime('%Y-%m-%dT%H:%M:%fZ','now',?)")
                    params = ["-%d days" % days]
                count = c.execute(
                    "SELECT COUNT(*) FROM tasks WHERE " + where, params).fetchone()[0]
                if count:
                    c.execute("DELETE FROM task_events WHERE task_id IN"
                              " (SELECT id FROM tasks WHERE " + where + ")", params)
                    c.execute("DELETE FROM task_findings WHERE task_id IN"
                              " (SELECT id FROM tasks WHERE " + where + ")", params)
                    c.execute("DELETE FROM task_dependencies WHERE task_id IN"
                              " (SELECT id FROM tasks WHERE " + where + ")"
                              " OR blocker_task_id IN"
                              " (SELECT id FROM tasks WHERE " + where + ")", params * 2)
                    c.execute("DELETE FROM tasks WHERE " + where, params)
                c.commit()
                return {"purged": count}

    def task_prompt(self, task_id):
        with connect() as c:
            task = get_task(c, task_id, include_events=True)
            if task is None:
                raise ApiError(404, "task not found: %s" % task_id)
            lines = ["You are working on task #%s.\n" % task_id,
                     "# %s\n" % task["title"],
                     "Status: %s | Priority: %s" % (task["status"], task["priority"])]
            if task.get("due_date"):
                lines.append("Due date: %s" % task["due_date"])
            if task.get("body"):
                lines.append("\n%s" % task["body"])
            if task.get("acceptance"):
                lines.append("\nAcceptance criteria:\n%s" % task["acceptance"])
            if task.get("verify_command"):
                lines.append("\nVerification command:\n%s" % task["verify_command"])
            lines.append("\nMove implementation work to review, not done.")
            return "\n".join(lines)

    def task_deps(self, task_id):
        with connect() as c:
            if get_task(c, task_id) is None:
                raise ApiError(404, "task not found: %s" % task_id)
            blocked_by = [dict(r) for r in c.execute(
                "SELECT t.id, t.status, t.title FROM task_dependencies td"
                " JOIN tasks t ON t.id = td.blocker_task_id WHERE td.task_id = ?"
                " ORDER BY t.priority DESC, t.id ASC", (task_id,))]
            blocks = [dict(r) for r in c.execute(
                "SELECT t.id, t.status, t.title FROM task_dependencies td"
                " JOIN tasks t ON t.id = td.task_id WHERE td.blocker_task_id = ?"
                " ORDER BY t.priority DESC, t.id ASC", (task_id,))]
            return {"blocked_by": blocked_by, "blocks": blocks}

    def task_claim(self, task_id, body):
        agent = body.get("agent", "agent")
        lease = body.get("lease", "2h")
        try:
            until = lease_modifier(lease)
        except ValueError as e:
            raise ApiError(400, str(e))
        with WRITE_LOCK:
            with connect() as c:
                row = c.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                if row is None:
                    raise ApiError(404, "task not found: %s" % task_id)
                claimable = row["status"] in ("ready", "inbox") or (
                    row["status"] == "claimed" and row["lease_until"]
                    and row["lease_until"] < now_iso())
                if not claimable or has_open_blockers(c, task_id):
                    raise ApiError(409, "task %s is not available to claim." % task_id)
                c.execute("UPDATE tasks SET status = 'claimed', claimed_by = ?,"
                          " claimed_at = ?, lease_until = ? WHERE id = ?",
                          (agent, now_iso(), until, task_id))
                log_event(c, task_id, "claimed", agent, "lease %s" % lease)
                c.commit()
                return get_task(c, task_id, include_events=True)

    def claim_next(self, body):
        agent = body.get("agent", "agent")
        lease = body.get("lease", "2h")
        try:
            until = lease_modifier(lease)
        except ValueError as e:
            raise ApiError(400, str(e))
        with WRITE_LOCK:
            with connect() as c:
                row = c.execute(
                    "SELECT * FROM tasks candidate WHERE (status = 'ready' OR"
                    " (status = 'claimed' AND lease_until IS NOT NULL"
                    " AND lease_until < strftime('%Y-%m-%dT%H:%M:%fZ','now')))"
                    " AND NOT EXISTS (SELECT 1 FROM task_dependencies td JOIN tasks b"
                    " ON b.id = td.blocker_task_id WHERE td.task_id = candidate.id"
                    " AND b.status <> 'done')"
                    " ORDER BY priority DESC, created_at ASC LIMIT 1").fetchone()
                if row is None:
                    raise ApiError(404, "No available tasks.")
                task_id = row["id"]
                c.execute("UPDATE tasks SET status = 'claimed', claimed_by = ?,"
                          " claimed_at = ?, lease_until = ? WHERE id = ?",
                          (agent, now_iso(), until, task_id))
                log_event(c, task_id, "claimed", agent, "lease %s" % lease,
                          {"source": "claim-next"})
                c.commit()
                return get_task(c, task_id, include_events=True)

    def next_task(self):
        with connect() as c:
            row = c.execute(
                "SELECT * FROM tasks candidate WHERE status = 'ready'"
                " AND NOT EXISTS (SELECT 1 FROM task_dependencies td JOIN tasks b"
                " ON b.id = td.blocker_task_id WHERE td.task_id = candidate.id"
                " AND b.status <> 'done')"
                " ORDER BY priority DESC, created_at ASC LIMIT 1").fetchone()
            if row is None:
                raise ApiError(404, "No ready tasks.")
            return task_dict(row, c, include_events=True)

    def task_release(self, task_id, body):
        with WRITE_LOCK:
            with connect() as c:
                row = c.execute("SELECT status FROM tasks WHERE id = ?", (task_id,)).fetchone()
                if row is None:
                    raise ApiError(404, "task not found: %s" % task_id)
                if row["status"] not in ("claimed", "blocked"):
                    raise ApiError(400, "task %s is not claimed or blocked." % task_id)
                c.execute("UPDATE tasks SET status = 'ready', claimed_by = NULL,"
                          " claimed_at = NULL, lease_until = NULL WHERE id = ?", (task_id,))
                log_event(c, task_id, "released", actor_from(self, body), "")
                c.commit()
                return get_task(c, task_id, include_events=True)

    def task_review(self, task_id, body):
        summary = body.get("summary", "")
        if not summary:
            raise ApiError(400, "review summary is required.")
        with WRITE_LOCK:
            with connect() as c:
                if get_task(c, task_id) is None:
                    raise ApiError(404, "task not found: %s" % task_id)
                c.execute("UPDATE tasks SET status = 'review', result_summary = ?,"
                          " claimed_by = NULL, claimed_at = NULL, lease_until = NULL"
                          " WHERE id = ?", (summary, task_id))
                log_event(c, task_id, "review", actor_from(self, body), summary)
                c.commit()
                return get_task(c, task_id, include_events=True)

    def task_done(self, task_id, body):
        summary = body.get("summary", "")
        force = bool(body.get("force"))
        with WRITE_LOCK:
            with connect() as c:
                row = c.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                if row is None:
                    raise ApiError(404, "task not found: %s" % task_id)
                effective = summary or row["result_summary"] or ""
                warnings = []
                if summary_mentions_pending(effective):
                    warnings.append("the summary still mentions pending work")
                open_findings = c.execute(
                    "SELECT COUNT(*) FROM task_findings WHERE task_id = ? AND status = 'open'",
                    (task_id,)).fetchone()[0]
                if open_findings:
                    warnings.append("task has %s open finding(s)" % open_findings)
                if warnings and not force:
                    raise ApiError(409, "task %s has unfinished work (%s); use force to close it anyway."
                                   % (task_id, "; ".join(warnings)))
                c.execute("UPDATE tasks SET status = 'done',"
                          " result_summary = CASE WHEN ? = '' THEN result_summary ELSE ? END,"
                          " claimed_by = NULL, claimed_at = NULL, lease_until = NULL"
                          " WHERE id = ?", (summary, summary, task_id))
                log_event(c, task_id, "done", actor_from(self, body), summary)
                next_id, next_due = None, None
                if row["status"] != "done":
                    next_id, next_due = create_next_occurrence(c, row, actor_from(self, body))
                c.commit()
                task = get_task(c, task_id, include_events=True)
                task["next_occurrence_id"] = next_id
                task["next_occurrence_due"] = next_due
                return task

    def task_note(self, task_id, body):
        note = body.get("note", "")
        if not note:
            raise ApiError(400, "note is required.")
        with WRITE_LOCK:
            with connect() as c:
                if get_task(c, task_id) is None:
                    raise ApiError(404, "task not found: %s" % task_id)
                log_event(c, task_id, "note", actor_from(self, body), note)
                c.commit()
                return {"noted": task_id}

    def task_reopen(self, task_id, body):
        target = body.get("to", "ready")
        reason = body.get("reason", "")
        if target not in ("ready", "inbox", "blocked"):
            raise ApiError(400, "reopen target must be ready, inbox, or blocked.")
        if not reason:
            raise ApiError(400, "reopen reason is required.")
        with WRITE_LOCK:
            with connect() as c:
                row = c.execute("SELECT status FROM tasks WHERE id = ?", (task_id,)).fetchone()
                if row is None:
                    raise ApiError(404, "task not found: %s" % task_id)
                if row["status"] == target:
                    raise ApiError(400, "task %s is already %s." % (task_id, target))
                if (row["status"], target) not in TRANSITIONS:
                    raise ApiError(400, "cannot move task %s from %s to %s."
                                   % (task_id, row["status"], target))
                c.execute("UPDATE tasks SET status = ?, claimed_by = NULL, claimed_at = NULL,"
                          " lease_until = NULL WHERE id = ?", (target, task_id))
                log_event(c, task_id, "reopened", actor_from(self, body),
                          "%s -> %s: %s" % (row["status"], target, reason))
                c.commit()
                return get_task(c, task_id, include_events=True)

    def task_block(self, task_id, body):
        blocker = body.get("blocker_id")
        if not isinstance(blocker, int):
            raise ApiError(400, "blocker_id is required.")
        if blocker == task_id:
            raise ApiError(400, "task cannot block itself.")
        with WRITE_LOCK:
            with connect() as c:
                for tid in (task_id, blocker):
                    if get_task(c, tid) is None:
                        raise ApiError(404, "task not found: %s" % tid)
                if dependency_would_cycle(c, task_id, blocker):
                    raise ApiError(400, "dependency would create a cycle.")
                c.execute("INSERT OR IGNORE INTO task_dependencies (task_id, blocker_task_id)"
                          " VALUES (?, ?)", (task_id, blocker))
                log_event(c, task_id, "blocked_by", actor_from(self, body),
                          "blocked by #%s" % blocker)
                c.commit()
                return {"blocked_by": blocker}

    def task_unblock(self, task_id, body):
        blocker = body.get("blocker_id")
        if not isinstance(blocker, int):
            raise ApiError(400, "blocker_id is required.")
        with WRITE_LOCK:
            with connect() as c:
                cur = c.execute("DELETE FROM task_dependencies WHERE task_id = ?"
                                " AND blocker_task_id = ?", (task_id, blocker))
                if cur.rowcount == 0:
                    raise ApiError(400, "task %s is not blocked by %s." % (task_id, blocker))
                log_event(c, task_id, "unblocked_by", actor_from(self, body),
                          "removed blocker #%s" % blocker)
                c.commit()
                return {"unblocked": blocker}

    def list_findings(self, task_id):
        with connect() as c:
            if get_task(c, task_id) is None:
                raise ApiError(404, "task not found: %s" % task_id)
            rows = c.execute(
                "SELECT * FROM task_findings WHERE task_id = ?"
                " ORDER BY status = 'open' DESC, id ASC", (task_id,)).fetchall()
            return {"findings": [dict(r) for r in rows]}

    def add_finding(self, task_id, body):
        severity = body.get("severity", "medium")
        if severity not in ("low", "medium", "high", "critical"):
            raise ApiError(400, "finding severity must be low, medium, high, or critical.")
        note = body.get("note", "")
        if not note:
            raise ApiError(400, "finding note is required.")
        followup = body.get("followup_task_id")
        with WRITE_LOCK:
            with connect() as c:
                if get_task(c, task_id) is None:
                    raise ApiError(404, "task not found: %s" % task_id)
                if followup is not None and get_task(c, followup) is None:
                    raise ApiError(404, "follow-up task not found: %s" % followup)
                cur = c.execute(
                    "INSERT INTO task_findings (task_id, severity, status, note, followup_task_id)"
                    " VALUES (?, ?, 'open', ?, ?)", (task_id, severity, note, followup))
                log_event(c, task_id, "finding_added", actor_from(self, body),
                          "[%s/open] %s" % (severity, note))
                c.commit()
                return {"finding_id": cur.lastrowid}

    def resolve_finding(self, finding_id, body):
        status = body.get("status", "resolved")
        if status not in ("accepted", "resolved"):
            raise ApiError(400, "finding resolve status must be accepted or resolved.")
        with WRITE_LOCK:
            with connect() as c:
                row = c.execute("SELECT * FROM task_findings WHERE id = ?",
                                (finding_id,)).fetchone()
                if row is None:
                    raise ApiError(404, "finding not found: %s" % finding_id)
                if row["status"] != "open":
                    raise ApiError(400, "finding %s is not open." % finding_id)
                c.execute("UPDATE task_findings SET status = ? WHERE id = ?",
                          (status, finding_id))
                log_event(c, row["task_id"], "finding_closed", actor_from(self, body),
                          "finding #%s %s" % (finding_id, status))
                c.commit()
                return {"finding_id": finding_id, "status": status}

    def activity(self, qs):
        try:
            limit = int(qs.get("limit", ["20"])[0])
        except ValueError:
            raise ApiError(400, "limit must be an integer.")
        with connect() as c:
            rows = c.execute(
                "SELECT created_at, task_id, event_type, actor, note FROM task_events"
                " ORDER BY created_at DESC, id DESC LIMIT ?", (limit,)).fetchall()
            return {"events": [dict(r) for r in rows]}

    def export(self, qs):
        fmt = qs.get("format", ["json"])[0]
        if fmt not in ("json", "csv"):
            raise ApiError(400, "export format must be json or csv.")
        with connect() as c:
            rows = c.execute(
                "SELECT id, title, body, status, priority, due_date, recurs, branch,"
                " allowed_paths_json, tags_json, acceptance, verify_command,"
                " claimed_by, claimed_at, lease_until, result_summary,"
                " created_at, updated_at FROM tasks ORDER BY id ASC").fetchall()
            tasks = [dict(r) for r in rows]
        if fmt == "json":
            return 200, tasks, "json"
        import csv
        import io
        buf = io.StringIO()
        if tasks:
            w = csv.DictWriter(buf, fieldnames=list(tasks[0].keys()))
            w.writeheader()
            w.writerows(tasks)
        return 200, buf.getvalue(), "text"

    def export_md(self):
        with connect() as c:
            data = board_data(c)
        lines = ["# cxq board\n",
                 "Generated: %s\n" % now_iso()]
        for status in STATUSES:
            tasks = data["columns"][status]
            lines.append("## %s (%d)\n" % (status, len(tasks)))
            if not tasks:
                lines.append("_(empty)_\n")
            for t in tasks:
                line = "- #%s **%s** [P%s]" % (t["id"], t["title"].replace("*", ""), t["priority"])
                if t.get("due_date"):
                    line += " (due %s)" % t["due_date"]
                if t.get("claimed_by"):
                    line += " -- %s" % t["claimed_by"]
                lines.append(line)
            lines.append("")
        return 200, "\n".join(lines), "text"

DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cxq board</title>
<style>
:root{--bg:#f6f6f4;--surface:#fff;--text:#1a1a1a;--muted:#666;--border:#ddd;--accent:#2563eb;--danger:#b91c1c;--warn:#b45309}
html[data-theme="dark"]{--bg:#16181d;--surface:#1f222a;--text:#e8e8e8;--muted:#9aa0aa;--border:#3a3f4a;--accent:#60a5fa;--danger:#f87171;--warn:#fbbf24}
*{box-sizing:border-box}
body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--text)}
header{position:sticky;top:0;background:var(--surface);border-bottom:1px solid var(--border);padding:10px 16px;display:flex;flex-wrap:wrap;gap:8px;align-items:center;z-index:10}
header h1{font-size:18px;margin:0 8px 0 0}
input,select,textarea{font:inherit;color:var(--text);background:var(--surface);border:1px solid var(--border);border-radius:6px;padding:6px 8px}
button{font:inherit;background:var(--accent);color:#fff;border:0;border-radius:6px;padding:6px 12px;cursor:pointer}
button.ghost{background:var(--surface);color:var(--text);border:1px solid var(--border)}
button.danger{background:var(--danger)}
#board{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px;padding:16px}
.col{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:10px;min-height:120px}
.col h2{font-size:14px;margin:0 0 8px;text-transform:capitalize}
.card{border:1px solid var(--border);border-radius:8px;padding:8px;margin-bottom:8px;cursor:pointer;background:var(--bg)}
.card:hover{border-color:var(--accent)}
.card .t{font-weight:600}
.card .m{font-size:12px;color:var(--muted);margin-top:4px}
.flag{color:var(--danger);font-weight:700}
.flag.warn{color:var(--warn)}
#modal{position:fixed;inset:0;background:rgba(0,0,0,.5);display:none;align-items:flex-start;justify-content:center;padding:24px;z-index:20}
#modal.open{display:flex}
.sheet{background:var(--surface);border-radius:12px;padding:16px;max-width:640px;width:100%;max-height:90vh;overflow:auto}
.sheet label{display:block;font-size:13px;color:var(--muted);margin:10px 0 4px}
.sheet input,.sheet select,.sheet textarea{width:100%}
.row{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}
#auth{position:fixed;inset:0;background:var(--bg);display:none;align-items:center;justify-content:center;z-index:30}
#auth.open{display:flex}
#auth .box{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:24px;max-width:420px;width:90%}
footer{padding:8px 16px;color:var(--muted);font-size:12px}
#error{color:var(--danger);padding:0 16px}
@media (max-width:600px){#board{grid-template-columns:1fr}}
</style>
</head>
<body>
<header>
  <h1>cxq board</h1>
  <input id="q" type="search" placeholder="Search title / body / tags">
  <select id="f-status"><option value="">all statuses</option></select>
  <input id="f-tag" placeholder="tag">
  <input id="f-agent" placeholder="agent">
  <button id="btn-refresh" class="ghost">Refresh</button>
  <button id="btn-new">+ New task</button>
  <button id="btn-theme" class="ghost">Dark / light</button>
  <span id="counts" style="color:var(--muted);font-size:13px"></span>
  <span id="overdue-badge" class="flag" style="font-size:13px"></span>
</header>
<div id="error"></div>
<main id="board"></main>
<footer>Live refresh: polling every 5s (no SSE). One shared queue — the server owns the SQLite file; agents connect with <code>CXQ_REMOTE_URL</code> / <code>CXQ_REMOTE_TOKEN</code>. <span id="health"></span></footer>

<div id="modal"><div class="sheet">
  <h2 id="m-title" style="margin:0">Task</h2>
  <input type="hidden" id="m-id">
  <label>Title</label><input id="m-t">
  <label>Body</label><textarea id="m-body" rows="3"></textarea>
  <div class="row">
    <div style="flex:1"><label>Priority</label><input id="m-priority" type="number" min="0"></div>
    <div style="flex:1"><label>Due date</label><input id="m-due" type="date"></div>
    <div style="flex:1"><label>Recurs</label><select id="m-recurs"><option value="">never</option><option value="daily">daily</option><option value="weekly">weekly</option><option value="monthly">monthly</option></select></div>
    <div style="flex:1"><label>Status</label><select id="m-status"></select></div>
  </div>
  <label>Tags (comma-separated)</label><input id="m-tags">
  <label>Allowed paths (comma-separated)</label><input id="m-files">
  <label>Acceptance criteria</label><textarea id="m-acceptance" rows="3"></textarea>
  <label>Verification command</label><input id="m-verify">
  <label>Reason (required when moving out of review / done)</label><input id="m-reason" placeholder="why is this changing?">
  <label>Review summary (for the Review button)</label><input id="m-summary" placeholder="what was implemented?">
  <div class="row">
    <button id="m-save">Save edits</button>
    <button id="m-claim" class="ghost">Claim</button>
    <button id="m-release" class="ghost">Release</button>
    <button id="m-review" class="ghost">→ Review</button>
    <button id="m-done">Mark done</button>
    <button id="m-close" class="ghost">Close</button>
  </div>
  <h3>History</h3>
  <div id="m-events" style="font-size:13px;color:var(--muted)"></div>
</div></div>

<div id="auth"><div class="box">
  <h2 style="margin-top:0">cxq token</h2>
  <p style="color:var(--muted)">Paste the <code>CXQ_TOKEN</code> for this queue. It is stored only in this browser (localStorage) and sent as a Bearer header.</p>
  <input id="auth-token" type="password" placeholder="CXQ_TOKEN" style="width:100%">
  <div class="row"><button id="auth-save">Connect</button></div>
  <p id="auth-error" style="color:var(--danger)"></p>
</div></div>

<script>
const STATUSES = ["inbox","ready","claimed","blocked","review","done","wontfix"];
const $ = id => document.getElementById(id);
let token = localStorage.getItem("cxq_token") || "";
let boardCache = null;

function api(method, path, body) {
  return fetch(path, {method, headers: {"Authorization": "Bearer " + token, "Content-Type": "application/json"}, body: body ? JSON.stringify(body) : undefined})
    .then(async r => { const t = await r.text(); let j; try { j = JSON.parse(t); } catch(e) { j = {error: t}; }
      if (!r.ok) throw new Error(j.error || ("HTTP " + r.status)); return j; });
}
function showAuth(msg) { $("auth").classList.add("open"); if (msg) $("auth-error").textContent = msg; }
function hideAuth() { $("auth").classList.remove("open"); }
$("auth-save").onclick = () => { token = $("auth-token").value.trim(); if (!token) return; localStorage.setItem("cxq_token", token); hideAuth(); load(); };
$("btn-theme").onclick = () => { const h = document.documentElement; const next = h.getAttribute("data-theme") === "dark" ? "light" : "dark"; h.setAttribute("data-theme", next); localStorage.setItem("cxq_theme", next); };
if (localStorage.getItem("cxq_theme")) document.documentElement.setAttribute("data-theme", localStorage.getItem("cxq_theme"));
else if (matchMedia("(prefers-color-scheme: dark)").matches) document.documentElement.setAttribute("data-theme", "dark");
STATUSES.forEach(s => { const o = document.createElement("option"); o.value = s; o.textContent = s; $("f-status").appendChild(o); const o2 = o.cloneNode(true); $("m-status").appendChild(o2); });

async function load() {
  if (!token) { showAuth(); return; }
  const q = new URLSearchParams();
  const search = $("q").value.trim(), st = $("f-status").value, tag = $("f-tag").value.trim(), agent = $("f-agent").value.trim();
  if (search) q.set("search", search); if (st) q.set("status", st); if (tag) q.set("tag", tag); if (agent) q.set("agent", agent);
  q.set("all", "1");
  try {
    const data = await api("GET", "/api/v1/tasks?" + q.toString());
    const tasks = data.tasks || [];
    const cols = {}; STATUSES.forEach(s => cols[s] = []);
    tasks.forEach(t => cols[t.status] ? cols[t.status].push(t) : cols.inbox.push(t));
    boardCache = cols;
    const board = $("board"); board.innerHTML = "";
    let total = 0;
    STATUSES.forEach(s => {
      total += cols[s].length;
      const col = document.createElement("div"); col.className = "col";
      col.innerHTML = "<h2>" + s + " (" + cols[s].length + ")</h2>";
      cols[s].forEach(t => {
        const c = document.createElement("div"); c.className = "card";
        let meta = "P" + t.priority;
        if (t.due_date) meta += " · due " + t.due_date;
        if (t.overdue) meta += ' <span class="flag">OVERDUE</span>';
        if (t.lease_expired) meta += ' <span class="flag">LEASE EXPIRED</span>';
        if (t.claimed_by) meta += " · " + t.claimed_by;
        c.innerHTML = '<div class="t">#' + t.id + " " + escapeHtml(t.title) + '</div><div class="m">' + meta + "</div>";
        c.onclick = () => openTask(t.id);
        col.appendChild(c);
      });
      board.appendChild(col);
    });
    $("counts").textContent = total + " tasks";
    // Queue-wide overdue badge, from /api/v1/stats (not the filtered
    // board above): the daily "what needs attention" count. Empty when
    // nothing is overdue. There is no push digest: the server has no
    // scheduler by design, it only serves the count on poll.
    api("GET", "/api/v1/stats").then(s => { $("overdue-badge").textContent = s.overdue ? ("Overdue: " + s.overdue) : ""; }).catch(() => {});
    $("error").textContent = "";
    fetch("/api/v1/health").then(r => r.json()).then(h => { $("health").textContent = "Server " + h.version + " · schema v" + h.schema_version; }).catch(() => {});
  } catch (e) { if (/401|token/i.test(e.message)) showAuth(e.message); else $("error").textContent = e.message; }
}
function escapeHtml(s) { return String(s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c])); }
async function openTask(id) {
  try {
    const t = await api("GET", "/api/v1/tasks/" + id);
    $("m-id").value = t.id; $("m-title").textContent = "Task #" + t.id;
    $("m-t").value = t.title || ""; $("m-body").value = t.body || "";
    $("m-priority").value = t.priority; $("m-due").value = t.due_date || ""; $("m-recurs").value = t.recurs || "";
    $("m-status").value = t.status; $("m-tags").value = (t.tags || []).join(", ");
    $("m-files").value = (t.allowed_paths || []).join(", ");
    $("m-acceptance").value = t.acceptance || ""; $("m-verify").value = t.verify_command || "";
    $("m-reason").value = ""; $("m-summary").value = "";
    $("m-events").innerHTML = (t.events || []).slice(-10).map(e => "<div>" + escapeHtml(e.created_at) + " <b>" + escapeHtml(e.event_type) + "</b> by " + escapeHtml(e.actor) + (e.note ? ": " + escapeHtml(e.note) : "") + "</div>").join("") || "No events yet.";
    $("modal").classList.add("open");
  } catch (e) { $("error").textContent = e.message; }
}
function currentForm() {
  return {title: $("m-t").value, body: $("m-body").value, priority: parseInt($("m-priority").value || "50", 10),
    due_date: $("m-due").value || null, recurs: $("m-recurs").value || null, status: $("m-status").value,
    tags: $("m-tags").value.split(",").map(s => s.trim()).filter(Boolean),
    allowed_paths: $("m-files").value.split(",").map(s => s.trim()).filter(Boolean),
    acceptance: $("m-acceptance").value, verify_command: $("m-verify").value,
    reason: $("m-reason").value.trim() || undefined};
}
$("m-save").onclick = async () => { const id = $("m-id").value; try { await api("PATCH", "/api/v1/tasks/" + id, currentForm()); $("modal").classList.remove("open"); load(); } catch (e) { alert(e.message); } };
$("m-claim").onclick = async () => { const id = $("m-id").value; try { await api("POST", "/api/v1/tasks/" + id + "/claim", {agent: "web", lease: "2h"}); $("modal").classList.remove("open"); load(); } catch (e) { alert(e.message); } };
$("m-release").onclick = async () => { const id = $("m-id").value; try { await api("POST", "/api/v1/tasks/" + id + "/release", {}); $("modal").classList.remove("open"); load(); } catch (e) { alert(e.message); } };
$("m-review").onclick = async () => { const id = $("m-id").value; const s = $("m-summary").value.trim(); if (!s) { alert("Review needs a summary."); return; } try { await api("POST", "/api/v1/tasks/" + id + "/review", {summary: s}); $("modal").classList.remove("open"); load(); } catch (e) { alert(e.message); } };
$("m-done").onclick = async () => { const id = $("m-id").value; try { await api("POST", "/api/v1/tasks/" + id + "/done", {summary: $("m-summary").value.trim(), force: false}); $("modal").classList.remove("open"); load(); } catch (e) { if (confirm(e.message + "\n\nForce close anyway?")) { try { await api("POST", "/api/v1/tasks/" + id + "/done", {summary: $("m-summary").value.trim(), force: true}); $("modal").classList.remove("open"); load(); } catch (e2) { alert(e2.message); } } } };
$("m-close").onclick = () => $("modal").classList.remove("open");
$("btn-new").onclick = () => { $("m-id").value = ""; $("m-title").textContent = "New task"; $("m-t").value = ""; $("m-body").value = ""; $("m-priority").value = 50; $("m-due").value = ""; $("m-recurs").value = ""; $("m-status").value = "ready"; $("m-tags").value = ""; $("m-files").value = ""; $("m-acceptance").value = ""; $("m-verify").value = ""; $("m-events").innerHTML = ""; $("m-save").onclick = async () => { try { const t = await api("POST", "/api/v1/tasks", {title: $("m-t").value, body: $("m-body").value, priority: parseInt($("m-priority").value || "50", 10), due_date: $("m-due").value || null, recurs: $("m-recurs").value || null, status: $("m-status").value, tags: $("m-tags").value.split(",").map(s => s.trim()).filter(Boolean), allowed_paths: $("m-files").value.split(",").map(s => s.trim()).filter(Boolean), acceptance: $("m-acceptance").value, verify_command: $("m-verify").value}); $("modal").classList.remove("open"); load(); } catch (e) { alert(e.message); } }; $("modal").classList.add("open"); };
$("btn-refresh").onclick = load;
["q","f-status","f-tag","f-agent"].forEach(id => $(id).addEventListener("input", () => { clearTimeout(window._t); window._t = setTimeout(load, 300); }));
load();
setInterval(() => { if (!$("modal").classList.contains("open")) load(); }, 5000);
</script>
</body>
</html>
"""


def main():
    global DB_PATH, TOKEN
    ap = argparse.ArgumentParser(description="cxq server (shared SQLite queue)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--db", default=os.environ.get("CXQ_DB", "tasks.db"))
    args = ap.parse_args()
    TOKEN = os.environ.get("CXQ_TOKEN", "")
    if not TOKEN:
        print("cxq-server: CXQ_TOKEN is required (set it, or use `cxq serve --generate-token`).",
              file=sys.stderr)
        return 2
    DB_PATH = os.path.abspath(args.db)
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    with connect() as c:
        ensure_schema(c)
        version = c.execute("SELECT value FROM cxq_meta WHERE key = 'schema_version'").fetchone()[0]
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print("cxq server %s listening on http://%s:%s  db: %s  schema v%s"
          % (VERSION, args.host, args.port, DB_PATH, version), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\ncxq server stopped.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
