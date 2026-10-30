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
# Mensagem referencia dois destinos:
#   @jsm_ops                              -> integracao Jira Service Management
#   @webhook-togglemaster-self-healing    -> webhook deste mesmo stack TF
#
# TODO (Fase E): preencher resource com name, query, thresholds, tags.
# ----------------------------------------------------------------------
