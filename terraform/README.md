# Datadog Terraform — ToggleMaster Fase 4

Esta pasta contém a configuração como código (IaC) dos recursos do painel
Datadog que antes eram criados manualmente ou via workflow dedicado.

## 📦 O que está aqui

| Recurso Terraform | Função |
|---|---|
| `datadog_monitor.auth_5xx` | Monitor de taxa de erros 5xx do `auth-service` > 5% (requisito do Bloco 4 do PDF) |
| `datadog_webhook.self_healing` | Webhook chamado pelo monitor pra disparar o workflow `self-healing.yml` do GitHub Actions |

Ambos os recursos ganham a tag `managed-by:terraform` pra ficar claro no
painel do Datadog o que é gerenciado por código vs criado manualmente.

## 🧭 Posição no fluxo de deploy

Rode este Terraform **somente depois** que:

1. ✅ Infra AWS está provisionada (`Terraform Apply` do `togglemaster-app`)
2. ✅ ArgoCD instalado (`Install ArgoCD`)
3. ✅ Stack de observabilidade deployada (`Observability Deploy`)
4. ✅ Microsserviços rodando (`GitOps`)
5. ✅ **Métricas APM chegando ao Datadog** (gerar carga + aguardar ~10 min)

Sem o passo 5, o monitor nasce em `No Data` — a métrica
`trace.http.request.hits{service:auth-service}` só existe depois que o
`datadog connector` do OTel Collector começa a receber spans e agregar
APM Stats.

Detalhes dessa ordem em [`DEPLOY.md`](../DEPLOY.md) → Fase 6.

## 🔐 Como os segredos são tratados

Nada de secret versionado. Toda credencial sensível fica no AWS SSM
Parameter Store (criptografado com KMS) e é lida pelo Terraform via
`data "aws_ssm_parameter"` em tempo de `plan`/`apply`.

```
AWS SSM Parameter Store (SecureString)
    ├── /togglemaster/prod/datadog/api-key     ← ingestão
    ├── /togglemaster/prod/datadog/app-key     ← API de controle
    └── /togglemaster/prod/github/webhook-pat  ← dispatch do self-healing
            │
            ▼ (lido pelo providers.tf em runtime)
    Terraform (processo em memória)
            │
            ▼
    State S3 (bucket tech4-tfstates, criptografado at-rest)
```

- Nenhum valor sensível aparece em logs do workflow, `terraform output`,
  ou arquivos versionados.
- Rotação é só re-cadastrar no SSM (`aws ssm put-parameter --overwrite`)
  + rodar `apply` de novo. O `data source` lê o valor novo
  automaticamente.

## 🚀 Como usar

### Via workflow do GitHub Actions (recomendado)

Acesse `togglemaster-deploy` → **Actions** → **Datadog Terraform — Apply**
→ Run workflow com os inputs:

| Input | Default | Descrição |
|---|---|---|
| `action` | `plan` | `plan` gera o plano sem aplicar; `apply` cria/atualiza no Datadog |
| `threshold_percent` | `5` | % de erros 5xx a partir do qual o monitor dispara (critical) |
| `warning_percent` | `3` | % de erros pra entrar em warning |

**Primeira vez (safety-first):**

1. Rodar com `action=plan` → baixar o artifact `tfplan-<run_id>` →
   inspecionar
2. Se tudo OK, rodar de novo com `action=apply`

### Via terraform local (desenvolvimento)

🎯 **Objetivo:** rodar `plan` localmente antes de commitar mudanças.

📋 **Pré-requisitos:**
- [ ] Terraform ≥ 1.6.0 instalado (`terraform version`)
- [ ] AWS CLI configurado com perfil `aws_fiap`
- [ ] Credenciais AWS Academy válidas (`aws sts get-caller-identity --profile aws_fiap`)
- [ ] Secrets no SSM: `api-key`, `app-key`, `webhook-pat` cadastrados

🔧 **Comandos:**

```bash
cd togglemaster-deploy/terraform

# Inicializa backend + providers (uma vez por máquina)
AWS_PROFILE=aws_fiap terraform init

# Validação de sintaxe (não toca em nada remoto)
terraform fmt -check
terraform validate

# Plan: mostra o que mudaria no Datadog (não altera nada)
AWS_PROFILE=aws_fiap terraform plan

# Apply: aplica no Datadog (só se tiver certeza)
AWS_PROFILE=aws_fiap terraform apply
```

✅ **Como saber se funcionou:**
- Datadog → **Monitors** → o monitor `[ToggleMaster] auth-service - taxa
  de erros 5xx > 5%` aparece
