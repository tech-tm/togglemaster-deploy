# Status atual do deploy

> Snapshot do estado do projeto no momento em que o ambiente AWS Academy
> foi destruído para economia de tempo de sessão. Use este documento quando
> voltar, pra retomar sem precisar reler todo o DEPLOY.md.

**Última atualização**: ao final da **Fase 5.2** do `DEPLOY.md`.

---

## Onde você parou

| Fase do DEPLOY.md | Status |
|---|---|
| 0 — Setup (SSM + Secrets GitHub) | ✅ feito |
| 1 — Terraform Apply (infra) | ✅ feito |
| 2 — Imagens dos microsserviços no ECR | ✅ feito |
| 3 — Install ArgoCD + aplicação principal | ✅ feito |
| 4 — Observability Deploy + Datadog Secret | ✅ feito |
| **5 — GitOps + Bloco 3** | ✅ **FEITO + VALIDADO** |
| 6 — Alertas + JSM + Slack | ❌ pendente |
| 7 — Teste end-to-end | ❌ pendente |
| 8 — Vídeo + Relatório | ❌ pendente |

**Última validação feita**: Fase 5.2 (envs OTEL nos pods, envs AWS no evaluation/analytics, zero erros de SQS/credenciais).

---

## O que você já tinha pronto no ambiente destruído

Isso ajuda a lembrar o que **deveria estar funcionando** no próximo deploy:

### Blocos técnicos do PDF (status código)

- ✅ **Bloco 1** — Prometheus + Grafana + Loki + dashboard customizado
- ✅ **Bloco 2** — OTel Collector exportando para Datadog
- ✅ **Bloco 3** — 5 microsserviços instrumentados + Service Map populado no Datadog APM
- ❌ **Bloco 4** — Monitor/JSM/Slack/Self-Healing ainda não executado

### Resultados visuais confirmados

- Grafana dashboard "ToggleMaster - Visao Geral" com dados nos 3 painéis
- Datadog APM → Services com os 5 serviços
- Datadog APM → Service Map com setas entre `evaluation` → `auth`, `flag`, `targeting`
- Logs do collector sem 403 nem erros de ingestão
- Logs do evaluation sem `NoCredentialProviders`

---

## O que persiste do ambiente destruído

### No GitHub (persiste sempre)

- Todo o código nos 2 repos (`togglemaster-app`, `togglemaster-deploy`)
- GitHub Secrets dos 2 repos (verificar que não expiraram as credenciais AWS Academy)

### No AWS SSM Parameter Store

**Atenção:** os SSM parameters do projeto se dividem em dois grupos.
Após `terraform destroy`, apenas o grupo B sobrevive.

**Grupo A — gerenciados pelo Terraform (destruídos pelo destroy):**

Esses são recriados automaticamente no próximo `Terraform Apply` com valores
novos (senhas aleatórias geradas pelo módulo `security`):

- `/togglemaster/prod/auth/credentials` → gerado pela camada `security`
- `/togglemaster/prod/flag/credentials` → idem
- `/togglemaster/prod/targeting/credentials` → idem
- `/togglemaster/prod/redis/credentials` → idem
- `/togglemaster/prod/evaluation/master_key` → idem
- `/togglemaster/prod/evaluation/service_api_key` → idem
- `/togglemaster/prod/cluster-name` → gerado pela camada `compute`

**Grupo B — criados manualmente (persistem entre destroy/apply):**

Esses você cria uma vez via `aws ssm put-parameter` e eles continuam lá
mesmo após `terraform destroy` (porque não são `aws_ssm_parameter` do Terraform):

- `/togglemaster/prod/datadog/api-key` → **API Key do Datadog** (ingestão)
- `/togglemaster/prod/datadog/app-key` → **App Key do Datadog** (gerenciamento, pro Bloco 4)
- `/togglemaster/prod/datadog/site` → `datadoghq.com` (opcional)

### Em contas externas

- **Datadog**: conta ativa, API Key válida, App Key válida (se já criada).
- **Jira Service Management**: ❌ ainda não configurado (Fase 6).
- **Slack**: ❌ workspace/canal `#alerts` ainda não integrado ao JSM (Fase 6).
- **Datadog webhook pro GitHub**: ❌ ainda não configurado (Fase 6).

---

## O que precisa ser recriado no próximo deploy

### Imediato — ao voltar à sessão AWS Academy

1. **Renovar GitHub Secrets** com as 3 credenciais da sessão nova:
   - Em `togglemaster-app`: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
   - Em `togglemaster-deploy`: idem

2. **Atualizar `~/.aws/credentials` local**.

### Fases automáticas (seguem o DEPLOY.md)

Como todas as correções estão versionadas no Git, basta seguir o DEPLOY.md:

