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
