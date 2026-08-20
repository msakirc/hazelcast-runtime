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

ENTRYPOINT ["/opt/hazelcast/entrypoint.sh"]
