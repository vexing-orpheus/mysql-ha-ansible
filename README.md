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
│   ├── 01-vars.yml           # non-secret config (PG version, ports, network, tuning)
│   └── vault.yml.example     # copy -> vault.yml, fill in, then ansible-vault encrypt
├── site.yml                  # main build playbook
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
- **Disk**: 50 GB OS volume, **plus a separate data volume for DB nodes**
  mounted under the PostgreSQL data directory (or a parent of it, e.g.
  `/var/lib/postgresql`) — DB nodes fail the play if no such dedicated
  volume is detected.

## 1. Control VM setup

On a separate VM (not one of the 5 cluster nodes):

```bash
sudo apt update && sudo apt install -y python3-pip
pip3 install --break-system-packages ansible

cd pg-ha-ansible
ansible-galaxy collection install -r requirements.yml
```

You'll need SSH + sudo access as a sudo-capable user on all 5 target nodes.
`run.sh` (see below) prompts for the SSH username and password interactively,
so nothing is hardcoded in `ansible.cfg`.

## 2. Configure

1. **Inventory** — edit `inventory/hosts.yml` with your 5 real IPs. Hostnames
   (`pg-node-1`, `proxy-node-1`, ...) must match each machine's actual
   `hostname -s`, since Patroni/etcd/HAProxy configs key off that name.
2. **Non-secret vars** — review `group_vars/all/01-vars.yml`: cluster VIP,
   `vip_interface` (confirm with `ip -4 addr show` on a proxy node),
   networks, PostgreSQL version (defaults to 18 — override with
   `-e pg_version=16` at run time if needed).
3. **Secrets** —
   ```bash
   cp group_vars/all/vault.yml.example group_vars/all/vault.yml
   vi group_vars/all/vault.yml        # set real passwords + alert_webhook_url
   ansible-vault encrypt group_vars/all/vault.yml
   ```

## 3. Run

```bash
ansible-playbook site.yml --ask-vault-pass
```

`--ask-vault-pass` is the only flag needed — Ansible has to decrypt
`group_vars/all/vault.yml` before it can parse the first play at all, so
that password can't be collected any other way. Everything else (SSH
username, and one password used for both SSH login and sudo/become) is
prompted for interactively by `site.yml`'s own first play, which then
applies those credentials to all 5 hosts for the rest of the run. To pass
extra options through (e.g. `--limit`, `-e pg_version=16`), just append
them: `ansible-playbook site.yml --ask-vault-pass --limit pg-node-1`.

If your nodes use SSH keys rather than password auth, leave the SSH
password prompt blank when it appears — key-based auth will be used
automatically as long as `ssh_user` matches a key-authorized account.

`run.sh` still works the old way (`./run.sh playbooks/cluster_health.yml`)
for playbooks that don't have their own credential-prompt play, such as
running `cluster_health.yml` standalone.

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
   assertion fails, so `site.yml` itself fails the run if the cluster
   comes up unhealthy.

Each role waits on real state (etcd health, Patroni role, HAProxy stats
page, PgBouncer's listening port) before moving on, so a partial failure
stops the play instead of silently continuing.

## 4. Verify (on demand)

The health check above already runs automatically at the end of every
`site.yml` build. To re-check cluster health later without re-running the
whole build (e.g. from cron/CI), run it standalone:

```bash
./run.sh playbooks/cluster_health.yml
```

## Backups, archiving & alerts

Backups and WAL archiving are handled by pgBackRest (`roles/pgbackrest`),
installed on all 3 DB nodes. `postgresql_patroni` sets `archive_mode`,
`archive_command`, and `restore_command` in `patroni.yml` so archiving is
wired up from the moment Postgres starts — there's a brief harmless window
during a fresh `site.yml` run where WAL archive attempts fail because
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

**Alerts** go to `alert_webhook_url` (in `group_vars/all/vault.yml`, a
Slack/Discord-style incoming webhook — treat it as a secret, anyone with the
URL can post to your channel). `alert_webhook_payload_key` controls the JSON
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

To test the alert path end-to-end: point `alert_webhook_url` at a real test
channel, then stop `etcd` on one node and rerun
`./run.sh playbooks/cluster_health.yml` — a failure message should land in
the channel.

## Re-running / making changes

Every role is idempotent — re-running `site.yml` after changing a variable
(e.g. `haproxy_stats_pass`, `pgbouncer_pool_mode`) will update the relevant
config file and restart only the affected service via its handler. Patroni
config changes are POSTed to `/reload` rather than restarting PostgreSQL.

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
  inventory and re-running `site.yml` also updates firewall rules — no
  manual IP list maintenance.
- This was converted from an existing dual-arch (x86_64 + s390x) bash
  script suite; s390x support was intentionally dropped per requirements.
  If you need it back, the etcd/PostgreSQL tuning branches in the original
  `01_bootstrap_all_nodes.sh` / `03_install_postgresql_patroni.sh` show
  what arch-conditional logic would need to be reintroduced (huge page
  size, `random_page_cost`, I/O scheduler, VRRP unicast default).
