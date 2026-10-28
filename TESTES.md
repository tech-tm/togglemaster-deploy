# Testes de Validação

Checklist de testes **automatizáveis** e **visuais** para validar o funcionamento
da plataforma, por bloco técnico da Fase 4.

- Use **antes de gravar o vídeo** da entrega (smoke test completo).
- Use **a cada renovação de sessão AWS Academy** para confirmar que nada quebrou.
- Use **após qualquer mudança** (push na `deploy`) para validar o impacto.

> **Convenção**: cada teste tem **O que executar** (comando) e **O que esperar**
> (saída). Se o esperado não bater, veja `TROUBLESHOOTING.md`.

---

## Índice

- [Pré-requisitos](#pré-requisitos)
- [T0 — Preflight (ambiente externo)](#t0--preflight-ambiente-externo)
- [T1 — Bloco 1: Prometheus + Grafana + Loki + Dashboard](#t1--bloco-1-prometheus--grafana--loki--dashboard)
- [T2 — Bloco 2: OTel Collector](#t2--bloco-2-otel-collector)
- [T3 — Bloco 3: Instrumentação + APM + Service Map](#t3--bloco-3-instrumentação--apm--service-map)
- [T4 — Bloco 4: Alertas + JSM + Slack + Self-Healing](#t4--bloco-4-alertas--incident-management--chatops--self-healing)
- [T5 — Teste end-to-end (incidente proposital + self-healing)](#t5--teste-end-to-end-incidente-proposital--self-healing)
- [Script tudo-em-um (smoke test rápido)](#script-tudo-em-um-smoke-test-rápido)

---

## Pré-requisitos

Ter rodado todas as Fases 0-6 do [`DEPLOY.md`](./DEPLOY.md). Para rodar os
testes:

```bash
# AWS CLI apontando pra sessão ativa
aws sts get-caller-identity --profile aws_fiap   # confirma credenciais

# kubectl apontando pro cluster
aws eks update-kubeconfig --region us-east-1 --name togglemaster-eks
kubectl get nodes
```

---

## T0 — Preflight (ambiente externo)

Valida que o ambiente externo ao cluster está pronto. **Equivale ao workflow
`Preflight Check`.**

### T0.1 — Credenciais AWS válidas

**Executar:**
```bash
aws sts get-caller-identity --profile aws_fiap
```

**Esperar:** JSON com `UserId`, `Account`, `Arn`. Erro = sessão expirou (renove no Learner Lab).

### T0.2 — SSM parameters obrigatórios

**Executar:**
```bash
for p in \
  "/togglemaster/prod/cluster-name" \
  "/togglemaster/prod/auth/credentials" \
  "/togglemaster/prod/flag/credentials" \
  "/togglemaster/prod/targeting/credentials" \
  "/togglemaster/prod/redis/credentials" \
  "/togglemaster/prod/datadog/api-key" \
  "/togglemaster/prod/datadog/app-key"; do
    aws ssm get-parameter --name "$p" --with-decryption \
      --query "Parameter.Name" --output text --profile aws_fiap 2>&1 \
      | sed 's|/togglemaster/prod/||'
done
```

**Esperar:** cada parâmetro listado sem erro. Se aparecer `ParameterNotFound`, criar via `aws ssm put-parameter`.

### T0.3 — Datadog API key válida (ingestão)

**Executar:**
```bash
API_KEY=$(aws ssm get-parameter \
  --name "/togglemaster/prod/datadog/api-key" \
  --with-decryption --query "Parameter.Value" --output text --profile aws_fiap)
SITE=$(aws ssm get-parameter \
  --name "/togglemaster/prod/datadog/site" \
  --query "Parameter.Value" --output text --profile aws_fiap 2>/dev/null \
  || echo "datadoghq.com")

curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  "https://api.$SITE/api/v1/validate" \
  -H "DD-API-KEY: $API_KEY"
```

**Esperar:** `HTTP 200`. Qualquer outra coisa = key errada (ver TROUBLESHOOTING #15).

---

## T1 — Bloco 1: Prometheus + Grafana + Loki + Dashboard

Valida a stack open source de monitoramento.

### T1.1 — Pods da observabilidade todos Running

**Executar:**
```bash
kubectl get pods -n observability \
  --field-selector=status.phase!=Running
```

**Esperar:** `No resources found` (ou lista vazia). Qualquer pod aparecendo = problema.

### T1.2 — ArgoCD Applications da observabilidade Synced + Healthy

**Executar:**
```bash
kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  | grep -E "observability|kube-prometheus-stack|loki-stack|grafana-config"
```

**Esperar:** cada linha com `Synced` + `Healthy`. `OutOfSync + Healthy` = pods ok, mas Git divergente (sync manual pode resolver).

### T1.3 — Dashboard customizado existe no Grafana

**Executar:**
```bash
kubectl get cm -n observability grafana-dashboard-togglemaster \
  -o jsonpath='{.metadata.labels}'
```

**Esperar:** `{"grafana_dashboard":"1",...}` (o label `grafana_dashboard:"1"` é o que faz o sidecar importar).

### T1.4 — Grafana acessível (teste visual)

**Executar:**
```bash
# Em um terminal separado
kubectl port-forward -n observability \
  svc/kube-prometheus-stack-grafana 3000:80
```

Abrir no browser: `http://localhost:3000`
- Usuário: `admin`
- Senha: `togglemaster`

**Esperar visualmente:**
- [ ] Login funciona
- [ ] Menu Dashboards → "ToggleMaster - Visao Geral do Ecossistema" existe
- [ ] Abrindo o dashboard: painéis "CPU por pod", "Memória por pod", "Taxa de erros 5xx" e **painel Loki** carregam
- [ ] Painel Loki mostra logs em tempo real do namespace `togglemaster`

### T1.5 — Prometheus coletando métricas

**Executar:**
```bash
# port-forward em terminal separado
kubectl port-forward -n observability \
  svc/kube-prometheus-stack-prometheus 9090:9090 &

sleep 2
# Pergunta "up" (quantos targets estão vivos)
curl -s "http://localhost:9090/api/v1/query?query=up" \
  | grep -oE '"value":\[[^]]+\]' | wc -l

# Encerra port-forward
kill %1 2>/dev/null
```

**Esperar:** número > 0 (quantidade de targets up).

---

## T2 — Bloco 2: OTel Collector

Valida que o collector está rodando e exportando pro Datadog.

### T2.1 — Pod do Collector Running

**Executar:**
```bash
kubectl get pods -n observability \
  -l app.kubernetes.io/name=opentelemetry-collector
```

**Esperar:** 1 pod `Running 1/1`.

### T2.2 — Secret datadog-secret existe

**Executar:**
```bash
kubectl get secret datadog-secret -n observability \
  -o jsonpath='{.data}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(sorted(d.keys()))"
```

**Esperar:** `['api-key', 'site']`.

### T2.3 — Collector sem erros de ingestão

**Executar:**
```bash
kubectl logs -n observability \
  deploy/otel-collector-opentelemetry-collector \
  --since=10m 2>/dev/null \
  | grep -iE "403|forbidden|invalid.*key" \
  | wc -l
```

**Esperar:** `0`.

### T2.4 — Collector está exportando (traces visíveis nos logs)

**Executar:**
```bash
# Primeiro gera um pouco de tráfego
INGRESS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for i in {1..10}; do
  curl -s -o /dev/null "http://$INGRESS/evaluation/evaluate?user_id=u$i&flag_name=test"
done

sleep 10

# Procura evidencia de recebimento de traces
kubectl logs -n observability \
  deploy/otel-collector-opentelemetry-collector \
  --since=2m 2>/dev/null | grep -iE "trace|span" | tail -3
```

**Esperar:** pelo menos uma linha com `trace` ou `span` nos logs recentes.

---

## T3 — Bloco 3: Instrumentação + APM + Service Map

Valida que os 5 microsserviços estão instrumentados e enviando telemetria.

### T3.1 — Pods togglemaster todos Running

**Executar:**
```bash
kubectl get pods -n togglemaster \
  --field-selector=status.phase!=Running
```

**Esperar:** `No resources found`.

### T3.2 — Envs OTEL nos 5 serviços

**Executar:**
```bash
for svc in auth flag targeting evaluation analytics; do
  count=$(kubectl exec -n togglemaster deploy/${svc}-service -- env 2>/dev/null \
    | grep -c "^OTEL_")
  echo "$svc-service: $count envs OTEL_*"
done
```

**Esperar:**
- Go (auth, evaluation): mínimo 4 cada
- Python (flag, targeting, analytics): mínimo 6 cada

### T3.3 — Credenciais AWS no evaluation e analytics

**Executar:**
```bash
for svc in evaluation analytics; do
  count=$(kubectl exec -n togglemaster deploy/${svc}-service -- env 2>/dev/null \
    | grep -cE "^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)")
  echo "$svc-service: $count credenciais AWS (esperado: 3)"
done
```

**Esperar:** `3` em cada.

### T3.4 — Zero erros de SQS NoCredentialProviders

**Executar:**
```bash
kubectl logs -n togglemaster deploy/evaluation-service --since=10m 2>/dev/null \
  | grep -iE "nocredentialproviders|credential.*chain" \
  | wc -l
```

**Esperar:** `0`.

### T3.5 — Ingress respondendo nos 5 serviços

**Executar:**
```bash
INGRESS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

for route in validate flag targeting evaluation analytics; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://$INGRESS/$route/health")
  echo "/$route/health → HTTP $code"
done
```

**Esperar:** `HTTP 200` em todas as 5 rotas.

### T3.6 — Service Map populado no Datadog (teste visual)

**Executar:** gere carga:
```bash
INGRESS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for i in {1..30}; do
  curl -s -o /dev/null "http://$INGRESS/evaluation/evaluate?user_id=u$i&flag_name=test"
done
```

Aguardar 2-3 min. Abrir Datadog UI:

**Esperar visualmente:**
- [ ] **APM → Services** lista os 5 serviços (auth, flag, targeting, evaluation, analytics)
- [ ] **APM → Service Map** mostra setas:
  - evaluation → auth
  - evaluation → flag
  - evaluation → targeting
  - flag → auth
  - targeting → auth
- [ ] Clicando em um trace do `evaluation-service`: aparecem spans aninhados dos 3 serviços chamados

**Importante**: `analytics` aparece **só depois** que o SQS entregar mensagens pra ele (pode levar mais tempo).

---

## T4 — Bloco 4: Alertas + Incident Management + ChatOps + Self-Healing

Valida configuração do bloco reativo. **Depende do setup manual em contas externas** (Jira Service Management + Slack + Datadog webhook).

### T4.1 — Monitor do Datadog criado

**Executar:**
```bash
API_KEY=$(aws ssm get-parameter --name "/togglemaster/prod/datadog/api-key" \
  --with-decryption --query "Parameter.Value" --output text --profile aws_fiap)
APP_KEY=$(aws ssm get-parameter --name "/togglemaster/prod/datadog/app-key" \
  --with-decryption --query "Parameter.Value" --output text --profile aws_fiap)
SITE=$(aws ssm get-parameter --name "/togglemaster/prod/datadog/site" \
  --query "Parameter.Value" --output text --profile aws_fiap 2>/dev/null \
  || echo "datadoghq.com")

curl -s "https://api.$SITE/api/v1/monitor" \
  -H "DD-API-KEY: $API_KEY" \
  -H "DD-APPLICATION-KEY: $APP_KEY" \
  | python3 -c "
import json, sys
monitors = json.load(sys.stdin)
tm = [m for m in monitors if 'ToggleMaster' in m.get('name','')]
for m in tm:
    print(f\"ID {m['id']}: {m['name']}\")
    print(f\"  status: {m.get('overall_state','?')}\")
"
```

**Esperar:** 1 monitor `[ToggleMaster] auth-service - taxa de erros 5xx > 5%` com status `OK` ou `No Data`.

### T4.2 — Workflow `Self-Healing Rollout` existe

**Executar:**
```bash
# Checa que o arquivo existe no repo e esta valido
test -f .github/workflows/self-healing.yml && echo "✓ existe"
python3 -c "import yaml; list(yaml.safe_load_all(open('.github/workflows/self-healing.yml')))" && echo "✓ YAML valido"
```

**Esperar:** `✓ existe` e `✓ YAML valido`.

### T4.3 — Setup externo (teste visual)

Verifica no painel das ferramentas:

- [ ] **JSM**: site criado (`<seunome>.atlassian.net`) + módulo Operations ativo + integração "Datadog" ativa (Settings → Operations → Integrations)
- [ ] **Slack**: canal `#alerts` configurado + bot JSM adicionado + integração Slack ativa no JSM
- [ ] **Datadog**: integração **Jira Service Management Ops** instalada (Integrations → busca "Jira Service Management Ops")
- [ ] **Datadog**: webhook `togglemaster-self-healing` configurado (Integrations → Webhooks) apontando pro `repository_dispatch` do GitHub

### T4.4 — Trigger manual do Self-Healing (teste de fumaça)

**Executar:**

GitHub → `togglemaster-deploy` → Actions → **Self-Healing Rollout** → Run workflow:
- `service`: `auth-service`
- `alert_url`: `manual-test`

**Esperar:**
- Workflow termina com status ✅.
- Resumo mostra `kubectl rollout restart deployment auth-service -n togglemaster` executado.
- `kubectl rollout status` mostra sucesso.

```bash
# Confirma localmente
kubectl rollout history deployment auth-service -n togglemaster | tail -5
```

**Esperar:** uma linha nova de revisão com timestamp recente.

---

## T5 — Teste end-to-end (incidente proposital + self-healing)

**Esse é o teste decisivo para o vídeo da entrega.** Causa falha proposital no cluster, observa alerta disparar, JSM abrir alerta, Slack notificar e o self-healing agir.

### T5.1 — Preparação

```bash
# Garante kubectl acessível, Datadog recebendo tráfego regular
INGRESS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Ingress: http://$INGRESS"
```

### T5.2 — Causar falha

**Opção A — Simular 5xx no auth** (recomendado, menos invasivo):

```bash
# Derruba o auth-service para forçar erros 5xx no evaluation
kubectl scale deployment auth-service -n togglemaster --replicas=0
```

### T5.3 — Gerar carga que force o alerta

```bash
INGRESS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Carga em paralelo para gerar muitos 5xx
for i in {1..500}; do
  curl -s -o /dev/null "http://$INGRESS/evaluation/evaluate?user_id=u$i&flag_name=test" &
done
wait
echo "✓ 500 requisições enviadas"
```

### T5.4 — Observar reação (próximos ~5-10 min)

Monitorar em 4 lugares em paralelo:

1. **Datadog → Monitors**: o monitor `[ToggleMaster] auth-service - taxa de erros 5xx > 5%` entra em `Alert` (vermelho).
2. **JSM → Operations → Alerts**: alerta aberto automaticamente.
3. **Slack → canal `#alerts`**: notificação chega via integração JSM.
4. **GitHub → `togglemaster-deploy` → Actions → Self-Healing Rollout**: run novo com `trigger: datadog-webhook`.

### T5.5 — Validar o self-healing

```bash
# O auth-service deve ter sido escalado de volta (ou tentar)
kubectl rollout history deployment auth-service -n togglemaster | tail -5

# E deve haver uma restauração manual nos replicas se o self-healing
# executou um 'kubectl rollout restart' num deployment com replicas=0.
# Nesse caso faça manualmente:
kubectl scale deployment auth-service -n togglemaster --replicas=1
```

### T5.6 — Prints obrigatórios (relatório PDF)

Durante este teste, capture:

- [ ] **Grafana dashboard** com dados (CPU/Mem/Requests/Logs)
- [ ] **Datadog Service Map** com os 5 serviços conectados
- [ ] **Datadog Trace** distribuído de uma chamada `/evaluate`
- [ ] **Slack** canal `#alerts` com a notificação do incidente (via JSM)
- [ ] **GitHub Actions** → Self-Healing Rollout → log do `kubectl rollout restart`

---

## Script tudo-em-um (smoke test rápido)

Cola no terminal e roda — valida T1 a T3 em sequência:

```bash
#!/usr/bin/env bash
set +e
pass=0
fail=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "✓ $name"
    pass=$((pass+1))
  else
    echo "✗ $name"
    fail=$((fail+1))
  fi
}

echo "============================================================"
echo "SMOKE TEST — ToggleMaster"
echo "============================================================"

# T1
check "T1.1 Pods observability sem erro" bash -c 'test -z "$(kubectl get pods -n observability --field-selector=status.phase!=Running -o name 2>/dev/null)"'
check "T1.3 Dashboard ConfigMap existe" kubectl get cm grafana-dashboard-togglemaster -n observability

# T2
check "T2.1 Pod OTel Collector Running" bash -c 'kubectl get pods -n observability -l app.kubernetes.io/name=opentelemetry-collector --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -q .'
check "T2.2 Secret datadog-secret existe" kubectl get secret datadog-secret -n observability
check "T2.3 Zero erros 403 Datadog (10min)" bash -c '[ "$(kubectl logs -n observability deploy/otel-collector-opentelemetry-collector --since=10m 2>/dev/null | grep -ciE "403|forbidden|invalid.*key")" = "0" ]'

# T3
check "T3.1 Pods togglemaster sem erro" bash -c 'test -z "$(kubectl get pods -n togglemaster --field-selector=status.phase!=Running -o name 2>/dev/null)"'
check "T3.3 Evaluation tem 3 envs AWS" bash -c '[ "$(kubectl exec -n togglemaster deploy/evaluation-service -- env 2>/dev/null | grep -cE "^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)")" = "3" ]'
check "T3.4 Zero erros SQS NoCredentialProviders" bash -c '[ "$(kubectl logs -n togglemaster deploy/evaluation-service --since=10m 2>/dev/null | grep -ciE "nocredentialproviders")" = "0" ]'

INGRESS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$INGRESS" ]; then
  for route in validate flag targeting evaluation analytics; do
    check "T3.5 Ingress /$route/health HTTP 200" bash -c "[ \$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'http://$INGRESS/$route/health') = '200' ]"
  done
fi

echo
echo "============================================================"
echo "Resultado: $pass passaram / $fail falharam"
echo "============================================================"
```

Se todos passarem → stack técnica validada. Siga para T4/T5 (visuais + end-to-end).
