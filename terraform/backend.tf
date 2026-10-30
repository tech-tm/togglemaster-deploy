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
# TODO (Fase C): preencher configuracao completa.
# ----------------------------------------------------------------------
