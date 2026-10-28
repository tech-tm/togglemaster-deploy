# Alertas, Incidentes e Self-Healing (Fase 4 — Bloco 4)

Documentação da camada reativa do ToggleMaster: alertas inteligentes,
gerenciamento de incidentes, notificação ChatOps e automação de self-healing
(GitHub Actions).

Stack:

| Função | Produto |
|---|---|
| Observabilidade e alertas | **Datadog** |
| Incident management | **Jira Service Management Operations** (JSM Ops) |
| ChatOps | **Slack** |
| Self-healing | **GitHub Actions** (`repository_dispatch`) |

---

## Arquitetura

```mermaid
graph TD
    A[Microsservicos<br/>instrumentados OTel] -->|OTLP| B[OTel Collector]
    B -->|traces + metrics| C[Datadog APM]

    C -->|calcula taxa 5xx| D[Datadog Monitor<br/>auth-service 5xx > 5%]

    D -->|@jsm_ops| E[Jira Service Management<br/>Operations]
    D -->|@webhook-togglemaster<br/>self-healing| F[GitHub Actions<br/>repository_dispatch]

    E -->|integracao Slack| G[Slack #alerts]
    F -->|workflow self-healing.yml| H[kubectl rollout restart<br/>deployment/auth-service]

    H -->|~1min depois| I[auth-service com<br/>pods novos]
    I -.->|~5min| D
```

**Fluxo passo a passo:**

1. OTel Collector recebe traces dos microsserviços (Bloco 2 + 3).
2. Collector exporta pro Datadog APM.
3. Datadog Monitor avalia a cada minuto a taxa de erros `5xx / total` nos últimos 5 min.
4. Se > 5% dispara, notifica dois destinos em paralelo:
   - `@jsm_ops` → cria alerta no JSM Operations, encaminha pro Slack.
   - `@webhook-togglemaster-self-healing` → GitHub Actions `repository_dispatch`.
5. GitHub Actions executa `kubectl rollout restart deployment/auth-service`.
6. ~1 min depois, pods novos entram em serviço; Datadog monitora e o alerta se auto-resolve se o rollout curar o problema.

---

## Componentes

| Componente | Fonte | Responsabilidade |
|---|---|---|
| **Datadog Monitor** | `alerts/datadog/monitor-5xx-auth.json` | Define a condição do alerta |
| **Workflow `alerts-deploy.yml`** | `.github/workflows/` | Aplica o monitor via API Datadog (create ou update) |
| **Workflow `self-healing.yml`** | `.github/workflows/` | Reage ao webhook, faz `rollout restart` |
| **Integração JSM ↔ Datadog** | configurado no painel JSM | Encaminha alertas Datadog → alertas/incidentes JSM |
| **Integração JSM ↔ Slack** | configurado no painel JSM | Encaminha incidentes → canal Slack |
| **Webhook Datadog → GitHub** | configurado no painel Datadog | Dispara `repository_dispatch` no self-healing |

---

## Setup inicial — passo a passo

### Passo 1 — Pré-requisitos

#### SSM Parameters

```bash
# Datadog API Key (ingestão de dados) — mesma do Bloco 2
aws ssm put-parameter --name "/togglemaster/prod/datadog/api-key" \
  --type SecureString --value "<DD_API_KEY>" --overwrite \
  --profile aws_fiap

# Datadog Application Key (gerenciamento via API: criar monitors)
aws ssm put-parameter --name "/togglemaster/prod/datadog/app-key" \
  --type SecureString --value "<DD_APP_KEY>" --overwrite \
  --profile aws_fiap

# Datadog Site (opcional, default datadoghq.com)
aws ssm put-parameter --name "/togglemaster/prod/datadog/site" \
  --type String --value "datadoghq.com" --overwrite \
  --profile aws_fiap
```

Para criar a **Application Key**:
Datadog UI → avatar canto superior direito → **Organization Settings** →
**Application Keys** → **New Key** → nome `togglemaster-ci` → copie o valor.

#### GitHub Personal Access Token (PAT)

