# Programa: produção sem limitações bloqueantes

**Status: PROPOSED, 2026-08-03. O dono ratifica a decisão de ambição (§2) por
ADR antes de qualquer implementação — é a exigência de
`R3-general-maturity.md` §1, e este documento existe para instanciá-la, não
para contorná-la.**

**O pedido do dono, verbatim como diretriz:** *"quero um framework pronto para
ser usado em produção, sem limitações bloqueantes"* — sabendo que o custo é
alto. Isso é um gatilho de demanda legítimo sob a regra do R3: o gatilho é a
declaração de ambição do dono, registrada aqui e no ADR de ratificação.

**Entradas.** `docs/supported-profile.md` (as limitações declaradas);
`planning/runtime-feasibility-study.md` (o instrumento certo por limitação);
`planning/runtime-feasibility-audit-2026-08-03.md` (as correções da auditoria);
ADR-051 (o bloqueio real do WP10); `planning/sync-async-evaluation.md` (o
contrato do braço worker-pool).

**A tese do programa em uma frase:** *"sem limitações bloqueantes" é muito
mais barato que "sem limitações"* — porque, classificadas honestamente, as
limitações mais caras não são bloqueantes, e as bloqueantes têm instrumento
nomeado e medido. Nenhuma fase deste programa exige o runtime.

---

## 1. O que "bloqueante" significa, para não virar palavra elástica

Uma limitação é **bloqueante** se satisfaz pelo menos um:

- **B-op:** impede um sistema real típico de rodar em produção com segurança
  operacional (acordar de madrugada por bug de aplicação);
- **B-adoção:** impede um consumidor externo de adotar o framework mesmo
  querendo (sem release, sem janela de suporte, sem upgrade path);
- **B-classe:** exclui uma classe inteira e comum de aplicação (ex.: apps cujo
  request é dominado por I/O bloqueante).

Não é bloqueante o que é **prática padrão da indústria** (rodar atrás de
proxy), o que é **dívida interna** invisível ao usuário (o fork), nem o que
restringe **amplitude** sem impedir produção (Linux-only — a produção alvo é
Linux).

### 1.1 As limitações declaradas, classificadas

| # | Limitação (`supported-profile.md`) | Classe | Por quê |
|---|---|---|---|
| L1 | handler que falha mata o processo (`:54-56`) | **BLOQUEANTE (B-op)** | bug de aplicação é inevitável; custar o processo inteiro e toda conexão em voo é o que separa "roda" de "roda sem medo". É a pior e a mais próxima de resolver (ADR-051) |
| L6 | pre-1.0, sem backports/LTS (`:19-20`) | **BLOQUEANTE (B-adoção)** | ninguém externo adota sem política de release, janela de suporte e upgrade path. É a mais barata de todas |
| L2 | handlers síncronos; um ocupa uma lane (`:43-44`) | **BLOQUEANTE CONDICIONAL (B-classe)** | só morde apps com muito I/O bloqueante por request; para elas, morde forte. Instrumento: worker pool (braço B), não runtime |
| L5 | 43 divergências no fork (`:21-24`) | não bloqueante (dívida interna) | o usuário não vê; nós pagamos rebase. Reduzir é higiene, não desbloqueio |
| L4 | Linux x86-64 apenas (`:14-15`) | não bloqueante para produção; **B-adoção parcial** para dev | servidores de produção são Linux; o atrito real é dev em macOS/Windows. Nível "dev-smoke" resolve o atrito sem pagar "supported" |
| L3 | sem TLS/HTTP2/WS nativos; exige proxy revisado (`:28-39`) | **não bloqueante** | Gin/Axum em produção também rodam atrás de nginx/ALB/Caddy. Vira bloqueante apenas com requisito concreto (mTLS sem sidecar, WS end-to-end) — tratado por gatilho |

**Consequência estrutural:** o conjunto bloqueante é {L1, L6, L2-condicional}
— e nenhum dos três é o item "muito alto" da tabela do R3. Os itens caros
(R3-C plataformas, R3-D async amplo, R3-E protocolos) estão todos fora do
conjunto bloqueante ou entram só por gatilho. O programa explora isso.

---

## 2. A decisão de ambição a ratificar (minuta do ADR)

Conforme `R3-general-maturity.md` §1, campo a campo:

- **Problema observado:** o dono quer o Druse utilizável em produção real por
  terceiros, e o perfil atual contém três limitações bloqueantes (§1.1).
- **Usuários/workloads:** APIs HTTP/1.1 em Linux atrás de proxy — o shape da
  maioria das APIs em produção — incluindo apps com I/O bloqueante moderado e
  operadores que exigem contenção de falha e política de release.
