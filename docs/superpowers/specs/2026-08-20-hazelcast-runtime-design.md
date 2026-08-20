# Hazelcast Runtime — Design

**Date:** 2026-08-20
**Status:** Approved (design) + adversarial review folded in (v2), pending implementation plan
**Owner:** Sakir

## Problem

A Spring Boot monolith currently auto-configures an **embedded** Hazelcast member
(one member per app instance). At ~1M active users, with a move from VMs to
Kubernetes coming, embedded topology couples data-grid scaling and lifecycle to
the app: every app restart/deploy churns the grid, and app and cache cannot scale
independently.

Extract Hazelcast into its own **standalone cluster runtime** that the monolith
connects to as a **client**. The runtime must run on VMs (current prod), in
Kubernetes (target), and on a local dev PC, selected by configuration only.

## Goals

- One container image, three run profiles (`local` / `vm` / `k8s`) chosen by
  swapping the discovery (`join`) block.
- Client/server topology: monolith drops embedded member, connects as a client.
- Deploy to VM (TCP/IP discovery) and k8s (Kubernetes API discovery) with no image change.
- Survive the phased migration (see Migration Phases) including a cross-network window.
- Ship Docker image, Helm chart, docker-compose, and a monolith connection guide.
- Safe defaults for 1M users: sync backups, split-brain protection, graceful rolling
  restarts gated on cluster-safe, eviction/backpressure guards, observability.

## Non-Goals (out of scope)

- Enterprise features: disk persistence (Hot Restart), WAN replication, TLS/auth,
  off-heap (High-Density Memory Store).
- Monolith-side code changes. We deliver connection **config + guide** only.
- A published Spring client starter library. Not wanted.
- Management Center deployment (free 3-member limit); replaced by a metrics pipeline.
- **In-grid MapStore/MapLoader persistence** at launch — see Data Safety decision.

## Decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Topology | Client/server | Independent scaling + restart isolation at 1M users. |
| Edition | Hazelcast OSS, **pinned patch** (e.g. `5.5.x`, exact tag/digest) | Free; k8s + TCP/IP discovery, backups, near-cache suffice to start. No floating `5.x` tag. |
| Server build | Config-only image | `FROM hazelcast/hazelcast:<pinned>` + templated `hazelcast.yaml`; no Java module. |
| Cache population | **App-side cache-aside** (monolith reads DB on miss) | Keeps image config-only. In-grid MapStore would need a Java module — deferred (see below). |
| k8s discovery | Kubernetes API mode | Readiness/zone awareness, autoscale-friendly; needs RBAC in chart. |
| Deliverables | Image + Helm + compose + docs | No starter lib. |

### Config-only vs persistence — resolved
The image is **config-only**. It contains no `MapStore`/`MapLoader` (those are Java
classes on the classpath, impossible in `hazelcast.yaml` alone). Therefore the grid
holds **ephemeral, rebuildable data**, and the **monolith** owns the cache-aside
pattern: on cache miss it reads the source DB and populates the grid; on write it
updates DB then grid. If read/write-through *inside* Hazelcast is later required, it
becomes an **optional Java module** (member app with MapStore impls + DB driver +
secret-based creds) — a separate, explicit decision, not part of v1.

## Architecture

### The runtime
A single container: `FROM hazelcast/hazelcast:<pinned>` with one `hazelcast.yaml`.
The Java process is the stock Hazelcast member; we own configuration, not code.

### Configuration model (env vars are scalar-only)
The official image's `HZ_*` override sets **scalar leaf** properties only
(`HZ_CLUSTERNAME`, not `HZ_CLUSTER_NAME`; `HZ_NETWORK_RESTAPI_ENABLED=true`). It
**cannot** express list-valued or repeated structures (`tcp-ip.member-list`,
multiple `split-brain-protection` rules, the `kubernetes` join sub-tree).

Therefore:
- The **whole `join:` block is templated/swapped per profile** (Helm template for
  k8s; envsubst/init-container or mounted file for vm/local). Not driven by env vars.
- Env vars carry only true scalars: cluster name, member-count hints, heap percent,
  REST enable flag.
- `HZ_PROFILE` selects which `join` block is rendered.

