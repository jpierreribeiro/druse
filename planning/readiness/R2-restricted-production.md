# R2 — plano para produção restrita

**Status:** EM EXECUÇÃO. R2-WP01 e R2-WP03 fechados em 2026-08-02; R2-WP02
fechado em 2026-08-03; WP04–WP08 abertos.
**Objetivo:** autorizar workloads de produção dentro de um envelope explícito,
com SLO, observabilidade, capacidade, segurança e rollback provados.
**Entrada:** R1 promovido e um candidato de release imutável.

> **O gate continua em R1.** Fechar o WP01 significa que o instrumento passou a
> ser capaz de explicar uma falha — não que exista qualquer evidência sobre o
> produto. Nenhum soak foi executado. Ver
> `evidence/2026-08-02-r2-instrument-audit/verdict.md`, seção "What this does
> NOT establish".

“Produção restrita” significa que plataforma, protocolo, topologia, tipos de
handler e carga ficam dentro de `docs/supported-profile.md`. Não significa
framework geral nem compatibilidade com qualquer aplicação Odin.

## 1. Entregáveis

| ID | Entregável | Saída principal | Estado |
|---|---|---|---|
| R2-WP01 | auditoria e correção do instrumento | soak capaz de explicar toda falha | **fechado** 2026-08-02 |
| R2-WP02 | pré-registro e qualificação do host | ambiente/candidato congelados | **fechado** 2026-08-03 |
| R2-WP03 | observabilidade fora da zona cega | saturation e scrape distinguíveis | **fechado** 2026-08-02 |
| R2-WP04 | soak escalonado e final de 12 h | estabilidade do candidato | aberto — smoke e burn-in PASS nas taxas re-derivadas (pré-registro §4.1); rehearsal em curso; finais bloqueados por §4.2 |
| R2-WP05 | capacidade, knee e degradação | envelope e SLO operacional | aberto — bloqueado por WP04 |
| R2-WP06 | segurança e supply chain | corpus, SBOM, rebuild e vendor policy | aberto — 8 de 8 itens executados 2026-08-03: F-005, SECURITY.md, rebuild, BOM, framing pelo proxy, fuzz, revisão de endpoints, pins F8/F12/F-007. Achados abertos: TRUST-001, SHADOW-001 |
| R2-WP07 | canário e rollback produtivo | composição real validada | aberto — degrau 1 (shadow) entregue 2026-08-03; degraus 2–6 como risco aceito (§8.1) |
| R2-WP08 | freeze/aceite de risco | decisão Tier 2 | aberto — critério de saída emendado 2026-08-03 (§9.1) |

### R2-WP01 — fechado

Doze achados por leitura (`INS-001` a `INS-012`) e um décimo terceiro
encontrado ao **executar** o instrumento reparado (`INS-013`): num host sem
`nstat`, `pipefail` matava o sampler na primeira iteração e o artefato de doze
horas resultante — sem telemetria alguma — era classificado como PASS.

Dos oito artefatos de referência hoje commitados em `ops/soak/fixtures/`, o
instrumento anterior aprovava três que deveriam ser vermelhos e travava em dois
sem produzir veredito nenhum.

Entregue: `ops/soak/schema.md` (`soak/1`), `ops/soak/preflight.sh`,
`ops/soak/fixtures/`, `ops/soak/campaigns/TEMPLATE.md`, correções em
`run-soak.sh` e `analyze-soak.py`, sete critérios novos em `CRITERIA.md`, e
`build/check_soak_controls.sh` expandido para 26 asserções — oito controles
negativos obrigatórios mais três dos achados da auditoria.

Evidência: `evidence/2026-08-02-r2-instrument-audit/`.

## 2. Etapa A — instrumento antes do produto

### R2-WP01 — auditar `ops/soak`

**Achado:** AUD-P1-003 e falha histórica de diagnosabilidade.

#### Defeito já localizado

Em `ops/soak/run-soak.sh`, o sampler atual faz conceitualmente:

```text
stats_http="$(curl ...)" || true
stats_curl_exit=$?
```

