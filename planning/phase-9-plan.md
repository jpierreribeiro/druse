# Plano — Fechar o gap de performance vs Go net/http (arquitetura de I/O)

## Context

Numa campanha de otimização medida em AWS c5 (8 vCPU, não-burstable), provamos que o
Druse pode competir com o Go net/http numa rota trivial (`GET /ping`), mas identificamos
um gap real. O owner quer **≥ Go em todos os aspectos** (throughput, latência, CPU),
autorizou a mudança arquitetural (projeto grande), e pediu para eu **estudar o netpoller do
Go, aplicar as ideias, medir, e documentar esta etapa**.

**Decisão explícita do owner (2026-07-25):** manter os **241k req/s** do PoC v1 **E** melhorar
latência e CPU ao mesmo tempo, **escrevendo infraestrutura do ZERO se necessário.** Isso
autoriza diretamente a Fase B (accept dedicado → recupera os 241k *com* a garantia) e a Fase A
(multishot recv + provided buffers → ataca o CPU), ambas construindo a infra que o Odin não
tem (os stubs `unimplemented()` no uring). O caminho deixa de ser "patch incremental" e passa a
ser "construir a base de I/O correta".

### Estado medido (c5, `GET /ping`, keep-alive, wrk -c100)

| Build | req/s | p99 | CPU | Garantia WP71 | Gates |
|---|---|---|---|---|---|
| baseline | 80k | 517ms | 521% | ✅ | ✅ |
| **p28** (mergeável) | 108k | **149µs** | 355% | ✅ | ✅ (141 PASS) |
| v1 (PoC, descartado) | 241k | 3.2ms | 382% | ❌ quebra | ❌ |
| Go net/http | 181k | 3.57ms | **176%** | — | — |

**p28 esmaga o Go em latência (p99 24×), preserva a garantia, passa tudo — está commitado
(`651804b`) e deve ser mergeado.** Falta throughput e CPU.

### Por que não conseguimos "manter os 241k" (a pergunta do owner)

Os 241k do **v1** vêm de **não suspender o accept** — o que quebra a garantia WP71 (uma
conexão de health nova nunca deve ficar presa atrás de uma lane bloqueada num handler
síncrono). No modelo atual, **accept e handler compartilham a mesma thread-lane**, então
para honrar a garantia a lane precisa cancelar seu accept antes de bloquear — e é esse
cancel-por-request que custa o throughput. **A única forma de ter os 241k COM a garantia é
tirar o accept da thread-lane** (accept dedicado). Isso é arquitetura, não patch.

### Por que o CPU é o mais difícil (fato medido)

**Até o v1 (sem nenhuma garantia, o teto de perf) perde em CPU pro Go: 382% vs 176%.** Logo
o gap de CPU **não é a dança de accept** — é **syscalls por request**. Cada request no
Druse faz recv one-shot (+re-arm), send, accept re-arm. O Go amortiza tudo isso.

## O estudo (o que aprendi das fontes primárias)

### Go netpoller (`runtime/netpoll.go`, `netpoll_epoll.go`)
- **Um** poller multiplexa milhares de fds com **epoll edge-triggered** (`netpollopen` arma
  ET). Edge-triggered reduz drasticamente syscalls sob carga (não re-arma por evento).
- Goroutine que faz I/O sem dados prontos é **estacionada** (removida da run queue); quando
  o fd fica pronto, `netpollready` a devolve à run queue de um P. Sem spin, sem busy-wait.
- Eficiência = **poucos syscalls amortizados + batching** (um `epoll_wait` colhe muitos
  eventos) + goroutines baratas. É isso que dá os 176% de CPU.

### io_uring multishot + provided buffers (o equivalente moderno, e mais eficiente)
- **`IORING_RECV_MULTISHOT`**: um único SQE de recv continua entregando um CQE por chegada
  de dados, **sem re-arm** — elimina o syscall de recv por request.
- **Provided buffer ring** (`IORING_REGISTER_PBUF_RING` + `IOSQE_BUFFER_SELECT`): o kernel
  escolhe um buffer de um pool pré-registrado por recv; o CQE carrega o buffer ID. Elimina
  o mapeamento por-I/O e reduz cópias.
- **`IORING_ACCEPT_MULTISHOT`**: um SQE de accept persistente entrega um CQE por conexão —
  elimina o re-arm do accept **e** a dança de cancel/re-arm.
- **Bloqueio no Odin:** `core/sys/linux/uring/ops.odin` tem `provide_buffers`,
  `remove_buffers`, `read_multishot` como **stubs `unimplemented()`**; não há
  `recv_multishot`/`accept_multishot` nem `setup_buf_ring`. **A infra precisa ser construída
  do zero** na camada uring → nbio → odin-http.

### Conclusão de design
As duas metas restantes têm dois levers distintos:
- **CPU** → multishot recv + provided buffers (menos syscalls/request; o análogo do
  edge-triggered do Go, mas melhor).
- **Throughput + garantia (os 241k de volta)** → multishot accept **numa thread de accept
  dedicada**, separando accept das lanes de handler (garantia estrutural, sem cancel/request).

## Fase 9 — Arquitetura de I/O e paridade de performance (WP114–WP121)

Tratada como uma **Fase formal do projeto**, na convenção Druse: último WP foi WP113
(Fase 8); corretivos foram C1–C7. Esta é a **Fase 9**, WPs a partir de **WP114**. Cada WP
segue o ritual: **Spec Gate** (contrato + evidência requerida) → implementação com RED test
→ **Test Gate** (todos os gates verdes + benchmark) → **Freeze** (medição no registro). Nenhum
WP avança com um gate vermelho.

