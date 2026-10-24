# Guia de Deploy — do zero ao vídeo da entrega

Checklist linear com comandos literais. Siga **na ordem**. Se algo falhar,
veja [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md).

> **Dica**: imprima essa página ou abra em outra aba. Marque cada passo com
> `[x]` conforme avança.

---

## Pré-requisitos (uma vez, fora do projeto)

- [ ] Conta **AWS Academy** com Learner Lab ativo.
- [ ] Conta **Datadog** (plano gratuito for education).
- [ ] Conta **OpsGenie** (plano free, 5 usuários).
- [ ] Servidor **Discord** com um canal `#alerts`.
- [ ] AWS CLI, kubectl, helm, jq instalados localmente.

---

## Fase 0 — Setup inicial (uma vez por sessão AWS Academy)

### 0.1 Credenciais AWS no `~/.aws/credentials`

Pegue as credenciais do AWS Academy e cole em `~/.aws/credentials` (seção `[default]`). Elas duram ~4h.

> ⚠️ **A sessão AWS Academy expira em ~4h.** Veja a seção
> **"Renovação de sessão AWS Academy"** no final do documento quando isso acontecer.
> Não é só renovar o `~/.aws/credentials` — também precisa atualizar os
> secrets do GitHub E re-sincronizar o Secret do cluster (via GitOps),
> senão `evaluation-service` e `analytics-service` perdem acesso ao SQS/DynamoDB.

### 0.2 Secrets do GitHub

Nos repos **`togglemaster-app`** e **`togglemaster-deploy`**:

Settings → Secrets and variables → Actions → New repository secret

Crie em cada repo:

| Nome | Valor |
|---|---|
| `AWS_ACCESS_KEY_ID` | da AWS Academy |
| `AWS_SECRET_ACCESS_KEY` | da AWS Academy |
| `AWS_SESSION_TOKEN` | da AWS Academy |
| `AWS_REGION` | `us-east-1` |
| `DB_USERNAME` | ex: `postgres` (só no `togglemaster-app`) |
| `TERRAFORM_STATE_BUCKET` | nome do bucket S3 que armazena o state (só no `togglemaster-app`) |
| `PERSONAL_ACCESS_TOKEN` | PAT do GitHub com escopo `repo` (só no `togglemaster-app`) |

### 0.3 Parâmetros no AWS SSM

Rode no terminal (adapte os valores):

```bash
# ------- Base (necessario para subir infra e microsservicos) -------

# Nome do cluster EKS que o Terraform vai criar
aws ssm put-parameter --name "/togglemaster/prod/cluster-name" \
  --type String --value "togglemaster-eks" --overwrite

# Credenciais do Postgres por serviço (JSON com username + password)
for svc in auth flag targeting; do
  aws ssm put-parameter --name "/togglemaster/prod/$svc/credentials" \
    --type SecureString \
    --value '{"username":"postgres","password":"<ESCOLHA_UMA_SENHA>"}' \
    --overwrite
done

# Credencial do Redis (JSON com password)
aws ssm put-parameter --name "/togglemaster/prod/redis/credentials" \
  --type SecureString \
  --value '{"password":"<ESCOLHA_UMA_SENHA>"}' \
  --overwrite

# ------- Datadog (Blocos 2 e 4) -------

# API Key: Datadog UI → Organization Settings → API Keys → New Key
aws ssm put-parameter --name "/togglemaster/prod/datadog/api-key" \
  --type SecureString --value "<DD_API_KEY>" --overwrite

# App Key: Datadog UI → Organization Settings → Application Keys → New Key
aws ssm put-parameter --name "/togglemaster/prod/datadog/app-key" \
  --type SecureString --value "<DD_APP_KEY>" --overwrite

# Site (opcional): default datadoghq.com. Se sua conta for us5, eu, etc, ajuste.
aws ssm put-parameter --name "/togglemaster/prod/datadog/site" \
  --type String --value "datadoghq.com" --overwrite
```

### 0.4 Preflight Check (confere se tudo está no lugar)

Rode o workflow:

**`togglemaster-deploy`** → Actions → **Preflight Check** → Run workflow → branch `deploy`