O `true` sobrescreve `$?`; `stats_curl_exit` tende a registrar zero mesmo quando
o curl falha. Corrigir sem desligar `set -e` global de forma ampla: capturar
status num `if` ou numa região mínima com `set +e`, restaurando imediatamente.

Esse bug precisa de um mutante: provocar refused/timeout/empty reply e exigir
que os exit codes 7/28/52/56 permaneçam distinguíveis. Nenhum soak começa antes
desse controle ficar verde.

#### Auditoria completa do instrumento

Revisar:

- `ops/soak/run-soak.sh`
- `ops/soak/analyze-soak.py`
- `ops/soak/CRITERIA.md`
- `ops/soak/openload/`
- `ops/soak/soak-server/`
- `build/check_soak_controls.sh`
- `ops/soak/experiments/run-saturation-attribution.sh`

Responder:

1. Todo child exit diferente de zero chega ao veredito?
2. `planned`, `completed`, status e failures fecham aritmeticamente?
3. Falhas injetadas são separadas das espontâneas sem desaparecer do total?
4. CSV raw possui timestamp absoluto e classe para cada failure?
5. Counter do kernel é delta desde baseline ou valor global indistinguível?
6. `stats_http`, curl exit e arquivo JSON são atomicamente correlacionados?
7. O processo que morre antes de `final-state.txt` produz FAIL explicável em
   vez de exceção do analisador?
8. Perfis ausentes têm motivo pré-registrado?
9. CPU affinity/host topology realmente existem antes de `taskset`?
10. Manifesto rejeita tree suja ou toolchain diferente?

#### Arquivos previstos

- modificar os cinco componentes acima conforme a auditoria;
- criar `ops/soak/preflight.sh`;
- expandir `build/check_soak_controls.sh`;
- criar fixtures em `ops/soak/fixtures/` para PASS, classified FAIL,
  unclassified FAIL, child death e missing final-state;
- criar `ops/soak/schema.md` ou schema JSON versionado para os artefatos;
- gerar `evidence/YYYY-MM-DD-r2-instrument-audit/`.

#### Controles negativos obrigatórios

- zerar curl exit;
- descartar `failure_examples`;
- aumentar `completed` sem classe/status correspondente;
- retirar um workload sem registrar `skipped`;
- remover um sample de stats;
- simular server death antes do cleanup;
- alterar critério depois do manifesto;
- mudar binário após hash e antes do run.

#### Aceite

- cada fixture produz veredito e razões exatas;
- erro do instrumento nunca vira PASS;
- o analyser não depende de arquivos que o runner pode deixar de criar sem
  emitir diagnóstico;
- critérios e schema têm versão/hash no manifesto;
- `build/check_soak_controls.sh` está no gate principal e prova os mutantes.

## 3. Etapa B — candidato, SLO e host

### R2-WP02 — pré-registro

Criar `ops/soak/campaigns/YYYY-MM-DD-<candidate>.md` **antes** do primeiro run,
contendo:

- hipótese e não-hipóteses;
- commit/tree/binários/toolchain;
- host e isolamento;
- workloads/rates/connections;
- SLOs, budgets e tolerâncias;
- critérios de abort e invalidação;
- comparações permitidas;
- plano de repetição;
- owner e janela.

#### Preflight do host dedicado

- mínimo 8 CPUs quando a campanha usar 0–3/4–7;
- CPU governor e turbo registrados;
- NUMA/topologia registrada;
- sem vizinho ruidoso conhecido;
- swap policy registrada;
- nofile, memlock, cgroup e kernel compatíveis;
- `nstat`, `taskset`, `curl`, Go e Odin nas versões previstas;
- portas livres e relógio UTC sincronizado;
- espaço em disco estimado para CSV bruto de 12 h;
- gerador e servidor em CPU sets distintos;
- smoke de upload/stream/proxy antes da carga.

Se o host não satisfizer a topologia, alterar o plano e commitá-lo antes do
run; não adaptar affinity silenciosamente durante a campanha.

