#!/usr/bin/env bash
set -euo pipefail

# ---- defaults (overridable by env) ----
export HZ_PROFILE="${HZ_PROFILE:-local}"
export HZ_CLUSTER_NAME="${HZ_CLUSTER_NAME:-hz-local}"
export HZ_MEMBERLIST="${HZ_MEMBERLIST:-127.0.0.1}"
export HZ_SBP_MIN="${HZ_SBP_MIN:-2}"
export HZ_BACKUP_COUNT="${HZ_BACKUP_COUNT:-1}"
export HZ_PARTITION_COUNT="${HZ_PARTITION_COUNT:-271}"
export HZ_HEARTBEAT_SECONDS="${HZ_HEARTBEAT_SECONDS:-60}"
export HZ_REST_DATA="${HZ_REST_DATA:-false}"
export HZ_K8S_SERVICE_NAME="${HZ_K8S_SERVICE_NAME:-hazelcast-runtime}"
export HZ_K8S_NAMESPACE="${HZ_K8S_NAMESPACE:-default}"
TPL="${HZ_TPL:-/opt/hazelcast/config/hazelcast.yaml.tpl}"
# Render to a path the non-root `hazelcast` user can write (config dir is root-owned).
OUT="${HZ_OUT:-/tmp/hazelcast.yaml}"

# ---- build JOIN_BLOCK per profile ----
if [ "$HZ_PROFILE" = "k8s" ]; then
  export JOIN_BLOCK="      multicast:
        enabled: false
      kubernetes:
        enabled: true
        service-name: ${HZ_K8S_SERVICE_NAME}
        namespace: ${HZ_K8S_NAMESPACE}"
else
  MEMBERS=""
  IFS=',' read -ra ARR <<< "$HZ_MEMBERLIST"
  for m in "${ARR[@]}"; do
    m="$(echo "$m" | xargs)"   # trim
    # Hazelcast YAML member-list is a PLAIN sequence of address strings
    # (- "host"), NOT `- member: host` maps (that is the XML form).
    MEMBERS="${MEMBERS}          - \"${m}\"
"
  done
  export JOIN_BLOCK="      multicast:
        enabled: false
      tcp-ip:
        enabled: true
        member-list:
${MEMBERS}"
fi

# ---- DATA REST group gate (local testing only) ----
if [ "$HZ_REST_DATA" = "true" ]; then
  export DATA_GROUP="        DATA:
          enabled: true"
else
  export DATA_GROUP=""
fi

# ---- render ----
RENDERED="$(envsubst < "$TPL")
# partition-count: ${HZ_PARTITION_COUNT}"

if [ "${1:-}" = "--render-only" ]; then
  echo "$RENDERED"
  exit 0
fi

echo "$RENDERED" > "$OUT"
echo "[entrypoint] profile=$HZ_PROFILE cluster=$HZ_CLUSTER_NAME sbp-min=$HZ_SBP_MIN rest-data=$HZ_REST_DATA"
# NOTE: `hz` is a picocli app; `-c/--config` belongs to the `start` SUBCOMMAND and
# MUST come AFTER `start` (hz -c <f> start fails "Unknown options: '-c'").
exec hz start -c "$OUT"
