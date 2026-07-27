# MySQL HA Cluster — Ansible

Builds a 5-node Percona XtraDB Cluster (Galera) + HAProxy/Keepalived cluster,
driven from a separate Ansible control VM, idempotently, with proper role
separation. **x86_64 only.**

Galera has its own built-in group communication/quorum, so there's no
separate consensus-store role, and — per an explicit choice to keep the
proxy layer simple — there's no MySQL-aware connection pooler (ProxySQL)
either: HAProxy talks straight TCP to the cluster, health-checked via a
small `clustercheck` endpoint on each DB node. See "Notes / things worth
knowing" below for what that trades away.

## Layout

```
mysql-ha-ansible/
├── ansible.cfg
├── requirements.yml          # collections: community.general, community.mysql, ansible.posix
├── inventory/hosts.yml       # edit the 5 node IPs here
├── group_vars/all/
│   └── 01-vars.yml           # non-secret config (MySQL version, ports, network, tuning)
├── install.yml                # main build playbook — prompts for all credentials/secrets
├── playbooks/cluster_health.yml
└── roles/
    ├── common               # packages, NTP, /etc/hosts, sysctl, THP, UFW, Percona repo
    ├── mysql_galera         # Percona XtraDB Cluster + Galera (db_nodes)
    ├── xtrabackup           # backup/check/restore-verify cron (one fixed db_node)
    └── haproxy_keepalived   # read/write routing + VIP failover (proxy_nodes)
```

## Hardware requirements

Minimum per node (DB or proxy), enforced by the `common` role at the start
of every run — the play fails fast on any node that doesn't meet these:

- **CPU**: 4 vCPUs (8+ recommended for DB nodes — warns, doesn't fail, if unmet)
- **RAM**: 12 GB (16 GB+ recommended for DB nodes — warns, doesn't fail, if
  unmet). Higher than a generic "8GB is enough for a database" floor because
  InnoDB's buffer pool takes ~55% of RAM by default (`innodb_buffer_pool_pct`)
  and Galera's gcache adds a further fixed ~1GB on top of that — see
  "Memory-based tuning" below. The percentage is kept well under the more
  common 70-80% because these are reserved, not lazily-grown, and on a host
  with strict memory overcommit (`vm.overcommit_memory=2`) a too-large
  reservation can leave too little commit headroom for anything else on the
  box, including SSH/Ansible's own management access.
- **Disk**: 50 GB OS volume. A separate data volume for DB nodes, mounted
  under the MySQL data directory (or a parent of it, e.g. `/var/lib/mysql`),
  is recommended but not required — DB nodes warn, not fail, if the data
  directory shares a device with the OS volume.

## 1. Control VM setup

On a separate VM (not one of the 5 cluster nodes):

```bash
sudo apt update && sudo apt install -y python3-pip
pip3 install --break-system-packages ansible

cd mysql-ha-ansible
ansible-galaxy collection install -r requirements.yml
```

You'll need SSH + sudo access as a sudo-capable user on all 5 target nodes.
Every playbook (see below) prompts for the SSH username and password
interactively, so nothing is hardcoded in `ansible.cfg`.

## 2. Configure

1. **Inventory** — edit `inventory/hosts.yml` with your 5 real IPs. Hostnames
   (`db-node-1`, `proxy-node-1`, ...) must match each machine's actual
   `hostname -s`, since the Galera/HAProxy configs key off that name.
2. **Non-secret vars** — review `group_vars/all/01-vars.yml`: `vip_prefix`,
   the Percona repo series (`percona_product_series`, defaults to `pxc80`).
   `cluster_vip`/`app_network`/`ops_network` are no longer set here — they're
   prompted for at run time (see below). `vip_interface` is auto-detected per
   proxy node from its default route; only uncomment it in
   `group_vars/all/01-vars.yml` if you need to force a specific NIC.
3. **Secrets** — nothing to do here. There's no vault file: every MySQL /
   HAProxy / keepalived credential and the alert webhook URL is prompted for
   interactively when you run `install.yml` (see below), so nothing is
   committed to this repo. Those values still end up in plaintext in the
   rendered config files on the target nodes themselves (`galera.cnf`,
   `/root/.my.cnf`, `keepalived.conf`, ...) — that's inherent to how each
   service consumes its credentials, not something this playbook can avoid.

## 3. Run

```bash
ansible-playbook install.yml
```

No flags needed. `install.yml`'s first play prompts you, in order, for: SSH
username, one password used for both SSH login and sudo/become, the cluster
VIP (default `10.223.16.79`), the `app_network`/`ops_network` CIDRs used for
UFW rules (default `10.223.16.0/24`), then the MySQL root password, the
Galera SST account (used internally between DB nodes for state transfer), the
health-check (`clustercheck`) account, the application database name/user,
the HAProxy stats account, the VRRP (keepalived) auth password, and finally
the alert webhook URL. Press Enter on any prompt to keep its default
(usernames and network CIDRs have one; passwords and the webhook URL don't —
type a value or leave blank if you don't need it, e.g. no webhook). Those
values are then applied to all 5 hosts for the rest of the run. To pass extra
options through (e.g. `--limit`, `-e percona_product_series=pxc57`), just
append them: `ansible-playbook install.yml --limit db-node-1`.

Because nothing is persisted, you'll re-enter all of the above on every
`install.yml` run — that's the trade-off of not using a vault file. To change
a credential (e.g. `haproxy_stats_pass`), just type the new value next time
you run `install.yml`; the affected role is idempotent and will update the
config and restart only the affected service.

Running `playbooks/cluster_health.yml` on its own (e.g. via
`ansible-playbook playbooks/cluster_health.yml`) prompts for its own subset
of the above (SSH username/password, health-check credentials, HAProxy
stats credentials, alert webhook URL, cluster VIP), since it never goes
through `install.yml`'s credentials play. That prompt is automatically
skipped when `cluster_health.yml` runs as the last step of the full
`install.yml` build.

If your nodes use SSH keys rather than password auth, leave the SSH
password prompt blank when it appears — key-based auth will be used
automatically as long as the SSH username matches a key-authorized account.

This runs, in order:

1. **common** on all 5 nodes in parallel — OS prep, kernel tuning, UFW,
   Percona repo.
2. **mysql_galera** on the 3 DB nodes **one at a time** (`serial: 1`, in
   inventory order — db-node-1 first). Galera has its own built-in group
   communication/quorum: db-node-1 bootstraps a brand-new cluster only if no
   peer already has one running (`systemctl start mysql@bootstrap.service`);
   every other node — and db-node-1 itself on a re-run against an
   already-live cluster — just starts normally and joins via IST/SST from
   whichever peers are already up. Running this play `serial: 1` just makes
   first-time bootstrap deterministic instead of a race.
3. **xtrabackup** on the 3 DB nodes in parallel — cron jobs for scheduled
   backups, an integrity check, and restore verification, all gated to run
   on a single fixed node rather than chasing a floating primary (see
   "Backups & alerts" below).
4. **haproxy_keepalived** on both proxy nodes in parallel.
5. **cluster_health** (imported from `playbooks/cluster_health.yml`) —
   reports each node's wsrep state/cluster membership (asserts all 3 DB
   nodes are in the Primary component), backup freshness, HAProxy status per
   proxy node, which node currently holds the VIP, and DB-node disk usage.
   Sends a consolidated alert to `alert_webhook_url` if anything is
   unhealthy, then exits non-zero if the cluster-membership assertion fails,
   so `install.yml` itself fails the run if the cluster comes up unhealthy.

Each role waits on real state (wsrep sync state, the clustercheck endpoint,
HAProxy's stats page) before moving on, so a partial failure stops the play
instead of silently continuing.

## 4. Verify (on demand)

The health check above already runs automatically at the end of every
`install.yml` build. To re-check cluster health later without re-running the
whole build (e.g. from cron/CI), run it standalone:

```bash
ansible-playbook playbooks/cluster_health.yml
```

## Backups & alerts

Backups are handled by Percona XtraBackup (`roles/xtrabackup`), which is
already installed on all 3 DB nodes by `mysql_galera` (it's also what
Galera's SST uses to clone a joining node). Every Galera node holds
identical data, so backups here just run on **one fixed node**
(`xtrabackup_backup_node` in
`group_vars/all/01-vars.yml`, default `groups['db_nodes'][1]` — i.e.
db-node-2, deliberately not the HAProxy-designated write node db-node-1).
That keeps backup I/O off the node serving writes, and avoids maintaining 3
independent, redundant backup chains of the same data.

**Repo is local disk** on that one node (`xtrabackup_repo_path`, default
`/var/lib/xtrabackup`). If `xtrabackup_backup_node` ever changes (or that
node is rebuilt from scratch), the next scheduled full backup starts a fresh
chain there — nothing carries over automatically.

**Point-in-time recovery**: binary logging is enabled (`log_bin` in
`galera.cnf.j2`, `binlog_expire_logs_seconds` controls retention) so
`mysqlbinlog` can replay transactions past the latest backup — see
"Restoring from a backup" below for how the two combine.

**Schedule** (all in `group_vars/all/01-vars.yml` /
`roles/xtrabackup/defaults/main.yml`, overridable):
- Full backup: weekly, Sunday 01:00. Diff backup (against the latest full,
  not chained): daily (except Sunday) 01:00.
- Integrity check (verifies the latest backup completed and isn't stale):
  daily 05:00.
- Restore verification: weekly, Sunday 03:00.

All of the above run via cron **on `xtrabackup_backup_node` only** — no
"am I the leader" wrapper is needed, since which node runs backups is a
fixed Ansible variable, not runtime cluster state.

**Retention** (`roles/xtrabackup/defaults/main.yml`, overridable):
- `xtrabackup_retention_full: 4` — keeps the last 4 full backup sets (each
  full backup plus the diffs taken against it).

With full backups weekly, that's roughly **4 weeks of backup history**, with
daily diffs giving same-day recovery granularity within that window. Pruning
happens automatically at the end of every full backup run
(`backup.sh full`), deleting full/diff directories older than the oldest
retained full. Override `xtrabackup_retention_full` in
`group_vars/all/01-vars.yml` if you want a longer/shorter window, e.g. `8`
for ~2 months.

**Restore verification** actually proves a backup is usable, not just
present: it prepares and restores the latest full backup into a scratch
directory (`xtrabackup_restore_verify_path`), boots a temporary standalone
(non-Galera) `mysqld` on a throwaway port (`xtrabackup_restore_verify_port`,
default 5555), runs a liveness query, then tears both down. To hand-trigger
it instead of waiting for the weekly cron:
```bash
sudo /usr/local/lib/xtrabackup-scripts/restore_verify.sh
```

**Alerts** go to `alert_webhook_url` (prompted for interactively at run
time — an incoming webhook URL; treat it as a secret, anyone with the URL
can post to your channel). `alert_webhook_format` (group_vars, default
`simple`) picks the payload shape:
- `simple` — a flat `{key: message}` object. `alert_webhook_payload_key`
  controls the key (`text` for Slack, `content` for Discord).
- `teams` — a MessageCard object (`@type`/`@context`/`summary`/`title`/`text`),
  the shape Microsoft Teams or a Power Automate "When an HTTP request is
  received" trigger built around a Teams post normally expects. If you're
  going through Power Automate rather than a native Teams incoming webhook,
  double-check the flow's trigger JSON schema actually matches this shape (or
  adjust the schema) — a schema mismatch will silently drop the fields
  instead of erroring.

Two independent alert paths, both honoring `alert_webhook_format`:
- Each cron script (`backup.sh`, `check.sh`, `restore_verify.sh`) posts
  immediately on its own failure, via the shared
  `roles/xtrabackup/templates/alert.sh.j2` helper.
- `playbooks/cluster_health.yml`'s final play aggregates *everything* it
  checked (wsrep state/cluster membership, backup freshness, HAProxy) and
  posts one consolidated message if anything is unhealthy — this is what
  catches a problem even if the immediate cron-side alert never fired (e.g.
  the node couldn't reach the webhook URL at the time).

To test the alert path end-to-end: stop `mysql` on one replica node, then run
`ansible-playbook playbooks/cluster_health.yml` and enter a real test
channel's URL at the `alert_webhook_url` prompt — a failure message should
land in the channel.

**Enabling alerting after the fact** (e.g. you left the webhook prompt blank
on your initial `install.yml` run): since nothing is persisted, just re-run
the build and actually enter a URL at the prompt this time:
```bash
ansible-playbook install.yml
```
Every other prompt (SSH creds, DB passwords, etc.) can be re-entered
unchanged — every role is idempotent, so nothing gets rebuilt or restarted
except what actually changed. To avoid touching the proxy nodes at all,
scope it down instead (`localhost` must stay in the limit — it's the play
that prompts for and distributes every credential; without it the DB nodes
get no updated values):
```bash
ansible-playbook install.yml --limit "localhost,db_nodes"
```
This updates `/usr/local/lib/xtrabackup-scripts/alert.sh` on the designated
backup node, so cron alerts (`backup.sh`/`check.sh`/`restore_verify.sh`
failures) work from then on with no further action needed — that part is
persisted as a rendered file, unlike the credentials themselves.

**Running `cluster_health.yml` non-interactively (cron/CI)**: run standalone,
this playbook normally prompts for SSH creds, health-check/HAProxy-stats
creds, the alert webhook URL, and the cluster VIP — fine interactively, but
it'll hang forever with no TTY. Every one of those prompts is skipped if its
variable is already supplied via `-e`, so a fully non-interactive run looks
like:
```bash
ansible-playbook playbooks/cluster_health.yml \
  -e ssh_user=deploy -e ssh_pass='' \
  -e health_user=clustercheck -e health_pass='...' \
  -e haproxy_stats_user=haproxyadmin -e haproxy_stats_pass='...' \
  -e alert_webhook_url='https://hooks.slack.com/services/...' \
  -e cluster_vip=10.223.16.79
```
(`ssh_pass=''` means "use SSH keys + passwordless sudo", same as leaving
that prompt blank interactively.) Put the real values in a proper secrets
store for your scheduler (e.g. an Ansible Vault–encrypted `-e @secrets.yml`,
or your cron user's environment) rather than a plaintext crontab line —
`-e` values show up in `ps` output and shell history otherwise.

## Re-running / making changes

Every role is idempotent — re-running `install.yml` after changing a variable
(e.g. `innodb_buffer_pool_pct` in `group_vars/all/01-vars.yml`, or a
different value typed at a credential prompt such as `haproxy_stats_pass`)
will update the relevant config file and restart only the affected service
via its handler.

**Caution:** `mysql_galera`'s restart handler restarts the full `mysql`
service, not a graceful reload — safe here because that role's play always
runs with `serial: 1` (see `install.yml`), so only one DB node is ever
mid-restart at a time and the other two retain Galera quorum (2 of 3) while
it rejoins via IST/SST. If you ever invoke this role outside `install.yml`
without `serial: 1`, don't — a parallel restart across all 3 nodes would
drop the cluster.

## Notes / things worth knowing

- **No connection pooling/multiplexing.** By design, there's no ProxySQL (or
  other MySQL-aware pooler) layer here — HAProxy is TCP-only, so every
  client connection is a real backend MySQL connection, no pooling. Fine at
  moderate connection counts; watch `Threads_connected` under high
  concurrency and consider adding ProxySQL later if it becomes a bottleneck.
- **Static write-node priority, not a dynamic election.** Galera has no
  single elected leader. `haproxy.cfg` designates db-node-1 as the active
  writer and lists db-node-2/3 as HAProxy `backup` servers (only used once
  db-node-1 fails its `clustercheck`). HAProxy will automatically shift
  writes back to db-node-1 the moment it's healthy again (`backup` server
  semantics) — a brief, avoidable cutover after recovery, not a bug. If
  you'd rather control fail-back manually, remove the `backup` keyword's
  implicit preference by monitoring and cutting over deliberately instead of
  trusting automatic re-promotion.
- **All 3 nodes stay directly writable at the MySQL layer.** Nothing here
  enforces `read_only` on db-node-2/3 — HAProxy is what funnels application
  writes to one node. Concurrent direct writes to multiple nodes (bypassing
  HAProxy) will replicate via Galera's certification-based replication, but
  can cause certification-conflict rollbacks under contention. Don't let
  application code connect directly to DB node IPs for writes.
- **Percona repo series**: pinned via `percona_product_series: pxc80` in
  `group_vars/all/01-vars.yml`. Override with `-e
  percona_product_series=pxc57` at run time if you need a different major
  version — the `common` role's `percona-release setup` step picks up
  whatever series you pass.
- **Memory-based tuning** (`innodb_buffer_pool_size`,
  `innodb_buffer_pool_instances`) is computed per-host from
  `ansible_memtotal_mb` at runtime. Override with
  `innodb_buffer_pool_size_override` in `group_vars/all/01-vars.yml` if you
  want a fixed value. `max_connections` is similarly RAM-aware: it scales
  down from the `mysql_max_connections` ceiling (default 500) using whatever
  RAM is left over after the buffer pool and Galera's gcache
  (`roles/mysql_galera/defaults/main.yml`'s `mysql_conn_*` vars), so a
  minimum-spec node doesn't advertise more connections than it can actually
  back — e.g. ~400 on a 12GB node vs. the full 500 on a 16GB+ one. Override
  with `mysql_max_connections_override` to pin a fixed value instead.
- **Firewall**: UFW rules are built from the inventory groups directly
  (`groups['db_nodes']`, `groups['proxy_nodes']`), so adding a node to the
  inventory and re-running `install.yml` also updates firewall rules — no
  manual IP list maintenance.

## Restoring from a backup

There's no playbook for this — restoring into production is manual, since it
involves stopping the cluster and reasoning about which backup chain and
binlog position to restore from, which isn't safe to fully automate. The
only restore-related automation is
`roles/xtrabackup/templates/restore_verify.sh.j2`
(`/usr/local/lib/xtrabackup-scripts/restore_verify.sh` on
`xtrabackup_backup_node`), and that only ever restores into a scratch
directory to test that a backup is usable — it never touches real data (see
"Backups & alerts" above).

**Caveat:** the xtrabackup repo lives on a single fixed node
(`xtrabackup_backup_node`, default db-node-2). If that node is unrecoverable,
your backup chain goes with it — the other two nodes have identical *live*
data (that's what Galera guarantees) but no independent backup history of
their own. Treat `xtrabackup_repo_path` as something worth shipping off-box
periodically (e.g. `rsync` to another host) if you need backups to survive
the loss of that specific node.

Steps below restore to a specific point in time (call the target node
`db-node-1`); for a plain restore of the latest backup instead of PITR, skip
the `mysqlbinlog` replay step.

1. **Stop MySQL on all 3 DB nodes** so the cluster doesn't try to
   re-certify writes against a node mid-restore:
   ```bash
   sudo systemctl stop mysql
   ```
2. **On the target node**, move the current data directory aside and
   restore the latest full backup (plus its most recent diff, if any) from
   `xtrabackup_backup_node`:
   ```bash
   sudo mv /var/lib/mysql /var/lib/mysql.bak
   sudo mkdir -p /var/lib/mysql
   # Copy (or rsync) the full-*/diff-* directories over from xtrabackup_backup_node first, then:
   sudo xtrabackup --prepare --apply-log-only --target-dir=/path/to/full-YYYYmmdd_HHMMSS
   sudo xtrabackup --prepare --target-dir=/path/to/full-YYYYmmdd_HHMMSS --incremental-dir=/path/to/diff-YYYYmmdd_HHMMSS
   sudo xtrabackup --copy-back --target-dir=/path/to/full-YYYYmmdd_HHMMSS --datadir=/var/lib/mysql
   sudo chown -R mysql:mysql /var/lib/mysql
   ```
3. **Optional point-in-time replay** past the backup, using binlogs copied
   from `xtrabackup_backup_node`'s `{{ mysql_log_dir }}` (or wherever you
   ship them):
   ```bash
   sudo mysqlbinlog --start-position=<pos-from-xtrabackup_binlog_info> \
       --stop-datetime="2026-07-15 14:30:00" mysql-bin.000123 \
       | sudo mysql --defaults-extra-file=/root/.my.cnf
   ```
   (`xtrabackup_binlog_info` inside the prepared backup directory records
   the exact binlog file/position the backup was taken at.)
4. **Start MySQL on the restored node only**, *without* rejoining the
   existing cluster's gcomm address yet — bootstrap it as a new
   single-node cluster so the other two nodes clone from it, not the other
   way around:
   ```bash
   sudo systemctl start mysql@bootstrap.service
   sudo systemctl enable mysql
   ```
5. **Start MySQL on the other two nodes.** With `wsrep_cluster_address`
   still pointing at all 3 DB node IPs (unchanged in `galera.cnf`), they'll
   detect the running node and clone themselves via SST
   (`wsrep_sst_method=xtrabackup-v2`), wiping their own data automatically:
   ```bash
   sudo systemctl start mysql
   ```
6. **Verify**, then remove the `.bak` directory from step 2 once you're
   confident the restored data is correct:
   ```bash
   ansible-playbook playbooks/cluster_health.yml
   ```

## Replacing a lost DB node (VM gone, disk dead, unrecoverable)

This covers the case where a DB node's VM itself is gone — not just its
data — and you need to bring in a fresh replacement.

This is mostly a non-event for Galera: there's no separate cluster
membership bookkeeping to fix up, and any node's local data can be fully
rebuilt from the surviving nodes via SST. The steps are the ordinary
`install.yml` flow, not a special procedure.

**If the dead node was carrying HAProxy's write traffic (db-node-1)**,
HAProxy fails over to db-node-2/3 automatically (see "Notes" above on
`backup` server ordering) as soon as `clustercheck` reports db-node-1 down —
confirm that happened before touching anything else:
```bash
ansible-playbook playbooks/cluster_health.yml
```
You should see the two survivors both `Primary`/`Synced`. With only 2 of 3
nodes up, the cluster is still quorate (Galera needs a strict majority — 2
of 3), but a second node loss would take the whole cluster down, so replace
the dead node promptly.

**Step by step:**

1. **Confirm the surviving 2 nodes are healthy first** (see above).

2. **Provision the replacement VM.** Reuse the same hostname (`db-node-1`)
   and IP if at all possible — it matches what's already in
   `inventory/hosts.yml` and what every other node's `wsrep_cluster_address`
   points at. If the IP has to change, update `inventory/hosts.yml` first.

3. **Run the build against just that node (plus `localhost` for
   credentials):**
   ```bash
   ansible-playbook install.yml --limit "localhost,db-node-1"
   ```
   `mysql_galera`'s peer-liveness check (in `roles/mysql_galera/tasks/main.yml`)
   will detect that db-node-2/3 already have a live cluster and skip
   bootstrap automatically — db-node-1 just starts normally and clones the
   full dataset via SST (`xtrabackup-v2`), even though it's `db_nodes[0]`
   and would otherwise be the deterministic bootstrap node. No manual
   membership surgery needed.

4. **Verify the cluster is back to full strength:**
   ```bash
   ansible-playbook playbooks/cluster_health.yml
   ```
   Expect all 3 DB nodes `Primary`/`Synced`, and HAProxy routing writes back
   to db-node-1 once its `clustercheck` passes.
