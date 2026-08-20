# Hazelcast Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone OSS Hazelcast 5.x cluster runtime (one config-only image) deployable to local docker-compose, VMs, and Kubernetes, that a Spring monolith connects to as a client.

**Architecture:** A single Docker image `FROM hazelcast/hazelcast:<pinned>` with a shell `entrypoint.sh` that renders `hazelcast.yaml` from a template per `HZ_PROFILE` (local/vm/k8s) — choosing the discovery `join` block, expanding a comma-separated member list, and gating the DATA REST group. No Java/MapStore in the image; the monolith owns cache-aside. Ship docker-compose (local), a Helm chart (k8s, Kubernetes API discovery + RBAC + graceful-shutdown safety), and a monolith connection guide.

**Tech Stack:** Hazelcast OSS 5.5.x, Docker, docker-compose, Helm 3, POSIX shell + `envsubst` (gettext), bash smoke tests, curl. Optional: kind / Docker Desktop Kubernetes for chart apply test.

**Design reference:** `docs/superpowers/specs/2026-08-20-hazelcast-runtime-design.md` (review GREEN v3).

**Conventions:**
- Cluster name is required and env-namespaced (default `hz-local` for local).
- Split-brain `minimum-cluster-size` = majority: **2** for the 3-member local/default, **3** for a 5-member prod cluster. Set per environment.
- All commits use the repo's existing footer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File Structure

```
hazelcast-runtime/
  config/
    hazelcast.yaml.tpl          # envsubst template: rest, split-brain, maps, metrics, ${JOIN_BLOCK}
  docker/
    entrypoint.sh               # renders join block + member-list + DATA gate, execs `hz start`
    Dockerfile                  # FROM hazelcast/hazelcast:<pinned>; COPY tpl+entrypoint; JAVA_OPTS
  docker-compose.yml            # 3-member local cluster, HZ_PROFILE=local
  test/
    smoke.sh                    # cluster forms (size==3), put/get, backup survives kill, quorum blocks
  helm/hazelcast-runtime/
    Chart.yaml
    values.yaml                 # prod-safe defaults (5 members, min-size 3, budgets)
    values-local.yaml
    values-vm.yaml              # documents VM/tcp-ip (compose is the runnable local)
    values-k8s.yaml
    templates/
      _helpers.tpl
      configmap.yaml            # renders hazelcast.yaml (k8s join) from chart values
      statefulset.yaml
      service-headless.yaml
      service-perpod.yaml       # optional phase-2 external exposure (per-pod LB)
      serviceaccount.yaml
      rbac.yaml                 # Role+RoleBinding (+optional ClusterRole for nodes)
      pdb.yaml
      networkpolicy.yaml
      NOTES.txt
  docs/
    connection-guide.md         # monolith client config, 3 phases, resilience, stampede, failure modes
  Makefile                      # build/up/smoke/lint/template/clean
  README.md
  .dockerignore
  .gitignore                    # (already exists)
```

---

## Task 1: Repo scaffold, version pin, ignores, README

**Files:**
- Create: `.dockerignore`, `README.md`, `Makefile`
- Verify: Docker + Hazelcast tag availability

- [ ] **Step 1: Confirm Docker Desktop is running and resolve the pinned Hazelcast tag**

Run:
```bash
docker version --format '{{.Server.Version}}'
docker pull hazelcast/hazelcast:5.5.0 || docker pull hazelcast/hazelcast:5.5
docker run --rm hazelcast/hazelcast:5.5.0 hz -V 2>/dev/null | head -3
```
Expected: server version prints; image pulls; `hz -V` prints a 5.5.x version. **Only `5.5.0` (and moving tag `5.5`) are published as public OSS images — 5.5.1+ point patches 404.** Record the exact tag as `<PINNED>` (default `5.5.0`). To see all tags: `curl -s 'https://hub.docker.com/v2/repositories/hazelcast/hazelcast/tags?page_size=50' | grep -o '"name":"5\.[0-9.]*"'` and pick the newest published 5.x.

- [ ] **Step 2: Write `.dockerignore`**

```
docs/
helm/
test/
.git/
*.md
Makefile
```

- [ ] **Step 2b: Write `.gitattributes` (Windows host — force LF on scripts)**

Repo is authored on Windows/Git Bash. CRLF in `entrypoint.sh` breaks the Linux
container shebang (`bash\r: not found`). Force LF:
```
* text=auto eol=lf
*.sh text eol=lf
Dockerfile text eol=lf
*.yaml text eol=lf
*.yml text eol=lf
Makefile text eol=lf
```
(The Dockerfile also strips CRLF defensively — belt and suspenders.)

- [ ] **Step 3: Write `Makefile`**

```makefile
PINNED ?= 5.5.0
IMAGE  ?= hazelcast-runtime:local

.PHONY: build up down smoke lint template clean
build:
	docker build --build-arg HZ_VERSION=$(PINNED) -t $(IMAGE) -f docker/Dockerfile .
up:
	docker compose up -d
down:
	docker compose down -v
smoke:
	bash test/smoke.sh
lint:
	helm lint helm/hazelcast-runtime
template:
	helm template hz helm/hazelcast-runtime -f helm/hazelcast-runtime/values-k8s.yaml
clean: down
	docker rmi $(IMAGE) 2>/dev/null || true
```