Com escopo `repo` — vai ser usado pelo Datadog pra chamar `repository_dispatch`:

GitHub → Settings → Developer settings → **Personal access tokens (classic)** →
Generate new token → nome `togglemaster-datadog-webhook` → escopo `repo` → copie.

---

### Passo 2 — Criar conta e site do JSM

Se ainda não tem:

1. Acesse https://www.atlassian.com/software/jira/service-management.
2. Clique em **Get it free** → crie o site (algo tipo `<seunome>.atlassian.net`).
3. Durante o setup, escolha o template **"IT Service Management"** (vem com Operations habilitado).

O **JSM Operations** é o módulo que gerencia alertas e on-call. Confirme que está ativo em:
`https://<seunome>.atlassian.net/jira/your-work` → menu lateral → **Operations**.

---

### Passo 3 — Instalar integração Datadog no JSM

No painel do **Jira Service Management**:

1. Acesse **Settings** (engrenagem) → **Operations** → **Integrations**.
2. Procure por **Datadog** na lista → **Add integration**.
3. Dê um nome (ex: `togglemaster-datadog`) e selecione o **team** que receberá os alertas.
4. O JSM gera uma **API Key** da integração — copie.
5. Em **Advanced**, habilite:
   - [x] Create JSM alerts
   - [x] Close JSM alerts when Datadog alert is recovered
6. Salve.

No painel do **Datadog**:

1. Acesse **Integrations** → procure por **Jira Service Management**.
2. Clique **Install** → cole a **API Key da integração** gerada acima.
3. Confirme que a integração aparece ativa.

Agora o handle `@jsm_ops` funciona em mensagens de monitor.

> **Importante**: há duas integrações distintas no Datadog com nomes parecidos:
> - **Jira** → cria issues no Jira Software (tickets). Não é o que queremos.
> - **Jira Service Management Ops** (ou **JSM Ops**) → cria alertas no módulo Operations do JSM. **É esta que queremos.**

---

### Passo 4 — Integrar JSM com Slack

1. No **Slack**: crie o canal `#alerts` (se ainda não existir).
2. No **JSM**: Settings → Operations → **Integrations** → **Slack** → **Add integration**.
3. Autorize o workspace do Slack e selecione o canal `#alerts`.
4. Configure quais eventos encaminham pro Slack:
   - [x] Alert created
   - [x] Alert acknowledged
   - [x] Alert closed
5. Salve.

Dica: o JSM também suporta criar **channels dedicados por incidente**
automaticamente (um canal por alerta). Útil pra times maiores. Pro escopo
da Fase 4, mandar tudo pro `#alerts` é suficiente.

**Testar que o fluxo funciona** (antes de aplicar o monitor):

JSM → Operations → **Alerts** → **Create test alert** → preencha e crie.

- A nova alerta deve aparecer na UI do JSM.
- Em ~1 min, uma mensagem deve aparecer no Slack `#alerts`.

Se não aparecer, revise a integração Slack.

---

### Passo 5 — Datadog webhook para self-healing

1. Datadog → Integrations → **Webhooks** → **New Webhook**.
2. Nome: `togglemaster-self-healing` (sem `@` — ele é adicionado automaticamente).
3. **URL**:
   ```
   https://api.github.com/repos/tech-tm/togglemaster-deploy/dispatches
   ```
4. **Payload** (JSON):
   ```json
   {
     "event_type": "datadog-alert",
     "client_payload": {
       "service": "auth-service",
       "alert_name": "$ALERT_TITLE",
       "alert_url":  "$LINK",
       "alert_id":   "$ALERT_ID"
     }
   }
   ```
5. **Custom Headers**:
   | Header | Valor |
   |---|---|
   | `Accept` | `application/vnd.github+json` |
   | `Authorization` | `token <SEU_PAT_GITHUB>` |
   | `X-GitHub-Api-Version` | `2022-11-28` |
6. Salvar.

> O webhook se chama internamente `togglemaster-self-healing`, por isso o
> monitor usa `@webhook-togglemaster-self-healing` (o Datadog adiciona o prefixo).

