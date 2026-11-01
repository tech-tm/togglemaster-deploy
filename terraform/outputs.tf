# ----------------------------------------------------------------------
# outputs.tf
# ----------------------------------------------------------------------
# Valores expostos ao fim do 'terraform apply', consumidos pelo workflow
# 'datadog-terraform-apply.yml' para montar o Summary no GitHub Actions.
#
# Nenhum output e sensivel (IDs numericos, nomes de recurso e URLs
# publicas da UI nao sao segredo).
# ----------------------------------------------------------------------

output "monitor_id" {
  description = "ID numerico do monitor no Datadog"
  value       = datadog_monitor.auth_5xx.id
}

output "monitor_url" {
  description = "URL direta para a UI do monitor"
  value       = "https://app.${var.datadog_site}/monitors/${datadog_monitor.auth_5xx.id}"
}

output "webhook_name" {
  description = "Nome do webhook (confirmacao de que foi criado)"
  value       = datadog_webhook.self_healing.name
}
