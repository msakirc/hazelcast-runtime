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
