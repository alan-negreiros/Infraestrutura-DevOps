# Justificativa de Arquitetura

Este documento explica as abordagens escolhidas para a infraestrutura das APIs de **Contratos** e **Flash Sales**
e como cada uma contribui para **escalabilidade**, **segurança** e **confiabilidade**, com base nas práticas de DevOps.

## 1. Princípios adotados

| Princípio | Como foi aplicado |
|---|---|
| **Infraestrutura como Código** | Todo o ambiente é descrito em arquivos versionados: Dockerfiles, `docker-compose.yml`, manifestos Kustomize, configuração do cluster kind, Prometheus, Grafana e pipeline. Nada é configurado manualmente. |
| **Reprodutibilidade** | Um comando sobe cada ambiente (`docker compose up`, `scripts/k8s-up.sh`). Versões de imagens, ferramentas e dependências (`package-lock.json`) são fixadas. O mesmo script que um desenvolvedor usa é o que a pipeline executa. |
| **Paridade entre ambientes** | Compose e Kubernetes usam as mesmas imagens e os mesmos arquivos de configuração (`config/`): o mesmo template do Nginx, as mesmas regras de alerta e o mesmo dashboard. Muda só o que é específico de cada ambiente (endereços e portas), via variáveis de ambiente. |
| **Artefato imutável** | A imagem é construída uma única vez no CI; a mesma imagem é escaneada, testada no cluster efêmero e publicada (*build once, deploy many*). |
| **Configuração por ambiente (12-factor)** | Endereços, portas e credenciais vêm de variáveis de ambiente, ConfigMaps e Secrets. As diferenças entre local e produção ficam isoladas em *overlays* do Kustomize. |
| **Segurança desde o início (*shift-left*)** | Lint, auditoria de dependências, scan de imagem e validação de manifestos rodam em todo pull request, antes de qualquer deploy. |
| **Observabilidade** | Métricas, alertas, dashboard e logs estruturados fazem parte da entrega, não são um passo posterior. |

## 2. Decisões e justificativas

### 2.1 Containers

- **Build multi-stage**: um estágio instala tudo e compila o TypeScript; o estágio final contém apenas o JavaScript
  compilado e as dependências de produção. A imagem final não tem compilador, testes nem dependências de desenvolvimento.
- **Usuário não-root (`node`) e código somente leitura**: os arquivos da aplicação pertencem ao root e o processo
  roda como outro usuário, então um invasor não consegue alterar o código em execução.
- **npm, npx, yarn e corepack removidos da imagem final**: não são usados em runtime e são uma fonte frequente de CVEs.
- **`HEALTHCHECK` na imagem**: o Docker sabe se o container está saudável, e o Compose só libera os dependentes
  quando as dependências estão de fato prontas (`depends_on: condition: service_healthy`).

### 2.2 Gateway como ponto único de entrada

Um Nginx na frente das APIs centraliza os requisitos transversais em vez de espalhá-los pelo código:

- **Roteamento por prefixo** (`/contratos/*`, `/flash-sales/*`): os clientes conhecem um único endereço.
- **Rate limiting**: uma *flash sale* é por definição um pico de tráfego. Limitar requisições por IP protege o
  backend de abuso e de bots, devolvendo `429` em vez de deixar o sistema degradar para todos.
- **Bloqueio de `/metrics`**: as métricas internas não ficam expostas publicamente; o Prometheus as coleta direto nos pods.
- **Rastreabilidade**: cada requisição recebe um `X-Request-ID`, repassado às APIs e registrado em log JSON.
- **Retentativas seguras**: o Nginx só tenta outra réplica em falha de conexão e nunca reenvia `POST`, evitando
  compras duplicadas.
- **Resolução de DNS dinâmica**: novas réplicas (`--scale` no Compose, HPA no Kubernetes) entram no balanceamento sem reiniciar o gateway.

### 2.3 Isolamento da exportação (padrão *bulkhead*)

A rota `POST /tickets/export` foi feita para consumir muita CPU e memória e **bloqueia o event loop** do Node.js.
Se rodasse nas mesmas réplicas do checkout, uma exportação deixaria compras sem resposta durante a execução.

Por isso a mesma imagem é implantada duas vezes: `flash-sales` atende o checkout e `flash-sales-export` atende só a
exportação, com mais memória, limite de heap (`--max-old-space-size`) compatível com o limite do container,
probes mais tolerantes e um HPA próprio que escala por CPU **e** memória. Uma sobrecarga na exportação não afeta as vendas.

A tolerância da readiness probe da exportação (até ~30 s sem resposta) foi definida a partir de um teste de carga.
Com uma probe agressiva, o pod saía do balanceamento a cada exportação, e o HPA, que conta pods não prontos como 0% de
CPU, nunca escalava, mesmo com 134% de uso. Com a probe tolerante o HPA escala, e o liveness ainda reinicia um processo
travado de verdade.

### 2.4 Kubernetes

