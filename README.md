# Zabbix 8 + ClickHouse history storage (Docker Compose demo)

A self-contained example of Zabbix 8.0's new **ClickHouse history storage
provider**, running entirely via `docker compose up`. It brings up Zabbix
server/frontend on PostgreSQL (config data), a ClickHouse container for
history data, and three monitored agents so you can see history rows land in
ClickHouse right away.

## What's included

| Service          | Purpose                                             | Exposed port |
|-------------------|-----------------------------------------------------|--------------|
| `postgres-server` | Zabbix config database                              | -            |
| `clickhouse`      | History storage backend                             | 8123 (HTTP), 9000 (native) |
| `tabix`           | Web UI for browsing ClickHouse directly              | 8082         |
| `zabbix-server`   | Zabbix server                                       | 10051        |
| `zabbix-web`      | Zabbix frontend (nginx)                             | 8081         |
| `zabbix-agent`    | Agent for the built-in "Zabbix server" host          | -            |
| `test-agent-1/2`  | Extra agents to generate sample history data         | -            |
| `clickhouse-init` | One-off: creates the ClickHouse schema (runs & exits) | -           |
| `zabbix-init`     | One-off: provisions hosts via the Zabbix API (runs & exits) | -      |

## Quickstart

```bash
docker compose up -d
```

Wait about a minute for the one-off `clickhouse-init` and `zabbix-init`
containers to finish (`docker compose logs -f zabbix-init`), then open:

- Zabbix frontend: http://localhost:8081 (`Admin` / `zabbix`)
- ClickHouse Tabix UI: http://localhost:8082 (server `http://clickhouse:8123`
  from your browser use `http://localhost:8123`, user `default` / `changeme`)

In **Data collection → Hosts** you should see `Zabbix server`, `test-agent-1`
and `test-agent-2` all reporting as available, with data already flowing into
ClickHouse (check **Monitoring → Latest data**).

## Why `zabbix-init` exists

Zabbix ships the built-in `Zabbix server` host with its agent interface
hardcoded to `127.0.0.1:10050`, which assumes the agent runs colocated with
the server process. In this compose file the agent is a separate container
(`zabbix-agent`), so `zabbix-server` looking at its own `127.0.0.1` never
finds it — the host shows as unavailable even though everything else works.

`zabbix-init` is a one-off container that waits for the Zabbix API, then:

1. Points the `Zabbix server` host's interface at the `zabbix-agent`
   container's DNS name instead of `127.0.0.1`.
2. Registers `test-agent-1` / `test-agent-2` as hosts (group "Docker test
   hosts", template "Linux by Zabbix agent") so they show up monitored
   without any manual clicking in the UI.

It's idempotent — safe to leave running every `docker compose up`.

## Configuration knobs

- ClickHouse credentials (`default` / `changeme`), history retention
  (`CH_TTL`, default 31 days), and TTL/engine settings are environment
  variables on `clickhouse-init` in `docker-compose.yml`.
- Zabbix admin credentials used for provisioning are set via `ZBX_USER` /
  `ZBX_PASSWORD` on `zabbix-init` — change them there (and in the frontend)
  if you expose this beyond local use.

## Resetting

```bash
docker compose down -v
```

This drops the Postgres and ClickHouse volumes, so the next `up` starts
completely fresh (including re-running provisioning).
