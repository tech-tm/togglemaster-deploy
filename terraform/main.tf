# ----------------------------------------------------------------------
# main.tf
# ----------------------------------------------------------------------
# 'locals' compartilhados entre os recursos desta camada.
# Centraliza a mensagem padrao do monitor para evitar duplicacao e
# facilitar manutencao (um lugar so para ajustar).
# ----------------------------------------------------------------------

locals {
  # Mensagem generica do monitor de 5xx (multi-servico).
  #
  # Compartilhada pelos 5 monitores criados via for_each em monitors.tf.
  # Usa a variavel {{service.name}} do Datadog, que e expandida em tempo
  # de disparo com o servico que efetivamente alertou — assim a mesma
  # mensagem serve para auth, flag, targeting, evaluation e analytics.
  #
  # Formatacao em Markdown — e renderizada em:
  #   - UI do Datadog Monitors
  #   - E-mails de notificacao
  #   - Payload que o Datadog envia para integracoes (@jsm_ops, @webhook-*)
  #
  # Os '@mentions' no final sao obrigatorios: sao eles que acionam o
  # fluxo de incident management (JSM) e self-healing (GitHub Actions).
  #
  # Convencao do Datadog: variaveis {{...}} sao expandidas em tempo de
  # disparo. Variaveis Terraform (${}) sao expandidas no apply.
  monitor_message = <<-EOT
    ## {{service.name}} com taxa de erros HTTP 5xx acima de ${var.threshold_percent}%

    **Servico afetado:** `{{service.name}}`
    **Namespace:** `togglemaster`
    **Severidade:** critical

    ### Diagnostico rapido

    - Logs do servico: filtre `service:{{service.name}} status:error` no Datadog Logs
    - Dashboard Grafana: painel 'Taxa de erros HTTP 5xx por servico'

    ### Automacao acionada

    - **Incident management**: incidente aberto automaticamente -> notificacao no canal do ChatOps
    - **Self-Healing**: `kubectl rollout restart deployment/{{service.name}}` executado via GitHub Actions

    ### Links

    - [ToggleMaster Observability](https://github.com/${var.github_repo}/blob/deploy/docs/observability.md)
    - [Runbook de Alertas](https://github.com/${var.github_repo}/blob/deploy/docs/alerting.md)

    @${var.incident_handle}
    @webhook-togglemaster-self-healing
  EOT

  # Tags base aplicadas a todos os recursos criados por esta camada.
  # 'managed-by:terraform' identifica no painel do Datadog o que e
  # gerenciado por codigo (vs criado manualmente).
  common_tags = [
    "team:${var.team}",
    "env:${var.env}",
    "fase:4",
    "managed-by:terraform",
  ]
}