#### SLO inicial a decidir

O projeto já possui critérios técnicos em `ops/soak/CRITERIA.md`; R2 adiciona o
SLO do serviço. Definir, por workload:

- disponibilidade/status esperado;
- p50/p95/p99 máximo abaixo do knee;
- erro/recusa permitido e política de retry;
- orçamento de scrape ausente;
- tempo de recuperação após saturação;
- memória/FD/thread stability;
- RTO do restart e rollback.

Não copiar números de microbenchmark como SLO.

#### R2-WP02 — fechado 2026-08-03

**Host qualificado:** `184.72.201.140`, `c5.2xlarge`, Xeon 8275CL, Ubuntu 26.04,
kernel `7.0.0-1006-aws`, 143 GiB livres. `preflight=pass`, `smoke=pass` nas três
pernas sem override. Evidência: `evidence/2026-08-02-r2-host-qualification/`.

**Pré-registro commitado antes de qualquer run**, em
[`../../ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md`](../../ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md),
com o SLO do serviço e **origem declarada por número** — 1 `measured`,
11 `inherited` com citação, 18 `open` com o método de obtenção. Emendado duas
vezes, sempre antes de rodar: uma para a affinity, outra para a máquina.

**Affinity de registro:** servidor `0,1,4,5`, gerador `2,3,6,7`, `DRUSE_SOAK_LANES=2`.
Toda taxa de §4 rebaixada a carga oferecida inicial, sem base herdada (§3.4).

**Três defeitos do instrumento fechados, cada um com positivo e mutante:**

1. o preflight comparava os CPU sets como **strings** — `0-3` contra `4-7` numa
   c5.2xlarge passava, sendo os dois conjuntos as duas metades dos mesmos quatro
   cores. Mesma classe de INS-003 e INS-013;
2. **`RLIMIT_MEMLOCK` não era checado.** A AMI vem com 8 MiB e os rings do
   io_uring pinam contra isso — é o F-C03-2, que aparece como crash de startup;
3. o compilador era checado por **existir**, não por **compilar**. Um host com a
   toolchain pinada e sem `clang` passava no preflight e morria no primeiro link.

**A pergunta de topologia de 2026-07 está respondida.** O primeiro host designado
era a máquina das campanhas antigas; `lscpu -e` finalmente rodou nela: quatro
cores físicos, irmãos `(0,4) (1,5) (2,6) (3,7)`. Todas aquelas campanhas rodaram
com o gerador nos cores físicos do próprio servidor. Registrado, não corrigido —
emendar relatório publicado é decisão do dono.

**Achado de produto, fora do escopo deste WP:** `STREAM-001`, em
`evidence/2026-08-03-stream-truncation-finding/`. Um stream destacado pedido duas
vezes seguidas é truncado em silêncio (200 OK, zero diagnóstico). Reproduz em
dois servidores independentes, um deles no gate. Não corrigido aqui.

## 4. Etapa C — observabilidade que sobreviva à pressão

### R2-WP03 — fechado

**Braço B**, decidido em ADR-050 a partir da medição em
`evidence/2026-08-02-r2-observability-arms/`, com os critérios congelados antes
do run em [`R2-WP03-preregistration.md`](R2-WP03-preregistration.md) (G3).

Sob ocupação total e determinística das lanes, 120 amostras agendadas por braço:
o `baseline` (`/stats` como rota) respondeu **0 de 120** — o controle negativo
ficou vermelho, que era a condição para o run valer — e os braços A e B
responderam **120 de 120**. A e B **empataram** em disponibilidade e latência; a
decisão foi por **B4**, ambiguidade estrutural: toda ausência de A é um erro
HTTP, e cada um dos quatro erros HTTP é produzível tanto por uma aplicação que
parou quanto por uma rede que perdeu a troca. A torna o caso indistinguível mais
raro; ele não o remove. B não tem rede entre a métrica e o leitor, então as
causas que restam — `missing`, `unreadable`, `malformed`, `stale`, `no_process`
— nomeiam todas a aplicação.