---

### Passo 6 — Aplicar o Monitor

Rode o workflow:

```
Actions → "Alerts Deploy" → Run workflow → branch deploy
```

Inputs (todos têm default sensato):

| Input | Default |
|---|---|
| `incident_handle` | `jsm_ops` |
| `threshold_percent` | `5` |
| `warning_percent` | `3` |

O workflow faz:
1. Lê API Key e App Key do Datadog do SSM.
2. Lê `alerts/datadog/monitor-5xx-auth.json`, substitui placeholders (incluindo `${INCIDENT_HANDLE}`).
3. Busca monitor existente por `name` no Datadog.
4. Se não existe: `POST` cria. Se existe: `PUT` atualiza.
5. Imprime URL do monitor no resumo.

---

## Fluxo de disparo (o que acontece quando falha)

Linha do tempo (aproximada):

```text
T+0s      auth-service começa a retornar 5xx (ex: RDS caiu)
T+30s     Primeiras métricas chegam ao Datadog via OTel Collector
T+60s     Datadog Monitor avalia (window last_5m)
T+5min    Taxa de erros ultrapassa 5% → alerta dispara (status: alert)
T+5min    Dois webhooks disparam em paralelo:
            @jsm_ops                              → alerta aberto no JSM
            @webhook-togglemaster-self-healing    → GitHub Actions dispatch
T+5min30s Integração JSM encaminha pro Slack #alerts
T+5min30s GitHub Actions começa o workflow self-healing
T+6min    kubectl rollout restart executado
T+6min30s Pods novos em serviço
T+10min   Datadog detecta métricas voltando ao normal
T+15min   Monitor auto-resolve, alerta JSM fecha, Slack notifica recovery
```

---

## Como testar sem causar incidente real

### Opção 1 — Trigger manual do Monitor

Datadog Monitor UI → **Resolve** (botão) → **Trigger** —
força o alerta a entrar em `alert`. Boa pra confirmar o fluxo completo
(JSM, Slack, Self-Healing) sem causar falha de verdade.

### Opção 2 — Workflow self-healing manual

```
Actions → "Self-Healing Rollout" → Run workflow →
  service: auth-service
  alert_url: manual-test
```

Isso executa só o rollout restart, sem passar pelo Datadog. Útil pra validar o
pipeline de self-healing isoladamente.

### Opção 3 — Simulação real (recomendada pro vídeo da fase)

1. Pause temporariamente o auth-service:
   ```bash
   kubectl scale deployment auth-service -n togglemaster --replicas=0
   ```
2. Faça carga chamando o `/evaluation/evaluate` (que chama auth internamente):
   ```bash
   INGRESS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   for i in {1..1000}; do
     curl -s "http://$INGRESS/evaluation/evaluate?user_id=u$i&flag_name=test" > /dev/null
   done
   ```
3. Observe: alerta dispara → JSM abre alerta → Slack notifica → self-healing escala de volta.
4. Volte a replica:
   ```bash
   kubectl scale deployment auth-service -n togglemaster --replicas=1
   ```

---

## Troubleshooting

### Monitor não dispara mesmo com erros 5xx

Verifique que o Datadog APM está recebendo traces:

- Datadog UI → **APM > Services** → `auth-service` deve aparecer.
- Se não aparecer: o OTel Collector não está exportando. Checar:
  - Secret `datadog-secret` no namespace `observability`.
  - Logs do Collector: `kubectl logs -n observability deploy/otel-collector-opentelemetry-collector`.

### JSM não recebe o alerta

- Datadog → Integrations → **Jira Service Management Ops** → confirmar que a integração está `active`.
- JSM → Settings → Operations → Integrations → log da integração Datadog.
- Verificar que a mensagem do Monitor tem `@jsm_ops` (handle fixo).

### Slack não recebe notificação

- JSM → Settings → Operations → Integrations → Slack → **Logs** da integração → ver erro.
- No Slack: confirmar que o canal `#alerts` existe e que o bot JSM foi adicionado.
- Testar o fluxo isolado: JSM → Operations → **Create test alert** → ver se chega no Slack.

