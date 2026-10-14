{{- define "shop.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{- define "shop.labels" -}}
{{ include "shop.selectorLabels" . }}
app.kubernetes.io/part-of: shop
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
team: {{ .root.Values.team | quote }}
{{- end }}

{{- define "shop.dbEnv" -}}
- {name: DB_HOST, value: {{ .Values.db.host | quote }}}
- {name: DB_PORT, value: {{ .Values.db.port | quote }}}
- {name: DB_NAME, value: {{ .Values.db.name | quote }}}
- {name: DB_USER, value: {{ .Values.db.user | quote }}}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.db.passwordSecret }}
      key: password
      optional: true
{{- end }}

{{- define "shop.spread" -}}
{{- $s := .spread -}}
{{- $selector := include "shop.selectorLabels" (dict "root" .root "name" .name) -}}
{{- if eq $s.mode "topologySpreadConstraints" -}}
topologySpreadConstraints:
  - maxSkew: {{ $s.maxSkew }}
    topologyKey: {{ $s.topologyKey }}
    whenUnsatisfiable: {{ ternary "DoNotSchedule" "ScheduleAnyway" $s.strict }}
    nodeTaintsPolicy: Honor
    matchLabelKeys: [pod-template-hash]
    labelSelector:
      matchLabels:
        {{- $selector | nindent 8 }}
{{- else if eq $s.mode "podAntiAffinity" -}}
affinity:
  podAntiAffinity:
    {{- if $s.strict }}
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: {{ $s.topologyKey }}
        labelSelector:
          matchLabels:
            {{- $selector | nindent 12 }}
    {{- else }}
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: {{ $s.topologyKey }}
          labelSelector:
            matchLabels:
              {{- $selector | nindent 14 }}
    {{- end }}
{{- else if ne $s.mode "none" }}
{{- fail (printf "%s.spread.mode: unknown value %q (expected topologySpreadConstraints, podAntiAffinity or none)" .name $s.mode) }}
{{- end }}
{{- end }}