**OBS-001, encontrado ao medir e não ao ler.** Todo contador de `Server_Stats` é
escrito quando o trabalho **termina**. Sob ocupação total nada termina, então
todos congelam, e a fórmula de utilização que a documentação ensina lê **zero**
quando a utilização é **um**. Um servidor saturado e um ocioso desenham as
mesmas linhas planas. Medido: 4 de 4 lanes dentro de handlers, 120 de 120
scrapes recusados por saturação, `handler_dwell_ns` = 0.

Entregue: quatro campos em `web.Server_Stats` (`active_connections`,
`handlers_active`, `handler_capacity`, `connection_capacity` — nenhum símbolo
novo, nenhum patch de vendor), exportador de referência em
`examples/10-config-and-health` e `ops/soak/soak-server`, `ops/monitoring/`
(formato, amostrador, regras de alerta, dashboard, medição de overhead),
`tests/r2-observability-saturation/`, `build/check_r2_observability_controls.sh`
com seis mutantes, e ADR-050 — que também responde a pergunta de agregação de
ADR-049 e **não** o fecha como recusado.

**Este WP não promove nada. O gate continua em R1.**

#### Residual declarado

**Conexões ativas × idle não foi separado.** `active_connections` é
"admitidas e ainda não fechadas". O backend mantém um `Connection_State` com
`.Idle`, mas o atribui por um ponto de estrangulamento **e** por três escritas
diretas (`.New`, `.Closing`, `.Closed`), então um contador no ponto de
estrangulamento subcontaria conexões que fecham direto a partir de `.Idle`.
Fazer certo é mudança de vendor nos quatro sítios, e ela não foi feita aqui.
Registrado como residual, não como concluído.

#### Análise de arquitetura (histórico, como o WP foi especificado)

Comparar, com dois braços:

1. listener administrativo em outro `App` no mesmo processo, com lanes e
   conexão reservadas;
2. processo/sidecar administrativo separado, lendo métricas exportadas por
   mecanismo bounded.

O primeiro isola saturação de lanes, mas não fault/OOM do processo. O segundo
isola domínio de falha, mas exige canal/ownership novo. Não criar API pública
antes da medição e do ADR.

#### Sinais mínimos

- readiness/draining;
- capacity de handlers resolvida e ocupação atual;
- conexões ativas/idle e recusas de saturação;
- responses/bytes/send errors/write aborts;
- FDs, RSS/HWM, threads e restart count do processo;
- ListenDrops/ListenOverflows e retransmits do host;
- scrape success/latency e causa da ausência;
- proxy upstream connect errors/retries/active connections.

Manter cardinalidade limitada e nenhuma string derivada de request nos eventos
do framework.

#### Arquivos previstos

- modificar `ops/soak/soak-server/main.odin` apenas após a decisão de braço;
- modificar `examples/10-config-and-health/`;
- criar `ops/monitoring/` com regras/dashboard de referência;
- criar `tests/r2-observability-saturation/`;
- criar `build/check_r2_observability_controls.sh`;
- atualizar `docs/reference/observability.md` e runbook.

#### Aceite

- saturation de aplicação é distinguível de perda de rede;
- scrape ausente é alerta, não dado interpolado;
- métricas continuam observáveis no braço escolhido ou a perda possui causa
  registrada pelo sampler externo;
- restart e draining aparecem na timeline;
- overhead abaixo do budget pré-registrado.

## 5. Etapa D — soak escalonado

### R2-WP04 — executar, não apenas planejar

Executar a mesma build/configuração em quatro degraus:

| Degrau | Duração | Objetivo | Pode promover? |
|---|---:|---|---|
| smoke | 10 min | wiring, schema, clocks, hashes | não |
| burn-in | 30 min | toda classe de workload/fault aparece | não |
| rehearsal | 2 h | detectar drift rápido e estimar volume de evidência | não |
| final | ≥12 h | critério de estabilidade R2 | sim, se PASS |

