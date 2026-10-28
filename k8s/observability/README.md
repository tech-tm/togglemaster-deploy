# Observabilidade (Fase 4) — Blocos 1 e 2

Stack de observabilidade do ToggleMaster, provisionada via **GitOps/ArgoCD** no cluster EKS.
Nada é aplicado manualmente: o ArgoCD sincroniza os Helm charts diretamente dos repositórios oficiais.

## Componentes

| Componente | Origem | Função | Bloco |
|---|---|---|---|
| **Prometheus** | chart `kube-prometheus-stack` | Métricas de infraestrutura | 1 |
| **Grafana** | chart `kube-prometheus-stack` | Visualização (dashboards + logs) | 1 |
| **Loki** | chart `loki-stack` | Centralização e indexação dos logs | 1 |
| **Promtail** | chart `loki-stack` | DaemonSet que coleta logs dos contêineres e envia ao Loki | 1 |
| **OTel Collector** | chart `opentelemetry-collector` (contrib) | Peça central: recebe OTLP e roteia para Prometheus e Datadog | 2 |

Tudo roda no namespace `observability`.

## Arquitetura GitOps (App of Apps)

```text
app-of-apps.yaml  (Application pai, aplicada no bootstrap via envsubst)
        │
        └── k8s/observability/applications/
              ├── kube-prometheus-stack.yaml   → Helm: Prometheus + Grafana
              ├── loki-stack.yaml              → Helm: Loki + Promtail
              ├── otel-collector.yaml          → Helm: OTel Collector (contrib)
              └── grafana-config.yaml          → ConfigMaps (datasource Loki + dashboard)
```

- As Applications de Helm apontam **direto** para os repositórios de charts oficiais —
  sem renderizar, o ArgoCD resolve o Helm.
- O `grafana-config` aplica os manifests da pasta `grafana/` (datasource do Loki e o
  dashboard customizado) via Kustomize.

## Fluxo de telemetria (Bloco 2)

```text
                                      ┌─────────────────────┐
                                      │  Microsserviços     │
                                      │  (OTel SDK)         │
                                      └──────────┬──────────┘
                                                 │ OTLP (gRPC :4317 / HTTP :4318)
                                                 ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  OTel Collector (contrib)  —  namespace observability         │
   │                                                               │
   │  receivers.otlp ──► processors ──► exporters                  │
   │                     ├─ memory_limiter    ├─ datadog  ──► APM  │
   │                     ├─ k8sattributes     ├─ prometheus (:8889) │
   │                     ├─ resource          └─ debug             │
   │                     └─ batch                                  │
   └───────────────────────────────┬──────────────────────────────┘
                                   │ scrape (ServiceMonitor)
                                   ▼
                             Prometheus
                                   │
                                   ▼
                              Grafana (dashboard)

   # Em paralelo, Promtail (DaemonSet) continua coletando os logs
   # de container (stdout/stderr) e enviando ao Loki para o painel
   # de logs em tempo real do Grafana.
```

**Pipelines configurados** (ver `applications/otel-collector.yaml`):
- `traces` → Datadog
- `metrics` → Datadog + Prometheus (via scrape em `:8889`)
- `logs` → Datadog (logs estruturados da aplicação; logs de container ficam com o Promtail)

## Dashboard customizado

`grafana/dashboard-togglemaster.yaml` é um ConfigMap (label `grafana_dashboard: "1"`)
que o sidecar do Grafana importa automaticamente. Cobre os 3 painéis exigidos pelo PDF:

1. **Uso de recursos do cluster** — CPU e memória por pod do namespace `togglemaster`.
2. **Taxa de requisições dos microsserviços** — req/s e taxa de erros 5xx por serviço
   (depende da instrumentação OTel do Bloco 3).
3. **Logs em tempo real** — painel de logs do Loki filtrado por `namespace="togglemaster"`.

## Pré-requisito do Bloco 2: Secret do Datadog

O OTel Collector precisa da `DD_API_KEY` para exportar para o Datadog. Seguindo o padrão
do projeto (secrets no SSM), armazene a chave em:

| SSM Parameter | Tipo | Obrigatório |
|---|---|---|
| `/togglemaster/prod/datadog/api-key` | SecureString | sim |
| `/togglemaster/prod/datadog/site` | String | não (default: `datadoghq.com`) |

