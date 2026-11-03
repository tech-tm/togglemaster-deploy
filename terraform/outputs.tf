# ----------------------------------------------------------------------
# outputs.tf
# ----------------------------------------------------------------------
# Valores expostos ao fim do 'terraform apply', consumidos pelo workflow
# 'datadog-terraform-apply.yml' para montar o Summary no GitHub Actions.
#
# Como agora ha um monitor por servico (for_each em monitors.tf), os
# outputs de monitor sao MAPAS { "<servico>" = <valor> }.
#
# Nenhum output e sensivel (IDs numericos, nomes de recurso e URLs
# publicas da UI nao sao segredo).
# ----------------------------------------------------------------------

output "monitor_ids" {
  description = "Mapa servico -> ID numerico do monitor no Datadog"
  value       = { for svc, m in datadog_monitor.services_5xx : svc => m.id }
}

output "monitor_urls" {
  description = "Mapa servico -> URL direta para a UI do monitor"
  value = {
    for svc, m in datadog_monitor.services_5xx :
    svc => "https://app.${var.datadog_site}/monitors/${m.id}"
  }
}

output "webhook_name" {
  description = "Nome do webhook (confirmacao de que foi criado)"
  value       = datadog_webhook.self_healing.name
}