- [ ] **Step 4: Write `README.md`**

```markdown
# hazelcast-runtime

Standalone OSS Hazelcast 5.x cluster. One config-only image, three profiles
(local / vm / k8s). The Spring monolith connects as a client (cache-aside).

## Quick start (local)
    make build && make up && make smoke

## Deploy (k8s)
    helm install hz helm/hazelcast-runtime -f helm/hazelcast-runtime/values-k8s.yaml

See `docs/connection-guide.md` for wiring the monolith and
`docs/superpowers/specs/2026-08-20-hazelcast-runtime-design.md` for the design.
```

- [ ] **Step 5: Commit**

```bash
git add .dockerignore .gitattributes README.md Makefile
git commit -m "chore: scaffold hazelcast-runtime repo + pinned version"
```

---

## Task 2: Config template + entrypoint (the heart of the runtime)

**Files:**
- Create: `config/hazelcast.yaml.tpl`, `docker/entrypoint.sh`
- Test: render locally with `envsubst` + `docker run --rm ... hz-yaml-validate` equivalent (yaml parse)

- [ ] **Step 1: Write the failing render test**

Create `test/render_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# point the renderer at the repo template (default HZ_TPL is the in-container path)
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
```
Make executable: `chmod +x test/render_test.sh`.

- [ ] **Step 2: Run it to verify failure**

Run: `bash test/render_test.sh`
Expected: FAIL (entrypoint.sh does not exist yet).

- [ ] **Step 3: Write `config/hazelcast.yaml.tpl`**

```yaml
hazelcast:
  cluster-name: ${HZ_CLUSTER_NAME}
  properties:
    hazelcast.diagnostics.enabled: "true"
    hazelcast.backpressure.enabled: "true"
    hazelcast.max.no.heartbeat.seconds: "${HZ_HEARTBEAT_SECONDS}"
  network:
    port:
      port: 5701
      auto-increment: false
    rest-api:
      enabled: true
      endpoint-groups:
        HEALTH_CHECK:
          enabled: true
        CLUSTER_READ:
          enabled: true
${DATA_GROUP}
    join:
${JOIN_BLOCK}
  split-brain-protection:
    sbp-write:
      enabled: true
      minimum-cluster-size: ${HZ_SBP_MIN}
      protect-on: WRITE
  map:
    default:
      backup-count: ${HZ_BACKUP_COUNT}
      split-brain-protection-ref: sbp-write
      merge-policy:
        batch-size: 100
        class-name: com.hazelcast.spi.merge.PutIfAbsentMergePolicy
      eviction:
        eviction-policy: LRU
        max-size-policy: FREE_HEAP_PERCENTAGE
        size: 20
  partition-group:
    enabled: false
  metrics:
    enabled: true
    jmx:
      enabled: true
```
Note: `partition-count` is a member property set via JAVA_OPTS (`-Dhazelcast.partition.count`) in the Dockerfile, so it is identical everywhere and cannot drift; the render test greps the rendered `properties` echo added by the entrypoint (Step 4 writes it into the template output as a comment line `# partition-count: ${HZ_PARTITION_COUNT}`).

- [ ] **Step 4: Write `docker/entrypoint.sh`**

```bash
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
```
Make executable: `chmod +x docker/entrypoint.sh`.

- [ ] **Step 5: Run render test to verify pass**

Run: `bash test/render_test.sh`
Expected: `PASS render_test`. (If `envsubst` missing on the host, run inside the image in Task 3; the authoritative render test also runs there.)

- [ ] **Step 6: Commit**

```bash
git add config/hazelcast.yaml.tpl docker/entrypoint.sh test/render_test.sh
git commit -m "feat: env-driven hazelcast config template + entrypoint renderer"
```

---

## Task 3: Dockerfile + single-member boot test

**Files:**
- Create: `docker/Dockerfile`
- Test: build image, run one member (profile=local, self as member), assert `/hazelcast/health/ready` == 200

- [ ] **Step 1: Write `docker/Dockerfile`**

