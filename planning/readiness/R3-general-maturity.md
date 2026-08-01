# R3 — plano opcional de maturidade geral

**Status:** PLANO CONDICIONAL.
**Entrada:** R2 sustentado em produção restrita e decisão explícita de ampliar a
promessa do produto.
**Objetivo:** reduzir riscos estruturais de backend, plataforma, runtime,
release e ecossistema até uma classe de maturidade comparável — não idêntica —
a frameworks estabelecidos.

R3 não deve existir apenas para “continuar o roadmap”. Cada trilha começa por um
gatilho de demanda ou risco medido e pode terminar em **não fazer**. Produção
restrita saudável é um estado final válido.

## 1. Decisão de ambição

Antes de qualquer implementação, o owner escolhe um alvo:

| Alvo | Promessa | Custo permanente |
|---|---|---|
| R3-A | HTTP/1.1 Linux x86-64, mas com releases/suporte maduros | baixo-médio |
| R3-B | backend substituível e menor fork | médio-alto |
| R3-C | mais plataformas/toolchains | alto |
| R3-D | workload blocking/async mais amplo | alto e arquitetural |
| R3-E | HTTP/2/WebSocket nativos | muito alto; protocolo novo |
| R3-F | ecossistema integrado validado | médio, multi-repositório |

Os alvos são independentes. Não agrupar todos em “1.0” sem budget, owner e
demanda. Registrar a escolha em ADR com:

- problema observado;
- usuários/workloads que o têm;
- baseline R2;
- custo máximo aceitável;
- compatibilidade exigida;
- estratégia de rollback;
- condição de abandono.

## 2. Entregáveis

| ID | Trilha | Resultado possível |
|---|---|---|
| R3-WP01 | histórico de produção e requisitos | promover, adiar ou recusar trilhas |
| R3-WP02 | backend/vendor | reconciliar, segundo adapter ou migração |
| R3-WP03 | toolchain/plataformas | política estável e matriz real |
| R3-WP04 | blocking/cancelamento | manter sync, isolar ou adicionar runtime |
| R3-WP05 | protocolos | delegar ou implementar por requisito |
| R3-WP06 | releases/compatibilidade/suporte | processo de release maduro |
| R3-WP07 | druse-crystals/ecossistema | integração opcional verificada |
| R3-WP08 | feedback, incidentes e upgrade | battle-hardening documentado |
| R3-WP09 | freeze de maturidade | decisão sobre 1.0/nível suportado |

## 3. Etapa A — aprender com R2

### R3-WP01 — evidence backlog de produção

Coletar por pelo menos a janela definida pelo owner — preferencialmente várias
releases, não apenas dias:

- incidentes e quase-incidentes;
- razões de rollback;
- classes de handler e dependências usadas;
- saturation/refusal/retry reais;
- crashes, OOM, FD/memlock e drain;
- features pedidas e workarounds;
- tempo de upgrade de Odin/vendor/Druse;
- fricção de onboarding e operação;
- patches do backend que mais custam manutenção.

Criar:

- `planning/readiness/r3-evidence-backlog.md`;
- `docs/reports/YYYY-MM-DD-production-learning.md` por revisão;
- template de postmortem em `docs/runbooks/postmortem-template.md`;
- gate que proíba trilha R3 sem citar item real do backlog ou risco aceito R2.

#### Critério de entrada por trilha

- backend: rebase/defeito/custo medido;
- plataforma: consumidor real ou política comercial explícita;
- async/blocking: SLO/capacidade impossíveis dentro do modelo atual;
- protocolo: requisito de cliente que proxy não satisfaz;
- crystals: aplicações reais dependem do conjunto e precisam de compatibilidade.

Sem gatilho, a decisão é `DEFERRED`, não `TODO`.

## 4. Etapa B — backend e vendor

### R3-WP02 — reduzir a superfície de fork

**Risco:** AUD-P2-008.

#### Análise 1 — reconciliação completa

Para cada patch local, registrar ID estável, origem, classe e destino:

- bug upstream independente → oferecer upstream;
- política Druse → manter no adapter/core;
- bridge temporária → carregar com condição de saída;
- código morto → remover;
- divergência cuja necessidade desapareceu → retirar.

Arquivos:

- `vendor/odin-http/VENDOR.md`
- `planning/vendor-policy.md`
- criar `vendor/odin-http/PATCHES.json` ou TSV canônico, se um formato
  machine-readable simplificar o gate;
- `build/check_vendor_policy.sh`.

Evitar duas fontes manuais. O documento humano deve ser gerado ou validado
contra o inventário canônico.

#### Análise 2 — três braços

| Braço | Descrição | Prova necessária |
|---|---|---|
| A | manter backend vendorizado reconciliado | custo de rebase aceitável e todos os patches pinados |
| B | segundo adapter experimental | corpus neutro completo e ausência de leak de tipos |
| C | migrar para futuro `core:net/http` | API disponível, capabilities suficientes e performance/corretude equivalentes |