Exemplo de criação dos parâmetros:

```bash
aws ssm put-parameter \
  --name "/togglemaster/prod/datadog/api-key" \
  --type SecureString \
  --value "<SUA_API_KEY_DO_DATADOG>" \
  --overwrite

aws ssm put-parameter \
  --name "/togglemaster/prod/datadog/site" \
  --type String \
  --value "datadoghq.com" \
  --overwrite
```

Depois, execute o workflow para criar o Secret `datadog-secret` no namespace `observability`:

- **GitHub Actions**: aba Actions → *Sync Datadog Secret from SSM* → *Run workflow*.
- **Local**:
  ```bash
  CLUSTER_NAME=$(aws ssm get-parameter --name "/togglemaster/prod/cluster-name" --query "Parameter.Value" --output text)
  aws eks update-kubeconfig --region us-east-1 --name "$CLUSTER_NAME"

  DD_API_KEY=$(aws ssm get-parameter --name "/togglemaster/prod/datadog/api-key" --with-decryption --query "Parameter.Value" --output text)
  DD_SITE=$(aws ssm get-parameter --name "/togglemaster/prod/datadog/site" --query "Parameter.Value" --output text 2>/dev/null || echo "datadoghq.com")

  kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic datadog-secret -n observability \
    --from-literal=api-key="$DD_API_KEY" \
    --from-literal=site="$DD_SITE" \
    --dry-run=client -o yaml | kubectl apply -f -
  ```

> O Secret precisa existir **antes** do pod do OTel Collector subir. Se o ArgoCD sincronizar
> primeiro, o pod fica em `CreateContainerConfigError` até o Secret aparecer — ele se recupera
> sozinho depois (self-heal).

## Como ativar a stack

Passo adicionado ao workflow `.github/workflows/argocd-install.yml`:

```yaml
- name: apply Observability (App of Apps)
  run: |
    export REPO_URL="https://github.com/${{ github.repository }}"
    envsubst < k8s/observability/app-of-apps.yaml | kubectl apply -f -
```

Ou manualmente (com `kubectl` apontando para o cluster e ArgoCD já instalado):

```bash
export REPO_URL="https://github.com/tech-tm/togglemaster-deploy"
envsubst < k8s/observability/app-of-apps.yaml | kubectl apply -f -
```

## Endpoint do OTel Collector (para o Bloco 3)

Dentro do cluster, os microsserviços devem enviar OTLP para:

```text
otel-collector-opentelemetry-collector.observability.svc.cluster.local:4317   # gRPC
otel-collector-opentelemetry-collector.observability.svc.cluster.local:4318   # HTTP
```

Variáveis padrão recomendadas nos deployments (serão adicionadas no Bloco 3):

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector-opentelemetry-collector.observability.svc.cluster.local:4317"
  - name: OTEL_SERVICE_NAME
    value: "auth-service"     # trocar por serviço
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "deployment.environment=prod"
```

## Acessar o Grafana

```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000  —  usuário: admin  /  senha: togglemaster
```

> A senha `togglemaster` é um placeholder. Em produção, trocar por um Secret do
> Kubernetes (ex: via SSM, como o restante do projeto).

## Observações para o AWS Academy (EKS / LabRole)

- `kubeControllerManager`, `kubeScheduler`, `kubeEtcd` e `kubeProxy` estão **desativados**
  nos values do `kube-prometheus-stack`: o control plane do EKS é gerenciado e não é
  acessível para scraping, então mantê-los ativos geraria alertas falsos de "target down".
- O Loki está em modo single-binary com storage **efêmero** (`persistence: false`),
  suficiente para a demonstração. Para produção, usar object storage (S3).
- O OTel Collector usa a imagem `opentelemetry-collector-contrib` porque só ela inclui
  o exporter `datadog`. A imagem "core" (`otel/opentelemetry-collector`) não funcionaria.

## Próximos blocos

- **Bloco 3** — Instrumentação OTel dos 5 microsserviços no `togglemaster-app`.
- **Bloco 4** — Alertas (5xx > 5%) + Jira Service Management + Slack + Self-Healing.
