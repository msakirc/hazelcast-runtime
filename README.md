# hazelcast-runtime

Standalone OSS Hazelcast 5.x cluster. One config-only image, three profiles
(local / vm / k8s). The Spring monolith connects as a client (cache-aside).

## Quick start (local)
    make build && make up && make smoke

## Deploy (k8s)
    helm install hz helm/hazelcast-runtime -f helm/hazelcast-runtime/values-k8s.yaml

See `docs/connection-guide.md` for wiring the monolith and
`docs/superpowers/specs/2026-08-20-hazelcast-runtime-design.md` for the design.

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
