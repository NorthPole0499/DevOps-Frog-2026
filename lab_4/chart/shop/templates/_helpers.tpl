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