Não escolher B/C por preferência. Prototipar em `experiments/` e executar a
mesma matriz sem alterar a API pública.

#### Corpus de equivalência do adapter

- semantic matrix;
- raw-wire/framing;
- limits/deadlines;
- saturation/refusal;
- stats/observer;
- stop/drain;
- stream/upload;
- multi-server;
- fault campaigns;
- proxy real.

Criar `tests/transport-adapter-conformance/` somente quando existir segundo
adapter. O corpus deve receber factory/driver neutro; não duplicar expectativas.

#### Aceite

- nenhum patch sem owner/test/disposição;
- troca de backend não altera ledger público;
- equivalência byte/comportamento dentro do contrato;
- regressão de desempenho/memória dentro de budget pré-registrado;
- rollback de build para backend anterior continua disponível por uma janela
  definida, sem manter dois caminhos indefinidamente.

## 5. Etapa C — toolchain e plataformas

### R3-WP03 — transformar pin em política de suporte

O pin atual é forte, mas não responde por quanto tempo uma versão é suportada
nem como upgrades são qualificados.

#### Trabalho

- definir cadence de avaliação do Odin mensal;
- manter `odin-version.txt` como versão única suportada por release;
- criar job allowed-to-fail para próximo Odin e job obrigatório para o pin;
- registrar breaking changes e migration notes;
- medir tempo/custo de cada bump;
- definir janela de suporte de releases Druse e política de backport.

Arquivos previstos:

- `docs/toolchain-policy.md`;
- `docs/upgrade-guide.md`;
- `CHANGELOG.md`;
- `ops/ci/install-odin.sh`;
- `.github/workflows/` e `ops/ci/`;
- `build/check_toolchain_policy.sh`.

#### Plataforma

Separar níveis:

- **compile-only:** fontes não Linux compilam/stubam corretamente;
- **runtime smoke:** serve/route/stop em host real;
- **supported:** corpus, soak curto, packaging e owner.

Não promover macOS/Windows por compile-only. Para cada plataforma candidata:

1. inventariar dependências io_uring/Linux;
2. escolher backend/event loop;
3. executar adapter conformance;
4. executar proxy/supervisor equivalentes;
5. executar soak e resource accounting próprios;
6. documentar diferenças inevitáveis.

Se o custo duplicar o transporte e não houver consumidor, manter Linux-only é
decisão madura, não deficiência escondida.

## 6. Etapa D — modelo de execução

### R3-WP04 — blocking, isolamento e cancelamento

Usar `planning/sync-async-evaluation.md` e a evidência da Phase 9 como entrada;
não repetir a discussão do zero.

#### Perguntas

1. O problema é CPU, blocking I/O, FFI não cancelável ou composição de
   deadlines?
2. Mais lanes resolvem sem piorar memória/tail?
3. Processo worker resolve melhor que runtime async?
4. O código bloqueante aceita cancel token/deadline?
5. Como shutdown, ownership e arena atravessam a fronteira?

#### Braços

| Braço | Uso | Risco |
|---|---|---|
| manter sync + processos | CPU/FFI não cancelável | operação mais pesada, isolamento forte |
| bounded worker pool | blocking jobs conhecidos | filas/cancelamento/ownership novos |
| adapter async oficial | I/O com primitives maduras | grande mudança de execução |
| runtime próprio | somente se nenhum anterior atende | custo máximo e risco de scheduler |

O último braço é presumido recusado até evidência extraordinária.

#### Provas mínimas

- zero lifetime escape de `Context`/arena;
- fila e memória limitadas;
- cancellation observável;
- shutdown não espera indefinidamente por trabalho cancelável;
- FFI não cancelável continua isolada por processo/supervisor;
- fairness e starvation medidos;
- comparação com baseline sync em p50/p99, CPU, RSS e complexidade de uso;
- fault de worker não corrompe resposta ou registry.

Qualquer API pública passa pelos guardrails e por estudo de uso. Não expor
futures/tasks apenas porque o backend interno mudou.

## 7. Etapa E — protocolos

### R3-WP05 — HTTP/2 e WebSocket por requisito, não checklist

#### Gate de decisão

Para cada protocolo responder:

- qual workload não funciona via proxy/delegação atual?
- é requisito end-to-end ou apenas cliente→proxy?
- qual biblioteca/backend implementa parsing, flow control e segurança?
- qual novo estado/lifetime entra no core?
- quais ataques e corpus precisam ser adicionados?
- qual custo binário/dependência/suporte?

#### HTTP/2

Se cliente→proxy atende o produto, permanecer delegado. Implementação nativa
exige pelo menos:

- HPACK e limites de header/table;
- streams multiplexados e flow control;
- GOAWAY/drain;
- prioridades/fairness conforme política escolhida;
- h2c/TLS/ALPN decididos;
- request smuggling/downgrade entre proxy e backend;
- corpus e soak específicos.

