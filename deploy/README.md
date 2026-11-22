# Deploying the shared cxq server

Local mode is still the default: one SQLite file per repo (`.cxq/tasks.db`).
Shared mode adds one small server that owns the SQLite file, so every agent
VM talks to the same queue over HTTPS. Agents **never** point `sqlite3` at a
shared file over NFS/SSHFS — that corrupts SQLite. They use the HTTP API.

~~~text
agent VM ── CXQ_REMOTE_URL=https://cxq-queue.fly.dev ──► cxq server ──► /data/tasks.db
agent VM ── CXQ_REMOTE_TOKEN=<token>                  (Fly.io, 1 VM + 1 GB volume)
~~~

## Option A — Fly.io (primary, ~10 minutes)

### Cost, honestly

Fly.io no longer has a classic "free tier". It has a **free allowance**:
new accounts get a small monthly usage credit (historically ~$5/mo) that
covers one `shared-cpu-1x` / 256 MB VM plus a 1 GB volume for most months.
That is usually **$0 out of pocket**, but it is a credit, not a guarantee:
check the current allowance at
<https://fly.io/docs/about/pricing/> before deploying, and set a billing
alert. If the credit runs out, this exact setup costs a few dollars a month.
If $0-strict is a hard requirement, use Option B instead.

### Steps

~~~sh
# 1. Install flyctl and sign in (once per machine)
curl -L https://fly.io/install.sh | sh
fly auth signup   # or: fly auth login

# 2. From the cxq repo root, create the app + volume (one-time)
fly launch --no-deploy --name cxq-queue --region mia
fly volumes create cxq_data --size 1 --region mia

# 3. Set the auth token as a secret (never commit it)
fly secrets set CXQ_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"

# 4. Deploy
fly deploy

# 5. Check it (health is the only unauthenticated endpoint)
curl https://cxq-queue.fly.dev/api/v1/health
# {"status": "ok", "version": "0.4.0-dev", "schema_version": 4}
~~~

The dashboard is at `https://cxq-queue.fly.dev/` — paste the token once when
prompted; the browser keeps it in localStorage.

### How each agent connects

On every agent VM (or in its shell profile / agent env):

~~~sh
export CXQ_REMOTE_URL="https://cxq-queue.fly.dev"
export CXQ_REMOTE_TOKEN="<your agent's token — the legacy CXQ_TOKEN, or a per-agent token from `cxq tokens add <agent>`>"
cxq remote status   # reachable: yes, plus server version + task counts
cxq list            # now reads the shared queue, not a local .db
cxq claim-next --agent <name> --lease 2h --format prompt
~~~

One shared queue per repo/project: if you run several projects, deploy one
app per project (or one app with one queue and a `--tag` per project — the
server does not yet namespace queues; do not share one queue across
unrelated projects and expect separation).

Local mode is unchanged when `CXQ_REMOTE_URL` is unset.

### Token rotation

There are two tokens to rotate, and they rotate differently:

**The legacy single token** (`CXQ_TOKEN`) — rotate by redeploying:

~~~sh
NEW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
fly secrets set CXQ_TOKEN="$NEW"   # redeploys; the old token stops working immediately
# then update CXQ_REMOTE_TOKEN on every agent VM
~~~

**Per-agent tokens** — rotate one agent without touching the others, no
redeploy, from the server host (on Fly, `fly ssh console -C "cxq tokens
rotate <agent> --db /data/tasks.db"`; on a VPS, run it where the DB lives):

~~~sh
cxq tokens rotate muse     # prints the new token once; the old one stops working immediately
cxq tokens revoke muse     # revokes without re-issuing; rotate later to re-issue
cxq tokens list --db /data/tasks.db   # who has a token, when each was last used
~~~

A revoked token stays revoked until rotated, and is rejected with 401 like
an unknown token. The legacy token is unaffected by per-agent
revoke/rotate, and vice versa. Do not put any token in the repo, in a task,
or in a screenshot.

## Option B — Oracle Cloud Always Free VPS + Tailscale (truly $0, more setup)

If Fly.io's credit model is not acceptable, the honest $0 option is an
Oracle Cloud **Always Free** VM (Ampere A1: 1 OCPU, 6 GB RAM, 200 GB disk —
actually free forever, not a trial). Setup takes ~30–45 minutes and needs a
card for account verification (Oracle charges $0 on Always Free resources,
but the account itself is not card-free).

~~~sh
# On the VPS (Ubuntu 22.04/24.04), as root:
apt-get update && apt-get install -y python3 git
git clone https://github.com/daniel-aranda/Agents-todo.git /opt/cxq
cd /opt/cxq && ./install.sh --prefix /usr/local --no-modify-profile

# Token + systemd service (no daemon in cxq itself; systemd owns the process):
python3 -c 'import secrets; print(secrets.token_urlsafe(32))'  # save this as the token
cat >/etc/systemd/system/cxq.service <<'EOF'
[Unit]
Description=cxq shared queue server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cxq
WorkingDirectory=/var/lib/cxq
Environment=CXQ_TOKEN=<paste the token here>
Environment=CXQ_DB=/var/lib/cxq/tasks.db
ExecStart=/usr/bin/python3 /opt/cxq/server/cxq_server.py --host 127.0.0.1 --port 8080 --db /var/lib/cxq/tasks.db
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
useradd --system --home /var/lib/cxq cxq
mkdir -p /var/lib/cxq && chown cxq:cxq /var/lib/cxq
systemctl daemon-reload && systemctl enable --now cxq

# Private access only: install Tailscale on the VPS and on every agent VM,
# then agents use the Tailscale IP/hostname as CXQ_REMOTE_URL, e.g.
#   export CXQ_REMOTE_URL="http://cxq-vps:8080"
# Never expose port 8080 to the public internet without TLS in front of it.
~~~

Limits: you operate the VM yourself (OS patches, disk, backups). The queue
is only reachable on the Tailscale network, which is the point — it is
private by default.

## Backups

The queue is one SQLite file. Back up the **data**, not the VM:

~~~sh
# 1. Logical export (works against any deployment, no shell access needed):
curl -s -H "Authorization: Bearer $CXQ_REMOTE_TOKEN" \
  "https://cxq-queue.fly.dev/api/v1/export?format=json" > cxq-backup-$(date +%F).json

# 2. Fly.io volume snapshot (Fly only):
fly volumes snapshots create cxq_data
fly volumes snapshots list cxq_data

# 3. Offline SQLite backup (from a local copy of the .db file):
sqlite3 tasks.db ".backup tasks-backup.db"
~~~

Restore is: put the backup `.db` file back at the server's `CXQ_DB` path
(or re-import the JSON export into a fresh queue) and restart the server.
The server auto-migrates a v3 database to v4 on startup, so old backups
still load.

## What the server does not do

- No multi-queue namespacing (one server = one queue).
- No per-user permissions — every token (legacy or per-agent) can do
  everything; per-agent tokens only identify the actor, they do not
  restrict what that agent may do. If a per-agent token leaks, revoke just
  that one with `cxq tokens revoke <agent>`.
- No TLS termination of its own — Fly.io terminates TLS; on a VPS, keep it
  behind Tailscale (Option B) or a reverse proxy with TLS.
- No background daemon inside cxq — `cxq serve` runs in the foreground;
  Fly/systemd own the process lifecycle.