```dockerfile
ARG HZ_VERSION=5.5.0
FROM hazelcast/hazelcast:${HZ_VERSION}

USER root
# envsubst (gettext) for config rendering. Base image is Alpine (apk).
# HARD-FAIL if it can't be installed — a missing envsubst = silent-broken image
# (every container would die at `envsubst < tpl` under set -e). No `|| true`.
RUN apk add --no-cache gettext && command -v envsubst

COPY config/hazelcast.yaml.tpl /opt/hazelcast/config/hazelcast.yaml.tpl
COPY docker/entrypoint.sh /opt/hazelcast/entrypoint.sh
# Strip any CRLF (repo authored on Windows) so the container shebang/exec work,
# then make executable.
RUN sed -i 's/\r$//' /opt/hazelcast/entrypoint.sh && chmod +x /opt/hazelcast/entrypoint.sh
USER hazelcast

ENV JAVA_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:MaxRAMPercentage=70 \
-Dhazelcast.partition.count=271 \
-Dhazelcast.shutdownhook.policy=GRACEFUL \
-Dhazelcast.graceful.shutdown.max.wait=90 \
-Dhazelcast.diagnostics.enabled=true \
-Dhazelcast.diagnostics.directory=/tmp"
# diagnostics.directory MUST be a path the non-root `hazelcast` user can write;
# default /opt/hazelcast is root-owned -> FileNotFoundException spam on every member.

ENTRYPOINT ["/opt/hazelcast/entrypoint.sh"]
```
Note: base image `hazelcast/hazelcast:5.5.0` is Alpine and does **not** ship `envsubst`; the `RUN apk add gettext && command -v envsubst` line installs it and hard-fails the build if it can't (no silent-broken image). The custom `ENTRYPOINT` correctly overrides the base image's. The image already defines `JAVA_OPTS_DEFAULT` (includes `-XX:MaxRAMPercentage=80.0`); our `JAVA_OPTS` is appended after it, and later JVM args win, so `70` takes effect — **verify** in Step 4 with `docker exec hz1 sh -c 'cat /proc/1/cmdline | tr "\0" " "' | grep -o 'MaxRAMPercentage=[0-9.]*'` (expect the last one = 70).

- [ ] **Step 2: Build**

Run: `docker build --build-arg HZ_VERSION=5.5.0 -t hazelcast-runtime:local -f docker/Dockerfile .`
Expected: build succeeds.

- [ ] **Step 3: Verify render works inside the image**

Run:
```bash
docker run --rm -e HZ_PROFILE=local -e HZ_MEMBERLIST=127.0.0.1 -e HZ_REST_DATA=true \
  hazelcast-runtime:local /opt/hazelcast/entrypoint.sh --render-only | head -40
```
Expected: valid rendered YAML with `rest-api`, `HEALTH_CHECK`, `DATA`, `tcp-ip`, and a plain-string member entry `- "127.0.0.1"`.

- [ ] **Step 4: Boot a single member and check health**

Run:
```bash
docker run -d --name hz1 -p 5701:5701 \
  -e HZ_PROFILE=local -e HZ_CLUSTER_NAME=hz-local -e HZ_MEMBERLIST=127.0.0.1 \
  -e HZ_SBP_MIN=1 -e HZ_REST_DATA=true hazelcast-runtime:local
# cold start on Windows Docker Desktop (image pull + JVM) can be slow; poll, don't fixed-sleep
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5701/hazelcast/health/ready)" = "200" ] && break
  sleep 2
done
curl -s -o /dev/null -w 'ready=%{http_code}\n' http://localhost:5701/hazelcast/health/ready
```
Expected: `ready=200` (single member, `HZ_SBP_MIN=1` so it is ready). Then:
```bash
curl -s http://localhost:5701/hazelcast/health/node-state; echo
docker rm -f hz1
```
Expected: `"ACTIVE"` (note: `node-state` returns a **quoted** JSON string; any exact-match assertion must include the quotes. `cluster-size` by contrast returns a bare integer). If `/health/ready` 404s, REST enable failed — inspect `docker logs hz1` and the rendered `/opt/hazelcast/config/hazelcast.yaml`.

- [ ] **Step 5: Commit**

```bash
git add docker/Dockerfile
git commit -m "feat: config-only Dockerfile with GC/graceful/partition JAVA_OPTS"
```

---

## Task 4: docker-compose 3-member cluster + cluster-formation test

**Files:**
- Create: `docker-compose.yml`
- Test: `docker compose up`; assert cluster-size == 3

- [ ] **Step 1: Write `docker-compose.yml`**

```yaml
services:
  hz1: &hz
    image: hazelcast-runtime:local
    build:
      context: .
      dockerfile: docker/Dockerfile
    environment:
      HZ_PROFILE: local
      HZ_CLUSTER_NAME: hz-local
      HZ_MEMBERLIST: "hz1,hz2,hz3"
      HZ_SBP_MIN: "2"
      HZ_BACKUP_COUNT: "1"
      HZ_REST_DATA: "true"
    networks: [hznet]
  hz2:
    <<: *hz
    ports: ["5701:5701"]
  hz3:
    <<: *hz
networks:
  hznet: {}
```
Note: only `hz2` publishes 5701 to the host (single stable client entry for smoke tests); members talk over `hznet` by service name.

- [ ] **Step 2: Bring up and wait for formation**

Run:
```bash
docker compose up -d --build
for i in $(seq 1 30); do
  SIZE=$(curl -s http://localhost:5701/hazelcast/health/cluster-size 2>/dev/null || echo 0)
  [ "$SIZE" = "3" ] && break; sleep 2
done
echo "cluster-size=$SIZE"
```
Expected: `cluster-size=3` within ~60s. If it stalls at 1, discovery failed — check `docker compose logs hz2 | grep -i members`.

- [ ] **Step 3: Verify ready + safe**