### Self-healing workflow não dispara

- GitHub → repo → **Settings** → Secrets → confirmar que o PAT no header do webhook do Datadog está válido.
- Datadog → Integrations → Webhooks → `togglemaster-self-healing` → ver execuções recentes.
- Testar o `repository_dispatch` manualmente:
  ```bash
  curl -X POST "https://api.github.com/repos/tech-tm/togglemaster-deploy/dispatches" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: token <SEU_PAT>" \
    -d '{"event_type":"datadog-alert","client_payload":{"service":"auth-service","alert_url":"test"}}'
  ```

### Self-healing dispara mas falha no rollout

- Logs do próprio workflow na aba Actions.
- Causas comuns:
  - Cluster não acessível (sessão do AWS Academy expirada → PAT inválido no SSM).
  - Deployment inexistente (microsserviços ainda não aplicados).

---

## Justificativa das escolhas (para o relatório PDF da fase)

### Datadog vs New Relic

Escolhemos **Datadog** pelos seguintes motivos:

- **APM e Infrastructure num só pacote** — não precisa de contas separadas para traces e métricas.
- **Service Map nativo e visual** — atende diretamente o requisito do PDF ("o painel do APM deve exibir o mapa de dependências dos 5 microsserviços").
- **OTLP nativo** — recebe sem necessidade de agent proprietário; integra bem com o OTel Collector do Bloco 2.
- **Integração madura com JSM** — ambos têm handle dedicado (`@jsm_ops`), sem webhook genérico.
- **Education for free** — conta gratuita cobre as necessidades da fase.

New Relic também atenderia o requisito, mas a curva de aprendizado da UI é mais acentuada e a integração com JSM é via webhook genérico (menos integrada).

### Jira Service Management vs PagerDuty

Escolhemos **Jira Service Management Operations (JSM Ops)** pelos motivos:

- **Free tier adequado** (até 3 agents) suficiente para o grupo da fase.
- **Interface com Datadog nativa** — integração dedicada via handle `@jsm_ops`.
- **Integração Slack nativa** — cria channels dedicados por incidente, posta updates automáticos, suporta ChatOps avançado.
- **UI unificada com Jira** — se já usa Jira para gerenciamento de projetos, o Operations é só mais um módulo (menos ferramentas pra gerenciar).
- **Produto ativo e com roadmap** — mantido pela Atlassian como peça central da estratégia de ITSM.

Alternativa considerada:

- **PagerDuty**: mais robusto para equipes de SRE grandes, mas:
  - Free tier mais restrito (10 users, mas limita incidents/mês).
  - UI mais complexa, curva de aprendizado maior.
  - Integração com Slack é via app oficial (bom) mas sem o nível de automação do JSM (channels dedicados por incidente, ChatOps nativo).

### Slack vs Microsoft Teams

Escolhemos **Slack** porque:

- **Padrão de mercado em DevOps** — integração nativa e madura com todas as ferramentas que usamos (JSM, Datadog, GitHub).
- **ChatOps avançado via JSM** — JSM cria channels dedicados por incidente, posta updates automáticos, permite acknowledgment direto do canal.
- **Free tier** cobre o escopo da fase.

Microsoft Teams funciona também mas exige conta corporativa Microsoft 365.

### Self-Healing via GitHub Actions

- **Reaproveita o CI/CD já existente** — nada de instalar operator novo no cluster.
- **Auditável no histórico do GitHub** — cada execução fica registrada com logs.
- **Fácil de testar manualmente** (`workflow_dispatch`).
- **Seguro por padrão** — whitelist de serviços, namespace fixo, sem credenciais no payload.

Alternativas consideradas e descartadas:

- **AWS Lambda**: boa escolha também, mas adiciona um recurso novo no stack Terraform.
- **Argo Rollouts analysis + auto-rollback**: mais sofisticado, mas requer rewriting dos Deployments como Rollouts.
- **JSM Automation Rules**: funciona dentro do JSM mas acoplado ao vendor; preferimos deixar o self-healing independente do incident manager.
