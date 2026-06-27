{{/*
Selector labels — the load-bearing contract. The router InferencePool selects
decode pods by llm-d.ai/guide + llm-d.ai/model; keep both in sync with the
ApplicationSet's router matchLabels. llm-d.ai/role:decode is the upstream role.
These go into the Deployment .spec.selector (immutable) — don't change shape.
*/}}
{{- define "llm-d-modelserver.selectorLabels" -}}
llm-d.ai/role: decode
llm-d.ai/guide: {{ .Values.guide }}
llm-d.ai/model: {{ .Values.modelLabel }}
{{- end -}}

{{/* Full label set on the pod + objects (selector labels + accelerator info). */}}
{{- define "llm-d-modelserver.labels" -}}
{{ include "llm-d-modelserver.selectorLabels" . }}
llm-d.ai/accelerator-variant: gpu
llm-d.ai/accelerator-vendor: nvidia
{{- end -}}

{{/* Fail fast if a required per-model value is missing. */}}
{{- define "llm-d-modelserver.validate" -}}
{{- if not .Values.resourceName }}{{ fail "resourceName is required" }}{{ end -}}
{{- if not .Values.model }}{{ fail "model is required" }}{{ end -}}
{{- if not .Values.modelLabel }}{{ fail "modelLabel is required" }}{{ end -}}
{{- end -}}