### Health / REST (must be explicitly enabled)
Hazelcast 5.x **disables the REST API by default**. Probes fail (connection
refused / 404) and the StatefulSet never becomes Ready unless enabled:
```yaml
hazelcast:
  network:
    rest-api:
      enabled: true
      endpoint-groups:
        HEALTH_CHECK: { enabled: true }
```
Health endpoints on port 5701: `/hazelcast/health/{ready,node-state,cluster-state,
cluster-safe,migration-queue-size,cluster-size}`.
- **readiness** → `/hazelcast/health/ready` (verify on pinned patch that it returns
  200 only post-join / post-migration; behavior refined across 5.x minors).
- **liveness** → `/hazelcast/health/node-state`.
- **preStop gate** → poll `/hazelcast/health/cluster-safe` == 200 before terminating.

### Split-brain protection (correct keys, chosen quorum)
Not enabled by default; requires a named rule referenced per map:
```yaml
hazelcast:
  split-brain-protection:
    sbp-write:
      enabled: true
      minimum-cluster-size: 3        # majority of a 5-member cluster
      protect-on: WRITE
  map:
    default:
      split-brain-protection-ref: sbp-write
      merge-policy:
        class-name: com.hazelcast.spi.merge.PutIfAbsentMergePolicy
```
`minimum-cluster-size` = majority (3 for 5 members). Merge policy is set explicitly
(default `PutIfAbsentMergePolicy`) so heal behavior is intentional, not accidental.
Split-brain protection is a coarse member-count check, not per-partition — it limits
divergence, does not eliminate it.

### Map defaults (capacity + eviction guard)
Every map gets an eviction safety valve so a hot map cannot OOM a member:
```yaml
map:
  default:
    backup-count: 1                 # SYNC (default) — see Data Safety
    eviction:
      eviction-policy: LRU
      max-size-policy: PER_NODE       # or FREE_HEAP_PERCENTAGE
      size: <tuned>
    time-to-live-seconds: <per-map>
    split-brain-protection-ref: sbp-write
```
`partition-count: 271` (default; correct up to ~25–40 members). Fixed at cluster
creation, must match on every member **and** client — set now, never drift.

### JVM / GC (explicit, not defaulted)
- Pin the JDK (matches the pinned Hazelcast base image).
- G1 with a pause target: `-XX:+UseG1GC -XX:MaxGCPauseMillis=200`; consider
  ZGC/Shenandoah only for larger heaps.
- Heap from container limit: `-XX:MaxRAMPercentage` (leave OS/off-heap headroom).
- **Raise heartbeat tolerance** so GC pauses don't cause false member suspicion:
  tune `hazelcast.max.no.heartbeat.seconds` and client heartbeat timeouts.
- Enable graceful shutdown: `-Dhazelcast.shutdownhook.policy=GRACEFUL` +
  `-Dhazelcast.graceful.shutdown.max.wait=<sec>` (see Data Safety).
- Enable diagnostics log: `-Dhazelcast.diagnostics.enabled=true` (rotated) for
  post-incident forensics (slow ops, heartbeats, migrations).

## Discovery per environment
- **local**: `tcp-ip` with the three compose service names.
- **vm**: `tcp-ip`, `member-list` templated from VM hostnames/IPs.
- **k8s**: `kubernetes` discovery, API mode, `service-name` + `namespace`.

## Migration Phases (client reachability)