Run:
```bash
curl -s -o /dev/null -w 'ready=%{http_code}\n' http://localhost:5701/hazelcast/health/ready
curl -s -o /dev/null -w 'safe=%{http_code}\n'  http://localhost:5701/hazelcast/health/cluster-safe
```
Expected: `ready=200`, `safe=200`.

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: 3-member local docker-compose cluster"
```

---

## Task 5: Smoke test — put/get, backup survival, quorum

**Files:**
- Create: `test/smoke.sh`
- Test: run it against the running compose cluster

- [ ] **Step 1: Write `test/smoke.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
BASE="${BASE:-http://localhost:5701}"
MAP=smoke; KEY=k1; VAL=hello-1m

pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; docker compose logs --tail=40 || true; exit 1; }
# poll cluster-size until it equals $1 (up to ~40s) — failure detection isn't instant;
# a fixed `sleep` races the cluster's member-removal + repartition.
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
```
Make executable: `chmod +x test/smoke.sh`.

- [ ] **Step 2: Run it (fails if REST DATA endpoint differs on pinned version)**

Run: `bash test/smoke.sh`
Expected: `ALL SMOKE TESTS PASSED`. (The legacy `/hazelcast/rest/maps/...` endpoint IS present in 5.5.0 under the `DATA` group — happy path works. Note it is deprecated-for-removal in 7.0.)
Fallback (only if the pinned image lacks the DATA/`/maps` endpoint): use the Hazelcast CLC. There is **no `hazelcast/clc` image**; install the binary (`brew install hazelcast/hz/clc` or the install script) and run against the published member:
```bash
clc config add local cluster.name=hz-local cluster.address=localhost:5701
clc -c local map set -n smoke k1 hello-1m
clc -c local map get -n smoke k1        # -> hello-1m
```
Flag is `-n/--name` (not `-m`); `-c` takes a named profile, not inline JSON. Keep the kill/quorum logic identical. Verify which path works on the pinned image and keep it.

- [ ] **Step 3: Wire into Makefile (already has `smoke` target) and commit**

```bash
git add test/smoke.sh
git commit -m "test: smoke — formation, put/get, backup survival, quorum"
```

---

## Task 6: Helm chart — templates + RBAC + graceful-shutdown safety

**Files:**
- Create: `helm/hazelcast-runtime/Chart.yaml`, `values.yaml`, `templates/_helpers.tpl`, `templates/configmap.yaml`, `templates/statefulset.yaml`, `templates/service-headless.yaml`, `templates/serviceaccount.yaml`, `templates/rbac.yaml`, `templates/pdb.yaml`, `templates/networkpolicy.yaml`, `templates/NOTES.txt`
- Test: `helm lint` + `helm template` assertions

- [ ] **Step 1: Write `Chart.yaml`**

```yaml
apiVersion: v2
name: hazelcast-runtime
description: Standalone OSS Hazelcast 5.x cluster (Kubernetes API discovery)
type: application
version: 0.1.0
appVersion: "5.5.0"
```

- [ ] **Step 2: Write `values.yaml` (prod-safe defaults)**

```yaml
image:
  repository: hazelcast-runtime
  tag: local
  pullPolicy: IfNotPresent

clusterName: prod-hz
replicaCount: 5

hazelcast:
  backupCount: 1
  sbpMinClusterSize: 3        # majority of 5
  partitionCount: 271
  heartbeatSeconds: 60

resources:
  requests: { cpu: "1", memory: "6Gi" }
  limits:   { cpu: "2", memory: "6Gi" }   # heap = 70% via MaxRAMPercentage

# graceful shutdown budget: grace >= preStop(P) + graceful.max.wait(G) + buffer
shutdown:
  preStopMaxSeconds: 30       # P
  gracefulMaxWaitSeconds: 90  # G
  bufferSeconds: 30
# terminationGracePeriodSeconds computed in _helpers as P+G+buffer

rbac:
  create: true
  clusterRoleForNodes: false  # true only if zone-aware / NodePort public discovery

externalClient:
  enabled: false              # phase-2: per-pod LoadBalancer + public-address
  serviceType: LoadBalancer
  annotations: {}             # REQUIRED per cloud to force INTERNAL LB (see values.yaml)

networkPolicy:
  enabled: true
  clientNamespaces: []        # namespaces allowed to reach 5701
  clientCidrs: []

topologySpreadZones: true     # soft zone spread
```

- [ ] **Step 3: Write `templates/_helpers.tpl`**

```yaml
{{- define "hzr.name" -}}{{ .Release.Name }}{{- end -}}
{{- define "hzr.headless" -}}{{ .Release.Name }}-hl{{- end -}}
{{- define "hzr.sa" -}}{{ .Release.Name }}-sa{{- end -}}
{{- define "hzr.grace" -}}
{{- add (add .Values.shutdown.preStopMaxSeconds .Values.shutdown.gracefulMaxWaitSeconds) .Values.shutdown.bufferSeconds -}}
{{- end -}}
{{- define "hzr.labels" -}}
app.kubernetes.io/name: hazelcast-runtime
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
```

- [ ] **Step 4: Write `templates/serviceaccount.yaml`**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "hzr.sa" . }}
  labels: {{- include "hzr.labels" . | nindent 4 }}
```