Falha num degrau interrompe os seguintes. Uma correção reinicia no smoke com
novo candidato. Não concatenar runs de builds distintas para formar 12 h.

#### Workloads mínimos

- health/admin;
- tiny response;
- JSON encode/decode em tipos representativos;
- resposta 64 KiB e corpo grande/spool;
- handler bloqueante com timeout próprio;
- slow reader;
- keep-alive/pooling via proxy real;
- RST/disconnect injetado;
- stream longo;
- stop/drain pelo menos uma vez em rehearsal separada, não no run de
  estabilidade se o critério exige processo único sobreviver 12 h.

#### Critérios mínimos

Manter os nove de `ops/soak/CRITERIA.md` e acrescentar:

- zero failure sem classe/texto/timestamp;
- zero descompasso aritmético;
- zero morte/restart no run de estabilidade;
- thread count explicável e estável;
- FDs retornam à faixa de baseline;
- RSS tail slope dentro do teto pré-registrado;
- nenhum kernel drop não explicado;
- stats/monitoring conforme budget;
- binários/configs idênticos ao manifesto.

#### Evidência

`evidence/YYYY-MM-DD-r2-soak-<candidate>/` segue a convenção do índice e inclui
o output integral do analyser. Preservar também runs RED; não sobrescrever
diretórios nem publicar apenas o melhor repeat.

## 6. Etapa E — capacidade e degradação

### R2-WP05 — definir o envelope, não um recorde

Reutilizar:

- `bench/application_matrix/run-rate-sweep.sh`
- `bench/application_matrix/run-openload-matrix.sh`
- `bench/application_matrix/summarise-rate-sweep.py`
- `bench/application_matrix/summarise-openload-matrix.py`
- `ops/campaign/`

#### Pré-condições do benchmark

- bytes/status/headers equivalentes entre candidatos;
- open-loop para encontrar knee;
- alternating order e repeats;
- afinidade e build mode fixados;
- servidor e gerador sem disputar CPUs;
- zero falha unclassified;
- p50 lido junto com share served para detectar rate censurado.

#### Matriz

Medir ao menos 50%, 75%, 90%, 100%, 110% e 130% do knee encontrado para:

- tiny;
- JSON pequeno/médio e body dominante em floats/maps quando aplicável;
- upload/body grande;
- resposta grande e slow reader;
- mix com blocking I/O;
- streams;
- proxy direto versus real.

Variar `max_handlers`, `max_connections` e pool upstream dentro de um plano
fatorial pequeno. Não otimizar três dimensões ad hoc depois do resultado.

#### Saídas

- knee/goodput e latências;
- refusal/503/timeout por classe;
- retry amplification;
- CPU/RSS/FD/connections/lanes;
- recovery time depois da sobrecarga;
- configuração recomendada e safe operating region;
- comparação com Axum, Gin/net-http e fasthttp/Fiber somente onde o harness
  prova trabalho equivalente.

O resultado vira `docs/performance-envelope.md`, com hardware e limites em
destaque. Não transformar uma linha de endpoint em promessa geral.

## 7. Etapa F — segurança e supply chain

### R2-WP06 — fechar a assurance do candidato

#### Trabalho de segurança

- adicionar raw-wire para F-005: header block excessivo exige 431 e close;
- mutante restaura silent drop e precisa ficar vermelho;
- revisar pins indiretos F8, F12 e F-007 contra o threat model R2;
- repetir smuggling/framing pelo proxy real para detectar divergência de parser;
- executar fuzz/corpus sanitizado no candidato;
- revisar todos os endpoints administrativos, upload, static e trust proxies;
- atualizar `SECURITY.md` para WP123, perfil e patch count real.

Uma varredura nova é recomendada porque a reconciliação atual explicitamente
não reescaneou o produto após várias fases. Finding novo recebe severidade,
reprodução, fix, teste e disclosure handling; não é corrigido apenas no report.

#### Vendor e supply chain