- **Baseline:** R2 completo (pré-condição dura deste programa, §3 Fase 0).
- **Alvos comprados:** R3-A (releases) **integral**; R3-B (backend/fork)
  **integral**; R3-D **apenas o braço worker-pool** (não "async amplo");
  R3-WP10 **integral**. R3-C **apenas nível dev-smoke** por gatilho; R3-E
  **DEFERRED** por gatilho; R3-F conforme demanda de crystals.
- **Custo máximo aceitável:** declarado pelo dono no ADR (este documento
  estima por fase em §4).
- **Compatibilidade:** nenhuma fase quebra o ledger público sem major; o
  envelope N=1 atual permanece válido durante todo o programa (workers entram
  opt-in, §3 Fase 2).
- **Rollback:** cada fase lista o seu; nenhum é "rebuild".
- **Condição de abandono:** por fase, em §3; a do programa inteiro é o R2
  revelar que o envelope atual já cobre os sistemas-alvo do dono.
- **O que este ADR explicitamente NÃO compra:** um runtime próprio (§5), TLS
  nativo sem gatilho, HTTP/2/WS nativos sem gatilho, plataforma "supported"
  não-Linux.

### 2.1 O envelope-alvo, publicável no fim do programa

> Druse serve sistemas reais em produção: Linux x86-64, HTTP/1.1 atrás de um
> proxy revisado (a mesma topologia de qualquer API moderna), handlers
> síncronos com worker pool limitado para trabalho bloqueante, **falha de
> handler custa 1/N da capacidade** em vez do processo, releases com política
> publicada, janela de suporte e upgrade path, backend com fork reconciliado e
> seam de substituição provado. Dev em macOS compila e roda smoke.

Nada nessa frase exige runtime, e cada cláusula tem prova nomeada abaixo.

---

## 3. As fases

Formato: **entrada → trabalho → prova exigida → remove o quê → abandono →
rollback**. "R2-WPxx" e "R3-WPxx" são planos distintos — os números colidem
(R2-WP06 é segurança; R3-WP06 é releases); os prefixos são obrigatórios.

### Fase 0 — terminar o R2, e o dever de casa documental

**Entrada:** agora. O host está qualificado e ocioso; a pre-registration está
committada.

**Trabalho:**
- R2-WP04 soak escalonado → R2-WP05 capacidade/degradação → R2-WP06
  segurança/supply-chain → R2-WP07 canário (exige tráfego real; se não
  existir, o dono decide waiver explícito com escopo reduzido — decisão dele,
  registrada, não silêncio) → R2-WP08 freeze.
- Em paralelo (não usa o host): as 9 correções da auditoria no estudo
  (`runtime-feasibility-audit-2026-08-03.md`, seção "Recomendação"), incluindo
  commitar `tina/docs/` e resolver a divergência normativa
  `supported-profile.md:46-49` × C-05 (503 vs close silencioso).
- Em paralelo (só documentação): **começar R3-WP06 releases** — política
  pré-1.0, janela de suporte, checklist, changelog (`R3:377-397`). É a
  limitação L6 e não toca código nem host.

**Prova:** as provas do próprio R2; para L6, os arquivos de
`docs/release-policy.md` + `docs/compatibility-policy.md` + um release
executado pelo checklist.

**Remove:** L6 (B-adoção) — a mais barata das bloqueantes.

**Abandono:** n/a — R2 é obrigação, não opção.

### Fase 1 — a decisão de propriedade do `nbio` (a chave de tudo)

**Entrada:** pode ser decidida durante a Fase 0 (é ADR, não código). A
implementação espera o R2.

**Trabalho:** decidir **vendorizar `core:nbio`** (recomendado) ou upstream:

- *Vendorizar:* sincronizar `vendor/nbio` com o `core:nbio` do toolchain
  `819fdc7` (hoje o vendor é cópia usada só por 2 benches — ADR-051), trocar
  os imports do fork `odin-http` e do adapter para `druse:vendor/nbio`, gate
  completo. Precedente de capacidade: `vendor/uring_buf_ring` construído do
  zero contra kernel 6.8 (WP115). A política de vendor já governa deltas.
- *Upstream:* oferecer o entry point a `odin-lang`; mas o toolchain é pinado —
  um aceite upstream só chega no próximo bump. Fazer **em paralelo**, nunca
  como caminho crítico.
- Implementar o entry point: `nbio` **adota um socket que não criou** (a peça
  que os braços A, B e socket-activation compartilham — ADR-051,
  `adrs.md:2864-2867`).

**Prova:** gate completo verde com os imports trocados; teste novo do entry
point; C-01 (inventário de ops assíncronas) atualizado — o check
`build/check_c01_controls.sh` obriga.

**Remove:** nada diretamente — **desbloqueia L1 (Fase 2) e L4/L5 (Fase 3-4)**.

**Abandono:** se o gate revelar divergência comportamental
`core:nbio`→`vendor/nbio` não sanável, upstream vira o caminho e a Fase 2
espera um bump de toolchain — custo de calendário, registrado.

