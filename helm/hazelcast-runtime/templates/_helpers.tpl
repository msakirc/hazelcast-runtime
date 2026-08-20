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
