# Alertas, Incidentes e Self-Healing (Fase 4 — Bloco 4)

Documentação da camada reativa do ToggleMaster: alertas inteligentes,
gerenciamento de incidentes (OpsGenie), notificação ChatOps (Discord) e
automação de self-healing (GitHub Actions).

---

## Arquitetura

```mermaid
graph TD
    A[Microsservicos<br/>instrumentados OTel] -->|OTLP| B[OTel Collector]
    B -->|traces + metrics| C[Datadog APM]

    C -->|calcula taxa 5xx| D[Datadog Monitor<br/>auth-service 5xx > 5%]

    D -->|@opsgenie-togglemaster| E[OpsGenie<br/>abre incidente]
    D -->|@webhook-togglemaster<br/>self-healing| F[GitHub Actions<br/>repository_dispatch]

    E -->|Discord integration| G[Discord #alerts]
    F -->|workflow self-healing.yml| H[kubectl rollout restart<br/>deployment/auth-service]

    H -->|~1min depois| I[auth-service com<br/>pods novos]
    I -.->|~5min| D
```

**Fluxo passo a passo:**

1. OTel Collector recebe traces dos microsserviços (Bloco 2 + 3).
2. Collector exporta pro Datadog APM.
3. Datadog Monitor avalia a cada minuto a taxa de erros `5xx / total` nos últimos 5 min.
4. Se > 5% dispara, notifica dois destinos em paralelo:
   - `@opsgenie-togglemaster` → OpsGenie abre incidente, Discord recebe notificação.
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
| **Integração OpsGenie ↔ Datadog** | configurado no painel OpsGenie | Encaminha alertas Datadog → incidentes OpsGenie |
| **Integração OpsGenie ↔ Discord** | configurado no painel OpsGenie | Encaminha incidentes → canal Discord |
| **Webhook Datadog → GitHub** | configurado no painel Datadog | Dispara `repository_dispatch` no self-healing |

---

## Setup inicial (passo a passo)

### Passo 1 — Pré-requisitos

**SSM Parameters** (criar uma vez):

```bash
# Datadog API Key (ingestão de dados) - mesma do Bloco 2
aws ssm put-parameter --name "/togglemaster/prod/datadog/api-key" \
  --type SecureString --value "<DD_API_KEY>" --overwrite

# Datadog Application Key (gerenciamento via API: criar monitors)
aws ssm put-parameter --name "/togglemaster/prod/datadog/app-key" \
  --type SecureString --value "<DD_APP_KEY>" --overwrite

# Datadog Site (opcional, default datadoghq.com)
aws ssm put-parameter --name "/togglemaster/prod/datadog/site" \
  --type String --value "datadoghq.com" --overwrite
```

Para criar a **Application Key**:
Datadog UI → avatar canto superior direito → **Organization Settings** →
**Application Keys** → **New Key** → nome `togglemaster-ci` → copie o valor.

**GitHub Personal Access Token (PAT)** com escopo `repo` — vai ser usado pelo
Datadog pra chamar `repository_dispatch`:

GitHub → Settings → Developer settings → **Personal access tokens (classic)** →
Generate new token → nome `togglemaster-datadog-webhook` → escopo `repo` → copie.

---

### Passo 2 — OpsGenie: criar team e integração Datadog

1. Criar conta: https://www.opsgenie.com/ (plano **Free** aceita 5 usuários).
2. **Teams** → New Team → nome `togglemaster` → adicionar você como membro.
3. **Settings** → **Integrations** → **Add integration** → escolher **Datadog**.
4. Nomear a integração como `togglemaster-datadog`.
5. OpsGenie gera uma **API Key** própria dessa integração. Copie.
6. No **Datadog**: Integrations → **OpsGenie** → **Install** → cole a API Key e dê o nome `togglemaster`.
7. Pronto — agora qualquer mensagem com `@opsgenie-togglemaster` encaminha pra OpsGenie.

> O nome depois do `@` segue o padrão `opsgenie-<account_name>` onde `<account_name>` é o que você cadastrou no passo 6.

---

### Passo 3 — Discord: webhook do canal

1. No servidor Discord → canal `#alerts` → **Edit channel** → **Integrations** → **Webhooks** → New Webhook.
2. Nome `OpsGenie-ToggleMaster`, copie a **Webhook URL**.
3. Volte ao OpsGenie: **Teams** → `togglemaster` → **Integrations** → Add integration → **Discord**.
4. Cole a Webhook URL do Discord.
5. Configure as regras de notificação (recomendado: notificar em **Create**, **Acknowledge** e **Close**).

> Alternativa: usar Slack ou Microsoft Teams no lugar do Discord — a integração do OpsGenie com ambos funciona do mesmo jeito.