**Rollback:** reverter imports para `core:nbio` (o vendor fica na árvore, como
hoje).

### Fase 2 — R3-WP10: processos worker (mata a pior limitação)

**Entrada:** Fase 1 completa + R2 fechado (o WP10 já exigia R2-WP03, fechado).

**Trabalho:** braço **B (listener herdado)** — ADR-051 mostrou que A e B pagam
o mesmo entry point e B perde **zero** conexões da accept queue quando um
worker morre. Supervisor publica `workers_expected`; agregação de stats via o
canal do ADR-050; orçamento refeito para N>1 (`R3:307-309`); drain por worker;
rollback para N=1 sem rebuild.

**Prova (as do R3, sem desconto):** controle positivo — matar um worker sob
carga, requisições nos demais **não falham**; **controle negativo — a mesma
campanha em N=1 tem de ficar vermelha**, senão não mediu contenção; unit
template com `MemoryMax` contabilizado por slice.

**Decisão de topologia, explícita para não invalidar o R2:** workers entram
como **topologia opt-in documentada** ao lado do perfil N=1. Promoção a
default **só** depois de repetir para N>1 as campanhas do R2 cuja evidência é
topológica (soak, capacidade, canário curto). Até lá o perfil publica os dois
envelopes. Isso resolve o furo apontado pela auditoria (achado I.1).

**Remove:** **L1** — falha de handler passa a custar 1/N e a accept queue
sobrevive. A cláusula central do envelope-alvo.

**Abandono:** o do R3 — se a observabilidade agregada mentir
(`workers_expected` não confiável) ou o F1n não ficar vermelho, manter N=1 e
registrar.

**Rollback:** N=1 sem rebuild (prova exigida acima).

### Fase 3 — R3-WP02: o fork reconciliado

**Entrada:** independente; pode correr em paralelo com a Fase 2 (pessoas
diferentes) ou depois.

**Trabalho:** reconciliação completa das 43 divergências (ID, origem, classe,
destino — upstream / política / bridge-com-saída / morto / retirar), formato
machine-readable + `build/check_vendor_policy.sh` (`R3:91-113`).

**Prova:** nenhum patch sem owner/teste/disposição; ledger público inalterado.

**Remove:** L5 parcialmente (dívida vira inventário governado). A retirada
*total* do fork é a Fase 4 ou o futuro `core:net/http` (braço C do R3-WP02),
por evidência.

**Abandono:** n/a — reconciliar é sempre válido; só a *migração* tem braços.

### Fase 4 — abstração de backend + segundo backend (o seam vira prova)

**Entrada:** Fases 1-3. É a parte cara do programa; o dono pode pará-lo aqui
com L1/L6/L5-parcial já removidas.

**Trabalho:** formalizar o contrato do adapter
(`tests/transport-adapter-conformance/` só nasce com o segundo adapter —
`R3:138-140`); construir o segundo backend. **Escolher o segundo backend por
dupla utilidade: kqueue/macOS** — prova o seam **e** compra L4 no nível
"dev-smoke" (compila, serve/route/stop em macOS real), sem prometer
"supported" (`R3:183-190` define os níveis; não promover por compile-only).

**Prova:** corpus de equivalência completo do R3-WP02 (semantic, raw-wire,
limits, saturação, stats, drain, stream/upload, fault, proxy real) rodando
contra os dois backends via factory neutra.

**Remove:** L4 no nível que importa para adoção (dev em macOS); L5 ganha a
saída definitiva (backend substituível ⇒ o fork é um backend entre dois).

**Abandono:** se o corpus provar que o contrato vaza tipos do backend no
ledger público, parar e redesenhar a fronteira antes de continuar — não
carregar dois backends com contrato furado.

### Fase 5 — R3-WP04 braço worker-pool (L2, a condicional)

**Entrada:** **gatilho medido**, como o R3 exige — mas o gatilho é barato de
instrumentar: o R2-WP05 (capacidade) já produz a matriz de workloads; a célula
"synthetic wait / PostgreSQL" dela é o número que decide. Se o knee de apps
I/O-bound ficar limitado por lanes com CPU ociosa, o gatilho disparou.

**Trabalho:** o braço B do contrato `sync-async-evaluation.md` §3, como está
escrito: handler inteiro no worker, lane fica com a conexão, fila hard-capped
com `Full`/timeout, **reusando o substrato de stream** (registry, delivery
limitada, wakeup — `sync-async-evaluation.md:66-69`); gate de equivalência
funcional §4 antes de qualquer número de performance.

**Prova:** as "provas mínimas" do R3-WP04 (`R3:222-232`): zero escape de
lifetime de `Context`/arena, cancelamento observável, fairness medida,
comparação com baseline sync em p50/p99/RSS, fault de worker não corrompe
registry. STREAM-001 é o memento: todo índice reciclado nesse caminho ganha
geração.

