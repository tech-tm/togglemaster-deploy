# ----------------------------------------------------------------------
# providers.tf
# ----------------------------------------------------------------------
# Declara os providers usados por esta camada:
#   - aws:     para ler credenciais do Datadog e PAT do GitHub armazenadas
#              em SSM Parameter Store (criptografadas com KMS)
#   - datadog: para criar o monitor e o webhook via API Datadog
#
# SEGURANCA: as credenciais sensiveis (API Key, App Key, PAT GitHub) sao
# lidas em tempo de 'plan/apply' direto do SSM via 'data "aws_ssm_parameter"'
# e marcadas como sensitive=true. Nunca aparecem em logs do workflow,
# em 'terraform output' ou em arquivos versionados.
#
# TODO (Fase C): preencher data sources + provider blocks.
# ----------------------------------------------------------------------
