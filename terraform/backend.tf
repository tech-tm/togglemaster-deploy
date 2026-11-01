# ----------------------------------------------------------------------
# backend.tf
# ----------------------------------------------------------------------
# Configura o backend remoto (S3) onde o Terraform guarda o state desta
# camada. O state registra os IDs e configuracoes dos recursos criados
# no Datadog, para que subsequentes 'plan' e 'apply' saibam o que ja
# existe e so apliquem mudancas incrementais.
#
# IMPORTANTE: usamos o mesmo bucket das demais camadas Terraform do
# projeto, com uma 'key' totalmente separada ('deploy/datadog/...'),
# garantindo isolamento com os states de networking, security, data,
# platform e compute.
#
# SEGURANCA: 'encrypt=true' usa criptografia at-rest com SSE-S3. O
# bucket ja tem versionamento habilitado, entao qualquer corrupcao do
# state pode ser revertida restaurando uma versao anterior.
# ----------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  backend "s3" {
    bucket  = "tech4-tfstates"
    key     = "deploy/datadog/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }

  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.50"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