**Remove:** L2 para a classe de apps que a sente.

**Abandono:** o do contrato — se o pool não vencer o baseline sync fora do
ruído nos workloads com wait ≫ service, manter sync puro e registrar.

### Fase 6 — protocolos e o resto, por gatilho (fica DEFERRED sem vergonha)

- **TLS nativo:** só com requisito concreto (mTLS sem sidecar, edge sem
  proxy). Se vier, é um projeto com corpus próprio — e nota da auditoria: nem
  o Tina o tem; não há atalho por runtime.
- **HTTP/2 / WebSocket:** o gate de decisão do R3-WP05 como está
  (`R3:330-371`). WebSocket compara com SSE primeiro.
- **R3-WP03 plataformas "supported":** só com consumidor real.
- **R3-WP07 crystals / R3-WP08 battle-hardening:** pelo ciclo do R3, alimentado
  pelo backlog do R3-WP01 — que passa a existir porque o R2 terá produção.

**Nada aqui é bloqueante pela definição de §1; deixar DEFERRED é o programa
funcionando, não falhando.**

---

## 4. Custo, na moeda da casa

Estimativas relativas (a moeda absoluta é do dono; a tabela do R3 §1 é a
referência de classe). "Host" = dias de máquina de campanha.

| Fase | Classe de custo | Forma do custo | Observação |
|---|---|---|---|
| 0 (R2) | já orçado no R2 | ~29h de host no soak + dias no WP05 + WP06 de engenharia | obrigação preexistente |
| 0b (R3-WP06 releases) | **baixo** | documentação/processo, 1 release ensaiado | melhor razão custo/desbloqueio do programa |
| 1 (nbio) | **baixo-médio** | ADR + sync do vendor + entry point + gate | o precedente WP115 diz que sabemos fazer |
| 2 (WP10) | **médio** | supervisor + agregação + campanha F1/F1n + orçamento N>1 | recursos já medidos (ADR-051): 14 FDs/~4,5 MiB por worker |
| 3 (fork) | **médio** | 43 disposições + gate | trabalho de formiga, zero risco de produto |
| 4 (backend) | **alto** | contrato + segundo backend + corpus 2× | a fase que o dono pode adiar sem perder L1/L6 |
| 5 (pool) | **médio-alto** | braço B completo + equivalência funcional | gatilho vem de graça do R2-WP05 |
| 6 | por gatilho | — | DEFERRED é resultado válido |

**Leitura honesta:** as três limitações bloqueantes custam
{baixo, baixo-médio+médio, médio-alto-condicional}. O "custo alto" que o dono
aceitou pagar mora quase todo na Fase 4 e na Fase 6 — que são as não
bloqueantes. O programa entrega o envelope-alvo de §2.1 sem precisar delas
além do nível dev-smoke.

---

## 5. O runtime: decisão permanente, critérios de reabertura

Presunção herdada do estudo e confirmada pela auditoria: **recusado**. Não por
dogma — pelos três fatos que decidiram viabilidade (blocos 0, 3 e 5) e pela
matriz §0.1. Reabre-se apenas se:

1. um gatilho da Fase 5/6 exigir suspensão real que o worker pool não entrega
   **medido** (o contrato §7 do sync-async-evaluation decide); ou
2. o Odin mudar de posição sobre concorrência (B0 diz que não vai); ou
3. surgir campanha de fault-injection sobre recuperação in-process (estilo
   Tina) com controle negativo vermelho e invariantes preservados — o único
   resultado que reabriria a linha 1 da matriz por outra via.

Enquanto nenhum ocorre, cada fase acima permanece útil num mundo com ou sem
runtime — foi o critério de desenho da ordem.

## 6. Higiene de medição que este programa herda da auditoria

- o two-box continua devido (agora como confirmação, não precondição), e a
  carga distribuída (4 dst IPs) nunca rodou no código com dedicated accept;
- a refutação do `DEFER_TASKRUN` é irrastreável (possível no-op em
  `vendor/nbio`); se a Fase 1 vendorizar o nbio, re-rodar essa medição custa
  uma tarde e fecha a dúvida de vez;
- qualquer número novo segue `benchmark-methodology.md` — número
  irreproduzível é anedota com casas decimais.

## 7. O que o dono precisa decidir para o programa começar

1. Ratificar a decisão de ambição (§2) por ADR — inclusive o que ela **não**
   compra.
2. Fase 1: vendorizar vs upstream-e-esperar (recomendação: vendorizar, com
   upstream em paralelo).
3. R2-WP07: existe tráfego real para o canário, ou waiver com escopo reduzido?
4. O custo máximo aceitável da Fase 4, que é onde o programa fica caro — e se
   ela entra agora ou após as Fases 0-3 provarem o resto.