| Recurso | Motivo |
|---|---|
| **Deployments** para APIs e gateway | Aplicações *stateless*: qualquer réplica atende qualquer requisição. Todo o estado está no PostgreSQL e no Redis. |
| **StatefulSets com PVC** para PostgreSQL e Redis | Identidade estável e volume persistente que sobrevive à recriação do pod. |
| **HPA** (`autoscaling/v2`) | Escala horizontal automática por CPU. O HPA da Flash Sales escala de forma agressiva (dobra a cada 15 s) para reagir ao início de uma venda, e todos reduzem devagar (janela de 5 min) para evitar oscilação. O campo `replicas` foi omitido dos Deployments para não conflitar com o HPA a cada `apply`. |
| **Requests e limits** | Os *requests* garantem capacidade no agendamento e servem de base para o cálculo do HPA; os *limits* impedem que uma réplica consuma os recursos do nó inteiro. |
| **Startup, liveness e readiness probes** | `startupProbe` dá tempo para a inicialização; `livenessProbe` (`/health`) reinicia processos travados; `readinessProbe` (`/ready`, que testa banco e Redis) tira do balanceamento uma réplica que perdeu as dependências ou está ocupada. |
| **Rolling update com `maxUnavailable: 0`** | Durante um deploy a capacidade nunca diminui: um pod novo precisa ficar pronto antes de um antigo sair. |
| **Encerramento gracioso** | `preStop` aguarda 5 s (tempo para o pod sair dos endpoints) e a aplicação trata o `SIGTERM` terminando as requisições em andamento. Deploys e *scale down* não derrubam requisições. |
| **PodDisruptionBudget** | Manutenções de nó (drain) nunca removem todas as réplicas de uma API ao mesmo tempo. |
| **Topology spread** | As réplicas são distribuídas entre os nós; a queda de um nó não derruba o serviço. |
| **initContainer `wait-for-postgres`** | As APIs só iniciam quando o banco aceita conexões, evitando reinícios em sequência na primeira subida. |
| **Calico como CNI no kind** | O CNI padrão do kind aplica NetworkPolicies via NFQUEUE, módulo ausente no kernel do Docker Desktop/WSL2. Nesse caso as políticas são aceitas pela API, mas **não bloqueiam nada**, uma falha silenciosa descoberta pelo teste de isolamento de rede. O Calico usa iptables e aplica as políticas igual em qualquer sistema e no CI. |
| **Cluster de 1 ou 3 nós conforme a memória** | Com menos de 6 GiB para o Docker, três nós mais o Calico levam a VM ao swap e o etcd começa a falhar. O script detecta a memória e escolhe a topologia; os manifestos são os mesmos. |
| **Kustomize com base + overlays** | Um único conjunto de manifestos; `local` e `production` declaram só as diferenças (imagens, tipo de Service, tamanho do volume, réplicas máximas). ConfigMaps e Secrets gerados recebem um hash no nome, então alterar uma configuração dispara um novo rollout automaticamente. |

### 2.5 Dados

- **Um banco e um usuário por serviço** (*database per service*): cada API só tem permissão no próprio banco
  (`REVOKE ALL ... FROM PUBLIC`). Um problema ou vazamento em um serviço não expõe os dados do outro, e os schemas evoluem de forma independente.
- **Senhas passadas como variáveis do `psql`** no script de inicialização, nunca concatenadas no SQL.
- **Redis com AOF e `maxmemory-policy noeviction`**: o estoque de ingressos é dado de negócio, não cache descartável.
  Com AOF o estoque sobrevive a reinícios; com `noeviction` o Redis nunca apaga chaves para liberar memória (prefere recusar escritas).
- **Consistência do estoque com múltiplas réplicas**: a API já faz a verificação e o decremento em um script Lua
  atômico no Redis. Por isso a Flash Sales pode escalar para dezenas de réplicas sem vender mais ingressos do que existem.

### 2.6 Segurança

| Camada | Medida |
|---|---|
| Segredos | Nenhuma senha real no Git. No Compose ficam no `.env` (ignorado); no kind o script gera senhas aleatórias; em produção o Secret é criado diretamente no cluster; na pipeline o kubeconfig é um secret do GitHub usado só no environment `production`. |
| Rede (Compose) | PostgreSQL, Redis e APIs ficam em uma rede `internal`, sem acesso a partir do host nem saída para a internet. Só gateway, Prometheus e Grafana publicam portas. |
| Rede (Kubernetes) | NetworkPolicy *default deny*: as APIs só recebem tráfego do gateway e do Prometheus; o PostgreSQL só de pods marcados como `postgres-client`; o Redis só de `redis-client`. |
| Pods | Namespace com **Pod Security Standard `restricted`** obrigatório: todos os containers rodam como não-root, sem escalada de privilégio, sem *capabilities*, com seccomp e, quando possível, com sistema de arquivos somente leitura. |
| Acesso à API do Kubernetes | Só o Prometheus tem ServiceAccount com permissão, e mínima (`get/list/watch` de pods no próprio namespace). Os demais pods nem montam o token. |
| Cadeia de suprimentos | `npm audit`, scan de imagem com Grype (bloqueia vulnerabilidades críticas que já têm correção), hadolint, Dependabot para npm, imagens base e actions, e publicação no GHCR com o `GITHUB_TOKEN` de escopo mínimo (`packages: write` apenas no job de publicação). |
| Aplicação | Redis com senha, cabeçalhos de segurança no gateway, `server_tokens off`, limite de tamanho de corpo e métricas inacessíveis externamente. |

