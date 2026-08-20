# Hazelcast Runtime — Design

**Date:** 2026-08-20
**Status:** Approved (design), pending implementation plan
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

- One container image, three run profiles (`local` / `vm` / `k8s`) chosen by env var.
- Client/server topology: monolith drops embedded member, connects as a client.
- Deploy to VM (TCP/IP discovery) and k8s (Kubernetes API discovery) with no image change.
- Survive the phased migration (see Migration Phases) including a cross-network window.
- Ship Docker image, Helm chart, docker-compose, and a monolith connection guide.
- Safe defaults for 1M users: backups, split-brain protection, graceful rolling restarts.

## Non-Goals (out of scope)

- Enterprise features: disk persistence (Hot Restart), WAN replication, TLS/auth,
  off-heap (High-Density Memory Store), rolling-upgrade compatibility guarantees.
- Monolith-side code changes. We deliver connection **config + guide** only; wiring
  the client into the monolith is the user's task.
- A published Spring client starter library. Not wanted.
- Management Center deployment beyond noting the free 3-member monitoring limit.

## Decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Topology | Client/server | Independent scaling + restart isolation at 1M users. |
| Edition | Hazelcast OSS 5.x | Free; k8s + TCP/IP discovery, backups, near-cache suffice to start. |
| Server build | Config-only image | `FROM hazelcast/hazelcast:5.x` + templated `hazelcast.yaml`; no Java module to maintain. Add a Java module later only if custom serializers/MapStore are needed. |
| k8s discovery | Kubernetes API mode | Readiness/zone awareness, autoscale-friendly; needs RBAC in chart. |
| Deliverables | Image + Helm + compose + docs | No starter lib. |

## Architecture

### The runtime
A single container: `FROM hazelcast/hazelcast:5.x` with one `hazelcast.yaml`
mounted/baked in. All environment differences (discovery method, member list,
cluster name, heap, backup count) are driven by `HZ_*` environment variables and
the profile-appropriate `join` block. The Java process is the stock Hazelcast
member; we own configuration, not code.

### Configuration model
- One `config/hazelcast.yaml` with env-var placeholders.
- `HZ_PROFILE` (or explicit `HZ_NETWORK_JOIN_*` vars) selects the discovery block:
  - `local` → TCP/IP static list on the docker-compose network.
  - `vm` → TCP/IP static list from `HZ_MEMBERLIST` (VM hostnames/IPs).
  - `k8s` → `kubernetes` join, API mode, `service-name` = headless service.
- Map defaults: `backup-count: 1`, eviction/TTL per map, designed **rebuildable
  from the source DB** (see Data Safety).
- `partition-count: 271` (default). Changing it later requires a full cluster
  restart and must match on every member and client — fix it now.

### Discovery per environment
- **local**: `tcp-ip` with the three compose service names as members.
- **vm**: `tcp-ip`, `member-list` populated from `HZ_MEMBERLIST` (comma-separated).
- **k8s**: `kubernetes` discovery, `service-name` + `namespace`, API mode. Chart
  provides ServiceAccount + Role (`get`/`list` on `pods` and `endpoints`) +
  RoleBinding. StatefulSet + headless Service give stable peer DNS.

## Migration Phases (client reachability)

1. **Phase 1 — monolith(VM) → HZ(VM).** Client `smart` routing, static member
   address list. Current state after extraction.
2. **Phase 2 — monolith(VM) → HZ(k8s), cross-network.** Each member must be
   reachable from outside the cluster. Options:
   - **Per-pod LoadBalancer/NodePort Services + client `smart` routing** (preferred
     if infra allows): full partition-aware routing, best throughput.
   - **Single LB + client `unisocket` routing** (fallback): one entry point, an
     extra network hop per op, lower throughput, simplest exposure.
   - Decision deferred to phase-2 rollout; chart supports both via values.
3. **Phase 3 — monolith(k8s) → HZ(k8s), in-cluster.** Client uses the same
   Kubernetes API discovery; no external exposure. External LB services removed.

### ⚠️ Security — OSS has no TLS and no client authentication
The cluster name is a namespace, not a credential. Member and client traffic are
**unencrypted and unauthenticated** in OSS. Anyone who can reach a member port can
read and write the entire grid.

- Phase 2 cross-network traffic **must** ride a private path — VPC peering, VPN,
  private link, or equivalent — **never the public internet**.
- Restrict member ports with security groups / firewall rules and, in k8s, a
  **NetworkPolicy** limiting ingress to known client CIDRs/namespaces.
