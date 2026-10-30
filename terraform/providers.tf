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
# com 'with_decryption=true'. Marcadas como sensitive=true automaticamente.
# Nunca aparecem em logs do workflow, 'terraform output' ou arquivos
# versionados. O state remoto esta criptografado (ver backend.tf).
# ----------------------------------------------------------------------

provider "aws" {
  region = var.aws_region
}

# ---------- Credenciais Datadog (criadas manualmente no SSM) ----------

data "aws_ssm_parameter" "dd_api_key" {
  name            = "/togglemaster/prod/datadog/api-key"
  with_decryption = true
}

data "aws_ssm_parameter" "dd_app_key" {
  name            = "/togglemaster/prod/datadog/app-key"
  with_decryption = true
}

# ---------- PAT do GitHub (pre-requisito manual, ver DEPLOY.md 0.3) ----

data "aws_ssm_parameter" "github_pat" {
  name            = var.github_pat_ssm_name
  with_decryption = true
}

# ---------- Provider Datadog --------------------------------------------
# api_url e montada a partir de 'var.datadog_site' (default: datadoghq.com).
# Para outras regioes (datadoghq.eu, us5.datadoghq.com, etc), ajustar o
# valor em terraform.tfvars.

provider "datadog" {
  api_key = data.aws_ssm_parameter.dd_api_key.value
  app_key = data.aws_ssm_parameter.dd_app_key.value
  api_url = "https://api.${var.datadog_site}/"
}
