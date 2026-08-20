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