Se der verde ✅, prossiga. Se der ❌, veja o que falta e volte no 0.3.

---

## Fase 1 — Infraestrutura (Terraform)

### 1.1 Rodar o Terraform Apply

**`togglemaster-app`** → Actions → **Terraform Apply** → Run workflow → branch `main`

Isso provisiona (em cascata):
- KMS + SSM customizations
- RDS (3 instâncias Postgres) + ElastiCache Redis + DynamoDB + SQS
- ECR (5 repositórios)
- EKS + Node Group
- Security Groups

Duração típica: **15 a 25 minutos**.

### 1.2 Validar

```bash
# Cluster EKS criado?
aws eks describe-cluster --name togglemaster-eks \
  --query 'cluster.{Name:name,Status:status,Version:version}'

# ECR com os 5 repos?
aws ecr describe-repositories \
  --query 'repositories[].repositoryName' --output table
```

---

## Fase 2 — Imagens dos microsserviços no ECR

Nessa fase, você faz **build + push** das imagens dos 5 serviços no ECR.

### 2.1 Disparar os workflows

Opção **A** (recomendado): faz um commit vazio em cada serviço no `togglemaster-app`
(gatilho natural dos workflows).

```bash
cd togglemaster-app
for svc in auth flag targeting evaluation analytics; do
  git commit --allow-empty -m "chore(deploy): trigger build $svc-service"
done
git push origin main
```

Opção **B**: dispare manualmente cada workflow:
`togglemaster-app` → Actions → `auth-service` → Run workflow (etc).

### 2.2 Validar

```bash
# Imagens com SHA do commit em todos os 5 repos
for svc in auth flag targeting evaluation analytics; do
  echo "--- $svc ---"
  aws ecr describe-images \
    --repository-name togglemaster-$svc \
    --query 'imageDetails[].imageTags' --output text
done
```

---

## Fase 3 — ArgoCD + aplicação principal

### 3.1 Instalar o ArgoCD

**`togglemaster-deploy`** → Actions → **Install ArgoCD** → Run workflow → branch `deploy`

Isso faz:
- Helm `argo-cd` v7.8.0 no namespace `argocd` (modo LoadBalancer + insecure, com `ignoreDifferences` globais pra evitar `ComparisonError`).
- Aplica `k8s/application.yaml` — Application do ArgoCD que gerencia os 5 microsserviços.

Duração: ~5 min.

### 3.2 Validar

**Conectar o `kubectl` ao cluster** (uma vez por sessão AWS Academy; sem isso os comandos `kubectl` falham):

```bash
aws eks update-kubeconfig --region us-east-1 --name togglemaster-eks

# Testa que a conexao funciona
kubectl get nodes
# Esperado: 3 nodes Ready (ou 2, se ainda nao aplicou o aumento de capacidade)
```

**Checar o ArgoCD de pé:**

```bash
kubectl get pods -n argocd              # todos Running
kubectl get applications -n argocd      # 'togglemaster' deve aparecer
```

### 3.3 Acessar a UI do ArgoCD

**a) Pegue a URL do Load Balancer** (o workflow `Install ArgoCD` configurou o Service como `LoadBalancer` — a AWS cria um ELB público):

```bash
kubectl get svc argocd-server -n argocd \
  -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
```

Esse hostname (algo tipo `xxxxxx.us-east-1.elb.amazonaws.com`) é o endereço da UI do ArgoCD.

> O ELB demora ~1-3 min pra ficar disponível após o workflow terminar. Se o comando acima retornar vazio, aguarde e tente de novo.

**b) Obtenha a senha inicial do admin** (gerada automaticamente pelo chart):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo    # quebra de linha pra legibilidade
```

**c) Acesse pelo browser:**

- URL: `http://<hostname-do-elb>` (o workflow instalou com `--insecure`, então HTTP funciona)
- Usuário: `admin`
- Senha: a que você acabou de recuperar no passo (b)

Na UI do ArgoCD você vê as Applications sincronizando (`togglemaster` nessa fase, depois `observability`, `kube-prometheus-stack`, etc.).