1. **Fase 0** — [Preflight Check](DEPLOY.md#04-preflight-check-confere-se-tudo-está-no-lugar) workflow deve passar.
2. **Fase 1** — Terraform Apply. **Duração: ~15-25 min**.
3. **Fase 2** — Build imagens. 5 pushes vazios dispara workflows. **Duração: ~5-10 min**.
4. **Fase 3** — Install ArgoCD. Agora com `ignoreDifferences` globais já aplicados pelo values.yaml. **Duração: ~5 min**.
5. **Fase 4** — Observability Deploy + Sync Datadog Secret. **Duração: ~10 min**.
6. **Fase 5** — GitOps push (basta um commit vazio na branch deploy). **Duração: ~5 min**.

**Tempo total estimado pra voltar ao mesmo estado**: ~45-60 min.

### Fase 6 — Setup externo (uma vez, dura entre sessões)

Já pode começar a fazer antes de ter cluster:

- [ ] Criar site Jira Service Management (`<seunome>.atlassian.net`) com template "IT Service Management"
- [ ] JSM: adicionar integração **Datadog** → copiar API Key → Datadog: instalar integração **Jira Service Management Ops** → colar a key
- [ ] JSM: adicionar integração **Slack**, autorizar workspace, selecionar canal `#alerts`
- [ ] Criar webhook `togglemaster-self-healing` no Datadog (passo 5 do `docs/alerting.md`)
- [ ] Criar Personal Access Token do GitHub (escopo `repo`)

Esses setups **persistem** entre destruições do cluster.

---

## Checklist rápido pra voltar

Imprimir e marcar:

```text
PRÉ-DEPLOY
[ ] Atualizar GitHub Secrets em togglemaster-app     (3 secrets AWS)
[ ] Atualizar GitHub Secrets em togglemaster-deploy  (3 secrets AWS)
[ ] Atualizar ~/.aws/credentials local
[ ] Rodar workflow 'Preflight Check' (togglemaster-deploy)
    → deve passar tudo verde

DEPLOY
[ ] Fase 1: Terraform Apply                          (~20 min)
[ ] Fase 2: 5 commits vazios no togglemaster-app     (dispara builds)
    git commit --allow-empty -m "chore: trigger build auth-service"
    (uma vez por serviço, nos 5)
[ ] Fase 3: Install ArgoCD                           (~5 min)
[ ] Fase 4.1: Observability Deploy                   (~10 min)
[ ] Fase 4.2: Sync Datadog Secret from SSM           (~1 min)
[ ] Fase 5: push vazio na branch 'deploy'            (dispara GitOps)
    cd togglemaster-deploy
    git pull --rebase origin deploy
    git commit --allow-empty -m "chore: trigger gitops"
    git push origin deploy

VALIDAÇÃO (via TESTES.md)
[ ] Rodar script "tudo-em-um" do TESTES.md
    → todos T1, T2, T3 passam
[ ] Grafana: dashboard com dados nos 3 painéis
[ ] Datadog APM: Service Map com os 5 serviços

CONTINUAR DE ONDE PAROU
[ ] Seguir para a Fase 6 do DEPLOY.md (Bloco 4)
```

---

## Pontos de atenção específicos pra sua situação

### 1. O que mudou desde a última vez

Entre o último "ambiente de pé" e agora, consolidamos no Git:

- Fix do `terminatingReplicas` em 3 camadas (argocd-cm + ignoreDifferences nas Apps + RespectIgnoreDifferences)
- Credenciais AWS no `togglemaster-secrets` para SQS/DynamoDB funcionarem
- `trim whitespace` + `validate credentials` no workflow `argocd-install.yml`
- Owner corrigido no `terraform-apply.yml` (`tech-tm`)
- Node group com 3 nodes em vez de 2
- `kubernetes_namespace` removido do módulo EKS do Terraform

**Nenhum desses exige ação manual sua** — tudo é aplicado pelos workflows.

### 2. Riscos conhecidos no deploy do zero

- Se o **GitHub Secrets** não forem atualizados antes dos workflows, qualquer um falha com `InvalidSignatureException` ou `ExpiredToken`.
- Se o SSM `/togglemaster/prod/datadog/api-key` tiver sido apagado, o OTel Collector fica em `CreateContainerConfigError`.

### 3. Diagnóstico se algo quebrar

Guia completo em [TROUBLESHOOTING.md](./TROUBLESHOOTING.md). Os cenários mais prováveis estão nos itens 1, 2, 3, 8, 14, 15 e 17.

---

## Depois de voltar

Quando o Preflight Check passar + a Fase 5 validar + o script de T1/T2/T3 do TESTES.md passar, você está **exatamente no mesmo estado** em que parou. Pode seguir pra:

1. **Fase 6** do DEPLOY.md (Bloco 4) — setup JSM, Slack, webhook Datadog, aplicar monitor.
2. **Fase 7** — teste end-to-end com incidente proposital + capturar prints.
3. **Fase 8** — gravar vídeo + montar relatório PDF.
