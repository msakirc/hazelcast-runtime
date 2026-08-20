#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# point the renderer at the repo template (default is the in-container path)
export HZ_TPL="config/hazelcast.yaml.tpl"
export HZ_PROFILE=local HZ_CLUSTER_NAME=hz-local HZ_MEMBERLIST="a,b,c" \
       HZ_SBP_MIN=2 HZ_BACKUP_COUNT=1 HZ_PARTITION_COUNT=271 HZ_REST_DATA=true
OUT="$(bash docker/entrypoint.sh --render-only)"
echo "$OUT" | grep -q 'rest-api:' || { echo "FAIL: no rest-api"; exit 1; }
echo "$OUT" | grep -q 'HEALTH_CHECK' || { echo "FAIL: no HEALTH_CHECK"; exit 1; }
echo "$OUT" | grep -q 'DATA:' || { echo "FAIL: DATA gate missing when enabled"; exit 1; }
echo "$OUT" | grep -q 'split-brain-protection' || { echo "FAIL: no SBP"; exit 1; }
echo "$OUT" | grep -q 'minimum-cluster-size: 2' || { echo "FAIL: SBP min wrong"; exit 1; }
echo "$OUT" | grep -qE '^\s*- "a"$' || { echo "FAIL: memberlist not expanded as plain strings"; exit 1; }
echo "$OUT" | grep -q 'partition-count: 271' || { echo "FAIL: partition-count"; exit 1; }
# k8s profile picks kubernetes join, no DATA
export HZ_PROFILE=k8s HZ_REST_DATA=false HZ_K8S_SERVICE_NAME=hz-hl HZ_K8S_NAMESPACE=default
OUT2="$(bash docker/entrypoint.sh --render-only)"
echo "$OUT2" | grep -q 'kubernetes:' || { echo "FAIL: no kubernetes join"; exit 1; }
echo "$OUT2" | grep -q 'service-name: hz-hl' || { echo "FAIL: k8s service-name"; exit 1; }
echo "$OUT2" | grep -q 'DATA:' && { echo "FAIL: DATA must be off in k8s"; exit 1; }
echo "PASS render_test"
