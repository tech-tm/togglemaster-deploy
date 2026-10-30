# ----------------------------------------------------------------------
# variables.tf
# ----------------------------------------------------------------------
# Variaveis de entrada da camada. Valores padrao vem de 'terraform.tfvars';
# o workflow 'datadog-terraform-apply.yml' tambem permite sobrescrever
# 'threshold_percent' e 'warning_percent' via inputs no 'workflow_dispatch'
# (sem precisar editar o tfvars).
# ----------------------------------------------------------------------

# ---------- Infra / ambiente ------------------------------------------

variable "aws_region" {
  description = "Regiao AWS onde o SSM Parameter Store vive"
  type        = string
  default     = "us-east-1"
}

variable "env" {
  description = "Ambiente logico (prod, staging, dev). Usado em tags."
  type        = string
  default     = "prod"
}

variable "team" {
  description = "Time dono dos recursos. Vira tag 'team:<valor>' no Datadog."
  type        = string
  default     = "togglemaster"
}

# ---------- Datadog ---------------------------------------------------

variable "datadog_site" {
  description = "Site Datadog (datadoghq.com, datadoghq.eu, us5.datadoghq.com, etc)"
  type        = string
  default     = "datadoghq.com"
}

variable "incident_handle" {
  description = "Handle da integracao de incident management no Datadog (sem o '@'). Default: Jira Service Management Ops."
  type        = string
  default     = "jsm_ops"
}

# ---------- Monitor de 5xx auth-service -------------------------------

variable "threshold_percent" {
  description = "Threshold critical do monitor em % de erros 5xx. Default: 5."
  type        = number
  default     = 5

  validation {
    condition     = var.threshold_percent > 0 && var.threshold_percent <= 100
    error_message = "threshold_percent precisa estar entre 1 e 100."
  }
}

variable "warning_percent" {
  description = "Threshold warning do monitor em % de erros 5xx. Default: 3."
  type        = number
  default     = 3

  validation {
    condition     = var.warning_percent > 0 && var.warning_percent <= 100
    error_message = "warning_percent precisa estar entre 1 e 100."
  }
}

# ---------- GitHub / webhook self-healing -----------------------------

variable "github_repo" {
  description = "Repositorio GitHub (org/name) onde vive o workflow self-healing"
  type        = string
  default     = "tech-tm/togglemaster-deploy"
}

variable "github_app_repo" {
  description = "Repositorio GitHub da aplicacao (usado em links da mensagem do monitor)"
  type        = string
  default     = "tech-tm/togglemaster-app"
}

variable "github_pat_ssm_name" {
  description = "Nome do parametro SSM que armazena o PAT do GitHub"
  type        = string
  default     = "/togglemaster/prod/github/webhook-pat"
}
