# ----------------------------------------------------------------------
# webhooks.tf
# ----------------------------------------------------------------------
# Recurso 'datadog_webhook.self_healing' — substitui a configuracao
# manual que era feita no painel Datadog (passo 5 do docs/alerting.md).
#
# Quando qualquer um dos monitores 'services_5xx' dispara, o Datadog
# chama este webhook, que faz POST em https://api.github.com/.../dispatches
# disparando o workflow 'self-healing.yml' do GitHub Actions (que executa
# 'kubectl rollout restart' no deployment DO SERVICO QUE ALERTOU).
#
# O nome do servico e passado dinamicamente via $TAGS[service]: cada
# monitor tem a tag 'service:<nome>', e o Datadog expande $TAGS[service]
# com esse valor em tempo de disparo. Assim o self-healing reinicia o
# servico correto (auth, flag, targeting, evaluation ou analytics).
#
# Nome do webhook: 'togglemaster-self-healing' (IDENTICO ao atual,
# para que a referencia '@webhook-togglemaster-self-healing' na
# mensagem do monitor continue funcionando).
#
# SEGURANCA: o PAT do GitHub e lido do SSM Parameter Store (ver
# providers.tf -> data.aws_ssm_parameter.github_pat). O valor fica no
# state remoto, que esta criptografado at-rest no S3. Nunca aparece em
# logs do workflow, 'terraform output' ou arquivos versionados.
#
# ROTACAO: para trocar o PAT, atualize o SSM:
#     aws ssm put-parameter \
#       --profile aws_fiap \
#       --name /togglemaster/prod/github/webhook-pat \
#       --type SecureString \
#       --value <novo-pat> \
#       --overwrite
# E rode 'terraform apply' novamente — o data source re-le o SSM e o
# header do webhook e atualizado no Datadog.
# ----------------------------------------------------------------------

resource "datadog_webhook" "self_healing" {
  name      = "togglemaster-self-healing"
  url       = "https://api.github.com/repos/${var.github_repo}/dispatches"
  encode_as = "json"

  # Payload enviado ao GitHub. Os placeholders ($TAGS[service], $ALERT_TITLE,
  # $LINK, $ALERT_ID) sao variaveis do DATADOG, substituidas em tempo de
  # disparo — nao sao variaveis Terraform.
  #
  # $TAGS[service] le a tag 'service:<nome>' do monitor que disparou
  # (definida em monitors.tf). O workflow self-healing.yml valida esse
  # valor contra uma whitelist antes de reiniciar — se vier vazio ou
  # invalido, ele falha com seguranca em vez de reiniciar o servico errado.
  payload = jsonencode({
    event_type = "datadog-alert"
    client_payload = {
      service    = "$TAGS[service]"
      alert_name = "$ALERT_TITLE"
      alert_url  = "$LINK"
      alert_id   = "$ALERT_ID"
    }
  })

  # Headers HTTP enviados ao GitHub:
  #   - Accept:                content type exigido pela API do GitHub
  #   - Authorization:         'token <PAT>' (classic ou fine-grained)
  #   - X-GitHub-Api-Version:  boa pratica, fixa a versao da API
  #
  # custom_headers e uma string JSON unica (schema do provider v3.x).
  # Os valores sao renderizados em tempo de 'apply'; o PAT vem do SSM
  # via data source (ver providers.tf) e so trafega em memoria do
  # processo Terraform + state criptografado no S3.
  custom_headers = jsonencode({
    "Accept"               = "application/vnd.github+json"
    "Authorization"        = "token ${data.aws_ssm_parameter.github_pat.value}"
    "X-GitHub-Api-Version" = "2022-11-28"
  })
}
