# PostgreSQL HA Cluster — Ansible

Builds the same 5-node PostgreSQL + Patroni + etcd + PgBouncer + HAProxy/Keepalived
cluster as the original bash scripts, but driven from a separate Ansible control
VM, idempotently, with proper role separation. **x86_64 only.**

## Layout

```
pg-ha-ansible/
├── ansible.cfg
├── requirements.yml          # collections: community.general, community.postgresql, ansible.posix
├── inventory/hosts.yml       # edit the 5 node IPs here
├── group_vars/all/
│   └── 01-vars.yml           # non-secret config (PG version, ports, network, tuning)
├── install.yml                # main build playbook — prompts for all credentials/secrets
├── playbooks/cluster_health.yml
└── roles/
    ├── common               # packages, NTP, /etc/hosts, sysctl, THP, UFW, PGDG repo
    ├── etcd                 # 3-node etcd cluster (db_nodes)
    ├── postgresql_patroni   # PostgreSQL + Patroni (db_nodes)
    ├── pgbackrest           # WAL archiving, backup/check/restore-verify cron (db_nodes)
    ├── pgbouncer            # connection pooler (proxy_nodes)
    └── haproxy_keepalived   # read/write routing + VIP failover (proxy_nodes)
```

## Hardware requirements

Minimum per node (DB or proxy), enforced by the `common` role at the start
of every run — the play fails fast on any node that doesn't meet these:

