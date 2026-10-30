# ----------------------------------------------------------------------
# monitors.tf
# ----------------------------------------------------------------------
# Recurso 'datadog_monitor.auth_5xx' — substitui o payload JSON
# 'alerts/datadog/monitor-5xx-auth.json' aplicado pelo workflow
# 'alerts-deploy.yml' (ambos serao removidos na Fase K).
#
# Monitor exigido pelo Bloco 4 do PDF (Tech Challenge Fase 4):
#   "Disparar se a taxa de erros HTTP 5xx do auth-service for maior que 5%"
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

resource "datadog_monitor" "auth_5xx" {
  name    = "[ToggleMaster] auth-service - taxa de erros 5xx > ${var.threshold_percent}%"
  type    = "metric alert"
  message = local.monitor_message

  # Query: taxa de erros 5xx em janela de 5 min.
  #
  # 'default_zero()' evita que a query retorne NaN quando nao ha trafego
  # (hits=0); forca o resultado a ser 0, mantendo o monitor em estado OK
  # ao inves de 'No Data' durante periodos ociosos.
  #
  # 'as_count()' converte metricas sumarizadas em counts absolutos para
  # fazer a divisao erros/hits corretamente.
  query = join("", [
    "sum(last_5m):default_zero(100 * (",
    "sum:trace.http.request.errors{service:auth-service,env:${var.env}}.as_count() / ",
    "sum:trace.http.request.hits{service:auth-service,env:${var.env}}.as_count()",
    ")) > ${var.threshold_percent}"
  ])

  monitor_thresholds {
    critical = var.threshold_percent
    warning  = var.warning_percent
  }

  # ---------- Opcoes de comportamento ---------------------------------

  # Nao notifica como "No Data" quando nao ha trafego. Com default_zero
  # na query, a divisao retorna 0 em vez de NaN, entao No Data e raro.
  notify_no_data      = false
  no_data_timeframe   = 10
  renotify_interval   = 30
  require_full_window = false

  # Aguarda 60s apos a janela de avaliacao antes de alertar. Da tempo
  # para metricas atrasadas chegarem no Datadog.
  evaluation_delay = 60

  # Inclui as tags do monitor nas notificacoes (ex: na mensagem do Slack
  # vinda do JSM, aparece 'service:auth-service', etc).
  include_tags = true

  # NOTA sobre 'new_group_delay' / 'new_host_delay':
  #
  # O JSON original tinha 'new_host_delay: 300' (deprecated). O sucessor
  # moderno 'new_group_delay' so e aceito pela API Datadog em monitores
  # multi-alert (grouped by tag, ex: 'sum:... by {host}'). Como este e
  # um monitor single-alert (uma unica serie agregada), o campo e
  # inutil aqui e a API rejeita com 400 Bad Request. Removido.

  # Prioridade 1 = highest. Vira P1 no incident management.
  priority = 1

  # Mensagem adicional enviada em renotificacoes (apos renotify_interval).
  escalation_message = "O alerta ainda esta ativo. Verifique o self-healing e o alerta no JSM."

  # ---------- Tags ----------------------------------------------------

  # Combina tags especificas do monitor com as comuns da camada
  # (team:togglemaster, env:prod, fase:4, managed-by:terraform).
  tags = concat(
    [
      "service:auth-service",
      "severity:critical",
    ],
    local.common_tags,
  )
}
