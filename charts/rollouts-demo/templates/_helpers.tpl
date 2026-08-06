{{- define "rollouts-demo.fullname" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rollouts-demo.selectorLabels" -}}
app: {{ include "rollouts-demo.fullname" . }}
{{- end -}}

{{- define "rollouts-demo.labels" -}}
{{ include "rollouts-demo.selectorLabels" . }}
app.kubernetes.io/name: {{ include "rollouts-demo.fullname" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