- reconciliar `vendor/odin-http/VENDOR.md` com `planning/vendor-policy.md`;
- eliminar numeração duplicada e definir ID estável por patch;
- registrar upstream commit, arquivo, motivo, teste e disposição;
- gerar inventário SPDX/CycloneDX se a ferramenta suportar Odin; caso contrário,
  produzir BOM versionada com hashes sem chamar o resultado de SBOM compatível;
- provar rebuild a partir de clone limpo/toolchain pin;
- comparar hashes de dois builds no mesmo ambiente; se não reprodutíveis,
  registrar fontes de nondeterminismo;
- assinar checksums/release conforme política do projeto.

#### Arquivos previstos

- `tests/wp9-wire/` ou corpus de suporte correspondente;
- `build/check_security_backlog.sh`;
- `build/check_vendor_policy.sh`;
- `vendor/odin-http/VENDOR.md`;
- `planning/vendor-policy.md`;
- `SECURITY.md`;
- criar `ops/release/build-release.sh` e `ops/release/verify-release.sh`;
- criar `evidence/YYYY-MM-DD-r2-security-supply-chain/`.

## 8. Etapa G — canário

### R2-WP07 — produção real com blast radius limitado

#### Pré-condições

- soak final PASS;
- capacidade e configuração aprovadas;
- proxy/security/supply chain aprovados;
- runbooks e alertas ativos;
- rollback ensaiado em R1;
- dados/rotas do canário definidos e reversíveis.

#### Progressão sugerida

1. shadow ou replay sanitizado, sem resposta ao usuário;
2. 1% de tráfego idempotente;
3. 5%;
4. 25%;
5. 50%;
6. 100% apenas dentro do serviço restrito.

Cada degrau tem janela mínima definida pelo SLO e número suficiente de eventos;
tempo sozinho não é critério. Promoção é manual e registrada.

#### Abort automático

- erro/status inesperado acima do budget;
- latência sustentada acima do SLO;
- restart, OOM, FD drift ou scrape gap não explicado;
- divergência de resposta contra controle;
- retry amplification acima do limite;
- qualquer evento de segurança ou dados.

Rollback preserva logs antes de retirar o candidato. Não “corrigir ao vivo” no
mesmo artefato.

### 8.1 O degrau 1 não precisa de tráfego real — corrigido em 2026-08-03

O R2-WP07 esteve registrado como **“bloqueado em tráfego produtivo real”**, e
essa leitura estava errada. O degrau 1 da progressão acima é *“shadow ou replay
sanitizado, **sem resposta ao usuário**”* — um degrau cuja definição é a ausência
de usuário. Ele precisa de candidato, da borda suportada e de tráfego em forma de
produção; os três existem. Bloqueado estavam os degraus 2 a 6, não o primeiro.

**Entregue:** `ops/canary/run-shadow.sh`, `ops/canary/shadow_replay.py`,
`ops/canary/containment_check.py`, o perfil declarado em
`ops/canary/shadow-profile.md` e o controle
`build/check_shadow_containment.sh` — positivo verde e cinco mutantes vermelhos.

**“Sem resposta ao usuário” é feito de quatro coisas**, três asseguradas e uma
que virou achado:

| # | Propriedade | Como se obtém |
|---|---|---|
| K1 | endereço de escuta do candidato | **registrado, não asseverado** — ver abaixo |
| K1b | todo peer que falou com o candidato era o proxy | observação amostrada durante toda a janela |
| K2 | o proxy fixado publica só em `127.0.0.1` | `docker inspect`, todo `HostIp` tem de ser loopback |
| K3 | a contabilidade **fecha** sem resto | log de acesso do proxy reconciliado contra a contagem do próprio driver, com os health probes internos do Caddy declarados e contados à parte |

K3 é a única que sobrevive a outra topologia: *toda requisição que a borda serviu
é uma que o shadow enviou*. Uma resposta que chegou a um usuário é uma requisição
servida que ninguém aqui enviou, e isso aparece como **resto não contabilizado**
em vez de como uma ausência que alguém precisa notar.

#### SHADOW-001 — o Druse não sabe escutar só em loopback