- **CPU**: 4 vCPUs (8+ recommended for DB nodes — warns, doesn't fail, if unmet)
- **RAM**: 8 GB (16 GB+ recommended for DB nodes — warns, doesn't fail, if unmet)
- **Disk**: 50 GB OS volume. A separate data volume for DB nodes, mounted
  under the PostgreSQL data directory (or a parent of it, e.g.
  `/var/lib/postgresql`), is recommended but not required — DB nodes warn,
  not fail, if the data directory shares a device with the OS volume.

## 1. Control VM setup

On a separate VM (not one of the 5 cluster nodes):

```bash
sudo apt update && sudo apt install -y python3-pip
pip3 install --break-system-packages ansible

cd pg-ha-ansible
ansible-galaxy collection install -r requirements.yml
```

You'll need SSH + sudo access as a sudo-capable user on all 5 target nodes.
Every playbook (see below) prompts for the SSH username and password
interactively, so nothing is hardcoded in `ansible.cfg`.

## 2. Configure

1. **Inventory** — edit `inventory/hosts.yml` with your 5 real IPs. Hostnames
   (`pg-node-1`, `proxy-node-1`, ...) must match each machine's actual
   `hostname -s`, since Patroni/etcd/HAProxy configs key off that name.
2. **Non-secret vars** — review `group_vars/all/01-vars.yml`: `vip_prefix`,
   PostgreSQL version (defaults to 18 — override with `-e pg_version=16` at
   run time if needed). `cluster_vip`/`app_network`/`ops_network` are no
   longer set here — they're prompted for at run time (see below).
   `vip_interface` is auto-detected per proxy node from its default route;
   only uncomment it in `group_vars/all/01-vars.yml` if you need to force a
   specific NIC.
3. **Secrets** — nothing to do here. There's no vault file: every
   PostgreSQL / PgBouncer / HAProxy / keepalived credential and the alert
   webhook URL is prompted for interactively when you run `install.yml` (see
   below), so nothing is committed to this repo. Those values still end up
   in plaintext in the rendered config files on the target nodes themselves
   (`patroni.yml`, `userlist.txt`, `keepalived.conf`, ...) — that's inherent
   to how each service consumes its credentials, not something this
   playbook can avoid.

## 3. Run

```bash
ansible-playbook install.yml
```

No flags needed. `install.yml`'s first play prompts you, in order, for: SSH
username, one password used for both SSH login and sudo/become, the cluster
VIP (default `10.223.16.79`), the `app_network`/`ops_network` CIDRs used for
`pg_hba.conf`/PgBouncer/UFW rules (default `10.223.16.0/24`), then the
PostgreSQL replication/superuser/rewind/health-check accounts, the
application database name/user, the PgBouncer admin account, the HAProxy
stats account, the VRRP (keepalived) auth password, and finally the alert
webhook URL. Press Enter on any prompt to keep its default (usernames and
network CIDRs have one; passwords and the webhook URL don't — type a value
or leave blank if you don't need it, e.g. no webhook). Those values are then
applied to all 5 hosts for the rest of the run. To pass extra options
through (e.g. `--limit`, `-e pg_version=16`), just append them:
`ansible-playbook install.yml --limit pg-node-1`.

Because nothing is persisted, you'll re-enter all of the above on every
`install.yml` run — that's the trade-off of not using a vault file. To change a
credential (e.g. `haproxy_stats_pass`), just type the new value next time
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

1. **common** on all 5 nodes in parallel — OS prep, kernel tuning, UFW, PGDG repo.
2. **etcd** on the 3 DB nodes in parallel — all three are configured with the
   full member list up front (`initial-cluster-state: new`) and started
   together, which is etcd's supported static-bootstrap pattern.
3. **postgresql_patroni** on the 3 DB nodes **one at a time** (`serial: 1`,
   in inventory order — pg-node-1 first). Patroni does its own leader
   election via etcd: whichever instance starts first initializes the
   cluster, and the others detect the existing leader key and clone as
   replicas automatically. Running this play `serial: 1` just makes that
   deterministic instead of a race.
4. **pgbackrest** on the 3 DB nodes in parallel — WAL archiving, and cron
   jobs for scheduled backups, an integrity check, and restore verification.
   See "Backups, archiving & alerts" below.
5. **pgbouncer** + **haproxy_keepalived** on both proxy nodes in parallel.
6. **cluster_health** (imported from `playbooks/cluster_health.yml`) —
   reports Patroni role per node (asserts exactly one primary), etcd
   health, WAL archiver failures, backup freshness, PgBouncer/HAProxy
   status per proxy node, which node currently holds the VIP, and DB-node
   disk usage. Sends a consolidated alert to `alert_webhook_url` if
   anything is unhealthy, then exits non-zero if the primary-count
   assertion fails, so `install.yml` itself fails the run if the cluster
   comes up unhealthy.

Each role waits on real state (etcd health, Patroni role, HAProxy stats
page, PgBouncer's listening port) before moving on, so a partial failure
stops the play instead of silently continuing.

## 4. Verify (on demand)

The health check above already runs automatically at the end of every
`install.yml` build. To re-check cluster health later without re-running the
whole build (e.g. from cron/CI), run it standalone:

```bash
ansible-playbook playbooks/cluster_health.yml
```

## Backups, archiving & alerts

Backups and WAL archiving are handled by pgBackRest (`roles/pgbackrest`),
installed on all 3 DB nodes. `postgresql_patroni` sets `archive_mode`,
`archive_command`, and `restore_command` in `patroni.yml` so archiving is
wired up from the moment Postgres starts — there's a brief harmless window
during a fresh `install.yml` run where WAL archive attempts fail because
`pgbackrest` hasn't been installed yet (that happens in the very next play);
it self-heals automatically once the `pgbackrest` play finishes, no restart
needed.

**Repo is local disk, per node** (`pgbackrest_repo_path`, default
`/var/lib/pgbackrest`) — deliberately not S3/NFS. Because Patroni's primary
floats across `pg-node-1/2/3`, a node's local backup chain only grows while
it's primary. After a failover, the new primary has no local chain yet, so
its next scheduled backup is automatically a full backup instead of an
incremental/diff one — pgBackRest handles this on its own, it's just worth
knowing you'll see an extra full backup after every failover. If you'd
rather backups survive independently of which node is primary, point
`pgbackrest_repo_path` at a shared mount or switch the role to an
S3-compatible `repo1-type` — not done here to keep the setup dependency-free.

**Schedule** (all in `group_vars/all/01-vars.yml` /
`roles/pgbackrest/defaults/main.yml`, overridable):
- Full backup: weekly, Sunday 01:00. Diff backup: daily (except Sunday) 01:00.
- Integrity check (`pgbackrest check` — WAL/manifest checksums, no restore): daily 05:00.
- Restore verification: weekly, Sunday 03:00.

All of the above run via cron **on all 3 DB nodes**, but a wrapper script
checks Patroni's role via its REST API first: backup/check exit immediately
unless the node is currently the leader; restore-verify exits immediately
*unless* it's a replica, so it never competes with the primary for I/O.

**Restore verification** actually proves a backup is usable, not just
present: it restores the latest backup into a scratch directory
(`pgbackrest_restore_verify_path`), boots a temporary Postgres instance on a
throwaway port (`pgbackrest_restore_verify_port`, default 5555), runs a
liveness query, then tears both down. To hand-trigger it instead of waiting
for the weekly cron:
```bash
sudo -u postgres /usr/local/lib/pgbackrest-scripts/restore_verify.sh
```

**Alerts** go to `alert_webhook_url` (prompted for interactively at run
time — a Slack/Discord-style incoming webhook; treat it as a secret, anyone
with the URL can post to your channel). `alert_webhook_payload_key` controls
the JSON
key used (`text` for Slack, `content` for Discord; Microsoft Teams needs a
fuller adaptive-card payload and isn't supported by this simple webhook
POST). Two independent alert paths:
- Each cron script (`backup.sh`, `check.sh`, `restore_verify.sh`) posts
  immediately on its own failure, via the shared
  `roles/pgbackrest/templates/alert.sh.j2` helper.
- `playbooks/cluster_health.yml`'s final play aggregates *everything* it
  checked (Patroni roles, etcd, WAL archiver failures, backup freshness vs.
  `pgbackrest_backup_freshness_hours`, PgBouncer/HAProxy) and posts one
  consolidated message if anything is unhealthy — this is what catches a
  problem even if the immediate cron-side alert never fired (e.g. the node
  couldn't reach the webhook URL at the time).

To test the alert path end-to-end: stop `etcd` on one node, then run
`ansible-playbook playbooks/cluster_health.yml` and enter a real test
channel's URL at the `alert_webhook_url` prompt — a failure message should land in the
channel.

## Re-running / making changes

Every role is idempotent — re-running `install.yml` after changing a variable
(e.g. `pgbouncer_pool_mode` in `group_vars/all/01-vars.yml`, or a different
value typed at a credential prompt such as `haproxy_stats_pass`) will update
the relevant config file and restart only the affected service via its
handler. Patroni config changes are POSTed to `/reload` rather than
restarting PostgreSQL.

**Caution:** the `etcd` role's own restart handler is intentionally
disabled (see `roles/etcd/handlers/main.yml`) to avoid an accidental
simultaneous restart of all 3 etcd members from a single play run, which
would drop quorum. Restart etcd nodes manually, one at a time, if you
change etcd config.

## Notes / things worth knowing

- **PostgreSQL 18 default**: pinned via `pg_version: 18` in
  `group_vars/all/01-vars.yml`. Ubuntu 26.04 ships PG18 in its main
  archive, but this playbook installs from PGDG explicitly (added by the
  `common` role) so the version is always pinned regardless of which
  Ubuntu release you're on.
- **Memory-based tuning** (`shared_buffers`, `effective_cache_size`, huge
  pages count) is computed per-host from `ansible_memtotal_mb` at runtime,
  matching the original scripts' auto-detection. Override with
  `shared_buffers_override` / `effective_cache_size_override` in
  `group_vars/all/01-vars.yml` if you want fixed values.
- **Firewall**: UFW rules are built from the inventory groups directly
  (`groups['db_nodes']`, `groups['proxy_nodes']`), so adding a node to the
  inventory and re-running `install.yml` also updates firewall rules — no
  manual IP list maintenance.
- This was converted from an existing dual-arch (x86_64 + s390x) bash
  script suite; s390x support was intentionally dropped per requirements.
  If you need it back, the etcd/PostgreSQL tuning branches in the original
  `01_bootstrap_all_nodes.sh` / `03_install_postgresql_patroni.sh` show
  what arch-conditional logic would need to be reintroduced (huge page
  size, `random_page_cost`, I/O scheduler, VRRP unicast default).

## Restoring from a backup

There's no playbook for this — restoring into production is manual, since it
involves stopping Patroni cluster-wide and reasoning about etcd/timeline
state, which isn't safe to fully automate. The only restore-related
automation is `roles/pgbackrest/templates/restore_verify.sh.j2`
(`/usr/local/lib/pgbackrest-scripts/restore_verify.sh` on each node), and
that only ever restores into a scratch directory to test that a backup is
usable — it never touches real data (see "Backups, archiving & alerts"
above).

**Caveat:** the pgBackRest repo (backups *and* WAL archive) is local disk,
per node. Because Patroni's primary floats across the 3 DB nodes, a node's
backup/WAL chain only stays intact for the time span it was continuously
primary. If a failover happened between the backup you need and your
target time, that node's chain is broken past the failover point — check
which node actually has the chain you need before starting:

```bash
# run on pg-node-1, pg-node-2, pg-node-3 — look for a backup set whose
# timeline covers your target
sudo -u postgres pgbackrest --stanza=pg-ha-cluster info
```

Steps below restore to a specific point in time on the node with the valid
chain (call it `pg-node-1`); for a plain restore of the latest backup
instead of PITR, drop `--type=time --target=...` from step 3.

1. **Stop Patroni on all 3 DB nodes** so another node can't get promoted
   while you're mid-restore:
   ```bash
   sudo systemctl stop patroni
   ```
2. **Clear the old cluster state from etcd.** A restore rewinds history, and
   Patroni will otherwise refuse to start on a timeline it doesn't
   recognize:
   ```bash
   etcdctl --endpoints=http://<any-db-node-ip>:<etcd_client_port> del /service/pg-ha-cluster --prefix
   ```
3. **On the node with the valid chain**, move the current data directory
   aside and restore:
   ```bash
   sudo -u postgres mv /var/lib/postgresql/18/main /var/lib/postgresql/18/main.bak
   sudo -u postgres mkdir -p /var/lib/postgresql/18/main
   sudo -u postgres pgbackrest --stanza=pg-ha-cluster --pg1-path=/var/lib/postgresql/18/main \
       --type=time --target="2026-07-15 14:30:00+00" --target-action=promote restore
   sudo chmod 700 /var/lib/postgresql/18/main
   ```
   (`--target-action=promote` finishes recovery and opens for writes once
   the target is reached; use `pause` instead if you want to inspect the
   data before committing to it. Swap `/var/lib/postgresql/18/main` for
   `pg_data_dir` and `18` for `pg_version` if you've overridden either.)
4. **Start Patroni on that node only.** With no cluster key in etcd,
   Patroni bootstraps using the restored data directory as the new primary:
   ```bash
   sudo systemctl start patroni
   ```
   Watch `journalctl -u patroni -f` and confirm it comes up as leader and
   completes recovery at the target.
5. **Start Patroni on the other two nodes.** They'll see a leader already
   registered in etcd and re-clone themselves as replicas via
   `pg_basebackup` (this cluster's `create_replica_methods` is
   `basebackup`, not pgBackRest), wiping their own old data automatically:
   ```bash
   sudo systemctl start patroni
   ```
   If a node doesn't auto-reinit, force it:
   `patronictl -c /etc/patroni/patroni.yml reinit pg-ha-cluster <node-name>`.
6. **Verify**, then remove the `.bak` directory from step 3 once you're
   confident the restored data is correct:
   ```bash
   ansible-playbook playbooks/cluster_health.yml
   ```

## Replacing a lost DB node (VM gone, disk dead, unrecoverable)

This covers the case where a DB node's VM itself is gone — not just its
data — and you need to bring in a fresh replacement, whether it was the
primary or a replica.

**If the dead node was the primary**, Patroni/etcd should have already
auto-promoted one of the other two nodes within ~30-40s
(`ttl: 30` + `loop_wait: 10` in `patroni.yml.j2`). This is normal automatic
failover, not something you trigger by hand. **Confirm that happened before
touching anything else:**
```bash
ansible-playbook playbooks/cluster_health.yml
```
You should see exactly one surviving node as `Leader`. Replication here is
async (no `synchronous_mode` set), so a handful of the most recent
transactions may not have made it to a replica — that's the normal HA
trade-off, not a bug.

What's left is a *membership* problem, not a data problem: you're down to
2-node etcd/Patroni redundancy until the dead node is replaced.

**Why you can't just run `ansible-playbook install.yml --limit pg-node-1`
on its own** — two sharp edges in the current playbook:

1. The `etcd` role always renders `initial-cluster-state: 'new'`
   (`roles/etcd/templates/etcd.conf.yml.j2`) and statically bootstraps —
   it has no "rejoin an existing cluster" mode. Pointing it at a fresh VM
   while the other two nodes already have an established cluster does
   **not** correctly join it. Worse, this fails silently: both the etcd
   role's own health check and `cluster_health.yml`'s etcd check only query
   `http://127.0.0.1:2379`, so a lone, self-bootstrapped etcd instance
   reports itself "healthy" even though it's an orphaned island with zero
   real quorum. Patroni can even start successfully on that node anyway,
   because `patroni.yml`'s `etcd3.hosts` lists all 3 DB node IPs and can
   reach the *real* cluster through the other two — so everything looks
   green while the new node's local etcd is quietly useless.
2. The credentials play at the top of `install.yml` runs on `hosts:
   localhost` and hands out every service password via `add_host`. If
   `localhost` isn't included in `--limit`, that whole play is skipped and
   every role on the target node renders with missing/placeholder
   passwords.

**Step by step:**

1. **Confirm the surviving 2 nodes are healthy first** (see above) — don't
   start etcd surgery on a cluster that isn't already stable.

2. **On a surviving node, find and remove the dead etcd member:**
   ```bash
   etcdctl --endpoints=http://127.0.0.1:2379 member list
   etcdctl --endpoints=http://127.0.0.1:2379 member remove <old-member-id>
   ```

3. **Pre-register the replacement as a new member**, so the existing
   cluster is expecting it before its etcd process ever starts (name must
   match `{{ etcd_cluster_name }}-{{ inventory_hostname }}`, default
   `etcd_cluster_name` is `pg-ha-etcd`):
   ```bash
   etcdctl --endpoints=http://127.0.0.1:2379 member add pg-ha-etcd-pg-node-1 \
       --peer-urls=http://<pg-node-1-ip>:2380
   ```

4. **Provision the replacement VM.** Reuse the same hostname (`pg-node-1`)
   and IP if at all possible — it matches what's already in
   `inventory/hosts.yml` and what every other node's rendered config
   points at. If the IP has to change, update
   `inventory/hosts.yml` first and redo step 3 with the new IP.

5. **Run the build against just that node (plus `localhost` for
   credentials):**
   ```bash
   ansible-playbook install.yml --limit "localhost,pg-node-1"
   ```
   This will still render `initial-cluster-state: 'new'` and start etcd
   wrong — that's expected, fix it next.

6. **Fix etcd on the replacement node** so it actually joins as the member
   you pre-registered in step 3, instead of running as an orphaned
   single-node cluster:
   ```bash
   sudo systemctl stop etcd
   sudo rm -rf /var/lib/etcd/*
   sudo sed -i "s/initial-cluster-state: 'new'/initial-cluster-state: 'existing'/" /etc/etcd/etcd.conf.yml
   sudo systemctl start etcd
   etcdctl --endpoints=http://127.0.0.1:2379 member list
   ```
   Confirm all 3 members show up and `endpoint health` is green **from
   each** node, not just the new one. Note that a future `install.yml` run
   touching this node will re-render the config back to
   `initial-cluster-state: 'new'` (the role doesn't know the difference) —
   harmless once the node has already joined and has cluster state on
   disk, since etcd ignores `initial-cluster-state` after the first
   successful start, but worth knowing if you're troubleshooting later.

7. **Restart Patroni on the replacement node** to make sure it's cloning
   against the now-correctly-joined local etcd rather than whatever it
   improvised during step 5:
   ```bash
   sudo systemctl restart patroni
   ```
   Watch `journalctl -u patroni -f` — it should detect the existing leader
   and clone as a replica via `pg_basebackup`.

8. **Verify the cluster is back to full strength:**
   ```bash
   ansible-playbook playbooks/cluster_health.yml
   ```
   Expect 1 primary, 2 replicas, all 3 etcd members healthy.
