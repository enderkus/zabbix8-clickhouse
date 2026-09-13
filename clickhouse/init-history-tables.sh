#!/usr/bin/env bash
# Creates the "zabbix" database and history_* tables in ClickHouse,
# mirroring the official Zabbix 8.0 clickhouse/history_all.sh schema scripts
# (https://www.zabbix.com/documentation/8.0/en/manual/appendix/install/clickhouse_setup).
#
# Runs as a one-off init container after ClickHouse reports healthy,
# and before zabbix-server starts (see docker-compose.yml depends_on).
set -euo pipefail

CH_URL="${CH_URL:-http://clickhouse:8123}"
CH_USER="${CH_USER:-default}"
CH_PASSWORD="${CH_PASSWORD:-changeme}"
CH_DB="${CH_DB:-zabbix}"
CH_TTL="${CH_TTL:-2678400}"   # 31 days, Zabbix default
CH_ENGINE="${CH_ENGINE:-MergeTree()}"
CH_PARTITION="${CH_PARTITION:-toDate}"

AUTH=(-u "${CH_USER}:${CH_PASSWORD}")

echo "[clickhouse-init] Waiting for ClickHouse at ${CH_URL}..."
until curl -sf "${AUTH[@]}" "${CH_URL}/ping" >/dev/null 2>&1; do
  sleep 2
done

echo "[clickhouse-init] Creating database '${CH_DB}' if missing..."
echo "CREATE DATABASE IF NOT EXISTS ${CH_DB}" | curl -sf "${AUTH[@]}" "${CH_URL}" --data-binary @-

create_table() {
  local name="$1" ddl="$2"
  local exists
  exists=$(echo "EXISTS TABLE ${CH_DB}.${name}" | curl -sf "${AUTH[@]}" "${CH_URL}" --data-binary @-)
  if [ "${exists}" = "1" ]; then
    echo "[clickhouse-init] Table ${CH_DB}.${name} already exists, skipping."
    return
  fi
  echo "[clickhouse-init] Creating table ${CH_DB}.${name}..."
  echo "${ddl}" | curl -sf "${AUTH[@]}" "${CH_URL}" --data-binary @-
}

create_table "history" "
CREATE TABLE ${CH_DB}.history
(
    itemid UInt64,
    clock_ns DateTime64(9),
    value Float64
)
ENGINE = ${CH_ENGINE}
PARTITION BY ${CH_PARTITION}(clock_ns)
PRIMARY KEY (itemid, clock_ns)
TTL clock_ns + toIntervalSecond(${CH_TTL})
"

create_table "history_str" "
CREATE TABLE ${CH_DB}.history_str
(
    itemid UInt64,
    clock_ns DateTime64(9),
    value String
)
ENGINE = ${CH_ENGINE}
PARTITION BY ${CH_PARTITION}(clock_ns)
PRIMARY KEY (itemid, clock_ns)
TTL clock_ns + toIntervalSecond(${CH_TTL})
"

create_table "history_log" "
CREATE TABLE ${CH_DB}.history_log
(
    itemid UInt64,
    clock_ns DateTime64(9),
    value String,
    source String,
    severity Int32,
    logeventid Int32,
    timestamp Int64
)
ENGINE = ${CH_ENGINE}
PARTITION BY ${CH_PARTITION}(clock_ns)
PRIMARY KEY (itemid, clock_ns)
TTL clock_ns + toIntervalSecond(${CH_TTL})
"

create_table "history_uint" "
CREATE TABLE ${CH_DB}.history_uint
(
    itemid UInt64,
    clock_ns DateTime64(9),
    value UInt64
)
ENGINE = ${CH_ENGINE}
PARTITION BY ${CH_PARTITION}(clock_ns)
PRIMARY KEY (itemid, clock_ns)
TTL clock_ns + toIntervalSecond(${CH_TTL})
"

create_table "history_text" "
CREATE TABLE ${CH_DB}.history_text
(
    itemid UInt64,
    clock_ns DateTime64(9),
    value String
)
ENGINE = ${CH_ENGINE}
PARTITION BY ${CH_PARTITION}(clock_ns)
PRIMARY KEY (itemid, clock_ns)
TTL clock_ns + toIntervalSecond(${CH_TTL})
"

create_table "history_json" "
CREATE TABLE ${CH_DB}.history_json
(
    itemid UInt64,
    clock_ns DateTime64(9),
    value JSON,
    value_str String
)
ENGINE = ${CH_ENGINE}
PARTITION BY ${CH_PARTITION}(clock_ns)
PRIMARY KEY (itemid, clock_ns)
TTL clock_ns + toIntervalSecond(${CH_TTL})
"

echo "[clickhouse-init] Done. Tables in ${CH_DB}:"
echo "SHOW TABLES FROM ${CH_DB}" | curl -sf "${AUTH[@]}" "${CH_URL}" --data-binary @-