`web.serve(&app, port)` recebe uma porta e **nenhum endereço**, e o transporte
faz bind em dual-stack Any — `::`, caindo para `0.0.0.0`
(`web/internal/transport/odin_http_adapter.odin`). **Não há como pedir a uma
aplicação Druse que escute apenas em loopback.**

Para o shadow isso remove a contenção natural. Para qualquer implantação
significa que o processo é alcançável em toda interface que o host tiver, e
confiná-lo é trabalho do firewall do host e não da aplicação — uma restrição
operacional real que `docs/supported-profile.md` hoje **não** enuncia.

Nenhuma API é inventada aqui (G5: um plano pode nomear uma necessidade pública,
não pode inventar assinatura). A necessidade fica nomeada; K1b é o substituto e é
**mais fraco em espécie** — uma propriedade vale sempre, uma observação vale
sobre a janela em que observou — e o manifesto rotula assim.

#### Degraus 2–6: risco aceito formal, não “bloqueado”

Os degraus de 1%, 5%, 25%, 50% e 100% exigem tráfego de usuários reais. Este
projeto não tem nenhum. “Bloqueado” não é um estado de encerramento — o README
do programa lista três: concluído, **risco aceito** (com owner, escopo, validade
e mitigação) e fora do perfil. Este é o segundo, redigido para ser assinado no
freeze do R2-WP08:

| Campo | Conteúdo |
|---|---|
| **Risco** | a composição do candidato com tráfego real nunca foi exercida. Diversidade de cliente, distribuição de keep-alive, mistura de rotas, tamanhos de corpo e concorrência reais são todos **declarados** (`shadow-profile.md` §2), não amostrados |
| **O que já cobre parte dele** | o shadow exercita a topologia suportada inteira — Caddy fixado, TLS, keep-alive, streams, corpos variados — e o R1 já exerceu shutdown, rollback e o contrato do proxy na mesma borda |
| **O que continua descoberto** | qualquer falha que só apareça sob distribuição real: cabeçalhos de clientes que ninguém previu, padrões de conexão de CDN, picos correlacionados, e o comportamento do rollback com usuários em voo |
| **Escopo** | somente o perfil de `docs/supported-profile.md`, atrás do proxy revisado, num serviço restrito |
| **Mitigação** | o degrau 1 roda antes de qualquer promoção; alertas e runbooks do R1 ativos; rollback ensaiado e medido (3 s, `evidence/2026-08-02-r1-pilot-exercise/`); o primeiro serviço real **é** o degrau 2 e será tratado como canário, com abort automático pela lista do §8 |
| **Validade** | até o primeiro tráfego de usuário real existir, e no máximo até a próxima revisão do gate |
| **Owner** | o dono do repositório — este documento propõe, não aceita: um risco aceito por quem o descobriu não é aceite |

**Isto não promove nada.** Um risco aceito é uma decisão registrada sobre
evidência que não existe; não é evidência.

## 9. R2-WP08 — freeze e decisão

### Pacote de decisão

- identidade do candidato;
- resultados R1 carregados;
- auditoria do instrumento;
- soak completo e repeats;
- envelope de capacidade;
- security/supply-chain;
- relatório do canário;
- riscos aceitos com validade;
- perfil suportado final;
- plano de suporte e próxima revisão.

### Critérios de saída

- zero P0/P1 aberto sem aceite formal;
- soak ≥12 h PASS pelos critérios pré-registrados;
- toda falha classificada;
- SLO e safe operating region publicados;
- observabilidade mantém diagnóstico sob saturação;
- proxy real, segurança e rebuild aprovados;
- canário e rollback concluídos;
- **o hash do artefato implantado é o hash aprovado** — emendado em 2026-08-03,
  ver §9.1.

### 9.1 Emenda de 2026-08-03 — o objeto do critério mudou, o rigor não

**O critério anterior era “artefato implantado é byte-idêntico ao aprovado”, e
está medido como insatisfazível.**