- [ ] **Step 5: Write `templates/rbac.yaml`**

```yaml
{{- if .Values.rbac.create }}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ .Release.Name }}-role
  labels: {{- include "hzr.labels" . | nindent 4 }}
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints"]
    verbs: ["get", "list"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ .Release.Name }}-rb
  labels: {{- include "hzr.labels" . | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ .Release.Name }}-role
subjects:
  - kind: ServiceAccount
    name: {{ include "hzr.sa" . }}
    namespace: {{ .Release.Namespace }}
{{- if .Values.rbac.clusterRoleForNodes }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ .Release.Name }}-nodes
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ .Release.Name }}-nodes-crb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ .Release.Name }}-nodes
subjects:
  - kind: ServiceAccount
    name: {{ include "hzr.sa" . }}
    namespace: {{ .Release.Namespace }}
{{- end }}
{{- end }}
```

- [ ] **Step 6: Write `templates/service-headless.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "hzr.headless" . }}
  labels: {{- include "hzr.labels" . | nindent 4 }}
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app.kubernetes.io/instance: {{ .Release.Name }}
  ports:
    - name: hazelcast
      port: 5701
      targetPort: 5701
```

- [ ] **Step 7: Write `templates/statefulset.yaml`**

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ .Release.Name }}
  labels: {{- include "hzr.labels" . | nindent 4 }}
