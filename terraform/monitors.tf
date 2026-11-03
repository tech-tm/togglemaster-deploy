# ----------------------------------------------------------------------
# monitors.tf
# ----------------------------------------------------------------------
# Recurso 'datadog_monitor.service_5xx' (Multi-Alert por serviço).
#
# Esse monitor antes era criado pelo workflow 'alerts-deploy.yml' a
# partir do payload JSON em 'alerts/datadog/monitor-5xx-auth.json'.
# Esses dois arquivos foram removidos — toda a configuracao vive
# agora aqui (Terraform).
#
# Monitor exigido pelo Bloco 4 do PDF (Tech Challenge Fase 4):
#   "Disparar se a taxa de erros HTTP 5xx de qualquer microsserviço for maior que 5%"
#
# A query usa as metricas APM 'trace.http.request.errors' e
# 'trace.http.request.hits' que sao geradas pelo 'datadog connector'
# do OTel Collector (ver togglemaster-deploy/k8s/observability/
# applications/otel-collector.yaml).
#
# A mensagem referencia dois destinos:
#   @${var.incident_handle}               -> integracao Jira Service Management Ops
#   @webhook-togglemaster-self-healing    -> webhook deste mesmo stack TF
#
# ----------------------------------------------------------------------
# Lista dos microsserviços instrumentados para monitorização individual
locals {
  services = [
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service"
  ]
}

resource "datadog_monitor" "services_5xx" {
  for_each = toset(local.services)

  name    = "[ToggleMaster] ${each.key} - taxa de erros 5xx > ${var.threshold_percent}%"
  type    = "metric alert"
  message = local.monitor_message


# resource "datadog_monitor" "service_5xx" {
#   name    = "[ToggleMaster] {{service.name}} - taxa de erros 5xx > ${var.threshold_percent}%"
#   type    = "metric alert"
#   message = local.monitor_message

  # Query: taxa de erros 5xx em janela de 5 min agrupada por 'service'.
  #
  # 'default_zero()' evita que a query retorne NaN quando nao ha trafego
  # (hits=0); forca o resultado a ser 0, mantendo o monitor em estado OK
  # ao inves de 'No Data' durante periodos ociosos.
  #
  # 'as_count()' converte metricas sumarizadas em counts absolutos para
  # fazer a divisao erros/hits corretamente.
  # query = join("", [
  #   "sum(last_5m):default_zero(100 * (",
  #   "sum:trace.http.request.errors{env:${var.env}}.as_count() / ",
  #   "sum:trace.http.request.hits{env:${var.env}}.as_count()",
  #   ")) by {service} > ${var.threshold_percent}"
  # ])
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

  # Nao notifica como "No Data" quando nao ha trafego. Com default_zero
  # na query, a divisao retorna 0 em vez de NaN, entao No Data e raro.
  # notify_no_data      = false
  # no_data_timeframe   = 10
  # renotify_interval   = 30
  # require_full_window = false

  notify_no_data      = false
  no_data_timeframe   = 10
  renotify_interval   = 30
  require_full_window = false
  evaluation_delay    = 60
  include_tags        = true
  priority            = 1

  # Aguarda 60s apos a janela de avaliacao antes de alertar. Da tempo
  # para metricas atrasadas chegarem no Datadog.
  # evaluation_delay = 60

  # Inclui as tags do monitor nas notificacoes (ex: na mensagem do Slack
  # vinda do JSM, aparece o 'service' correspondente, etc).
  # include_tags = true

  # Prioridade 1 = highest. Vira P1 no incident management.
  # priority = 1

  # Mensagem adicional enviada em renotificacoes (apos renotify_interval).
  escalation_message = "O alerta ainda esta ativo para o servico {{service.name}}. Verifique o self-healing e o alerta no JSM."

  # ---------- Tags ----------------------------------------------------

  # Combina tags comuns da camada (team:togglemaster, env:prod, fase:4, managed-by:terraform)
  # com a criticidade. O Datadog gerencia a tag 'service' dinamicamente por grupo.
  # tags = concat(
  #   [
  #     "severity:critical",
  #   ],
  #   local.common_tags,
  # )

    tags = concat(
    [
      "service:${each.key}",
      "severity:critical",
    ],
    local.common_tags,
  )
}