- Datadog → **Integrations** → **Webhooks** → `togglemaster-self-healing`
  aparece

## ↩️ Rollback

### Reverter apenas o monitor (preservar webhook)

```bash
cd togglemaster-deploy/terraform
AWS_PROFILE=aws_fiap terraform apply -target=datadog_monitor.auth_5xx
```

Útil se, por exemplo, você mudou a query e quer desfazer sem tocar no
webhook.

### Reverter apenas o webhook (preservar monitor)

```bash
AWS_PROFILE=aws_fiap terraform apply -target=datadog_webhook.self_healing
```

### Rollback total (destrói tudo que o Terraform gerencia)

Via workflow (recomendado):
`togglemaster-deploy` → Actions → **Datadog Terraform — Destroy** →
digite `destroy-datadog` no input de confirmação.

### Restaurar versão anterior do state (state corrompido)

O bucket S3 tem versionamento. Pra listar versões anteriores do state:

```bash
aws s3api list-object-versions \
  --profile aws_fiap \
  --bucket tech4-tfstates \
  --prefix deploy/datadog/terraform.tfstate
```

Pra restaurar uma versão específica, veja a doc do S3 object versioning.

## 🐛 Troubleshooting

### "Resource already exists" durante o `apply`

**Sintoma:** `apply` falha porque o monitor ou webhook já foi criado
manualmente (ou pelo workflow legado `alerts-deploy.yml`).

**Solução:** importar o recurso existente pro state antes do apply:

```bash
# Descobrir o ID do monitor atual (via API)
DD_API_KEY=$(aws ssm get-parameter --profile aws_fiap \
  --name /togglemaster/prod/datadog/api-key --with-decryption \
  --query 'Parameter.Value' --output text)
DD_APP_KEY=$(aws ssm get-parameter --profile aws_fiap \
  --name /togglemaster/prod/datadog/app-key --with-decryption \
  --query 'Parameter.Value' --output text)

MONITOR_ID=$(curl -sS "https://api.datadoghq.com/api/v1/monitor?name=%5BToggleMaster%5D%20auth-service" \
  -H "DD-API-KEY: $DD_API_KEY" -H "DD-APPLICATION-KEY: $DD_APP_KEY" \
  | jq -r '.[0].id')

cd togglemaster-deploy/terraform
AWS_PROFILE=aws_fiap terraform import datadog_monitor.auth_5xx $MONITOR_ID
AWS_PROFILE=aws_fiap terraform import datadog_webhook.self_healing togglemaster-self-healing
```

Depois rode `terraform plan` — deve mostrar poucas ou nenhuma mudança.

### `401 Unauthorized` no `plan`/`apply`

**Causa:** App Key errada no SSM. Comum confundir **Application Key**
(prefixo `ddapp_`) com **Personal Access Token** (prefixo `ddpat_`) ou
com API Key (32 chars hex sem prefixo).

**Solução:** criar uma Application Key no painel Datadog em `Personal
Settings` → `Application Keys` (não "API Keys", não "Access Tokens") e
atualizar o SSM:

```bash
read -s DD_APP_KEY   # cole a App Key, Enter
aws ssm put-parameter --profile aws_fiap \
  --name /togglemaster/prod/datadog/app-key \
  --type SecureString --value "$DD_APP_KEY" --overwrite
unset DD_APP_KEY
```

### `ParameterNotFound` no `plan`

**Causa:** PAT do GitHub não foi cadastrado no SSM (pré-requisito único).

**Solução:** seguir o passo 0.3 do `DEPLOY.md`, subseção **PAT do GitHub
(para o webhook de self-healing)**.

### `new_group_delay` ou outros campos inesperados aparecem no plan

Terraform mostra campos que o Datadog preenche como default — não é
drift real. Se o `apply` for bem-sucedido, pode ignorar.

### Mais troubleshoot

[`../TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) → **seção 20: Datadog
Terraform**.

## 📂 Arquivos

```
terraform/
├── backend.tf        # Backend S3 + required_providers
├── providers.tf      # Providers aws + datadog, data sources SSM
├── variables.tf      # Variáveis (env, team, thresholds, repos, SSM names)
├── terraform.tfvars  # Valores padrão versionados (sem secrets)
├── main.tf           # locals (monitor_message, common_tags)
├── monitors.tf       # datadog_monitor.auth_5xx
├── webhooks.tf       # datadog_webhook.self_healing
├── outputs.tf        # monitor_id, monitor_url, webhook_name
└── README.md         # este arquivo
```
