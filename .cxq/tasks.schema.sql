PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,

  title TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',

  status TEXT NOT NULL DEFAULT 'inbox'
    CHECK (status IN (
      'inbox',
      'ready',
      'claimed',
      'blocked',
      'review',
      'done',
      'wontfix'
    )),

  priority INTEGER NOT NULL DEFAULT 50,

  due_date TEXT,

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

CREATE INDEX IF NOT EXISTS idx_tasks_status_priority
ON tasks(status, priority DESC, created_at ASC);

CREATE INDEX IF NOT EXISTS idx_tasks_repo_status
ON tasks(repo_path, status);

CREATE INDEX IF NOT EXISTS idx_tasks_due
ON tasks(due_date);

CREATE TABLE IF NOT EXISTS task_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,

  event_type TEXT NOT NULL,
  actor TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  data_json TEXT NOT NULL DEFAULT '{}',

  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_task_events_task_created
ON task_events(task_id, created_at);

CREATE TABLE IF NOT EXISTS task_dependencies (
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  blocker_task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (task_id, blocker_task_id),
  CHECK (task_id <> blocker_task_id)
);

CREATE INDEX IF NOT EXISTS idx_task_dependencies_blocker
ON task_dependencies(blocker_task_id);

CREATE TABLE IF NOT EXISTS task_findings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,

  severity TEXT NOT NULL DEFAULT 'medium'
    CHECK (severity IN ('low', 'medium', 'high', 'critical')),

  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'accepted', 'resolved')),

  note TEXT NOT NULL DEFAULT '',
  followup_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL,

  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_task_findings_task_status
ON task_findings(task_id, status);

CREATE TABLE IF NOT EXISTS cxq_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT OR IGNORE INTO cxq_meta (key, value)
VALUES ('schema_version', '4');

UPDATE cxq_meta
SET value = '4'
WHERE key = 'schema_version'
  AND CAST(value AS INTEGER) < 4;

CREATE TRIGGER IF NOT EXISTS trg_tasks_updated_at
AFTER UPDATE ON tasks
FOR EACH ROW
BEGIN
  UPDATE tasks
  SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_task_findings_updated_at
AFTER UPDATE ON task_findings
FOR EACH ROW
BEGIN
  UPDATE task_findings
  SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  WHERE id = OLD.id;
END;