> **Dica de segurança**: a senha inicial fica guardada no secret `argocd-initial-admin-secret`. Em produção real, você logaria com ela, criaria usuários reais e deletaria esse secret. Pro escopo da fase, tudo bem manter.

---

## Fase 4 — Stack de observabilidade (Blocos 1 e 2)

### 4.1 Rodar o workflow

**`togglemaster-deploy`** → Actions → **Observability Deploy** → Run workflow → branch `deploy`

Esse workflow aplica o App-of-Apps da observabilidade e aguarda cada Application
sincronizar. **18 steps granulares** — se algo falhar, você vê exatamente em qual.

Duração: ~10 min (os Helm charts de Prometheus/Loki demoram).

### 4.2 Criar o Secret do Datadog

**`togglemaster-deploy`** → Actions → **Sync Datadog Secret from SSM** → Run workflow

Isso lê os parâmetros SSM do Datadog e cria o Secret `datadog-secret` no namespace
`observability`. **Sem esse secret, o OTel Collector fica em `CreateContainerConfigError`**.

### 4.3 Validar

```bash
# Applications sincronizadas
kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

# Pods de pé no namespace observability
kubectl get pods -n observability

# Grafana (abre no browser)
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000  —  user: admin  /  password: togglemaster
```

Dashboard "ToggleMaster - Visao Geral do Ecossistema" deve estar na lista.

---

## Fase 5 — Deploy dos microsserviços (Bloco 3)

### 5.1 Rodar o GitOps

Faça um commit vazio na branch `deploy` do `togglemaster-deploy`:

```bash
cd togglemaster-deploy
git checkout deploy

# IMPORTANTE: a branch 'deploy' recebe commits automaticos dos workflows
# docker-pipeline (quando as imagens dos microsservicos sao buildadas).
# Antes de qualquer push manual, puxe primeiro:
git pull --rebase origin deploy

git commit --allow-empty -m "chore(deploy): trigger gitops"
git push origin deploy
```

> Se o push for rejeitado com `[rejected] deploy -> deploy (fetch first)`,
> veja a seção **"Git: push rejected na branch deploy"** no final deste documento.

Isso dispara o workflow **GitOps** que:
1. Cria `togglemaster-secrets` (com credenciais Postgres, Redis, MASTER_KEY, SERVICE_API_KEY **e credenciais AWS da sessão atual**), `db-*-secret`, `redis-secret` no cluster.
2. Cria/atualiza o ConfigMap `togglemaster-config` com endpoints reais **e as envs OTEL_*** (Bloco 3).
3. Aplica os db-init Jobs.
4. Faz `kubectl rollout restart` nos 5 deployments pra pegar as novas envs.

Duração: ~5 min.

> **Importante**: as credenciais AWS no `togglemaster-secrets` vêm dos
> secrets do GitHub Actions (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
> `AWS_SESSION_TOKEN`). Elas são necessárias pro `evaluation-service` falar
> com SQS e pro `analytics-service` falar com SQS+DynamoDB. Como são
> credenciais temporárias do AWS Academy, elas expiram em 4h — reveja a
> seção **"Renovação de sessão AWS Academy"** quando isso acontecer.

### 5.2 Validar

```bash
# Pods dos microsserviços
kubectl get pods -n togglemaster

# ConfigMap tem as envs OTEL
kubectl get cm togglemaster-config -n togglemaster -o yaml | grep OTEL_

# Auth, flag e targeting: envs OTEL (devem ter 4-6 OTEL_*)
kubectl exec -n togglemaster deploy/auth-service -- env | grep OTEL_

# Evaluation: tem OTEL + credenciais AWS (sem as AWS_*, SQS falha com NoCredentialProviders)
kubectl exec -n togglemaster deploy/evaluation-service -- env | grep -E "^OTEL_|^AWS_"

# Analytics: idem
kubectl exec -n togglemaster deploy/analytics-service -- env | grep -E "^OTEL_|^AWS_"

# Logs do evaluation não devem ter "NoCredentialProviders"
kubectl logs -n togglemaster deploy/evaluation-service --tail=50 | grep -i "credential\|sqs" || echo "✓ Sem erros de credenciais"
```