### 2.7 Integração e entrega contínuas

A pipeline segue a ordem *falhar cedo e barato*: testes e validações estáticas (segundos) vêm antes do build de imagem,
que vem antes do teste em cluster (minutos), que vem antes da publicação e do deploy.

- **Qualidade**: verificação de tipos, testes unitários com cobertura e build para as duas APIs em paralelo (matriz).
- **Infraestrutura também é testada**: Dockerfiles, scripts, Compose e manifestos são validados como código.
- **Teste E2E em cluster efêmero**: a cada execução um cluster kind é criado no runner com o mesmo script usado
  localmente, e três testes rodam contra ele: o smoke test funcional pelo gateway, o teste de isolamento de rede
  (prova que as NetworkPolicies bloqueiam o que devem) e um teste de carga curto com limites de erro e latência.
  Isso valida juntos manifestos, NetworkPolicies, Pod Security, probes e as imagens.
- **Promoção do artefato testado**: o job de publicação não reconstrói a imagem; ele publica o arquivo que passou pelo scan e pelo E2E.
- **Versionamento rastreável**: cada imagem tem a tag `sha-<commit>`, e o deploy fixa essa tag no overlay de
  produção. É sempre possível saber qual commit está rodando e voltar para qualquer versão anterior.
- **Deploy seguro**: environment `production` (permite exigir aprovação manual), concorrência de um deploy por vez,
  espera pelo rollout e **rollback automático** (`kubectl rollout undo`) se a nova versão não ficar saudável.

### 2.8 Observabilidade

- **Métricas RED** (*Rate, Errors, Duration*) por serviço e rota, a partir do histograma que as APIs já exportam,
  e métricas de saturação do runtime (CPU, memória, lag do event loop).
- **Descoberta automática de alvos**: réplicas criadas pelo HPA ou pelo `--scale` passam a ser monitoradas sem configuração extra.
- **Alertas acionáveis**: instância fora do ar, taxa de erro, latência, event loop bloqueado e consumo de memória,
  cada um com tempo mínimo de duração (`for`) para evitar alarmes falsos.
- **Dashboard provisionado como código**: o Grafana sobe pronto, igual em todos os ambientes.
- **Logs estruturados com correlação**: JSON no gateway com `request_id`, e rotação de logs no Compose para não lotar o disco.

## 3. Resumo: como a solução garante cada requisito

| Requisito | Práticas que o atendem |
|---|---|
| **Escalabilidade** | APIs sem estado; HPA por CPU (e memória na exportação) com políticas de escala próprias; gateway com balanceamento e DNS dinâmico; isolamento da carga pesada (*bulkhead*); estoque consistente entre réplicas via Lua atômico; rate limiting para absorver picos. |
| **Segurança** | Segredos fora do Git; Pod Security `restricted`; NetworkPolicies *default deny*; redes internas no Compose; containers não-root e somente leitura; menor privilégio no banco e no RBAC; scans e auditorias automáticos na pipeline; `/metrics` não exposto. |
| **Confiabilidade** | Health checks em três níveis; *self-healing* do Kubernetes; rolling update sem perda de capacidade; encerramento gracioso; PDB e distribuição entre nós; persistência com PVC e AOF; testes E2E antes de publicar; deploy com rollback automático; alertas e dashboard. |

## 4. Limitações conhecidas e próximos passos

Para manter o escopo compatível com a atividade, alguns pontos ficaram como evolução recomendada:

- **Migrations em vez de `synchronize: true`**: o TypeORM cria o schema na inicialização. Funciona, mas em produção
  o ideal é versionar migrations e executá-las em um Job antes do rollout (inclusive para evitar a corrida entre réplicas na primeira subida).
- **Alta disponibilidade dos dados**: PostgreSQL e Redis rodam com uma réplica. Em produção, usar um serviço gerenciado
  (RDS, Cloud SQL) ou um operador (CloudNativePG, Redis Sentinel).
- **Gestão de segredos**: integrar Sealed Secrets ou External Secrets Operator com um cofre (Vault, AWS Secrets Manager).
- **TLS e Ingress**: em produção, expor o gateway via Gateway API ou Ingress com certificados do cert-manager.
- **GitOps**: substituir o `kubectl apply` da pipeline por Argo CD ou Flux, com o cluster sincronizando a partir do Git.
- **Alertmanager e tracing**: rotear alertas para e-mail ou chat e adicionar rastreamento distribuído com OpenTelemetry.
- **Exportação assíncrona**: idealmente a exportação viraria um job em fila, respondendo `202 Accepted`, em vez de uma
  requisição síncrona que bloqueia o processo. Isso exige mudar a aplicação, então foi mitigado na infraestrutura com o *bulkhead*.
