# Datadog Terraform — ToggleMaster Fase 4

Esta pasta contém a configuração como código (IaC) de duas peças que
antes eram criadas de forma manual ou semi-manual no Datadog:

- **Monitor de 5xx do `auth-service`** — hoje substitui o
  `alerts/datadog/monitor-5xx-auth.json` aplicado pelo workflow
  `alerts-deploy.yml`.
- **Webhook `togglemaster-self-healing`** — hoje substitui a
  configuração manual do painel do Datadog descrita no
  `docs/alerting.md`, passo 5.

> 🚧 **Em construção.** Este README será preenchido durante a Fase I do
> plano de implementação. Até lá, o conteúdo aqui é só o escopo.

## O que esta pasta NÃO toca

Pra deixar explícito o isolamento:

- Nenhum manifest Kubernetes, Helm chart ou ArgoCD Application
- Nenhum workflow existente além dos dois arquivos legados que serão
  removidos na Fase K (`alerts-deploy.yml` e `monitor-5xx-auth.json`)
- Nenhuma outra camada Terraform do projeto (`networking`, `security`,
  `data`, `platform`, `compute`)
- Nenhum valor existente no SSM — apenas **lê** os já cadastrados
  (`api-key`, `app-key`) e requer um novo (`github/webhook-pat`)

## Como usar

TODO (Fase I): instruções passo-a-passo para rodar localmente e via
workflow do GitHub Actions.

## Rollback

TODO (Fase I): comandos para reverter mudanças sem quebrar nada.

## Pré-requisitos

TODO (Fase I): PAT do GitHub cadastrado no SSM + trial Datadog ativa.