Depois disso, abra o **Datadog APM → Services**: os 5 serviços devem aparecer. Pode levar alguns minutos até os primeiros traces chegarem.

---

## Fase 6 — Alertas, OpsGenie, Discord (Bloco 4)

### 6.1 Setup manual (uma vez, fora do GitHub)

Siga o passo a passo em [`docs/alerting.md`](./docs/alerting.md), passos **2 a 4**:

- [ ] OpsGenie: criar team `togglemaster` + integração Datadog.
- [ ] Discord: criar webhook do canal `#alerts` + integrar no OpsGenie.
- [ ] Datadog: criar webhook `togglemaster-self-healing` apontando pro
  `repository_dispatch` do GitHub Actions.

### 6.2 Aplicar o Monitor

**`togglemaster-deploy`** → Actions → **Alerts Deploy** → Run workflow

Esse workflow lê o payload JSON versionado em `alerts/datadog/monitor-5xx-auth.json`
e cria/atualiza o Monitor no Datadog via API.

### 6.3 Validar

- Datadog UI → **Monitors** → o monitor `[ToggleMaster] auth-service - taxa de erros 5xx > 5%` deve aparecer com status `OK` ou `No Data`.

---

## Fase 7 — Teste end-to-end (pro vídeo)

### 7.1 Gerar carga normal

Pegue o endpoint do Ingress:

```bash
INGRESS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://$INGRESS"
```

Faça algumas chamadas de evaluate — **note que o Ingress exige o prefixo `/evaluation/`** (sem ele dá 404):

```bash
# Health dos 5 serviços (rotas do Ingress têm prefixo por serviço)
for route in validate flag targeting evaluation analytics; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$INGRESS/$route/health")
  echo "$route/health → HTTP $code"
done

# Carga: evaluate chama auth + flag + targeting (povoa o Service Map)
for i in {1..50}; do
  curl -s -o /dev/null "http://$INGRESS/evaluation/evaluate?user_id=u$i&flag_name=test-flag"
done
```

Observe no Datadog APM → **Service Map**: os 5 serviços devem aparecer
conectados por setas (`evaluation` → `auth`, `flag`, `targeting`).

> **Mapa de rotas do Ingress** (prefixo é rewriten pelo nginx):
> - `/validate/<path>` → `auth-service` recebe `/<path>`
> - `/flag/<path>` → `flag-service`
> - `/targeting/<path>` → `targeting-service`
> - `/evaluation/<path>` → `evaluation-service`
> - `/analytics/<path>` → `analytics-service`

### 7.2 Causar incidente proposital

Derruba o `auth-service` pra forçar erros no evaluation:

```bash
kubectl scale deployment auth-service -n togglemaster --replicas=0
```

Dispare carga:

```bash
for i in {1..500}; do
  curl -s -o /dev/null "http://$INGRESS/evaluation/evaluate?user_id=u$i&flag_name=test-flag" &
done
wait
```

Dentro de **~5 min**, observe:

1. **Datadog Monitor** entra em `Alert` (status vermelho).
2. **OpsGenie** abre um incidente (visível no dashboard do OpsGenie).
3. **Discord** canal `#alerts` recebe notificação (via integração OpsGenie).
4. **GitHub Actions** → `togglemaster-deploy` → workflow **Self-Healing Rollout** roda.
5. O workflow executa `kubectl rollout restart deployment/auth-service`.

### 7.3 Prints obrigatórios (relatório PDF)

Capture durante o passo 7.2:

- [ ] Dashboard do Grafana aberto, dados fluindo.
- [ ] Datadog APM → Service Map com os 5 serviços.
- [ ] Datadog APM → Trace distribuído de uma chamada `/evaluate`.
- [ ] Discord `#alerts` com a notificação do incidente.
- [ ] GitHub Actions → run do **Self-Healing Rollout** → log do `kubectl rollout restart`.

### 7.4 Restaurar

```bash
kubectl scale deployment auth-service -n togglemaster --replicas=1
```

---

## Fase 8 — Entrega

