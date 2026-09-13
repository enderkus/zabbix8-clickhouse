# Zabbix 8 + ClickHouse History Storage: Docker Compose Demo

A self-contained, runnable example of **Zabbix 8.0's ClickHouse history
storage provider**. One `docker compose up -d` gets you a full stack:
Zabbix server, frontend, PostgreSQL for configuration, ClickHouse for
history, and three monitored agents, with zero manual clicking in the UI.
Hosts are auto-provisioned via the Zabbix API and data is flowing into
ClickHouse within a minute.

Reference: [Zabbix 8.0 docs: ClickHouse setup](https://www.zabbix.com/documentation/8.0/en/manual/appendix/install/clickhouse_setup)

## Why ClickHouse for Zabbix history?

Zabbix has always stored history in its main SQL database (PostgreSQL/MySQL).
Zabbix 8.0 adds ClickHouse as an alternative **history storage provider**.
Config data (hosts, items, triggers, users) still lives in PostgreSQL, but
the high-volume numeric/text/log history rows are written to ClickHouse
instead.

That split matters because of what ClickHouse *is*: a columnar OLAP database
built for exactly this kind of workload, huge volumes of immutable,
timestamped rows.

- **Compression.** Columnar storage means every column (itemid, timestamp,
  value) is packed and compressed on its own, and time-series metric values
  compress extremely well since neighboring values in a column tend to be
  similar. This means retaining months of granular history in a fraction of
  the disk space a row-oriented SQL table would need for the same data.
- **Fast range/aggregate queries at scale.** Dashboards and graphs mostly
  do `SELECT ... WHERE itemid=X AND clock BETWEEN a AND b` or aggregate over
  large time windows. ClickHouse is built to scan exactly that pattern
  quickly across billions of rows, instead of relying on OLTP-style indexes
  optimized for point lookups.
- **Takes write load off PostgreSQL.** Under heavy ingestion (many hosts,
  low-interval items), history writes are usually what stresses a
  PostgreSQL-backed Zabbix install first. Offloading them to a
  purpose-built store lets Postgres focus on configuration and lets history
  volume scale independently.

Worth being upfront about what the official docs call out as trade-offs, so
you don't discover them the hard way:

- **The Zabbix housekeeper does not clean up ClickHouse data.** Retention is
  controlled entirely by ClickHouse's own `TTL` clause on each table (this
  repo sets it via `CH_TTL`, default 31 days). See
  [`clickhouse/init-history-tables.sh`](clickhouse/init-history-tables.sh).
- **Trends are not calculated or stored in ClickHouse.** Trend
  aggregation still happens against the SQL database only.
- **ClickHouse is not supported as a history backend for Zabbix proxies,**
  only for the server.
- Supported value types map to dedicated tables: numeric float goes to
  `history`, numeric unsigned to `history_uint`, character to `history_str`,
  log to `history_log`, text to `history_text`, JSON to `history_json`
  (ClickHouse doesn't accept JSON arrays, which the schema accounts for).

## What's included

| Service           | Purpose                                                  | Exposed port                |
|-------------------|-----------------------------------------------------------|------------------------------|
| `postgres-server`  | Zabbix configuration database                             | -                            |
| `clickhouse`       | History storage backend                                   | 8123 (HTTP), 9000 (native)   |
| `tabix`            | Web UI for browsing ClickHouse directly                   | 8082                         |
| `zabbix-server`    | Zabbix server, configured with `ZBX_HISTORYPROVIDER_0`     | 10051                        |
| `zabbix-web`       | Zabbix frontend (nginx)                                    | 8080                         |
| `zabbix-agent`     | Agent for the built-in "Zabbix server" host                | -                            |
| `test-agent-1/2`   | Extra agents to generate sample history data               | -                            |
| `clickhouse-init`  | One-off: creates the ClickHouse schema, then exits          | -                            |
| `zabbix-init`      | One-off: provisions hosts via the Zabbix API, then exits    | -                            |

## Quickstart

```bash
git clone <this-repo>
cd zabbix8
docker compose up -d
```

Wait about a minute for the one-off `clickhouse-init` and `zabbix-init`
containers to finish:

```bash
docker compose logs -f zabbix-init
```

Then open:

- **Zabbix frontend**: http://localhost:8080 (`Admin` / `zabbix`)
- **ClickHouse Tabix UI**: http://localhost:8082 (server `http://clickhouse:8123`,
  from your browser use `http://localhost:8123`, user `default` / `changeme`)

In **Data collection → Hosts** you should see `Zabbix server`, `test-agent-1`
and `test-agent-2` all reporting as available. Check **Monitoring → Latest
data** to see values already flowing in, served straight out of ClickHouse.

## Why `zabbix-init` exists

Zabbix ships the built-in `Zabbix server` host with its agent interface
hardcoded to `127.0.0.1:10050`, which assumes the agent runs colocated with
the server process. In this compose file the agent is its own container
(`zabbix-agent`), so `zabbix-server` looking at its own `127.0.0.1` never
finds it: the host shows as unavailable even though everything else works.
This is the exact issue this repo was built to fix and automate around.

`zabbix-init` is a one-off container that waits for the Zabbix API, then:

1. Points the `Zabbix server` host's interface at the `zabbix-agent`
   container's DNS name instead of `127.0.0.1`.
2. Registers `test-agent-1` / `test-agent-2` as hosts (group "Docker test
   hosts", template "Linux by Zabbix agent") so they show up monitored
   without any manual clicking in the UI.

It's idempotent, safe to leave running on every `docker compose up`.

## Configuration knobs

- ClickHouse credentials (`default` / `changeme`), history retention
  (`CH_TTL`, default 31 days = 2678400 seconds), and table engine/partition
  settings are environment variables on `clickhouse-init` in
  `docker-compose.yml`.
- Zabbix admin credentials used for provisioning are set via `ZBX_USER` /
  `ZBX_PASSWORD` on `zabbix-init`. Change them there (and in the frontend)
  before exposing this beyond local use.

## Resetting

```bash
docker compose down -v
```

Drops the Postgres and ClickHouse volumes, so the next `up` starts
completely fresh (including re-running provisioning).

## Disclaimer

This is a learning/demo setup, not a production hardening guide: default
passwords, no TLS, single-node ClickHouse. Change credentials and review the
[official ClickHouse setup docs](https://www.zabbix.com/documentation/8.0/en/manual/appendix/install/clickhouse_setup)
before running anything like this outside a local sandbox.