- The Helm chart defaults to `LoadBalancer` **internal** only where the cloud
  provider supports it, and ships a restrictive NetworkPolicy.
- TLS + mutual auth require Enterprise; revisit if the private-path assumption
  cannot hold.

## Data Safety at 1M users (OSS constraints)

- `backup-count: 1` → survives a single member loss, **not** a full-cluster restart.
- ⚠️ **No disk persistence in OSS.** A full cluster restart loses all in-memory
  data. Therefore every map holding "critical/session" data must be
  **rebuildable from the source DB** via a `MapStore` (read-through/write-through)
  or the app must tolerate loss. Default design treats maps as rebuildable cache.
- **Split-brain protection**: configure `min-cluster-size` (quorum) on writes so a
  minority partition rejects writes rather than diverging.
- **Graceful rolling restarts**: graceful member shutdown, adequate
  `terminationGracePeriodSeconds`, a **PodDisruptionBudget**, and pod
  **anti-affinity** so k8s never removes enough members at once to lose a partition
  and its backup together.
- ⚠️ **GC**: OSS stores data on-heap. Keep heap ≤ ~8 GB per member and **scale out**
  (more members), not up (bigger heaps), to bound GC pause times.

## Kubernetes / Helm chart

Chart `helm/hazelcast-runtime/` provides:

- **StatefulSet** — N members, stable identities, `HZ_PROFILE=k8s`.
- **Headless Service** — peer discovery (DNS + Kubernetes API `service-name`).
- **Per-pod LoadBalancer/NodePort Services** — optional, phase-2 external clients;
  toggled in values.
- **RBAC** — ServiceAccount + Role (`get`/`list` on `pods`, `endpoints`) + RoleBinding.
- **Probes** — readiness `/hazelcast/health/ready`, liveness `/hazelcast/health/node-state`.
- **Resources** — CPU/memory requests+limits; heap sized from limits (≤ ~8 GB).
- **Pod anti-affinity** — spread members across nodes/zones.
- **PodDisruptionBudget** — bound simultaneous voluntary disruptions.
- **NetworkPolicy** — restrict member-port ingress to known clients.
- **values-{local,vm,k8s}.yaml** — per-env member count, discovery, exposure, sizing.

HPA is noted but **not** enabled by default: autoscaling a stateful data grid
triggers rebalancing/migrations; scale members deliberately.

## Sizing (starting point — must tune to real bytes/user)

Assume ~5 KB/user in the grid → ~5 GB primary + ~5 GB backup ≈ 10 GB across the
cluster. Start: **5 members × 4 GB heap, backup-count 1, partition-count 271**.
Measure actual entry size and hit rate, then scale members out. These are a
starting line, not a guarantee.

## Repository layout

```
hazelcast-runtime/
  config/
    hazelcast.yaml              # env-templated member config
  docker/
    Dockerfile                 # FROM hazelcast/hazelcast:5.x
  docker-compose.yml           # 3-member local cluster
  helm/
    hazelcast-runtime/         # chart
      Chart.yaml
      values.yaml
      values-local.yaml
      values-vm.yaml
      values-k8s.yaml
      templates/               # statefulset, services, rbac, pdb, netpol, ...
  docs/
    connection-guide.md        # monolith client config for all 3 phases
    superpowers/specs/         # this design
  test/
    smoke/                     # testcontainers: boot cluster + client put/get
```

## Testing

- **Local smoke**: `docker-compose up` a 3-member cluster; a client puts/gets a key
  and confirms backup on member loss.
- **Testcontainers**: JVM test boots 2–3 member containers + a client, asserts
  cluster formation, partition backup survives one member kill, split-brain quorum
  rejects writes below `min-cluster-size`.
- **Helm**: `helm lint` + `helm template` render checks per values file; optional
  `kind`-based apply for k8s discovery + RBAC.

## Monolith connection guide (delivered as docs)

`docs/connection-guide.md` gives the client config for each phase: cluster name,
member/discovery addresses, `smart` vs `unisocket` routing, matching
`partition-count`, near-cache hints, and the removal of the embedded Spring
Hazelcast auto-configuration. No monolith code is changed by this repo.

## Open items to resolve during implementation

- Exact Hazelcast 5.x patch version to pin (latest stable at build time).
- Phase-2 exposure choice (per-pod LB vs unisocket) — decided at phase-2 rollout;
  chart supports both.
- Whether any map needs a `MapStore` day one (would add an optional Java module).
- Real per-user byte size to finalize member count and heap.