- [ ] Gravar vídeo de **até 25 min** cobrindo as 4 seções do PDF.
- [ ] Montar relatório PDF com os prints acima + justificativa técnica
  (texto pronto em [`docs/alerting.md`](./docs/alerting.md) → seção "Justificativa das escolhas").
- [ ] Submeter.

---

## Resumo visual

```mermaid
graph TD
    A[0.1-0.3 SSM + Secrets] --> B[0.4 Preflight ✓]
    B --> C[1. Terraform Apply]
    C --> D[2. Build imagens]
    D --> E[3. Install ArgoCD]
    E --> F[4.1 Observability Deploy]
    F --> G[4.2 Sync Datadog Secret]
    G --> H[5. GitOps push]
    H --> I[6.1 Setup OpsGenie/Discord manual]
    I --> J[6.2 Alerts Deploy]
    J --> K[7. Teste end-to-end + prints]
    K --> L[8. Vídeo + Relatório]
```

Se qualquer passo falhar: [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md).

---

## Git: push rejected na branch `deploy`

### Sintoma

```text
To github.com:tech-tm/togglemaster-deploy.git
 ! [rejected]        deploy -> deploy (fetch first)
error: failed to push some refs to 'github.com:tech-tm/togglemaster-deploy.git'
hint: Updates were rejected because the remote contains work that you do not
hint: have locally.
```

### Causa

Esse erro é **esperado** nesse projeto. A branch `deploy` recebe pushes
automáticos de outros workflows:

- A cada build de serviço no `togglemaster-app`, o `docker-pipeline.yml`
  chama o `reusable-gitops.yml` que **commita a tag nova da imagem** no
  `togglemaster-deploy/k8s/base/services/<serviço>/kustomization.yaml`.
- Esses commits acontecem silenciosamente, sem sua intervenção.
- Resultado: seu local fica desatualizado em relação ao remote.

### Solução (rebase)

**NÃO use `git push --force`** — você sobrescreveria os commits automáticos
e perderia as tags de imagem atualizadas.

```bash
cd togglemaster-deploy
git checkout deploy

# 1) Ve o que tem no remote que você nao tem local (opcional, só pra entender)
git fetch origin
git log HEAD..origin/deploy --oneline
# Esperado: 1+ commits do tipo "chore(deploy): update <servico> image to <sha>"

# 2) Rebase: puxa remote primeiro, reaplica seus commits locais em cima
git pull --rebase origin deploy

# 3) Agora o push funciona
git push origin deploy
```

### Se der conflito no rebase

Pouco provável — os workflows automáticos mexem em arquivos
`k8s/base/services/*/kustomization.yaml`, área diferente das suas edições
manuais típicas. Mas se der:

```bash
# Lista os arquivos em conflito
git status

# Resolve manualmente (edita, mantem a versao certa), depois:
git add <arquivos-resolvidos>
git rebase --continue
```

Se ficar confuso ou quiser desistir do rebase e voltar ao estado anterior:

```bash
git rebase --abort
```

### Hábito recomendado

Antes de qualquer push manual na branch `deploy`, **sempre** rode:

```bash
git pull --rebase origin deploy
```

Depois faça suas mudanças e dê `git push`. Vira hábito em 2-3 vezes.

---

## Idempotência do deploy (o que persiste vs o que precisa ser recriado)

Se você fizer `terraform destroy` + `Terraform Apply` novamente (ou se o Learner Lab for resetado), o que acontece:

### Persiste automaticamente (vem do Git) ✅

Todos esses são aplicados pelos workflows na nova rodada:

- Infra Terraform (EKS, RDS, Redis, SQS, DynamoDB, ECR) — `Terraform Apply`.
- ArgoCD + `ignoreDifferences` globais — `Install ArgoCD` aplica o `k8s/argocd/values.yaml`.
- Stack de observabilidade (Prometheus, Grafana, Loki, OTel Collector) com todos os fixes — `Observability Deploy`.
- Microsserviços com instrumentação OTel e credenciais AWS nos deployments — `GitOps` + ArgoCD.
- Monitor do Datadog — `Alerts Deploy`.
- Workflow de self-healing — já versionado.

