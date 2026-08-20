#!/usr/bin/env bash
set -euo pipefail
C=helm/hazelcast-runtime
R="$(helm template hz $C -f $C/values-k8s.yaml)"
chk(){ echo "$R" | grep -q "$1" || { echo "FAIL: missing $2"; exit 1; }; echo "ok: $2"; }
chk 'HZ_PROFILE' 'profile env'
chk 'value: "k8s"' 'k8s profile'
chk 'resources: \["pods", "services", "endpoints"\]' 'core RBAC resources'
chk 'endpointslices' 'endpointslices RBAC'
chk 'kubernetes.io/hostname' 'hostname anti-affinity'
chk 'topology.kubernetes.io/zone' 'zone spread'
chk 'terminationGracePeriodSeconds: 150' 'grace = P+G+buffer (30+90+30)'
chk 'maxUnavailable: 1' 'PDB'
chk 'cluster-safe' 'preStop cluster-safe gate'
chk 'kind: NetworkPolicy' 'networkpolicy'
# local profile: grace = 10+20+10 = 40, no netpol
RL="$(helm template hz $C -f $C/values-local.yaml)"
echo "$RL" | grep -q 'terminationGracePeriodSeconds: 40' || { echo "FAIL: local grace"; exit 1; }
echo "$RL" | grep -q 'kind: NetworkPolicy' && { echo "FAIL: local should have no netpol"; exit 1; }
echo "ALL HELM RENDER ASSERTIONS PASSED"
