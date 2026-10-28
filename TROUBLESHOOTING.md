# Troubleshooting

Guia dos erros reais encontrados durante o deploy, com causa e solução testadas.
A ordem segue a frequência que aparecem.

Se o erro que você está vendo **não** está aqui, abra uma issue ou colete:
- Logs do workflow do GitHub Actions.
- `kubectl describe` do pod/application afetado.
- Últimos 30 events do namespace (`kubectl get events -n <ns> --sort-by='.lastTimestamp' | tail -30`).

---

## Índice rápido

- [1. `ComparisonError: field not declared in schema`](#1-comparisonerror-field-not-declared-in-schema)
- [2. `UPGRADE FAILED: pre-upgrade hooks failed: timed out`](#2-upgrade-failed-pre-upgrade-hooks-failed-timed-out)
- [3. OTel Collector em `CreateContainerConfigError`](#3-otel-collector-em-createcontainerconfigerror)
- [4. Application `OutOfSync` indefinidamente](#4-application-outofsync-indefinidamente)
- [5. Dashboard não aparece no Grafana](#5-dashboard-não-aparece-no-grafana)
- [6. Service Map vazio no Datadog APM](#6-service-map-vazio-no-datadog-apm)
- [7. `trigger-argocd-install` do `terraform-apply.yml` falha](#7-trigger-argocd-install-do-terraform-applyyml-falha)
- [8. Credenciais AWS Academy expiradas](#8-credenciais-aws-academy-expiradas)
- [9. Monitor do Datadog retorna HTTP 403](#9-monitor-do-datadog-retorna-http-403)
- [10. Self-Healing workflow não dispara pelo webhook](#10-self-healing-workflow-não-dispara-pelo-webhook)
- [11. OTel Collector CrashLoop: `invalid keys: address`](#11-otel-collector-crashloop-invalid-keys-address)
- [12. Terraform EKS: `Error: Unauthorized` ao criar namespace](#12-terraform-eks-error-unauthorized-ao-criar-namespace)
- [13. Pod `Pending`: `failed to assign an IP address`](#13-pod-pending-failed-to-assign-an-ip-address)
- [14. Evaluation/Analytics: `NoCredentialProviders` (SQS/DynamoDB)](#14-evaluationanalytics-nocredentialproviders-sqsdynamodb)
- [15. OTel Collector ingestão 403: API Key errada no SSM](#15-otel-collector-ingest%C3%A3o-403-api-key-errada-no-ssm)
- [16. Ingress retorna 404 ao acessar endpoints dos microsserviços](#16-ingress-retorna-404-ao-acessar-endpoints-dos-microsservi%C3%A7os)
- [17. `InvalidSignatureException` ao chamar AWS no workflow](#17-invalidsignatureexception-ao-chamar-aws-no-workflow)
- [18. Application `togglemaster` fica `OutOfSync` em `/spec/replicas`](#18-application-togglemaster-fica-outofsync-em-specreplicas)
- [19. Terraform: `ResourceNotFoundException` ao fazer apply](#19-terraform-resourcenotfoundexception-ao-fazer-apply)

---

## 1. `ComparisonError: field not declared in schema`

### Sintoma

No ArgoCD, uma Application fica com:

```text
ComparisonError
Failed to compare desired state to live state: failed to calculate diff:
error calculating structured merge diff: error building typed value from
live resource: .status.terminatingReplicas: field not declared in schema
```

### Causa

O cluster EKS está em Kubernetes >= 1.33, que introduziu o feature gate
`DeploymentReplicaSetTerminatingReplicas`. Esse feature adiciona o campo
`.status.terminatingReplicas` em Deployments/StatefulSets/ReplicaSets.
A biblioteca `gitops-engine` usada pelo ArgoCD v2.14.x ainda não conhece
esse campo. Quando o ArgoCD tenta construir o "typed value" do live
resource pro Structured Merge Diff, falha.

### Solução

Adicionar `ignoreDifferences` globais no ConfigMap `argocd-cm`.

**Cluster já instalado** (fix imediato):

```bash
kubectl patch configmap argocd-cm -n argocd --type merge -p '{
  "data": {
    "resource.customizations.ignoreDifferences.apps_Deployment": "jsonPointers:\n- /status/terminatingReplicas\n",
    "resource.customizations.ignoreDifferences.apps_StatefulSet": "jsonPointers:\n- /status/terminatingReplicas\n",
    "resource.customizations.ignoreDifferences.apps_ReplicaSet":  "jsonPointers:\n- /status/terminatingReplicas\n",
    "resource.customizations.ignoreDifferences.apps_DaemonSet":   "jsonPointers:\n- /status/terminatingReplicas\n"
  }
}'

kubectl rollout restart statefulset argocd-application-controller -n argocd
kubectl rollout status  statefulset argocd-application-controller -n argocd --timeout=3m

# Forca recomparar a Application que estava travada
kubectl annotate application observability -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

**Clusters novos**: já vem corrigido em **3 camadas** (defesa em profundidade):

1. **Global via `k8s/argocd/values.yaml`** — `argocd-cm` com `resource.customizations.ignoreDifferences.*` quando o workflow `Install ArgoCD` roda.
2. **Application-level `ignoreDifferences`** — cada Application de observabilidade (`kube-prometheus-stack`, `loki-stack`, `otel-collector`) tem a mesma config repetida localmente, pra sobreviver caso o global falhe ou seja sobrescrito.
3. **`RespectIgnoreDifferences=true`** nas `syncOptions` de cada Application — garante que o ignore valha também durante o sync (`ServerSideApply`), não apenas no diff.

### Se o erro aparecer mesmo com as 3 camadas

Causa possível: cluster muito novo (k8s 1.34+) com outros campos novos que ainda não cobrimos. Adicione o novo campo nos 3 lugares:

```bash
# Qual campo está dando problema?
# A mensagem de erro aponta: "<caminho>: field not declared in schema"
# Ex: /status/<novo-campo>

# 1. Patch global imediato
kubectl patch configmap argocd-cm -n argocd --type merge -p '{
  "data": {
    "resource.customizations.ignoreDifferences.apps_Deployment": "jsonPointers:\n- /status/terminatingReplicas\n- /status/<novo-campo>\n"
  }
}'
kubectl rollout restart statefulset argocd-application-controller -n argocd

# 2. Permanentemente: adicionar nos 3 arquivos (values.yaml do argocd + 3 Applications)
```

---

## 2. `UPGRADE FAILED: pre-upgrade hooks failed: timed out`

### Sintoma

Workflow `Install ArgoCD` (ou `helm upgrade` manual) com:

```text
Error: UPGRADE FAILED: pre-upgrade hooks failed: 1 error occurred:
    * timed out waiting for the condition
```

### Causa

O chart `argo-cd` tem Jobs pré-upgrade (ex: migração de CRDs). Causas comuns:

- **Jobs órfãos de execução anterior** bloqueando o novo.
- **Timeout padrão do Helm (5 min)** curto demais em `t3.medium` do AWS Academy.
- Pods pendentes por **PVC sem StorageClass** ou **nós lotados**.

### Solução

**Diagnóstico primeiro:**

```bash
# Pods não-Running (hooks pendentes)
kubectl get pods -n argocd --field-selector=status.phase!=Running

# Jobs
kubectl get jobs -n argocd

# Events recentes
kubectl get events -n argocd --sort-by='.lastTimestamp' | tail -30

# Status do release Helm
helm status argocd -n argocd
```

**Fix:**

```bash
# Remove jobs órfãos
kubectl delete jobs -n argocd \
  -l app.kubernetes.io/instance=argocd \
  --ignore-not-found=true

# Repete o helm com timeout maior
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.8.0 \
  -f k8s/argocd/values.yaml \
  --timeout 15m \
  --wait
```

> O workflow `Install ArgoCD` já faz os dois automaticamente (`kubectl delete jobs`
> + `--timeout 15m`). Se mesmo assim travar, veja a seção "Diagnostico" do
> próprio workflow nos logs do GitHub Actions.

---

## 3. OTel Collector em `CreateContainerConfigError`

### Sintoma

```bash
kubectl get pods -n observability
# otel-collector-opentelemetry-collector-xxx   0/1   CreateContainerConfigError
```

Log:

```text
container "opentelemetry-collector" in pod "..." is waiting to start:
CreateContainerConfigError
```

### Causa

O pod precisa de duas variáveis vindo de um Secret (`DD_API_KEY` e `DD_SITE`)
que vive no Secret `datadog-secret` no namespace `observability`. Esse Secret
**não é versionado no Git** (por segurança — API key não vai pra repo). Ele é
criado dinamicamente pelo workflow `Sync Datadog Secret from SSM`.

Se o workflow nunca rodou (ou os SSM parameters não existem), o Secret não
existe e o Kubelet trava no `CreateContainerConfigError`.

### Solução

```bash
# 1. Secret existe?
kubectl get secret datadog-secret -n observability
# NotFound → é esse o problema
```

```bash
# 2. Parâmetros SSM existem?
aws ssm get-parameter --name "/togglemaster/prod/datadog/api-key" \
  --with-decryption --query "Parameter.Value" --output text | head -c 10

# Se "ParameterNotFound", criar primeiro:
aws ssm put-parameter --name "/togglemaster/prod/datadog/api-key" \
  --type SecureString --value "<DD_API_KEY>" --overwrite

aws ssm put-parameter --name "/togglemaster/prod/datadog/site" \
  --type String --value "datadoghq.com" --overwrite
```

```bash
# 3. Rode o workflow
# togglemaster-deploy → Actions → "Sync Datadog Secret from SSM" → Run workflow

# OU manualmente:
DD_API_KEY=$(aws ssm get-parameter --name "/togglemaster/prod/datadog/api-key" \
  --with-decryption --query "Parameter.Value" --output text)
DD_SITE=$(aws ssm get-parameter --name "/togglemaster/prod/datadog/site" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "datadoghq.com")

kubectl create secret generic datadog-secret -n observability \
  --from-literal=api-key="$DD_API_KEY" \
  --from-literal=site="$DD_SITE" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Em ~1-2 min o Kubelet re-tenta o container e o pod sobe. Se quiser forçar:

```bash
kubectl rollout restart deployment \
  otel-collector-opentelemetry-collector -n observability
```

---

## 4. Application `OutOfSync` indefinidamente

### Sintoma

No ArgoCD, uma Application fica `OutOfSync` por mais de 10 min sem convergir.

### Causa possível A — `repoURL` ou branch errada

Se a Application referencia um repo/branch que não existe, não sincroniza.

```bash
kubectl describe application <nome> -n argocd | grep -E "repoURL|targetRevision"
```

Confira que o `repoURL` bate com `git remote -v` do seu repo (ex: `tech-tm/...`).

### Causa possível B — Credenciais Git

Se o repo é privado, o ArgoCD precisa de credenciais. No seu caso são repos
públicos, então em geral não é isso.

### Causa possível C — Values do Helm chart inválidos

```bash
kubectl describe application <nome> -n argocd | tail -40
```

Procure por `error: ... validation failed` ou similar.

### Causa possível D — Recurso bloqueado por outro controlador

```bash
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
```

### Fix comum: forçar hard refresh

```bash
kubectl annotate application <nome> -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Se não resolver, apagar e deixar o App-of-Apps recriar:
kubectl delete application <nome> -n argocd
# (ArgoCD vai recriar em ~3 min via auto-sync do App-of-Apps)
```

---

## 5. Dashboard não aparece no Grafana

### Sintoma

Grafana abre, mas a seção "Dashboards" não lista "ToggleMaster - Visao Geral".

### Causa

O sidecar do Grafana leva ~60s para descobrir ConfigMaps novos. Se não aparecer
depois disso, duas causas típicas:

- O **label** no ConfigMap está errado.
- O **sidecar não está rodando** por falta de permissão.

### Solução

```bash
# 1. ConfigMap tem o label correto?
kubectl get cm grafana-dashboard-togglemaster -n observability \
  -o jsonpath='{.metadata.labels}'
# Esperado: {"grafana_dashboard":"1"}
```

```bash
# 2. Sidecar está rodando?
kubectl get pods -n observability \
  -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[*].spec.containers[*].name}'
# Esperado: grafana grafana-sc-dashboard grafana-sc-datasources
```

```bash
# 3. Logs do sidecar
kubectl logs -n observability \
  -l app.kubernetes.io/name=grafana \
  -c grafana-sc-dashboard --tail=50
```

```bash
# 4. Se nada mudar, force restart do Grafana
kubectl rollout restart deployment \
  kube-prometheus-stack-grafana -n observability
```

---

## 6. Service Map vazio no Datadog APM

### Sintoma

Datadog UI → APM → Service Map está vazio ou só tem alguns serviços
(não todos os 5).

### Causa A — Microsserviços sem envs OTEL

As envs `OTEL_*` vêm do ConfigMap `togglemaster-config`, criado dinamicamente
pelo workflow `GitOps`. Se o workflow nunca rodou depois do Bloco 3, os pods
não têm as envs.

```bash
kubectl exec -n togglemaster deploy/auth-service -- env | grep OTEL_
```

Se não aparecer `OTEL_EXPORTER_OTLP_ENDPOINT`, rode o `GitOps`:

```bash
cd togglemaster-deploy
git checkout deploy
git commit --allow-empty -m "chore: trigger gitops"
git push origin deploy
```

### Causa B — Collector não exportando

```bash
# Logs do collector
kubectl logs -n observability \
  deploy/otel-collector-opentelemetry-collector --tail=50 | grep -i "export\|error"
```

Procure por erros tipo `401` (API key errada) ou `connection refused`
(site errado).

### Causa C — Falta tráfego

O Datadog só mostra serviços no Service Map depois que recebe spans deles.
Faça algumas requisições e espere ~1-2 min:

```bash
INGRESS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

for i in {1..30}; do
  curl -s "http://$INGRESS/evaluate?user_id=u$i&flag_name=test"
done
```

### Causa D — Evaluation chamando flag/targeting sem propagar contexto

Só acontece se a propagação de contexto do Bloco 3 regredir. Confirmar que o
`evaluation-service` está passando `ctx` nas chamadas HTTP outbound:

```bash
grep -n "NewRequestWithContext" togglemaster-app/src/evaluation-service/evaluator.go
# Esperado: as duas funcoes fetchFlag e fetchRule usam NewRequestWithContext
```

---

## 7. `trigger-argocd-install` do `terraform-apply.yml` falha

### Sintoma

Último job do workflow `Terraform Apply` falha com erro de permissão/404 ao
tentar disparar o `argocd-install.yml` no `togglemaster-deploy`.

### Causa

O script `github-script` do job `trigger-argocd-install` tem o `owner`
hardcoded. Se o valor hardcoded não bater com o git remote dos seus repos,
o `createWorkflowDispatch` retorna 404.

### Solução

**Já corrigido no repo** para `owner = 'tech-tm'`.

Se o seu fork estiver em outra organização, atualize em
`togglemaster-app/.github/workflows/terraform-apply.yml` (procure por
`const owner =`). Valide com `git remote -v` do repo `togglemaster-deploy`.

Observação: mesmo com o owner certo, o job depende do secret
`PERSONAL_ACCESS_TOKEN` com escopo `repo` configurado no `togglemaster-app`.
Se o PAT estiver ausente ou expirado, o job também falha — nesse caso
rode `Install ArgoCD` manualmente pela UI do `togglemaster-deploy`.

---

## 8. Credenciais AWS Academy expiradas

### Sintoma

Qualquer workflow falha com:

```text
An error occurred (ExpiredToken) when calling the ... operation:
The security token included in the request is expired
```

### Causa

A sessão do AWS Academy dura **4 horas**. As credenciais no GitHub Secrets
viraram abóbora.

### Solução

1. Reabrir o Learner Lab no AWS Academy.
2. Clicar em "AWS Details" → copiar as 3 credenciais novas.
3. Em **cada repo** (`togglemaster-app` e `togglemaster-deploy`):
   Settings → Secrets and variables → Actions → atualizar:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`
   - `AWS_SESSION_TOKEN`
4. Localmente também, se usa `aws` CLI:
   ```bash
   nano ~/.aws/credentials
   # cola as novas credenciais
   ```
5. Re-rodar o workflow que falhou.

> O workflow `Preflight Check` detecta credenciais expiradas no primeiro step.
> Rodar ele é a maneira mais rápida de confirmar o problema.

---

## 9. Monitor do Datadog retorna HTTP 403

### Sintoma

Workflow `Alerts Deploy` falha com:

```text
HTTP 403
{"errors": ["Forbidden"]}
```

### Causa

Falta a **Application Key** (não é a API Key). API Key autoriza ingestão de
dados; App Key autoriza chamadas de **gerenciamento** da API (criar monitors,
dashboards, etc.).

### Solução

1. Datadog UI → avatar canto superior direito → **Organization Settings** →
   **Application Keys** → **New Key**.
2. Nome: `togglemaster-ci`.
3. Copie o valor.
4. Grave no SSM:
   ```bash
   aws ssm put-parameter --name "/togglemaster/prod/datadog/app-key" \
     --type SecureString --value "<DD_APP_KEY>" --overwrite
   ```
5. Rode `Alerts Deploy` de novo.

---

## 10. Self-Healing workflow não dispara pelo webhook

### Sintoma

Monitor do Datadog entra em `Alert`, JSM abre alerta, Slack notifica —
mas o workflow `Self-Healing Rollout` **não roda**.

### Causa

Pode ser:

- A — Webhook do Datadog com **PAT inválido/expirado** no header `Authorization`.
- B — URL do webhook aponta pro **repo errado**.
- C — **Payload do webhook não bate** com o `event_type: datadog-alert` que
  o workflow escuta.

### Solução

**Debug no painel do Datadog:**

Datadog UI → Integrations → **Webhooks** → `togglemaster-self-healing` →
aba de **execuções** → ver o status das últimas chamadas (HTTP code + body).

- **HTTP 401/403** → PAT inválido.
- **HTTP 404** → URL errada (owner ou repo).
- **HTTP 204** → disparou com sucesso! Problema está no workflow (checar
  aba Actions do GitHub).

**Teste manual direto da API do GitHub:**

```bash
curl -X POST \
  "https://api.github.com/repos/tech-tm/togglemaster-deploy/dispatches" \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: token <SEU_PAT>" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d '{
    "event_type": "datadog-alert",
    "client_payload": {
      "service": "auth-service",
      "alert_url": "test"
    }
  }'
```

- Se retornar 204 e o workflow aparece em Actions → URL/PAT estão OK, problema
  é no painel do Datadog.
- Se retornar erro → corrigir PAT ou URL antes.

---

## 11. OTel Collector CrashLoop: `invalid keys: address`

### Sintoma

```bash
kubectl logs -n observability deploy/otel-collector-opentelemetry-collector --tail=50
# Error: failed to get config: cannot unmarshal the configuration:
# 'service.telemetry.metrics' decoding failed due to the following error(s):
# 'migration.MetricsConfigV030' has invalid keys: address
```

Pod em `CrashLoopBackOff`, Application `otel-collector` fica `Degraded`.

### Causa

A chave `service.telemetry.metrics.address` foi **removida** no OpenTelemetry
Collector v0.123+ (migração para o padrão MetricReaders do OTel SDK). Se o
chart `opentelemetry-collector` do Helm puxar uma imagem contrib mais nova
que o seu values suporta, o config fica inválido.

### Solução

Já corrigido em `k8s/observability/applications/otel-collector.yaml`:

- Chave `service.telemetry.metrics.address` **removida** (as métricas internas
  do próprio collector não são requisito do Fase 4).
- Tag da imagem **fixada em `0.160.0`** pra evitar surpresas futuras:
  ```yaml
  image:
    repository: otel/opentelemetry-collector-contrib
    tag: "0.160.0"
  ```

Se precisar expor métricas internas no futuro, use a sintaxe nova:

```yaml
service:
  telemetry:
    metrics:
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888
```

---

## 12. Terraform EKS: `Error: Unauthorized` ao criar namespace

### Sintoma

```text
module.eks.aws_eks_node_group.nodes: Creation complete after 1m56s
module.eks.kubernetes_namespace.togglemaster: Creating...
│ Error: Unauthorized
│   with module.eks.kubernetes_namespace.togglemaster,
│   on ../../../modules/eks/main.tf line 88
```

### Causa

Anti-pattern clássico: criar o cluster EKS **e** um recurso Kubernetes
no mesmo `terraform apply`. O provider `kubernetes` resolve o token de
autenticação **cedo demais** (antes do plano de controle aceitar o caller
`LabRole`), causando `Unauthorized` ao chegar no `kubernetes_namespace`.

### Solução

Já corrigido em:

- `terraform/modules/eks/main.tf`: `resource "kubernetes_namespace" "togglemaster"` **removido**.
- `terraform/environments/prod/compute/main.tf`: provider `kubernetes` + `data "aws_eks_cluster_auth"` **removidos** (ficavam órfãos).

O namespace `togglemaster` é criado em 3 outros lugares (todos pós-cluster):

- Workflow `argocd-install.yml`
- Workflow `gitops.yml`
- Application do ArgoCD (`syncOption CreateNamespace=true`)

---

## 13. Pod `Pending`: `failed to assign an IP address`

### Sintoma

```text
FailedCreatePodSandBox   failed to setup network for sandbox ...
plugin type="aws-cni" name="aws-cni" failed (add):
add cmd: failed to assign an IP address to container
```

### Causa

O VPC CNI padrão do EKS tem **limite de IPs por nó** baseado no tipo de
instância. Para `t3.medium`: ~17 pods por nó. Se o cluster tiver 2 nós,
o teto é ~34 pods, e com Prometheus/Grafana/Loki/OTel + microsserviços
+ ArgoCD é fácil estourar.

**Isso NÃO é limitação específica do AWS Academy** — é limite do CNI padrão
da AWS. A solução ideal (prefix delegation via IRSA) **é** bloqueada pelo
AWS Academy por exigir criar IAM Role, mas a solução via mais nós funciona.

### Solução

Já corrigido em `terraform/environments/prod/compute/terraform.tfvars`:

```hcl
# Antes
desired_size = 2
# Depois
desired_size = 3
```

Com 3 nós `t3.medium`, a capacidade sobe pra ~51 pods — folga confortável.

**Após o apply**, se Jobs antigos ficaram marcados como falhos, limpa:

```bash
kubectl delete jobs -n observability \
  -l app.kubernetes.io/name=kube-prometheus-stack \
  --ignore-not-found

kubectl annotate application kube-prometheus-stack -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

---

## 14. Evaluation/Analytics: `NoCredentialProviders` (SQS/DynamoDB)

### Sintoma

Logs do `evaluation-service` ou `analytics-service`:

```text
Erro ao enviar mensagem para SQS: NoCredentialProviders:
no valid providers in chain. Deprecated.
```

### Causa

O SDK AWS procurou credenciais em todos os lugares padrão e não achou:

1. Env vars `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` — não setadas no pod.
2. `~/.aws/credentials` — não existe no container.
3. IRSA (IAM Role for Service Account) — **bloqueado pelo AWS Academy** (LabRole não pode criar IAM Role nova).

### Solução

Já corrigido em:

- `.github/workflows/secrets-sync.yml`: workflow agora adiciona
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
  no Secret `togglemaster-secrets` (vindos dos secrets do runner).
- `k8s/base/services/evaluation/deployment.yaml`: +3 envs `AWS_*` via `secretKeyRef`.
- `k8s/base/services/analytics/deployment.yaml`: idem.

**Importante**: como as credenciais são da sessão AWS Academy (duram ~4h),
**toda renovação de sessão exige re-rodar o GitOps** pra atualizar o Secret
k8s com as credenciais frescas:

```bash
cd togglemaster-deploy
git commit --allow-empty -m "chore: refresh aws session"
git push origin deploy
# espera ~3-5 min pelo GitOps terminar
kubectl rollout restart deployment evaluation-service analytics-service -n togglemaster
```

Protocolo completo: ver seção **"Renovação de sessão AWS Academy"** em `DEPLOY.md`.

---

## 15. OTel Collector ingestão 403: API Key errada no SSM

### Sintoma

Logs do collector:

```text
error  datadogexporter  Error posting hostname/tags series
error: "Permanent error: 403 Forbidden"
API Key invalid (403 response), dropping transaction
```

Datadog APM **vazio**, nenhum serviço aparece em "APM → Services".

### Causa

Confusão entre **API Key** e **Application Key** do Datadog. Elas servem pra
coisas diferentes:

| Credencial | Prefixo | Pra que serve | Vai em |
|---|---|---|---|
| **API Key** (DD_API_KEY) | **sem prefixo** — 32 chars hex puros | Ingestão de dados (traces, metrics, logs) | `/togglemaster/prod/datadog/api-key` |
| **Application Key** (DD_APP_KEY) | `ddpat_...` ou 40 chars hex | Chamar a API (criar monitors, dashboards) | `/togglemaster/prod/datadog/app-key` |

Erro comum: gravar a Application Key no slot da API Key. A Application Key
não autoriza ingestão → 403 Forbidden.

### Diagnóstico (teste direto na API)

```bash
API_KEY=$(kubectl get secret datadog-secret -n observability \
  -o jsonpath='{.data.api-key}' | base64 -d)
SITE=$(kubectl get secret datadog-secret -n observability \
  -o jsonpath='{.data.site}' | base64 -d)

echo "comprimento: $(echo -n "$API_KEY" | wc -c) chars"
echo "prefixo ddpat_? $(echo "$API_KEY" | grep -c '^ddpat_')"

curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  "https://api.$SITE/api/v1/validate" \
  -H "DD-API-KEY: $API_KEY"
# 200 {"valid":true}  → key correta
# 403                 → não é API Key
# 404                 → site errado
```

### Solução

1. Datadog UI → avatar → **Organization Settings** → **API Keys** (não "Application Keys").
2. Clique numa key existente ou **New Key**; copie o valor (**32 chars hex, sem prefixo**).
3. Grava no SSM:
   ```bash
   aws ssm put-parameter --name "/togglemaster/prod/datadog/api-key" \
     --type SecureString --value "<32_CHARS_HEX>" --overwrite
   ```
4. Re-sincroniza o Secret:
   ```bash
   # Pelo workflow:
   # togglemaster-deploy → Actions → Sync Datadog Secret from SSM → Run

   # Ou manual:
   DD_API_KEY=$(aws ssm get-parameter --name "/togglemaster/prod/datadog/api-key" \
     --with-decryption --query "Parameter.Value" --output text)
   DD_SITE=$(aws ssm get-parameter --name "/togglemaster/prod/datadog/site" \
     --query "Parameter.Value" --output text 2>/dev/null || echo "datadoghq.com")
   kubectl create secret generic datadog-secret -n observability \
     --from-literal=api-key="$DD_API_KEY" \
     --from-literal=site="$DD_SITE" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
5. Rolla o collector:
   ```bash
   kubectl rollout restart deployment \
     otel-collector-opentelemetry-collector -n observability
   ```

---

## 16. Ingress retorna 404 ao acessar endpoints dos microsserviços

### Sintoma

```bash
curl "http://$INGRESS/evaluate?user_id=u1&flag_name=test"
# HTTP/1.1 404 Not Found
```

### Causa

O `togglemaster-ingress` usa **prefixos por serviço** com `rewrite-target: /$2`.
O nginx-ingress só roteia requisições que batem com um dos prefixos.
Chamadas sem prefixo retornam 404 do nginx default backend.

### Mapa correto das rotas

| URL externa | Vai pro serviço | Vira no backend |
|---|---|---|
| `/validate/<path>` | auth-service | `/<path>` |
| `/flag/<path>` | flag-service | `/<path>` |
| `/targeting/<path>` | targeting-service | `/<path>` |
| `/evaluation/<path>` | evaluation-service | `/<path>` |
| `/analytics/<path>` | analytics-service | `/<path>` |

### Exemplos corretos

```bash
# health dos 5 serviços
for route in validate flag targeting evaluation analytics; do
  curl -s -o /dev/null -w "%s/health → %{http_code}\n" "$route" "http://$INGRESS/$route/health"
done

# chamada ao evaluate (note o prefixo /evaluation/)
curl "http://$INGRESS/evaluation/evaluate?user_id=u1&flag_name=test"

# listar flags (prefixo /flag/)
curl "http://$INGRESS/flag/flags" -H "Authorization: Bearer anything"
```

Fonte: `k8s/base/ingress.yaml`.

---

## 18. Application `togglemaster` fica `OutOfSync` em `/spec/replicas`

### Sintoma

Na UI do ArgoCD, Application `togglemaster` fica `OutOfSync + Healthy`. No diff aparece algo tipo:

```text
apps/Deployment/togglemaster/evaluation-service

spec:
  progressDeadlineSeconds: 600
  replicas: 2             ← no cluster (ajustado pelo HPA)
  replicas: 3             ← no Git (overlay prod)
  revisionHistoryLimit: 2
```

### Causa

Conflito clássico entre **HPA** (HorizontalPodAutoscaler) e **ArgoCD**:

- O Git declara `replicas: N` (via `k8s/overlays/prod/kustomization.yaml`).
- Mas existe um `HorizontalPodAutoscaler` (`k8s/base/services/{evaluation,analytics}/hpa.yaml`) que **sobrescreve esse valor em runtime** conforme carga de CPU/memória.
- ArgoCD compara desired state (Git) com live state (cluster) → sempre diferente quando o HPA está ativo.
- `selfHeal: true` tentaria reverter o HPA, criando uma guerra que o HPA sempre vence.

### Solução

Já corrigido em `k8s/application.yaml` da Application `togglemaster`:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    name: evaluation-service
    jsonPointers:
      - /spec/replicas
  - group: apps
    kind: Deployment
    name: analytics-service
    jsonPointers:
      - /spec/replicas
syncPolicy:
  syncOptions:
    - RespectIgnoreDifferences=true  # essencial com selfHeal
```

- O `ignoreDifferences` diz pro ArgoCD **ignorar** o campo `/spec/replicas` nesses 2 Deployments específicos.
- `RespectIgnoreDifferences=true` nas `syncOptions` garante que o `selfHeal` **também** respeite esse ignore (sem ele, o selfHeal reverteria o HPA).

### Como forçar re-sincronização após o fix

```bash
kubectl annotate application togglemaster -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

Em ~30s a Application deve ir pra `Synced + Healthy`.

### Boa prática: nunca declare replicas num Deployment com HPA

Se um Deployment tem HPA, o ideal seria **não declarar `replicas:`** no manifest base — deixa o HPA ser a única fonte de verdade. Mas nesse projeto o overlay prod seta `replicas` explicitamente (via `kustomize patches`), então optamos por manter e usar `ignoreDifferences` em vez de refatorar.

---

## 17. `InvalidSignatureException` ao chamar AWS no workflow

### Sintoma

Workflow falha num step que chama `aws` (ex: `Get cluster name from SSM`):

```text
aws: [ERROR]: An error occurred (InvalidSignatureException) when calling
the GetParameter operation: The request signature we calculated does not
match the signature you provided. Check your AWS Secret Access Key and
signing method.
```

### Causa

**Não é** credenciais expiradas (seria `ExpiredToken`). É uma de duas coisas:

1. **As 3 credenciais no GitHub Secrets são de sessões diferentes.** Muito
   comum no AWS Academy: você renova o lab, atualiza `AWS_ACCESS_KEY_ID`,
   mas esquece de atualizar `AWS_SECRET_ACCESS_KEY` ou `AWS_SESSION_TOKEN`.
   O mix de credenciais gera uma assinatura inválida.

2. **`AWS_SECRET_ACCESS_KEY` corrompido no copy/paste** — whitespace invisível
   no fim, quebra de linha, caractere `+`/`/`/`=` escapado errado pelo browser.

### Solução

**Protocolo correto de renovação** (seção também em `DEPLOY.md`):

1. Reabrir o Learner Lab no AWS Academy.
2. Clicar em **AWS Details** → copiar as **3 credenciais na mesma sessão**.
3. Em **cada repo** (`togglemaster-app` E `togglemaster-deploy`):
   Settings → Secrets and variables → Actions → atualizar **as 3 ao mesmo tempo**:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`
   - `AWS_SESSION_TOKEN`

> Ao colar no GitHub, confira que não há espaços antes/depois do valor.
> O GitHub NÃO trim espaços automaticamente.

### Validar localmente antes de retentar o workflow

```bash
# Atualiza o ~/.aws/credentials com as mesmas 3 credenciais
nano ~/.aws/credentials

# Testa — se funcionar local, funciona no workflow
aws sts get-caller-identity --profile aws_fiap
# Esperado: JSON com UserId, Account, Arn
# Erro: SignatureDoesNotMatch | InvalidSignatureException  → credenciais desalinhadas, renove TODAS as 3
```

### Prevenção (já aplicada)

- O workflow `argocd-install.yml` agora tem um step
  **"Validar credenciais AWS (sts get-caller-identity)"** logo após
  `Configure AWS credentials`. Se as credenciais estiverem erradas, falha
  cedo com mensagem clara em vez de confundir o diagnóstico depois.

---

## 19. Terraform: `ResourceNotFoundException` ao fazer apply

### Sintoma

Workflow **Terraform Apply** falha com erro parecido com:

```text
Error: listing tags for ECR (Elastic Container Registry) Repository
(arn:aws:ecr:...:136035252239:repository/flag-service): operation error
ECR: ListTagsForResource, https response error StatusCode: 400,
RepositoryNotFoundException: The repository with name 'flag-service'
does not exist in the registry with id '136035252239'
```

Pode acontecer com **qualquer tipo de recurso AWS** (ECR, RDS, Redis,
EKS, SQS, DynamoDB), não só ECR. A mensagem muda de nome do erro, mas
o padrão é o mesmo: "o recurso não existe".

### Causa — state drift

O arquivo `terraform.tfstate` (armazenado no S3 bucket, ex: `tech4-tfstates`)
é um **inventário** do que o Terraform acredita existir na AWS. Esse
inventário pode ficar **desalinhado** com a realidade:

```text
State no S3:        "existe 1 ECR chamado flag-service"
AWS de verdade:     "nao existe nenhum ECR com esse nome"
                    (foi destruido fora do Terraform ou destroy anterior falhou)
Terraform Apply:    tenta ler as tags do ECR → RepositoryNotFoundException
```

### Causa mais comum: destroy parcial no AWS Academy

A sessão AWS Academy expira em 4h. Se um `terraform destroy` começar perto
do fim da sessão:

1. Terraform destrói recursos um por um na AWS.
2. Sessão expira no meio.
3. State no S3 fica em estado intermediário: alguns recursos marcados
   como destruídos, outros como "ainda existem" (mas na AWS já foram).
4. Próximo `apply` lê o state desatualizado e tenta operar em recursos
   que não existem mais.

### Prevenção automática (já aplicada)

O workflow **Terraform Apply** foi atualizado para fazer `terraform refresh`
antes de qualquer `apply`, em **todas as 5 camadas** (`security`, `data`,
`platform`, `compute`, `networking`). O refresh sincroniza o state com a
AWS real: remove do state recursos destruídos fora do Terraform.

Procure por esse step em cada job:

```yaml
- name: Refresh State (detect and reconcile drift)
  run: |
    terraform plan -refresh-only -detailed-exitcode -out=refresh.tfplan
    # Se detectar drift (exit code 2), aplica o refresh pra sincronizar
```

### Diagnóstico pontual (verificar sem aplicar)

Existe um workflow dedicado **Terraform State Check** que apenas verifica
drift em todas as 5 camadas, sem fazer alterações:

```text
togglemaster-app → Actions → Terraform State Check → Run workflow
```

Output: tabela no `$GITHUB_STEP_SUMMARY` mostrando qual camada tem drift.
Com o input `auto_reconcile: true`, aplica refresh automaticamente.

### Fix manual (se o workflow ainda falhar)

Caso raro em que o refresh automático também falha (ex: recurso órfão
com referência circular), remover do state manualmente:

```bash
# 1. Precisa de credenciais AWS + Terraform local
cd togglemaster-app/terraform/environments/prod/<camada-com-problema>

# 2. Init com o backend
terraform init \
  -backend-config="bucket=$BUCKET_STATE" \
  -backend-config="key=prod/<camada>/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -reconfigure

# 3. Lista os recursos no state
terraform state list

# 4. Pra cada recurso problemático, confere se existe na AWS; se não existir, remove
# Exemplo pro ECR:
for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  if ! aws ecr describe-repositories --repository-names "$svc" --profile aws_fiap >/dev/null 2>&1; then
    echo "Removendo $svc do state (nao existe na AWS)"
    terraform state rm "module.ecr.aws_ecr_repository.repositories[\"$svc\"]"
  fi
done

# 5. Rodar o workflow 'Terraform Apply' normalmente — vai recriar o que faltar
```

### Por que o S3 (`tech4-tfstates`) não previne isso

O S3 **só armazena** o state. Não garante que o conteúdo bate com a AWS.
É como um cofre que guarda um inventário: se o inventário está escrito
errado, o cofre não corrige — só mantém o papel seguro.

As ferramentas que **corrigem** o conteúdo do state são:

- `terraform refresh` / `terraform plan -refresh-only` — sincroniza state com AWS.
- `terraform state rm` — remove do state recursos fantasma.
- `terraform import` — adiciona ao state recursos que existem na AWS mas foram criados fora do Terraform.

---

## Diagnóstico rápido (comandos úteis em qualquer situação)

```bash
# Credenciais AWS funcionando?
aws sts get-caller-identity

# Cluster acessível?
kubectl get nodes

# Estado de todos os namespaces chave
kubectl get pods -A | grep -E "argocd|togglemaster|observability"

# Todas as Applications do ArgoCD
kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

# Últimos eventos num namespace
kubectl get events -n <ns> --sort-by='.lastTimestamp' | tail -20

# Logs do argocd-application-controller (quem faz os diffs)
kubectl logs -n argocd statefulset/argocd-application-controller --tail=100

# FIM
```