---

### Passo 4 — Datadog: webhook para self-healing

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

### Passo 5 — Aplicar o Monitor

Rode o workflow:

```
Actions → "Alerts Deploy" → Run workflow → branch deploy
```

O workflow faz:
1. Lê API Key e App Key do Datadog do SSM.
2. Lê `alerts/datadog/monitor-5xx-auth.json`, substitui placeholders.
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
            @opsgenie-togglemaster     → incidente aberto no OpsGenie
            @webhook-togglemaster-...  → GitHub Actions dispatch
T+5min30s OpsGenie encaminha pro Discord
T+5min30s GitHub Actions começa o workflow self-healing
T+6min    kubectl rollout restart executado
T+6min30s Pods novos em serviço
T+10min   Datadog detecta métricas voltando ao normal
T+15min   Monitor auto-resolve, OpsGenie fecha o incidente, Discord notifica
```

---

## Como testar sem causar incidente real

### Opção A — Trigger manual do Monitor

Datadog Monitor UI → **Resolve** (botão) → **Trigger** —
força o alerta a entrar em `alert`. Boa pra confirmar o fluxo completo
(OpsGenie, Discord, Self-Healing) sem causar falha de verdade.

### Opção B — Workflow self-healing manual

```
Actions → "Self-Healing Rollout" → Run workflow →
  service: auth-service
  alert_url: manual-test
```

Isso executa só o rollout restart, sem passar pelo Datadog. Útil pra validar o
pipeline de self-healing isoladamente.

### Opção C — Simulação real (recomendada pro vídeo da fase)

1. Pause temporariamente o auth-service:
   ```bash
   kubectl scale deployment auth-service -n togglemaster --replicas=0
   ```
2. Faça carga chamando o `/evaluate` (que chama auth internamente):
   ```bash
   for i in {1..1000}; do curl -s http://<ingress>/evaluate?user_id=u$i\&flag_name=test; done
   ```
3. Observe: alerta dispara → incidente OpsGenie → notificação Discord → self-healing escala de volta.
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

### OpsGenie não recebe o alerta

- Datadog → Integrations → OpsGenie → confirmar que a integração está `active`.
- No OpsGenie → Settings → **Logs** → ver se há tentativa de envio.
- Verificar que a mensagem do Monitor tem `@opsgenie-<nome>` com o nome **exato** da conta cadastrada no Datadog.

### Discord não recebe notificação

- OpsGenie → Team `togglemaster` → Integrations → **Logs da integração Discord** → ver detalhe do erro.
- Testar a Webhook URL do Discord com `curl`:
  ```bash
  curl -X POST "<DISCORD_WEBHOOK_URL>" \
    -H "Content-Type: application/json" \
    -d '{"content":"teste de webhook"}'
  ```

### Self-healing workflow não dispara

- GitHub → repo → **Settings** → Secrets → confirmar que o PAT no header do webhook do Datadog está válido.
- Datadog → Integrations → Webhooks → `togglemaster-self-healing` → ver a aba de **execuções recentes**.
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
- **Integração madura com OpsGenie** — ambos são da Atlassian/F5, não exige intermediários.
- **Education for free** — conta gratuita cobre as necessidades da fase.

New Relic também atenderia o requisito, mas a curva de aprendizado da UI é mais acentuada e a integração com OpsGenie é via webhook genérico (menos integrado).

### OpsGenie vs PagerDuty

Escolhemos **OpsGenie** porque:

- **Free tier mais generoso** (5 usuários) suficiente para o grupo da fase.
- **Interface com Datadog nativa**, 1-click.
- **Integração Discord pronta** (PagerDuty exige intermediário tipo Zapier para Discord).
- **UI mais simples** para operador iniciante.

PagerDuty é mais robusto para equipes de SRE grandes, mas para o escopo da fase (demonstrar o fluxo end-to-end) o OpsGenie é mais pragmático.

### Self-Healing via GitHub Actions

- **Reaproveita o CI/CD já existente** — nada de instalar operator novo no cluster.
- **Auditável no histórico do GitHub** — cada execução fica registrada com logs.
- **Fácil de testar manualmente** (`workflow_dispatch`).
- **Seguro por padrão** — whitelist de serviços, namespace fixo, sem credenciais no payload.

Alternativas consideradas e descartadas:
- **AWS Lambda**: boa escolha também, mas adiciona um recurso novo no stack Terraform.
- **Argo Rollouts analysis + auto-rollback**: mais sofisticado, mas requer rewriting dos Deployments como Rollouts.
- **OpsGenie Runbook Automation**: requer plano Enterprise (pago).