### NÃO persiste no cluster (vem de fora do Git) ⚠️

Essas 3 fontes de dado ficam **fora** do cluster e são materializadas pelos workflows:

| Fonte | O que armazena | Quando recriar |
|---|---|---|
| **AWS SSM Parameter Store** | `cluster-name`, credenciais DB/Redis, Datadog api-key/app-key | **Persiste** entre sessões no AWS Academy. Só perde se alguém apagar manualmente ou se o Learner Lab for totalmente resetado. |
| **GitHub Secrets** | Credenciais AWS da sessão | **A cada 4h** (expiração da sessão AWS Academy) |
| **OpsGenie + Discord + Datadog webhook** | Config externa das contas SaaS | **1 vez** por conta (não expira) |

### Patches manuais que fizemos no cluster — resumo

Durante o troubleshooting fizemos alguns `kubectl patch` e `kubectl annotate` manuais. **Todos foram incorporados ao Git** depois, então em um novo deploy **não precisa repetir nenhum deles**. Lista pra referência:

| Patch manual que foi feito | Hoje está em (versionado) |
|---|---|
| `kubectl patch cm argocd-cm` com `ignoreDifferences` | `k8s/argocd/values.yaml` |
| `kubectl annotate application ... refresh=hard` | não precisa — ArgoCD sincroniza sozinho na primeira vez |
| `kubectl rollout restart argocd-application-controller` | não precisa — pod novo nasce com config correta |
| `kubectl rollout restart evaluation-service analytics-service` | não precisa — pod novo nasce com envs AWS do Secret |
| `kubectl create secret datadog-secret` manual | workflow `Sync Datadog Secret from SSM` faz isso |
| `kubectl patch argocd-cm` com `trim` ou outros | não precisa — workflow `Install ArgoCD` já blinda |

### Fluxo pra um deploy do zero (ordem)

Siga o `DEPLOY.md` do começo. Nenhuma etapa adicional é necessária.

---

## Renovação de sessão AWS Academy (a cada 4h)

A sessão AWS Academy expira após 4 horas. Quando expirar, as credenciais em
3 lugares distintos ficam velhas e precisam ser renovadas:

```text
Learner Lab (AWS Academy)
      │
      ├── ~/.aws/credentials       ← kubectl/aws CLI local
      ├── GitHub Secrets x2 repos  ← workflows do GitHub Actions
      └── Secret togglemaster-secrets ← pods evaluation + analytics
```

### Protocolo completo de renovação

```bash
# 1. Pega credenciais frescas no Learner Lab (AWS Details → copiar)

# 2. Atualiza ~/.aws/credentials local
nano ~/.aws/credentials

# 3. Atualiza os 3 secrets em CADA repo do GitHub
#    (togglemaster-app E togglemaster-deploy):
#      AWS_ACCESS_KEY_ID
#      AWS_SECRET_ACCESS_KEY
#      AWS_SESSION_TOKEN
#    Settings → Secrets and variables → Actions

# 4. Dispara o GitOps (que re-sincroniza o Secret k8s com credenciais frescas)
cd togglemaster-deploy
git checkout deploy
git commit --allow-empty -m "chore: refresh aws session"
git push origin deploy
# Aguarda ~3-5 min pelo workflow GitOps terminar.

# 5. Rolla os deployments que dependem de AWS SDK
kubectl rollout restart deployment evaluation-service analytics-service -n togglemaster
kubectl rollout status  deployment evaluation-service analytics-service -n togglemaster --timeout=3m

# 6. Confirma que o SQS voltou (não deve ter mais "NoCredentialProviders")
kubectl logs -n togglemaster deploy/evaluation-service --tail=30 | grep -iE "credential|sqs" || echo "✓ Sem erros"
```

### Sinais de que a sessão expirou

- Workflows com `ExpiredToken` nos logs.
- Pod `evaluation-service` com `NoCredentialProviders: no valid providers in chain`.
- `aws sts get-caller-identity` local falha.

Para o **vídeo da entrega** (Fase 7-8): **renove a sessão imediatamente antes
de começar a gravação** para ter 4h limpas.

# FIM
