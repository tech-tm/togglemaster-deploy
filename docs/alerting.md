# Alertas, Incidentes e Self-Healing (Fase 4 — Bloco 4)

Documentação da camada reativa do ToggleMaster: alertas inteligentes,
gerenciamento de incidentes, notificação ChatOps e automação de self-healing
(GitHub Actions).

Duas opções de **incident management + ChatOps** são suportadas:

| Opção | Incident management | ChatOps | Status |
|---|---|---|---|
| **A (recomendada)** | **Jira Service Management Operations** (JSM Ops) | **Slack** | Atual |
| **B (legacy)** | OpsGenie | Discord | ⚠️ Suporte até **5 abril 2027** (depois descontinuado) |

> **Por que mudamos a opção principal?** A Atlassian [parou de vender OpsGenie em junho de 2025](https://support.atlassian.com/jira-service-management-cloud/docs/merge-opsgenie-with-jira-service-management/) e descontinua o produto em abril de 2027. Novos usuários **não conseguem mais criar conta no OpsGenie** — por isso o caminho padrão é JSM Ops (que é o sucessor oficial, mantido pela mesma Atlassian).
>
> Quem já tem conta OpsGenie ativa pode continuar usando até 2027 (ver [Opção B](#opção-b-legacy--opsgenie--discord) abaixo).

---

## Arquitetura

```mermaid
graph TD
    A[Microsservicos<br/>instrumentados OTel] -->|OTLP| B[OTel Collector]
    B -->|traces + metrics| C[Datadog APM]

    C -->|calcula taxa 5xx| D[Datadog Monitor<br/>auth-service 5xx > 5%]

    D -->|@jsm_ops OU @opsgenie-togglemaster| E[Incident Mgmt<br/>JSM Ops ou OpsGenie]
    D -->|@webhook-togglemaster<br/>self-healing| F[GitHub Actions<br/>repository_dispatch]

    E -->|Slack OU Discord integration| G[Canal ChatOps<br/>#alerts]
    F -->|workflow self-healing.yml| H[kubectl rollout restart<br/>deployment/auth-service]

    H -->|~1min depois| I[auth-service com<br/>pods novos]
    I -.->|~5min| D
```

**Fluxo passo a passo:**

1. OTel Collector recebe traces dos microsserviços (Bloco 2 + 3).
2. Collector exporta pro Datadog APM.
3. Datadog Monitor avalia a cada minuto a taxa de erros `5xx / total` nos últimos 5 min.
4. Se > 5% dispara, notifica dois destinos em paralelo:
   - `@jsm_ops` (ou `@opsgenie-togglemaster` na opção B) → cria alerta/incidente, encaminha pro ChatOps.
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
| **Integração JSM ↔ Datadog** (opção A) | configurado no painel JSM | Encaminha alertas Datadog → alertas/incidentes JSM |
| **Integração JSM ↔ Slack** (opção A) | configurado no painel JSM | Encaminha incidentes → canal Slack |
| **Integração OpsGenie ↔ Datadog** (opção B legacy) | configurado no painel OpsGenie | Encaminha alertas Datadog → incidentes OpsGenie |
| **Integração OpsGenie ↔ Discord** (opção B legacy) | configurado no painel OpsGenie | Encaminha incidentes → canal Discord |
| **Webhook Datadog → GitHub** | configurado no painel Datadog | Dispara `repository_dispatch` no self-healing |

---

## Setup inicial — passo a passo

### Passo 1 — Pré-requisitos (comuns às duas opções)

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

### Opção A (recomendada) — Jira Service Management + Slack

#### A.1 Criar conta e site do JSM

Se ainda não tem:

1. Acesse https://www.atlassian.com/software/jira/service-management.
2. Clique em **Get it free** → crie o site (algo tipo `<seunome>.atlassian.net`).
3. Durante o setup, escolha o template **"IT Service Management"** (vem com Operations habilitado).

O **JSM Operations** (sucessor do OpsGenie) é o módulo que gerencia alertas e on-call. Confirme que está ativo em:
`https://<seunome>.atlassian.net/jira/your-work` → menu lateral → **Operations**.

#### A.2 Instalar integração Datadog no JSM

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

#### A.3 Integrar JSM com Slack

1. No **Slack**: crie o canal `#alerts` (se ainda não existir).
2. No **JSM**: Settings → Operations → **Integrations** → **Slack** → **Add integration**.
3. Autorize o workspace do Slack e selecione o canal `#alerts`.
4. Configure quais eventos encaminham pro Slack:
   - [x] Alert created
   - [x] Alert acknowledged
   - [x] Alert closed
5. Salve.

Dica: o JSM também suporta criar **channels dedicados por incidente** automaticamente (um canal por alerta). Útil pra times maiores. Pro escopo da Fase 4, mandar tudo pro `#alerts` é suficiente.

#### A.4 Testar que o fluxo funciona

Antes de aplicar o monitor, teste manualmente no JSM:

JSM → Operations → **Alerts** → **Create test alert** → preencha e crie.

- A nova alerta deve aparecer na UI do JSM.
- Em ~1 min, uma mensagem deve aparecer no Slack `#alerts`.

Se não aparecer, revise a integração Slack (Passo A.3).

---

### Opção B (legacy) — OpsGenie + Discord

> ⚠️ **Use esta opção apenas se você já tem conta OpsGenie ativa.** Novos
> usuários não conseguem criar conta no OpsGenie desde junho/2025. Esta
> seção é mantida pra referência de instalações antigas, e será removida
> quando o OpsGenie for descontinuado (abril/2027).

#### B.1 OpsGenie: criar team e integração Datadog

1. **Teams** → New Team → nome `togglemaster` → adicionar você como membro.
2. **Settings** → **Integrations** → **Add integration** → escolher **Datadog**.
3. Nomear a integração como `togglemaster-datadog`.
4. OpsGenie gera uma **API Key** própria dessa integração. Copie.
5. No **Datadog**: Integrations → **OpsGenie** → **Install** → cole a API Key e dê o nome `togglemaster`.

Agora o handle `@opsgenie-togglemaster` funciona (nome depois do `@` segue o padrão `opsgenie-<account_name>`).

#### B.2 Discord: webhook do canal

1. No servidor Discord → canal `#alerts` → **Edit channel** → **Integrations** → **Webhooks** → New Webhook.
2. Nome `OpsGenie-ToggleMaster`, copie a **Webhook URL**.
3. Volte ao OpsGenie: **Teams** → `togglemaster` → **Integrations** → Add integration → **Discord**.
4. Cole a Webhook URL do Discord.
5. Configure as regras de notificação (recomendado: notificar em **Create**, **Acknowledge** e **Close**).

> Alternativa pra opção B: Slack ou Microsoft Teams no lugar do Discord — a integração do OpsGenie com ambos funciona do mesmo jeito.

---

### Passo 5 — Datadog webhook para self-healing (comum às duas opções)

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

Inputs:

| Input | Valor Opção A (JSM) | Valor Opção B (OpsGenie legacy) |
|---|---|---|
| `threshold_percent` | `5` (default) | `5` |
| `warning_percent` | `3` (default) | `3` |
| `incident_handle` | `jsm_ops` (default) | `opsgenie-togglemaster` |

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
            @jsm_ops (ou @opsgenie-togglemaster)  → incidente aberto
            @webhook-togglemaster-self-healing    → GitHub Actions dispatch
T+5min30s Integração encaminha pro Slack #alerts (ou Discord)
T+5min30s GitHub Actions começa o workflow self-healing
T+6min    kubectl rollout restart executado
T+6min30s Pods novos em serviço
T+10min   Datadog detecta métricas voltando ao normal
T+15min   Monitor auto-resolve, incident fecha, ChatOps notifica recovery
```

---

## Como testar sem causar incidente real

### Opção 1 — Trigger manual do Monitor

Datadog Monitor UI → **Resolve** (botão) → **Trigger** —
força o alerta a entrar em `alert`. Boa pra confirmar o fluxo completo
(JSM/OpsGenie, Slack/Discord, Self-Healing) sem causar falha de verdade.

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
3. Observe: alerta dispara → incidente aberto → notificação no ChatOps → self-healing escala de volta.
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

### JSM/OpsGenie não recebe o alerta

Para **opção A (JSM)**:
- Datadog → Integrations → **Jira Service Management Ops** → confirmar que a integração está `active`.
- JSM → Settings → Operations → Integrations → log da integração Datadog.
- Verificar que a mensagem do Monitor tem `@jsm_ops` (sem sufixo — a integração JSM usa o handle fixo).

Para **opção B (OpsGenie)**:
- Datadog → Integrations → **OpsGenie** → confirmar `active`.
- OpsGenie → Settings → **Logs** → ver tentativa de envio.
- Confirmar que a mensagem tem `@opsgenie-<nome>` com o nome **exato** da conta cadastrada.

### Slack/Discord não recebe notificação

Para **opção A (Slack)**:
- JSM → Settings → Operations → Integrations → Slack → **Logs** da integração → ver erro.
- No Slack: confirmar que o canal `#alerts` existe e que o bot JSM foi adicionado.

Para **opção B (Discord)**:
- OpsGenie → Team `togglemaster` → Integrations → **Logs da integração Discord**.
- Testar a Webhook URL do Discord com `curl`:
  ```bash
  curl -X POST "<DISCORD_WEBHOOK_URL>" \
    -H "Content-Type: application/json" \
    -d '{"content":"teste de webhook"}'
  ```

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
- **Integração madura com JSM e OpsGenie** — ambos são da Atlassian, não exige intermediários.
- **Education for free** — conta gratuita cobre as necessidades da fase.

New Relic também atenderia o requisito, mas a curva de aprendizado da UI é mais acentuada e a integração com JSM/OpsGenie é via webhook genérico (menos integrado).

### Jira Service Management vs OpsGenie vs PagerDuty

Escolhemos **Jira Service Management Operations (JSM Ops)** pelos motivos:

- **Sucessor oficial do OpsGenie** — Atlassian descontinuou o OpsGenie para novos usuários em junho/2025, com encerramento total em abril/2027. JSM Ops é o produto que absorveu toda a funcionalidade de incident management do OpsGenie.
- **Free tier adequado** (até 3 agents) suficiente para o grupo da fase.
- **Interface com Datadog nativa** — integração dedicada via handle `@jsm_ops`.
- **Integração Slack nativa** — cria channels dedicados por incidente, posta updates automáticos, suporta ChatOps avançado.
- **UI unificada com Jira** — se já usa Jira para gerenciamento de projetos, o Operations é só mais um módulo (menos ferramentas pra gerenciar).

Alternativas consideradas:

- **OpsGenie**: funciona bem mas em descontinuação (até abril/2027). Não compensa adotar hoje para novos projetos.
- **PagerDuty**: mais robusto para equipes de SRE grandes, mas:
  - Free tier mais restrito (10 users, mas limita incidents/mês).
  - UI mais complexa, curva de aprendizado maior.
  - Integração com Slack é via app oficial (bom) mas sem o nível de automação do JSM (channels dedicados por incidente, ChatOps nativo).

### Slack vs Discord vs Microsoft Teams

Escolhemos **Slack** porque:

- **Padrão de mercado em DevOps** — integração nativa e madura com todas as ferramentas que usamos (JSM, Datadog, GitHub).
- **ChatOps avançado via JSM** — JSM cria channels dedicados por incidente, posta updates automáticos, permite acknowledgment direto do canal.
- **Free tier** cobre o escopo da fase.

Discord é melhor pra comunidades de gamers e menos integrado com ferramentas enterprise (apesar de ter funcionado com OpsGenie). Microsoft Teams funciona também mas exige conta corporativa Microsoft 365.

### Self-Healing via GitHub Actions

- **Reaproveita o CI/CD já existente** — nada de instalar operator novo no cluster.
- **Auditável no histórico do GitHub** — cada execução fica registrada com logs.
- **Fácil de testar manualmente** (`workflow_dispatch`).
- **Seguro por padrão** — whitelist de serviços, namespace fixo, sem credenciais no payload.

Alternativas consideradas e descartadas:

- **AWS Lambda**: boa escolha também, mas adiciona um recurso novo no stack Terraform.
- **Argo Rollouts analysis + auto-rollback**: mais sofisticado, mas requer rewriting dos Deployments como Rollouts.
- **JSM Automation Rules**: funciona dentro do JSM mas acoplado ao vendor; preferimos deixar o self-healing independente do incident manager.
