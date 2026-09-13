#!/usr/bin/env bash
# One-time provisioning against the Zabbix API, run as an init container after
# zabbix-web is reachable. Makes a fresh `docker compose up` fully monitored
# with no manual clicks in the frontend:
#
#   1. Fixes the built-in "Zabbix server" host's agent interface. Zabbix
#      ships it pointing at 127.0.0.1:10050, which only works when the agent
#      runs in the same container/host as zabbix-server. Here the agent is
#      its own container (see the `zabbix-agent` service), so the interface
#      must point at that container's DNS name on the compose network instead.
#   2. Creates the "Docker test hosts" host group and the test-agent-1 /
#      test-agent-2 hosts (template: Linux by Zabbix agent) if they don't
#      already exist, so the two demo agents show up monitored immediately.
#
# Idempotent: safe to run again on every `docker compose up`.
set -euo pipefail

ZBX_API="${ZBX_API:-http://zabbix-web:8080/api_jsonrpc.php}"
ZBX_USER="${ZBX_USER:-Admin}"
ZBX_PASSWORD="${ZBX_PASSWORD:-zabbix}"
AGENT_DNS="${AGENT_DNS:-zabbix-agent}"
HOST_NAME="${HOST_NAME:-Zabbix server}"
TEST_GROUP="${TEST_GROUP:-Docker test hosts}"
TEST_TEMPLATE="${TEST_TEMPLATE:-Linux by Zabbix agent}"
TEST_AGENTS="${TEST_AGENTS:-test-agent-1 test-agent-2}"

api() {
  curl -sf "${ZBX_API}" -H 'Content-Type: application/json-rpc' "$@"
}

api_auth() {
  curl -sf "${ZBX_API}" -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer ${TOKEN}" "$@"
}

echo "[zbx-init] Waiting for Zabbix API at ${ZBX_API}..."
until api -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' >/dev/null 2>&1; do
  sleep 3
done
echo "[zbx-init] API is up."

# apiinfo.version can succeed via the PHP frontend before zabbix-server has
# finished importing the initial Postgres schema (dbversion table missing
# yet), which makes user.login fail transiently. Retry until it works.
echo "[zbx-init] Waiting for database schema and logging in..."
TOKEN=""
for i in $(seq 1 60); do
  LOGIN_RESP=$(api -d "$(jq -nc --arg u "$ZBX_USER" --arg p "$ZBX_PASSWORD" \
    '{jsonrpc:"2.0",method:"user.login",params:{username:$u,password:$p},id:1}')" || true)
  TOKEN=$(echo "$LOGIN_RESP" | jq -r '.result // empty' 2>/dev/null || true)
  [ -n "$TOKEN" ] && break
  sleep 5
done
if [ -z "$TOKEN" ]; then
  echo "[zbx-init] Login failed after retries: $LOGIN_RESP" >&2
  exit 1
fi
echo "[zbx-init] Logged in as ${ZBX_USER}."

### 1. Fix the "Zabbix server" host's agent interface. ###
HOST_RESP=$(api_auth -d "$(jq -nc --arg h "$HOST_NAME" \
  '{jsonrpc:"2.0",method:"host.get",params:{filter:{host:[$h]},selectInterfaces:["interfaceid","ip","dns","useip"]},id:1}')")
INTERFACEID=$(echo "$HOST_RESP" | jq -r '.result[0].interfaces[0].interfaceid // empty')
CURRENT_DNS=$(echo "$HOST_RESP" | jq -r '.result[0].interfaces[0].dns // empty')

if [ -n "$INTERFACEID" ]; then
  if [ "$CURRENT_DNS" != "$AGENT_DNS" ]; then
    echo "[zbx-init] Pointing '${HOST_NAME}' agent interface at ${AGENT_DNS} (was dns='${CURRENT_DNS}')..."
    api_auth -d "$(jq -nc --arg id "$INTERFACEID" --arg dns "$AGENT_DNS" \
      '{jsonrpc:"2.0",method:"hostinterface.update",params:{interfaceid:$id,useip:0,ip:"",dns:$dns},id:1}')" >/dev/null
    echo "[zbx-init] Interface updated."
  else
    echo "[zbx-init] '${HOST_NAME}' interface already points at ${AGENT_DNS}, skipping."
  fi
else
  echo "[zbx-init] WARNING: host '${HOST_NAME}' not found, skipping interface fix." >&2
fi

### 2. Ensure the demo host group + test agent hosts exist. ###
GROUP_RESP=$(api_auth -d "$(jq -nc --arg g "$TEST_GROUP" \
  '{jsonrpc:"2.0",method:"hostgroup.get",params:{filter:{name:[$g]}},id:1}')")
GROUPID=$(echo "$GROUP_RESP" | jq -r '.result[0].groupid // empty')
if [ -z "$GROUPID" ]; then
  echo "[zbx-init] Creating host group '${TEST_GROUP}'..."
  GROUPID=$(api_auth -d "$(jq -nc --arg g "$TEST_GROUP" \
    '{jsonrpc:"2.0",method:"hostgroup.create",params:{name:$g},id:1}')" | jq -r '.result.groupids[0]')
fi

TEMPLATE_RESP=$(api_auth -d "$(jq -nc --arg t "$TEST_TEMPLATE" \
  '{jsonrpc:"2.0",method:"template.get",params:{filter:{host:[$t]}},id:1}')")
TEMPLATEID=$(echo "$TEMPLATE_RESP" | jq -r '.result[0].templateid // empty')
if [ -z "$TEMPLATEID" ]; then
  echo "[zbx-init] WARNING: template '${TEST_TEMPLATE}' not found, creating test agents without a template." >&2
fi

for name in $TEST_AGENTS; do
  EXISTING=$(api_auth -d "$(jq -nc --arg h "$name" \
    '{jsonrpc:"2.0",method:"host.get",params:{filter:{host:[$h]}},id:1}')" | jq -r '.result[0].hostid // empty')
  if [ -n "$EXISTING" ]; then
    echo "[zbx-init] Host '${name}' already exists, skipping."
    continue
  fi
  echo "[zbx-init] Creating host '${name}'..."
  if [ -n "$TEMPLATEID" ]; then
    TEMPLATES_ARG=$(jq -nc --arg t "$TEMPLATEID" '[{templateid:$t}]')
  else
    TEMPLATES_ARG='[]'
  fi
  api_auth -d "$(jq -nc --arg h "$name" --arg gid "$GROUPID" --argjson templates "$TEMPLATES_ARG" \
    '{jsonrpc:"2.0",method:"host.create",params:{host:$h,interfaces:[{type:1,main:1,useip:0,ip:"",dns:$h,port:"10050"}],groups:[{groupid:$gid}],templates:$templates},id:1}')" >/dev/null
  echo "[zbx-init] Host '${name}' created."
done

echo "[zbx-init] Provisioning complete."