`ops/release/verify-rebuild.sh` clonou o mesmo commit duas vezes, compilou com o
mesmo compilador fixado, na mesma máquina, e obteve
(`evidence/2026-08-03-r2-wp06-assurance/raw/rebuild-two-clean-clones.txt`):

```text
build_a_sha256=396138bbfa137a316085ff3e7e46b007e715e68f2a3c134959f751eced4eb83f
build_b_sha256=96d61da8e3f8818d509cb6cf47181f52fd1bca0050ffefa9c1760ff9de4ccb54
build_a_bytes=918640
build_b_bytes=918640
byte_identical=no
size_delta_bytes=0
```

Bytes diferentes, **tamanho idêntico**. A causa está fora do alcance deste
repositório — é a toolchain — e um critério vermelho para sempre por um motivo
que ninguém aqui pode remover não é rigor, é um critério que as pessoas aprendem
a ignorar.

**O que mudou é o objeto, não a exigência.** A leitura antiga exigia que *o
build* fosse reproduzível. A nova exige que *o artefato* seja o mesmo arquivo:

> compilar uma vez → hashear aquele arquivo → implantar **aquele** arquivo →
> provar que os bytes no alvo hasheiam para o valor aprovado.

**Isso é mais forte do que reproduzir o build, e a diferença é verificável.** Um
build reprodutível prova que dois compiladores concordaram; ele não diz nada
sobre o que foi para o alvo. Este critério tira a máquina de build da cadeia de
confiança inteira: os bytes revisados são os bytes que rodam, e a afirmação é
sobre o único artefato que serve tráfego.

**O que a emenda perde, dito porque perde mesmo.** Byte-identidade daria uma
segunda propriedade — qualquer pessoa poderia reconstruir o artefato a partir da
fonte e conferir. Isso não é recuperado aqui e não é reivindicado em lugar
nenhum: a nota de release diz *“construído a partir deste commit com este
compilador”*, e `approve-artefact.sh` grava essa distinção dentro do próprio
registro (`not_claimed=`), para que um leitor do artefato não precise achar este
parágrafo.

**Instrumento**, com controle positivo e cinco mutantes (G2):

| Arquivo | Papel |
|---|---|
| `ops/release/approve-artefact.sh` | grava o registro de aprovação: hash, tamanho, commit, tree, toolchain; **recusa** árvore suja |
| `ops/release/verify-deployed.sh` | hasheia o arquivo no alvo e compara; `deployed_identity=match` ou falha |
| `build/check_release_identity.sh` | positivo verde + M1 byte trocado, M2 mesmo tamanho e conteúdo diferente, M3 registro editado, M4 arquivo ausente, M5 registro sem hash |

O mutante **M2 é o que importa**: ele reproduz exatamente a forma que a medição
acima produziu — mesmo tamanho, conteúdo diferente — porque qualquer atalho que
compare comprimento passaria nele. Aqui isso é errado por demonstração, não por
princípio.

**Por que isto respeita G3.** G3 congela critérios antes do *run* que promove.
Nenhum run de promoção do R2-WP08 aconteceu — o WP08 é a decisão final e está
aberto. A emenda nomeia a medição que a forçou, preserva o artefato dessa
medição, e a medição é sobre a toolchain, não sobre um resultado do candidato
que alguém quisesse contornar. O critério continua exigindo uma prova
criptográfica sobre o artefato implantado; mudou de qual artefato ela fala.

`ops/release/verify-rebuild.sh` **continua no lugar** e continua sendo rodado:
ele não é mais um critério de saída, é a medição que mantém a fonte de
não-determinismo registrada. Se um dia a toolchain passar a reproduzir,
`byte_identical=yes` aparece nele e a byte-identidade volta a ser exigível — o
controle falha de propósito se aquele arquivo deixar de dizer
`byte_identical=no`, para que a volta seja uma decisão e não um esquecimento.

### Resultado permitido

- **PROMOTE TO R2:** produção apenas no perfil publicado;
- **HOLD AT R1:** evidência insuficiente ou SLO não atingido;
- **REVOKE:** regressão, identidade quebrada ou risco crítico.
