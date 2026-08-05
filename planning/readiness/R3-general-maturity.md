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

> **Instanciada em 2026-08-03.** O dono declarou a ambição — *"pronto para
> produção, sem limitações bloqueantes"*, com custo alto aceito — e
> [`R3-programa-sem-limitacoes-bloqueantes.md`](R3-programa-sem-limitacoes-bloqueantes.md)
> é o documento que a registra, classifica quais limitações declaradas são de
> fato bloqueantes, e sequencia as trilhas abaixo que o gatilho autoriza. Ele
> **não substitui** esta seção: a ratificação por ADR que ela exige foi feita
> em **2026-08-05 — ADR-052** (`planning/adrs.md`): o dono ratificou a ambição
> como *"um framework para outras pessoas usarem"*, campo a campo como esta
> seção exige, inclusive o que a decisão não compra.
>
> O resultado da classificação, resumido: o conjunto bloqueante é {L1 fault de
> handler, L6 release/LTS, L2 handlers síncronos — condicional}, e **nenhum dos
> três é um dos alvos caros** (R3-C plataformas, R3-D async amplo, R3-E
> protocolos). Esses ficam por gatilho, `DEFERRED` sem vergonha.

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
| R3-WP10 | contenção de falha de handler | manter N=1, ou processos worker — **Etapa 1 fechada** 2026-08-02 (ADR-051); Etapa 3 bloqueada por um ponto de entrada em `nbio` |

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

### R3-WP10 — contenção do fault de handler

**Entrada:** ADR-049 (PROPOSED) e R2-WP03 concluído. **Não começar antes do
WP03**, pelo motivo registrado no ADR: N processos tornam `web.stats()` uma
resposta por processo, e um `/stats` que parece global sem ser é pior que
nenhum.

> **R2-WP03 fechou em 2026-08-02, e este bloqueio caiu — só ele.** ADR-050
> escolheu um canal fora do caminho de request, e sob esse canal a agregação
> entre processos é possível: cada worker escreve seu próprio snapshot, o
> sidecar soma e publica `workers_seen` contra `workers_expected`. ADR-049 **não**
> foi fechado como recusado, porque a condição que o recusaria não se verificou.
>
> **O custo virou requisito de entrada deste WP:** o supervisor precisa publicar
> `workers_expected`, e ele não pode vir de contar arquivos. Um agregado é tão
> honesto quanto esse número, e um `workers_expected` errado reproduz exatamente
> o defeito — um número que parece global e não é — um nível acima.
>
> As outras dependências continuam abertas e nenhuma foi tocada por WP03:
> orçamento de memlock/RSS/FDs refeito para N > 1
> (`evidence/2026-08-01-r1-resource-budget/` foi produzida para N=1), semântica
> de drain por worker, rollback para N=1 sem rebuild, e a campanha de fault cujo
> **controle negativo em N=1 tem de ficar vermelho** ou ela não mediu contenção.

Hoje um fault de handler custa **100% da capacidade e toda conexão em voo**.
ADR-020 fecha a recuperação em definitivo e ADR-047 já decidiu o diagnóstico;
esta trilha trata apenas do **raio**, que nenhum dos dois tocou.

#### Braços

Os três de ADR-049, com a viabilidade já medida na árvore:

| Braço | Perda ao morrer um worker | Custo |
|---|---|---|
| A — `SO_REUSEPORT` | a accept queue daquele worker | 1 linha vendorizada (patch 44) |
| B — listener herdado | nenhuma | ponto de entrada novo no nbio |
| C — pre-fork | nenhuma | fork + threads + io_uring, sem precedente |

#### Etapa 1 fechada em 2026-08-02 — medida, e o resultado mudou o plano

`evidence/2026-08-02-r3-worker-budget/`, decisão em **ADR-051**.

**O orçamento de recursos NÃO é o obstáculo.** Por worker, com 4 lanes: 14 FDs,
5 threads, 5 rings io_uring, ~1020 KiB de bytes de ring, `VmLck` 0, ~4,5 MiB de
RSS — e **tudo constante em N** (W1 passou). `LimitMEMLOCK` é um RLIMIT, por
processo, com ~64× de folga; ele só apertaria por volta de 320 lanes num único
processo contra um máximo de 32. O que muda de significado é **`MemoryMax`**, que
é do cgroup e passa a ser dividido por N sem que nada no unit diga isso.

**A viabilidade registrada em ADR-049 estava errada em dois pontos**, ambos
verificados: `net.Socket_Option.Reuse_Port` vale **`-1`** em Linux (só FreeBSD o
implementa), e o caminho de bind do produto é **`core:nbio`**, não `vendor/nbio`
— que é importado por dois benches e por mais nada. A "uma linha" seria um no-op
num arquivo que o servidor não usa.

**Consequência: A e B convergem no mesmo requisito ausente** — `nbio` não sabe
adotar um socket que não criou — e a vantagem de custo de A desaparece.
**Nenhum braço foi adotado**, e isso **não** é "manter N=1": o custo de recursos
se paga; falta um ponto de entrada em `nbio`, que é trabalho nomeável.

**Bloqueio da Etapa 3.** A campanha de fault (F1 e o controle negativo F1n em
N=1) **não rodou e não podia rodar** — ela exige um braço implementado. Nenhuma
contenção foi demonstrada.

**Próximo:** um ponto de entrada em `nbio` que adote um socket existente. Como
`core:nbio` é do toolchain fixado e não vendorizado, isso é upstream ou uma
decisão de vendorizar o pacote — decisão de política, não detalhe.

#### O que precisa ser medido antes de escolher

O orçamento de recursos do R1 foi derivado para **N=1** e não transfere:
memlock (um ring io_uring por lane, agora × N), `MemoryMax`, `LimitNOFILE`.
`evidence/2026-08-01-r1-resource-budget/` teria de ser refeita para N>1 antes
de qualquer unit template ir para `ops/deploy/`.

#### Provas mínimas

- **Controle positivo:** matar um worker sob carga; as requisições nos demais
  workers não falham.
- **Controle negativo:** a mesma campanha com N=1 tem de ficar **vermelha**.
  Sem isso a campanha não mediu contenção — mediu que o serviço estava de pé.
- drain por worker não fecha admissão dos outros (o modo de falha que
  `tests/wp123-two-servers` já cobre dentro de um processo);
- `stats` agregado ou explicitamente por processo, decidido no WP03;
- orçamento de recursos refeito para N>1;
- rollback para N=1 sem rebuild;
- `docs/supported-profile.md` emendado no mesmo commit do comportamento.

#### Resultado permitido

- **manter N=1:** o custo de recursos ou de observabilidade não se paga;
- **adotar processos worker:** com braço nomeado, evidência de contenção e
  perfil emendado.

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