### WP114 — Mergear o p28 (a fundação)
Já commitado (`651804b`). PR + merge (com o `go` do owner). Base correta para o resto.
DoD: PR aberto, suíte verde na c5, merge autorizado.

### WP115 — Provided-buffer ring no `core/sys/linux/uring` (infra, do zero)
Implementar os stubs `unimplemented()`: `setup_buf_ring`/`provide_buffers` via
`IORING_REGISTER_PBUF_RING`, e decodificação de `IORING_CQE_F_BUFFER`/`F_MORE`. Vendorizar o
uring no Druse (não tocar o toolchain global). Spec Gate: contrato do buffer ring + prova de
lifecycle (recicla, sem UAF). DoD: prototipo pinado registra e recicla buffers sob io_uring.

### WP116 — `recv_multishot` no `core/nbio`
Expor recv multishot (`IORING_RECV_MULTISHOT` + `IOSQE_BUFFER_SELECT`) sobre WP115; callback
entrega buffers que o consumidor recicla. DoD: um echo multishot roda; buffers reciclados;
teste de memory safety verde.

### WP117 — Reescrever o path de recv do scanner (odin-http)
`vendor/odin-http/scanner.odin:263` (`nbio.recv_poly`, one-shot) → multishot + provided
buffers, reciclando após o parse. **Preservar todos os invariantes de framing** (patches
vendored + wire corpus). Test Gate: framing/wire corpus + suíte completa verdes. **Medir CPU**
vs Go/p28 — alvo: CPU rumo aos 176% do Go. Freeze: número no registro.

### WP118 — `accept_multishot` no uring/nbio
`IORING_ACCEPT_MULTISHOT` (accept persistente, sem re-arm). DoD: accept multishot entrega N
conexões de um SQE; teste verde.

### WP119 — Accept dedicado / thread-per-core (recupera os 241k COM garantia)
Mover o accept para **fora** das lanes de handler — thread(s) de accept (multishot, ou
SO_REUSEPORT por core) que entregam a conexão a uma lane livre. O handler **nunca toca o
accept** → a garantia WP71 vira **estrutural** e a dança cancel/tick por request (PATCH 28)
**desaparece** → recupera ~241k **com** a garantia. Spec Gate: o novo modelo de propriedade da
conexão + como a garantia WP71 é honrada estruturalmente. **Medir throughput** — alvo ≥ 241k,
p99 baixo, wp71/c05 verdes.

### WP120 — Reconciliar admissão e drain no novo modelo
`max_connections`/budget/refusal-503 (WP47/WP71) e o drain (WP59/C-05) sob accept dedicado.
Test Gate: `check_wp71_controls.sh`, `check_c05_controls.sh`, saturação (503 gracioso), drain
limpo — todos verdes.

### WP121 — Convergência, verdicto e freeze da Fase 9
Combinar tudo, medir o quadro completo vs Go (throughput, p50/p90/p99, CPU, syscalls/request),
e registrar honestamente onde igualamos/superamos e onde não (o CPU pode não igualar 100% o
netpoller de 15 anos do Go — medir, não prometer). Freeze da Fase 9 com a tabela final.

## Documentação desta etapa (entregável explícito pedido pelo owner)

Criar **`planning/perf-netpoller-study-and-architecture.md`** contendo:
- O estudo do netpoller do Go (edge-triggered, parking, batching) com fontes.
- O estudo de io_uring multishot + provided buffers e o gap do Odin (stubs).
- A resposta "por que não 241k" (accept compartilha a thread-lane).
- O design da Fase 9 (WP114–WP121) e os alvos de medição.
- Uma tabela viva de resultados medidos por WP (atualizada a cada medição).

Este doc é o **plano-mestre da Fase 9** (o análogo dos `planning/phase-N-plan.md`); os WPs o
refinam conforme executam.

## Arquivos críticos
- `core/sys/linux/uring/ops.odin` — stubs a implementar (`provide_buffers`,
  `read_multishot`; adicionar `recv_multishot`/`accept_multishot`/`setup_buf_ring`).
- `core/nbio/{ops,nbio,impl_linux}.odin` — expor multishot + buffer ring.
- `vendor/odin-http/{scanner,server}.odin` — reescrever recv e accept paths.
- `web/internal/transport/odin_http_adapter.odin` — reconciliar admissão/drain.
- `planning/perf-netpoller-study-and-architecture.md` — a documentação da etapa.

## Verificação (por WP, sem exceção)
1. **Correção primeiro:** `check_wp71_controls.sh`, `check_c05_controls.sh`, os testes de
   framing/wire corpus, e a suíte completa (`build/check.sh`) — todos verdes na c5.
   Nenhum WP avança com um gate vermelho (a disciplina que matou o v1 e o p29).
2. **Memory safety:** provided buffers reciclados corretamente (sem UAF, sem vazamento) —
   validar sob o teste de saturação c05 e um soak.
3. **Benchmark:** `wrk -t4 -c100` /ping vs Go/baseline/p28 em cada fase; A/B lado a lado na
   mesma caixa; registrar req/s, p50/p90/p99, CPU, e syscalls/request (`strace -c`).
4. **Ambiente:** caixa c5 não-burstable + (para o número publicável) uma caixa geradora
   separada. Terminar ao fim; o ambiente é scriptado.

## Regras de engajamento (as que nos trouxeram até aqui)
- Medir antes de afirmar; refutar é resultado válido (V1, p29, submit-only morreram na
  medição — cada morte foi progresso).
- Mudanças no toolchain (uring/nbio) são de dependência séria: vendorizar no Druse, não
  modificar o toolchain global; documentar cada patch.
- Não prometer "≥ Go em CPU" antes de medir; entregar a verdade dos dados.
