# ----------------------------------------------------------------------
# outputs.tf
# ----------------------------------------------------------------------
# Valores expostos ao fim do 'terraform apply':
#   - monitor_id   -> ID numerico do monitor no Datadog (nao e segredo)
#   - monitor_url  -> URL direta para a UI do monitor
#   - webhook_name -> nome do webhook (ja conhecido, mas util como confirmacao)
#
# O workflow 'datadog-terraform-apply.yml' usa estes outputs para montar
# o Summary no GitHub Actions.
#
# TODO (Fase C): preencher blocos output.
# ----------------------------------------------------------------------
