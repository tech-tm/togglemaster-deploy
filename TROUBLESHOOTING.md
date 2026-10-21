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

**Clusters novos**: já vem corrigido via `k8s/argocd/values.yaml` quando o workflow `Install ArgoCD` roda.

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

O script `github-script` tem o `owner` hardcoded com valor que **não bate** com
o git remote dos seus repos. Trecho em `togglemaster-app/.github/workflows/terraform-apply.yml`:

```javascript
const owner = 'togglemaster-fiapdevops';
```

Mas o remote real pode ser outro (ex: `tech-tm`).

### Solução

**Opção A** (recomendada): ignorar o erro. Esse job é opcional — depois do
Terraform terminar, você mesmo roda `Install ArgoCD` manualmente pela UI.

**Opção B**: corrigir o owner no arquivo. Em
`togglemaster-app/.github/workflows/terraform-apply.yml`, trocar:

```javascript
const owner = 'togglemaster-fiapdevops';
```

Por:

```javascript
const owner = '<org-correta>';   // ex: 'tech-tm'
```

Validar com `git remote -v` do repo `togglemaster-deploy`.

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

Monitor do Datadog entra em `Alert`, OpsGenie abre incidente, Discord notifica —
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
```
