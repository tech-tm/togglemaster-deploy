# ----------------------------------------------------------------------
# terraform.tfvars
# ----------------------------------------------------------------------
# Valores padrao do projeto (versionados). Sao sobrescritos pelos inputs
# do workflow 'datadog-terraform-apply.yml' quando disparado manualmente
# com valores diferentes de threshold/warning.
#
# NUNCA colocar segredos aqui. Todos os valores sensiveis vem do SSM
# Parameter Store via providers.tf.
# ----------------------------------------------------------------------

env               = "prod"
team              = "togglemaster"
threshold_percent = 5
warning_percent   = 3
incident_handle   = "jsm_ops"
datadog_site      = "datadoghq.com"
github_repo       = "tech-tm/togglemaster-deploy"
github_app_repo   = "tech-tm/togglemaster-app"
