# ----------------------------------------------------------------------
# monitors.tf
# ----------------------------------------------------------------------
# Um monitor de taxa de erros 5xx POR microsservico, criado via for_each.
#
# Antes era um monitor unico do auth-service (recurso 'auth_5xx'). Agora
# sao 5 monitores (um por servico), cobrindo o requisito do Bloco 4 do
# PDF de forma ampla ("taxa de erros 5xx de qualquer microsservico > 5%").
#
# A query usa as metricas APM 'trace.http.request.errors' e
# 'trace.http.request.hits', geradas pelo 'datadog connector' do OTel
# Collector (ver k8s/observability/applications/otel-collector.yaml).
#
# Cada monitor referencia dois destinos na mensagem (local.monitor_message
# em main.tf):
#   @${var.incident_handle}               -> Jira Service Management Ops
#   @webhook-togglemaster-self-healing    -> webhook deste mesmo stack TF
#
# O webhook recebe o nome do servico via $TAGS[service] (ver webhooks.tf),
# entao o self-healing reinicia exatamente o servico que alertou.
# ----------------------------------------------------------------------

locals {
  # Microsservicos monitorados individualmente.
  services = [
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service",
  ]
}

resource "datadog_monitor" "services_5xx" {
  for_each = toset(local.services)

  name    = "[ToggleMaster] ${each.key} - taxa de erros 5xx > ${var.threshold_percent}%"
  type    = "metric alert"
  message = local.monitor_message

  # Query: taxa de erros 5xx em janela de 5 min, filtrada pelo servico.
  #
  # 'default_zero()' evita NaN quando nao ha trafego (hits=0): forca o
  # resultado a 0, mantendo o monitor em OK em vez de 'No Data'.
  # 'as_count()' converte metricas sumarizadas em counts absolutos para
  # a divisao erros/hits.
  query = join("", [
    "sum(last_5m):default_zero(100 * (",
    "sum:trace.http.request.errors{service:${each.key},env:${var.env}}.as_count() / ",
    "sum:trace.http.request.hits{service:${each.key},env:${var.env}}.as_count()",
    ")) > ${var.threshold_percent}"
  ])

  monitor_thresholds {
    critical = var.threshold_percent
    warning  = var.warning_percent
  }

  # ---------- Opcoes de comportamento ---------------------------------
  notify_no_data      = false
  no_data_timeframe   = 10
  renotify_interval   = 30
  require_full_window = false
  evaluation_delay    = 60
  include_tags        = true
  priority            = 1

  # Mensagem adicional enviada em renotificacoes (apos renotify_interval).
  escalation_message = "O alerta ainda esta ativo para o servico {{service.name}}. Verifique o self-healing e o alerta no JSM."

  # ---------- Tags ----------------------------------------------------
  # 'service:<nome>' por monitor + tags comuns da camada
  # (team:togglemaster, env:prod, fase:4, managed-by:terraform).
  # A tag 'service' tambem alimenta o $TAGS[service] usado pelo webhook.
  tags = concat(
    [
      "service:${each.key}",
      "severity:critical",
    ],
    local.common_tags,
  )
}