spec:
  serviceName: {{ include "hzr.headless" . }}
  replicas: {{ .Values.replicaCount }}
  podManagementPolicy: Parallel
  updateStrategy:
    type: RollingUpdate
  selector:
    matchLabels:
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels: {{- include "hzr.labels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "hzr.sa" . }}
      terminationGracePeriodSeconds: {{ include "hzr.grace" . }}
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app.kubernetes.io/instance: {{ .Release.Name }}
              topologyKey: kubernetes.io/hostname
      {{- if .Values.topologySpreadZones }}
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/instance: {{ .Release.Name }}
      {{- end }}
      containers:
        - name: hazelcast
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - { name: hazelcast, containerPort: 5701 }
          env:
            - { name: HZ_PROFILE, value: "k8s" }
            - { name: HZ_CLUSTER_NAME, value: "{{ required "clusterName required" .Values.clusterName }}" }
            - { name: HZ_K8S_SERVICE_NAME, value: "{{ include "hzr.headless" . }}" }
            - { name: HZ_K8S_NAMESPACE, valueFrom: { fieldRef: { fieldPath: metadata.namespace } } }
            - { name: HZ_SBP_MIN, value: "{{ .Values.hazelcast.sbpMinClusterSize }}" }
            - { name: HZ_BACKUP_COUNT, value: "{{ .Values.hazelcast.backupCount }}" }
            - { name: HZ_PARTITION_COUNT, value: "{{ .Values.hazelcast.partitionCount }}" }
            - { name: HZ_HEARTBEAT_SECONDS, value: "{{ .Values.hazelcast.heartbeatSeconds }}" }
            # This pod-env JAVA_OPTS OVERRIDES the Dockerfile ENV entirely — it must
            # carry EVERY flag, incl. diagnostics.directory=/tmp (default
            # /opt/hazelcast is root-owned -> FileNotFoundException spam per pod).
            - name: JAVA_OPTS
              value: >-
                -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:MaxRAMPercentage=70
                -Dhazelcast.partition.count={{ .Values.hazelcast.partitionCount }}
                -Dhazelcast.shutdownhook.policy=GRACEFUL
                -Dhazelcast.graceful.shutdown.max.wait={{ .Values.shutdown.gracefulMaxWaitSeconds }}
                -Dhazelcast.max.no.heartbeat.seconds={{ .Values.hazelcast.heartbeatSeconds }}
                -Dhazelcast.diagnostics.enabled=true
                -Dhazelcast.diagnostics.directory=/tmp
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - >-
                    end=$(( $(date +%s) + {{ .Values.shutdown.preStopMaxSeconds }} ));
                    while [ $(date +%s) -lt $end ]; do
                    code=$(wget -q -O /dev/null -S http://127.0.0.1:5701/hazelcast/health/cluster-safe 2>&1 | awk '/HTTP\//{print $2}' | tail -1);
                    [ "$code" = "200" ] && exit 0; sleep 3; done; exit 0
          # startupProbe holds liveness off until join + first migration settle,
          # so a slow cold-formation can't trip liveness (5min budget).
          startupProbe:
            httpGet: { path: /hazelcast/health/ready, port: 5701 }
            periodSeconds: 10
            failureThreshold: 30
          readinessProbe:
            httpGet: { path: /hazelcast/health/ready, port: 5701 }
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet: { path: /hazelcast/health/node-state, port: 5701 }
            initialDelaySeconds: 40
            periodSeconds: 15
            timeoutSeconds: 10
            failureThreshold: 6
          resources: {{- toYaml .Values.resources | nindent 12 }}
```
Note: `podManagementPolicy: Parallel` speeds initial formation (all members start, discover via k8s API); `RollingUpdate` still replaces pods one-by-one on upgrade, and the preStop cluster-safe gate + PDB serialize safe termination.

- [ ] **Step 8: Write `templates/pdb.yaml`**

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .Release.Name }}-pdb
  labels: {{- include "hzr.labels" . | nindent 4 }}
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/instance: {{ .Release.Name }}
```

- [ ] **Step 9: Write `templates/networkpolicy.yaml`**

```yaml
{{- if .Values.networkPolicy.enabled }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ .Release.Name }}-netpol
  labels: {{- include "hzr.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/instance: {{ .Release.Name }}
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/instance: {{ .Release.Name }}   # member-to-member
      {{- range .Values.networkPolicy.clientNamespaces }}
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ . }}
      {{- end }}
      {{- range .Values.networkPolicy.clientCidrs }}
        - ipBlock:
            cidr: {{ . }}
      {{- end }}
      ports:
        - { protocol: TCP, port: 5701 }
{{- end }}
```

- [ ] **Step 10: Write `templates/NOTES.txt`**

```
{{ .Release.Name }} Hazelcast cluster ({{ .Values.replicaCount }} members, cluster-name={{ .Values.clusterName }}).

In-cluster client discovery (phase 3):
  cluster-name: {{ .Values.clusterName }}
  kubernetes: { service-name: {{ include "hzr.headless" . }}, namespace: {{ .Release.Namespace }} }

Cross-network client (phase 2): set externalClient.enabled=true and see docs/connection-guide.md.
terminationGracePeriodSeconds = {{ include "hzr.grace" . }}s (P+G+buffer).
```

- [ ] **Step 11: Write `templates/configmap.yaml`** (kept minimal — config is entrypoint-rendered; this documents effective values for operators)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-effective
  labels: {{- include "hzr.labels" . | nindent 4 }}
data:
  profile: "k8s"
  clusterName: {{ .Values.clusterName | quote }}
  sbpMinClusterSize: {{ .Values.hazelcast.sbpMinClusterSize | quote }}
  partitionCount: {{ .Values.hazelcast.partitionCount | quote }}
  terminationGracePeriodSeconds: {{ include "hzr.grace" . | quote }}
```

- [ ] **Step 12: Run `helm lint`**

Preflight: `command -v helm || echo "INSTALL helm 3 first (choco install kubernetes-helm)"`.
If helm is absent, install it before Tasks 6–7 (their assertions require `helm template`).
Run: `helm lint helm/hazelcast-runtime`
Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 13: Commit**

```bash
git add helm/hazelcast-runtime
git commit -m "feat: helm chart — statefulset, k8s-API RBAC, PDB, netpol, graceful-shutdown budget"
```

---

## Task 7: Per-env values + render assertions

**Files:**
- Create: `helm/hazelcast-runtime/values-local.yaml`, `values-vm.yaml`, `values-k8s.yaml`, `templates/service-perpod.yaml`, `test/helm_test.sh`

- [ ] **Step 1: Write `values-k8s.yaml`** (phase 3 in-cluster; phase 2 toggle documented)

```yaml
image: { repository: hazelcast-runtime, tag: "5.5.0" }
clusterName: prod-hz
replicaCount: 5
hazelcast: { backupCount: 1, sbpMinClusterSize: 3, partitionCount: 271, heartbeatSeconds: 60 }
networkPolicy:
  enabled: true
  clientNamespaces: ["monolith"]     # phase 3: monolith namespace
externalClient: { enabled: false }
```

- [ ] **Step 2: Write `values-local.yaml`** (kind/Docker-Desktop k8s, tiny)

```yaml
image: { repository: hazelcast-runtime, tag: local, pullPolicy: Never }
clusterName: hz-local
replicaCount: 3
hazelcast: { backupCount: 1, sbpMinClusterSize: 2, partitionCount: 271, heartbeatSeconds: 60 }
resources:
  requests: { cpu: "250m", memory: "1Gi" }
  limits:   { cpu: "500m", memory: "1Gi" }
shutdown: { preStopMaxSeconds: 10, gracefulMaxWaitSeconds: 20, bufferSeconds: 10 }
networkPolicy: { enabled: false }
topologySpreadZones: false
```

- [ ] **Step 3: Write `values-vm.yaml`** (documents the VM/tcp-ip path; VMs run the image directly, not Helm)

```yaml
# VMs run the image directly (systemd/docker), NOT Helm. Example unit env:
#   HZ_PROFILE=vm
#   HZ_CLUSTER_NAME=prod-hz
#   HZ_MEMBERLIST=10.0.0.11,10.0.0.12,10.0.0.13,10.0.0.14,10.0.0.15
#   HZ_SBP_MIN=3
#   HZ_BACKUP_COUNT=1
# This file exists so the three profiles are discoverable in one place.
clusterName: prod-hz
replicaCount: 5
hazelcast: { sbpMinClusterSize: 3 }
```

- [ ] **Step 4: Write `templates/service-perpod.yaml`** (phase-2 external smart-client exposure)

```yaml
{{- if .Values.externalClient.enabled }}
{{- range $i := until (int .Values.replicaCount) }}
apiVersion: v1
kind: Service
metadata:
  name: {{ $.Release.Name }}-ext-{{ $i }}
  labels: {{- include "hzr.labels" $ | nindent 4 }}
  {{- with $.Values.externalClient.annotations }}
  # cloud-specific INTERNAL-LB annotations — MUST be set per provider or the LB
  # provisions PUBLIC, exposing the unauthenticated OSS grid. Default empty.
  annotations: {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  type: {{ $.Values.externalClient.serviceType }}
  selector:
    statefulset.kubernetes.io/pod-name: {{ $.Release.Name }}-{{ $i }}
  ports:
    - { name: hazelcast, port: 5701, targetPort: 5701 }
---
{{- end }}
{{- end }}
```
Note: phase-2 smart routing additionally requires each pod to advertise its external address via `HZ_NETWORK_PUBLICADDRESS` / entrypoint `public-address` — documented in the connection guide; default phase-2 path is unisocket (no per-pod services). This template is the opt-in for long-lived phase-2.

- [ ] **Step 5: Write `test/helm_test.sh` (render assertions)**

```bash
#!/usr/bin/env bash
set -euo pipefail
C=helm/hazelcast-runtime
R="$(helm template hz $C -f $C/values-k8s.yaml)"
chk(){ echo "$R" | grep -q "$1" || { echo "FAIL: missing $2"; exit 1; }; echo "ok: $2"; }
chk 'HZ_PROFILE' 'profile env'
chk 'value: "k8s"' 'k8s profile'
chk 'resources: ["pods", "services", "endpoints"]' 'core RBAC resources'
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
```
Make executable and run: `chmod +x test/helm_test.sh && bash test/helm_test.sh`
Expected: `ALL HELM RENDER ASSERTIONS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add helm/hazelcast-runtime/values-*.yaml helm/hazelcast-runtime/templates/service-perpod.yaml test/helm_test.sh
git commit -m "feat: per-env helm values + phase-2 per-pod service + render assertions"
```

---

## Task 8: Monolith connection guide

**Files:**
- Create: `docs/connection-guide.md`

- [ ] **Step 1: Write `docs/connection-guide.md`**

````markdown
# Monolith Connection Guide

The monolith drops its embedded Hazelcast member and connects as a **client**.
The grid holds rebuildable data; the monolith owns **cache-aside** (read DB on miss).

## 0. Remove embedded auto-config
- Remove the `hazelcast` member config bean / `HazelcastInstance` member bootstrap.
- Exclude Spring Boot's embedded auto-config if present:
  `spring.autoconfigure.exclude=org.springframework.boot.autoconfigure.hazelcast.HazelcastAutoConfiguration`
- Add the Hazelcast **client** dependency, version matching the server (`5.5.x`).

## 1. Client config (Spring `hazelcast-client.yaml`)
```yaml
hazelcast-client:
  cluster-name: prod-hz            # MUST match the cluster exactly (see failure modes)
  properties:
    hazelcast.client.max.concurrent.invocations: "1000"   # client backpressure
  connection-strategy:
    async-start: true              # don't block app boot if cluster briefly down
    reconnect-mode: ASYNC
    connection-retry:
      cluster-connect-timeout-millis: 30000
      initial-backoff-millis: 500
      max-backoff-millis: 5000
  network:
    smart-routing: true
    # PHASE 1 (VM->VM) and PHASE 3 (k8s in-cluster) below; pick one block.
```

### Phase 1 — monolith(VM) → HZ(VM): static list, smart routing
```yaml
    cluster-members:
      - 10.0.0.11:5701
      - 10.0.0.12:5701
      - 10.0.0.13:5701
```

### Phase 2 — monolith(VM) → HZ(k8s), cross-network
Default: **unisocket** (simplest; time-box this phase).
```yaml
  network:
    smart-routing: false           # unisocket: one LB entry, one hop
    cluster-members: [ "hz-lb.internal:5701" ]   # single internal LoadBalancer
```
Long-lived phase-2 with smart routing → enable `externalClient` in the chart AND
have each pod advertise its external LB address (`HZ_NETWORK_PUBLICADDRESS` per pod),
then on the client:
```yaml
  network:
    smart-routing: true
    use-public-ip: true
    cluster-members: [ "hz-ext-0.internal:5701", "hz-ext-1.internal:5701" ]  # per-pod LBs
```
⚠️ Cross-network HZ traffic is unencrypted/unauthenticated (OSS). Keep it on a
private path (VPC peering / VPN); never the public internet.

### Phase 3 — monolith(k8s) → HZ(k8s): Kubernetes discovery, smart routing
```yaml
  network:
    smart-routing: true
    kubernetes:
      enabled: true
      service-name: <release>-hl
      namespace: <hz-namespace>
```

## 2. partition-count MUST match
Server runs `-Dhazelcast.partition.count=271`. Set the same on the client
(`hazelcast.partition.count=271`) or leave both default. Mismatch = undefined routing.

## 3. Near-cache (opt-in, per map)
```yaml
  near-cache:
    session-cache:
      time-to-live-seconds: 60
      max-idle-seconds: 30
      invalidate-on-change: true    # eventual; do NOT near-cache strong-consistency data
```

## 4. Cache-aside + cold-start stampede (monolith responsibility)
No OSS persistence: a full cluster restart empties the grid. On mass miss:
- **Single-flight per key**: one DB load per key, others wait (e.g. guava `LoadingCache`
  wrapper or a per-key lock) so 1M misses ≠ 1M DB reads.
- **Rate-limited warm-up** of hot keys after cluster restart.
- **Circuit breaker** + short negative caching around the DB.
Write path: update DB, then update/evict the grid entry.

## 5. Cluster-name mismatch — failure signatures
- **Client** wrong name → connection fails fast with an auth/`IllegalStateException`
  ("Unable to connect"). Safe: it just can't join.
- **Member** wrong name → silently forms its OWN cluster (split fleet). During
  VM↔k8s migration this is the dangerous one: verify `cluster-name` is identical
  (`prod-hz`) on every member and the client. Fail-fast if the env var is unset.
````

- [ ] **Step 2: Commit**

```bash
git add docs/connection-guide.md
git commit -m "docs: monolith connection guide — 3 phases, resilience, stampede, failure modes"
```

---

## Task 9: Optional — deploy chart to local Kubernetes (if available)

**Files:** none (validation only)

- [ ] **Step 1: Detect a local cluster**

Run: `kubectl config current-context 2>/dev/null && kubectl get nodes 2>/dev/null | head`
Expected: a context (Docker Desktop `docker-desktop` or `kind-*`). If none, **skip Task 9** (compose + helm render already cover the runtime; note the skip).

- [ ] **Step 2: Load image + install (local values, 3 members)**

Run:
```bash
# Docker Desktop shares the daemon; kind needs: kind load docker-image hazelcast-runtime:local
helm install hz helm/hazelcast-runtime -f helm/hazelcast-runtime/values-local.yaml
kubectl rollout status statefulset/hz --timeout=180s
```
Expected: rollout completes, 3/3 ready.

- [ ] **Step 3: Verify k8s-API discovery formed the cluster**

Run:
```bash
kubectl exec hz-0 -- wget -qO- http://127.0.0.1:5701/hazelcast/health/cluster-size
```
Expected: `3` (proves Kubernetes API discovery + RBAC work).

- [ ] **Step 4: Tear down**

Run: `helm uninstall hz`
Expected: released. Record result (pass/skip) in the final report.

---

## Task 10: Final wiring — README polish, Makefile check, whole-suite run

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Full clean run**

Run:
```bash
make clean; make build && make up
sleep 5; bash test/render_test.sh && bash test/smoke.sh && bash test/helm_test.sh && helm lint helm/hazelcast-runtime
make down
```
Expected: all PASS, `helm lint` 0 failed.

- [ ] **Step 2: Add a "Testing" + "Profiles" section to README**

Append to `README.md`:
```markdown
## Profiles
| Profile | Discovery | Where |
|---|---|---|
| local | tcp-ip (compose service names) | your PC (docker-compose) |
| vm    | tcp-ip (HZ_MEMBERLIST) | current prod VMs |
| k8s   | Kubernetes API | target k8s |

## Testing
    bash test/render_test.sh   # config rendering per profile
    make up && make smoke      # compose: formation, put/get, backup, quorum
    bash test/helm_test.sh     # helm render assertions
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README profiles + testing; final wiring"
```

---

## Self-Review (completed by author)

- **Spec coverage:** topology/client-server (Tasks 2–8), config-only image (Task 3),
  three profiles + env-driven join (Task 2), REST health enable (Task 2/3),
  split-brain keys + quorum (Task 2, smoke Task 5), backup survival (Task 5),
  graceful shutdown additive budget P+G+buffer (Task 6 helm + Task 7 assert 150/40),
  k8s API discovery + RBAC incl. endpointslices (Task 6/9), hostname anti-affinity +
  zone topologySpread (Task 6/7), PDB + NetworkPolicy (Task 6/7), phase-2 unisocket
  default + per-pod smart option (Task 7/8), cache-aside + stampede (Task 8),
  cluster-name failure modes (Task 8), observability metrics/jmx (Task 2), eviction +
  backpressure (Task 2 member, Task 8 client), sizing defaults (values.yaml Task 6).
  Enterprise/persistence correctly out of scope.
- **Placeholder scan:** none — every step has concrete file content or exact commands.
- **Type/name consistency:** env var names (`HZ_PROFILE`, `HZ_MEMBERLIST`, `HZ_SBP_MIN`,
  `HZ_K8S_SERVICE_NAME`) identical across template, entrypoint, compose, statefulset;
  helper `hzr.headless`/`hzr.grace` used consistently; grace math 30+90+30=150 and
  10+20+10=40 match the assertions.
- **Known runtime-verify points (flagged in-task):** exact pinned tag (Task 1),
  `envsubst` presence in base image (Task 3), legacy REST `/maps` vs CLC fallback
  (Task 5), `/health/ready` post-migration semantics (design open item).
```