1. **Phase 1 — monolith(VM) → HZ(VM).** Client `smart` routing, static member list.
2. **Phase 2 — monolith(VM) → HZ(k8s), cross-network.** Members are not reachable
   at their private pod IPs from outside. Options:
   - **Default: `unisocket` routing + a single internal LoadBalancer.** One entry
     point, simplest exposure. Accept the extra hop + one-member hotspot. **Phase 2
     is time-boxed**, not steady state.
   - **If phase 2 is long-lived: `smart` routing with External Smart Client
     Discovery.** Each pod must advertise its **external** address
     (`public-address` per pod, reserved LB IP, `use-public-ip: true` on the client),
     or use the Hazelcast Operator which automates this. Per-pod LBs cost money +
     quota (5 members = 5 external LBs). Plain per-pod LB + smart **without**
     public-address advertisement does NOT work (client gets private IPs it can't reach).
3. **Phase 3 — monolith(k8s) → HZ(k8s), in-cluster.** Same Kubernetes API discovery,
   no external exposure; external LB services removed.

### ⚠️ Security — OSS has no TLS and no client authentication
Cluster name is a namespace, not a credential. Member and client traffic are
**unencrypted and unauthenticated**. Anyone who can reach a member port owns the grid.

- Phase-2 cross-network traffic **must** ride a private path — VPC peering / VPN /
  private link — **never the public internet**.
- Restrict member ports with security groups / firewall and a **NetworkPolicy**
  limiting ingress to known client CIDRs/namespaces.
- Chart defaults to **internal** LoadBalancer where supported + restrictive NetworkPolicy.
- Cross-network heartbeats over a WAN-ish private link add latency variance → tune
  client heartbeat timeout; verify MTU to avoid fragmenting migration packets.
- TLS + mutual auth require Enterprise; revisit if the private-path assumption fails.

### ⚠️ Cluster-name mismatch (migration foot-gun)
A **client** with the wrong `cluster-name` fails to connect (auth-failure). A
**member** with a mismatched name silently forms its **own** cluster → two
half-clusters during VM↔k8s transition. Make cluster name a required,
env-namespaced value (e.g. `prod-hz`); fail-fast if unset. Document both failure
signatures in the connection guide.

## Data Safety at 1M users (OSS constraints)

- `backup-count: 1` **sync** → survives a single member loss. Anti-affinity MUST be
  `requiredDuringScheduling` so primary + backup never co-locate. Consider
  `backup-count: 2` for the most critical maps (no disk fallback = any double-fault
  is permanent loss).
- ⚠️ **No disk persistence in OSS.** Full-cluster restart loses all data. Recovery is
  the monolith's cache-aside repopulation from the DB (see Cold-start below).
- **Split-brain protection** as above; minority partition rejects writes.
- **Graceful rolling restarts — proven invariant, not asserted.** PDB + anti-affinity
  alone are insufficient with `backup-count: 1`. Required together:
  - `GRACEFUL` shutdown policy + `graceful.shutdown.max.wait` ≤ `terminationGracePeriodSeconds`.
  - **preStop hook polls `/hazelcast/health/cluster-safe` == 200** before the pod is
    allowed to terminate — i.e. terminate only when `partitionMovementComplete &&
    clusterSafe`.
  - StatefulSet `OrderedReady` / `RollingUpdate`, one member at a time (`maxUnavailable: 1`),
    PDB, `requiredDuringScheduling` anti-affinity.
- ⚠️ **GC / heap headroom.** On-heap storage; per-entry overhead (metadata, near-cache,
  backups, op buffers) means 5 KB/user of payload consumes materially more heap. Keep
  heap ≤ ~8 GB/member and **scale out**, not up. Reserve headroom (don't run cache to
  the heap ceiling).
- **Migration throttling.** Scale-out migrates ~1/N of 271 partitions over the network
  while serving traffic; cap concurrent migrations (`hazelcast.partition.migration.*`)
  and treat scale-out as a planned, throttled op. Do **not** inflate partition-count
  "to be safe" — 271 is right until ~25–40 members.

### ⚠️ Cold-start DB stampede (biggest 1M-user risk of "rebuild from DB")
Empty grid after full restart → 1M users' read-through misses hammer the DB at once,
potentially right after an outage. Mitigations (monolith/app-side, since cache-aside):
- Per-key load coalescing / single-flight so N concurrent misses = 1 DB read.
- Staged warm-up / rate-limited backfill of hot keys.
- DB read replicas for backfill load.
- App-level circuit breaking + short negative caching.
This is a first-class design concern, owned by the monolith, documented in the guide.

## Client resilience (connection guide)
The guide specifies, per phase:
- `cluster-name` (env-namespaced) and discovery/member addresses.
- Routing: `smart` (phase 1/3) vs `unisocket` (phase 2 default); `use-public-ip` when
  External Smart Client Discovery is used.
- `connection-strategy` (`async-start`, `reconnect-mode: ASYNC`) and `connection-retry`
  (cluster-connect-timeout, backoff) so rolling restarts / phase transitions degrade
  instead of throwing `HazelcastClientNotActiveException`.
- Matching `partition-count`; pinned **client library version** verified against the
  server patch (mixed 4.x-client → 5.x-server not assumed).
- **Near-cache** per map: `invalidate-on-change`, `time-to-live-seconds`, `max-idle`,
  and an explicit note on which maps are safe for near-cache (stale-read risk for
  session/auth-like data). Estimate M×N (app instances × members) connection + event
  fan-out load and set member socket/thread limits.
- **Backpressure**: enable `hazelcast.backpressure.enabled` + max concurrent
  invocations so a smart client can't OOM a member with queued ops.
- Removal of the embedded Spring Hazelcast auto-configuration.

## Kubernetes / Helm chart

Chart `helm/hazelcast-runtime/` provides:

- **StatefulSet** — N members, stable identities, `HZ_PROFILE=k8s`, GRACEFUL shutdown,
  `terminationGracePeriodSeconds` ≥ graceful wait, preStop cluster-safe gate.
- **Headless Service** — peer discovery.
- **Per-pod LoadBalancer/NodePort Services** — optional, phase-2 external clients;
  with per-pod `public-address` advertisement when smart routing is chosen. Toggled in values.
- **RBAC** — ServiceAccount + Role `get,list` on `pods, services, endpoints` (`""`) +
  `get,list` on `endpointslices` (`discovery.k8s.io`); **ClusterRole**/binding adding
  `nodes` (`get,list`) only if zone-aware or NodePort public discovery is used.
- **Probes** — readiness `/hazelcast/health/ready`, liveness `/hazelcast/health/node-state`.
- **Resources** — CPU/memory requests+limits; heap via `MaxRAMPercentage` (≤ ~8 GB).
- **Pod anti-affinity** — `requiredDuringScheduling`, spread across nodes/zones.
- **PodDisruptionBudget** — `maxUnavailable: 1`.
- **NetworkPolicy** — restrict member-port ingress to known clients.
- **values-{local,vm,k8s}.yaml** — per-env member count, discovery, exposure, sizing.

HPA is **not** enabled by default: autoscaling a stateful grid triggers migration
storms; scale members deliberately.

## Observability (replaces Management Center)
- Enable Hazelcast **metrics** + JMX / Prometheus-friendly scrape.
- Grafana dashboard + alerts on: member count < N, migration-queue > 0 sustained,
  heap > threshold, GC pause, `SplitBrainProtectionException` rate, client connection
  count/drops.
- Diagnostics log shipped + rotated.

## Sizing (starting point — must tune to real bytes/user)
Assume ~5 KB/user payload → materially more on-heap after overhead; ~5 GB primary +
~5 GB backup ≈ 10 GB+ across the cluster. Start: **5 members × 4 GB heap,
backup-count 1 sync, partition-count 271**, leaving GC/overhead headroom. Measure
real entry size + hit rate; scale members out. Starting line, not a guarantee.

## Repository layout
```
hazelcast-runtime/
  config/
    hazelcast.yaml              # base config (rest-api, split-brain, map defaults, jvm hints)
    join-local.yaml            # tcp-ip compose
    join-vm.yaml               # tcp-ip member-list
    join-k8s.yaml              # kubernetes API discovery
  docker/
    Dockerfile                 # FROM hazelcast/hazelcast:<pinned digest>
  docker-compose.yml           # 3-member local cluster
  helm/
    hazelcast-runtime/         # chart: statefulset, headless+per-pod svc, rbac (role+clusterrole),
                               # pdb, netpol, values-{local,vm,k8s}.yaml
  docs/
    connection-guide.md        # monolith client config, all 3 phases, resilience, stampede
    superpowers/specs/         # this design
  test/
    smoke/                     # testcontainers: cluster form, backup survives kill, quorum blocks writes
```

## Testing
- **Local smoke**: `docker-compose up` 3 members; client put/get; kill a member,
  confirm sync-backup survival.
- **Testcontainers**: boot 2–3 members + client; assert cluster formation; kill one
  member → partition backup survives; **enable split-brain protection first**, then
  assert writes below `minimum-cluster-size` throw `SplitBrainProtectionException`
  (test asserts configured behavior, not defaults).
- **Helm**: `helm lint` + `helm template` render checks per values file; optional
  `kind` apply exercising k8s API discovery + RBAC + probes going Ready.

## Open items to resolve during implementation
- Exact Hazelcast patch + JDK to pin (digest-pinned).
- Confirm `/hazelcast/health/ready` post-migration semantics on the pinned patch.
- Phase-2 exposure (unisocket default vs smart+public-address) — decided at rollout;
  chart supports both.
- Real per-user byte size → final member count + heap + eviction `size`.
- Whether any map later needs in-grid MapStore → optional Java module (separate spec).
```
