# ----------------------------------------------------------------------
# webhooks.tf
# ----------------------------------------------------------------------
# Recurso 'datadog_webhook.self_healing' — substitui a configuracao
# manual que era feita no painel Datadog (passo 5 do docs/alerting.md).
#
# Quando o monitor 'auth_5xx' dispara, o Datadog chama este webhook,
# que faz POST em https://api.github.com/.../dispatches disparando o
# workflow 'self-healing.yml' do GitHub Actions (que executa o
# 'kubectl rollout restart' no deployment do auth-service).
#
# Nome do webhook: 'togglemaster-self-healing' (IDENTICO ao atual,
# para que a referencia '@webhook-togglemaster-self-healing' na
# mensagem do monitor continue funcionando).
#
# TODO (Fase D): preencher resource com name, url, headers e payload.
# ----------------------------------------------------------------------
