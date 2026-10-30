# ----------------------------------------------------------------------
# outputs.tf
# ----------------------------------------------------------------------
# Valores expostos ao fim do 'terraform apply':
#   - monitor_id   -> ID numerico do monitor no Datadog (nao e segredo)
#   - monitor_url  -> URL direta para a UI do monitor
#   - webhook_name -> nome do webhook (confirmacao)
#
# O workflow 'datadog-terraform-apply.yml' usa estes outputs para montar
# o Summary no GitHub Actions.
#
# NOTA: os outputs estao comentados nesta fase porque dependem dos
# recursos 'datadog_monitor.auth_5xx' (Fase E) e 'datadog_webhook.
# self_healing' (Fase D), que ainda nao existem. Serao habilitados
# quando os recursos forem criados.
# ----------------------------------------------------------------------

# output "monitor_id" {
#   description = "ID numerico do monitor no Datadog"
#   value       = datadog_monitor.auth_5xx.id
# }
#
# output "monitor_url" {
#   description = "URL direta para a UI do monitor"
#   value       = "https://app.${var.datadog_site}/monitors/${datadog_monitor.auth_5xx.id}"
# }
#
# output "webhook_name" {
#   description = "Nome do webhook (confirmacao de que foi criado)"
#   value       = datadog_webhook.self_healing.name
# }