#### WebSocket

Antes de adicionar, comparar com SSE + upload/HTTP normal. Se necessário:

- handshake/upgrade;
- frame parser, masking, fragmentation e limits;
- ping/pong/idle;
- backpressure;
- cross-thread send/lifetime;
- drain/close codes;
- proxy interop e segurança.

Nenhuma assinatura é pré-definida neste plano. Prototipar em `experiments/`,
especificar, estudar uso e só então considerar API.

## 8. Etapa F — releases e suporte

### R3-WP06 — processo compatível com adoção externa

#### Entregáveis

- política semver ou política pré-1.0 explícita;
- calendário e janela de suporte;
- release checklist automatizado;
- changelog e upgrade guide por release;
- source archive mínimo verificado;
- checksums/assinatura/proveniência;
- política de CVE/advisory/backport;
- deprecation window;
- teste de consumo por vendoring/submodule, coerente com Odin sem package
  manager oficial;
- rollback e compatibilidade de configuração.

Arquivos previstos:

- criar `docs/release-policy.md`;
- criar `docs/compatibility-policy.md`;
- criar `ops/release/`;
- atualizar `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md` e README;
- criar `build/check_release_artifact.sh`.

#### 1.0

Só considerar 1.0 quando:

- API e comportamento tenham janela real de produção;
- upgrades tenham sido executados por aplicações externas ao core;
- suporte/toolchain/vendor estejam definidos;
- P0/P1 históricos estejam fechados e postmortems incorporados;
- user study e documentação para consumidor tenham passado;
- a equipe aceite o custo de compatibilidade, não apenas o valor de marketing.

## 9. Etapa G — druse-crystals e ecossistema

### R3-WP07 — integração sem acoplar a corretude do core

Crystals continuam outro repositório e não viram dependência do `web`.

#### Trabalho

- checkout por commit pinado no CI de integração;
- manifesto de compatibilidade Druse ↔ crystals ↔ Odin;
- compilar/testar todos os pacotes, eliminando o estado “28 de 29 unchecked”;
- executar aplicações de composição com DB, client HTTP, metrics e jobs;
- verificar deadlines e shutdown fim a fim;
- manter custo zero quando crystal não é importado;
- versionar contrato de integração e política de releases coordenadas;
- separar falha do crystal, core e ambiente no relatório.

Arquivos no Druse:

- `ops/ci/run-crystals-integration.sh`;
- `build/check_crystals_manifest.sh`;
- `docs/ecosystem-compatibility.md`;
- apenas fixtures de consumidor, nunca import de crystal em `web/`.

Arquivos no repositório crystals precisam de plano/PR próprios; este documento
não autoriza alteração externa silenciosa.

#### Aceite

- 100% dos pacotes declarados presentes e verificados;
- matriz de compatibilidade publicável;
- falha de integração reproduzível localmente;
- releases podem ser independentes ou a dependência coordenada está explícita;
- nenhum símbolo crystal entra no ledger do core por conveniência.

## 10. Etapa H — battle-hardening contínuo

### R3-WP08 — incidentes, upgrades e feedback

Criar um ciclo trimestral ou por release:

1. revisar incidentes/SLO/capacity;
2. reclassificar risks e triggers;
3. executar upgrade rehearsal;
4. revisar vendor/upstream e toolchain;
5. rodar security scan/fuzz/corpus;
6. verificar docs/runbooks contra exercício real;
7. entrevistar consumidores e registrar fricção;
8. decidir se o perfil cresce, permanece ou encolhe.

Maturidade inclui retirar promessa que não se consegue sustentar.

## 11. R3-WP09 — freeze

### Matriz de decisão

Cada trilha apresenta:

- gatilho original;
- alternativas medidas;
- decisão e ADR;
- arquivos/API afetados;
- custos de build/runtime/operação;
- testes/mutantes;
- evidência de host/canário;
- rollback;
- custo anual de manutenção.

### Critérios de saída gerais

- R2 permaneceu saudável durante a execução;
- nenhuma expansão quebre o perfil restrito existente sem migration path;
- backend/vendor e toolchain possuem owners e políticas;
- plataformas anunciadas têm runtime evidence;
- protocolos anunciados têm corpus, proxy interop e drain;
- modelo de execução continua bounded e diagnosticável;
- releases/compatibilidade/suporte estão publicados;
- crystals está validado como integração opcional;
- riscos restantes estão explícitos.

### Resultados permitidos

- **R3 MATURITY ACHIEVED:** somente para as trilhas escolhidas e provadas;
- **R2 REMAINS THE PRODUCT:** decisão válida quando expansão não se paga;
- **TRAIL REJECTED:** protótipo/evidência mostrou custo ou risco excessivo;
- **REVOKE/ROLLBACK:** regressão no perfil produtivo anterior.
