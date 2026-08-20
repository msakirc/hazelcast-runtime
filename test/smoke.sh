#!/usr/bin/env bash
set -euo pipefail
BASE="${BASE:-http://localhost:5701}"
MAP=smoke; KEY=k1; VAL=hello-1m

pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; docker compose logs --tail=40 || true; exit 1; }
# poll cluster-size until it equals $1 (up to ~40s) — failure detection isn't instant
wait_size(){
  for _ in $(seq 1 20); do
    [ "$(curl -s $BASE/hazelcast/health/cluster-size 2>/dev/null)" = "$1" ] && return 0
    sleep 2
  done
  return 1
}

# 1. cluster formed
wait_size 3 || fail "cluster not size 3"
pass "cluster size 3"

# 2. put/get via REST DATA group
curl -s -X POST "$BASE/hazelcast/rest/maps/$MAP/$KEY" -d "$VAL" >/dev/null
GOT="$(curl -s "$BASE/hazelcast/rest/maps/$MAP/$KEY")"
[ "$GOT" = "$VAL" ] || fail "get mismatch: '$GOT'"
pass "put/get roundtrip"

# 3. backup survival: kill one member, value must persist (backup-count 1, min-size 2)
docker compose stop hz1 >/dev/null
wait_size 2 || fail "size not 2 after kill"
GOT2="$(curl -s "$BASE/hazelcast/rest/maps/$MAP/$KEY")"
[ "$GOT2" = "$VAL" ] || fail "value lost after member kill: '$GOT2'"
pass "backup survived single member loss"

# 4. quorum: drop below minimum-cluster-size (2) -> writes rejected with 5xx
#    (protect-on: WRITE throws SplitBrainProtectionException; legacy REST surfaces 5xx).
#    Assert a SPECIFIC rejection (>=500), not merely "not 200", so a swallowed
#    error can't pass for the wrong reason; then prove the key was NOT written.
docker compose stop hz3 >/dev/null
wait_size 1 || fail "size not 1 after second kill"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/hazelcast/rest/maps/$MAP/k2" -d "nope")
[ "$CODE" -ge 500 ] 2>/dev/null || fail "below-quorum write must be rejected 5xx (got $CODE)"
READBACK="$(curl -s "$BASE/hazelcast/rest/maps/$MAP/k2")"
[ -z "$READBACK" ] || fail "below-quorum write leaked a value: '$READBACK'"
pass "quorum blocked write below minimum-cluster-size (5xx + no value)"
# If CODE came back 200/204 here, the legacy REST bridge is bypassing the per-map
# split-brain-protection-ref. In that case switch THIS assertion to the CLC path
# (client protocol honors quorum): `clc -c local map set -n smoke k2 nope` must
# fail with SplitBrainProtectionException. Determine empirically on the pinned image.

# restore
docker compose start hz1 hz3 >/dev/null
echo "ALL SMOKE TESTS PASSED"
