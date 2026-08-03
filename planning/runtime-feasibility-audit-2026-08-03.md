# Auditoria adversarial do estudo de viabilidade do runtime

**Status: AUDITORIA, 2026-08-03. Encomendada para derrubar o estudo, não para
validá-lo.** Alvo: `planning/runtime-feasibility-study.md` no PR #165
(`study/runtime-feasibility`, commit `456dc0f`).

**Método.** Cada alegação abaixo cita arquivo e linha desta árvore, um commit,
ou uma fonte externa nomeada como tal. Rótulos: **[medido]** = fato medido neste
repositório; **[externo]** = evidência de fora, não re-verificada aqui;
**[inferência]** = leitura minha. Fontes do Tina foram verificadas contra o
dossiê fornecido pelo dono (3.185 linhas, conferido) **e** contra um clone do
repositório público `pmbanugo/tina` no commit `24b2cb9` — o mesmo que o dossiê
âncora.

**Veredito em uma linha: a recomendação final do estudo sobrevive ao ataque —
e sai mais forte — mas quatro seções contêm erros de fato ou de comparação que
precisam de correção antes de o documento virar base de decisão.**

| Achado | Gravidade | Seção do estudo |
|---|---|---|
| A. A "contradição de 3×" está resolvida no próprio repositório; a premissa "mesma flag ativa" é falsa | **alta** | §1.2, §1.3 |
| B. Dois itens de §1.1 apresentados como "settled" descrevem código aposentado; a refutação do `DEFER_TASKRUN` tem proveniência suspeita | **alta** | §1.1, §6b/B3 |
| C. O raciocínio que mata o arm F ("estritamente pior que hoje") está errado como comparação | **alta** | §6, §3.2 |
| D. `tina/docs/` não está no repositório nem no PR — as citações eram inverificáveis pela régua da própria casa | média | §0.2, §3.1–3.4 |
| E. §0.2 é defensável, mas usa o argumento mais fraco disponível; o forte é outro | média | §0.2 |
| F. "Mesmo primeiro passo" vale no nível de política, não no técnico | média | §0.3, §4.5 |
| G. B5 exagera a necessidade ("exige reimplementar o wire") e contradiz uma avaliação anterior da própria árvore | média | §5, §6b/B5 |
| H. A matriz omite duas limitações declaradas e superlativa uma linha | baixa-média | §0.1 |
| I. A ordem §8b tem um custo de re-medição não declarado (R2 em N=1 vs workers em N>1) | média | §8b |

---

## A. §1.2 — a contradição de 3× tem explicação documentada, e a premissa do estudo é falsa

O estudo afirma (linhas 156–158) que `DRUSE_DEDICATED_ACCEPT` é
`#config(..., true)`, e conclui: *"the adopted path is the default and **both
measurements describe code that ships**"*. Isso está errado, e o histórico do
git o prova:

- **[medido]** A re-medição de ~80k/116k foi commitada em `44a169f`
  (2026-07-25 **16:14** −0300). A adoção do dedicated accept é `1fcf071`,
  merge `5593536` (2026-07-25 **22:07/22:08** −0300).
  `git merge-base --is-ancestor 5593536 44a169f` → falha: o dedicated accept
  **não é ancestral** do commit da re-medição.
- **[medido]** `git show 44a169f:vendor/odin-http/server.odin` contém **zero**
  ocorrências de `DRUSE_DEDICATED_ACCEPT`. A flag não existia no código que
  mediu ~80k. As duas medições descrevem **código diferente**, e o código de
  ~80k não embarca mais.
- **[medido]** O próprio arquivo que o estudo cita resolve a divergência, no
  adendo imediatamente após a seção de re-medição
  (`planning/perf-netpoller-study-and-architecture.md:514–539`): *"The
  correction above accurately describes `origin/main`, but its conclusion …
  is superseded by a measured implementation."* O mecanismo é quantificado:
  `io_uring_enter` caiu de ~5,03 para **0,160/request** (31×) ao remover o
  cancel/re-arm de accept do hot path — exatamente o padrão iowait-bound que a
  re-medição diagnosticou (`perf-netpoller…md:448–452`). Um corte de ~50% de
  iowait mais a remoção do ciclo de accept explica a classe 80k → 259k; o
  próprio documento previa "roughly double" só do iowait
  (`perf-netpoller…md:507–509`).
- **[medido]** A proveniência dos 259k/283k é a mais forte da árvore: A/B de
  cinco runs contra o bound antigo, contador de syscalls por `perf stat`, gate
  completo verde, três campanhas C-03 consecutivas
  (`docs/reports/2026-07-25-dedicated-accept-throughput.md:59–66, 145–182`).

**Consequência para o estudo.** §1.3 ("não conseguimos afirmar o gap dentro de
3×") está errado como formulado. O melhor número do código que embarca é
259k/283k = 91,7%/96,6% de fasthttp — single-box. Isso **satisfaz o critério
de abandono §8.2 do próprio estudo** ("within ~20% of the fasthttp class")
antes do two-box. O two-box continua devido — mas como confirmação e higiene de
benchmark, não como "precondição para a decisão" (§1.3). **[inferência]** A
recomendação global sai fortalecida: o motivo velocidade fica ainda mais vazio.

**O que ainda não foi medido e mantém uma ponta solta [medido, por ausência]:**
a forma de carga distribuída (4 IPs de destino) da re-medição nunca foi
re-rodada sobre o código com dedicated accept. Nenhum relatório posterior a
2026-07-25 a repete (`docs/reports/` de 07-26 a 08-01). Se alguém quiser
manter viva a hipótese de que 259k é artefato de single-dst, este é o
experimento: repetir `wrk` 4×1-thread → `127.0.0.{1..4}` no binário atual.
Até lá, a leitura honesta é "resolvido por mudança de código, com confirmação
distribuída pendente" — não "contradição aberta de 3×".

## B. §1.1 — dois "settled" que não estão, e uma refutação com proveniência suspeita

### B.1 "Framework == bare nbio (~78k); o teto é a camada de I/O" — obsoleto

O estudo (linhas 132–136) cita `perf-netpoller-study-and-architecture.md §1`.
A medição real está em **outro arquivo** —
`planning/perf-wp-multishot-scanner.md:43–52` — e descreve o código
**pré**-dedicated-accept: framework a 4,97 enters/req, echo a 4,99
(`perf-wp-multishot-scanner.md:123–127`). O código default atual faz
**0,160 enters/req e 259k req/s** — 3,3× acima do "teto" de 78k. Um teto que
foi ultrapassado pelo próprio produto não é um fato settled; é história. O
estudo apresenta os dois números como verdades simultâneas (§1.1 e §1.2), o
que é internamente inconsistente.

### B.2 "`DEFER_TASKRUN` foi tentado e refutado" — proveniência não sustentada

A refutação (`perf-wp-multishot-scanner.md:68`; ecoada em
`perf-netpoller…md:456–459`) diz "patched into nbio, rebuilt, benchmarked —
throughput flat". Três fatos da árvore lançam dúvida sobre **qual nbio** foi
patchado:

1. **[medido]** A regra da casa era *"never modify the global toolchain:
   vendor into Druse"* (`perf-netpoller…md:172`).
2. **[medido]** A linha vizinha cita `COOP_TASKRUN` em
   `vendor/nbio/impl_linux.odin:139` — um arquivo que **o servidor não
   carrega**: ADR-051 verificou que `vendor/nbio` é importado por dois benches
   e nada mais, e que o produto usa `core:nbio` do toolchain
   (`planning/adrs.md:2842–2851`; confirmado: só
   `bench/echo_oneshot/main.odin` e `bench/echo_reuseport/main.odin` importam
   `vendor/nbio`).
3. **[medido]** ADR-051 documentou exatamente essa classe de engano — *"a 'uma
   linha' seria um no-op num arquivo que o produto não usa"* — **uma semana
   depois** do experimento DEFER_TASKRUN. Ninguém voltou para re-verificar a
   refutação sob essa luz.

Se o patch entrou em `vendor/nbio` e o benchmark rodou `web.app`, o
experimento benchmarkou um no-op — e "throughput flat" é o resultado garantido
de um no-op. **[inferência]** A refutação pode ser válida (o patch pode ter
ido no toolchain, contra a regra; ou o bench pode ter sido o echo, que importa
`vendor/nbio`), mas o registro não diz qual binário foi rebuildado, e a régua
da casa é que número irreproduzível é anedota. O estudo deveria rebaixar
"refuted" para "refutação de proveniência não rastreável; re-rodar se o lever
voltar a importar". O mesmo desconto vale para "`COOP_TASKRUN` was already
on": a citação aponta para o arquivo errado; que o `core:nbio` do toolchain
`819fdc7` ligue as mesmas flags é plausível (o vendor é cópia do pacote), mas
não está verificado nesta árvore.

### B.3 §6b/B3 usa um número aposentado como "our measured problem"

O estudo (linhas 548–550): *"Our measured problem is ~5 `io_uring_enter` per
request"*. Falso para o código default desde 2026-07-25: **0,160/request**
(`docs/reports/2026-07-25-dedicated-accept-throughput.md:63–66`). O alvo que o
SQPOLL atacaria já não existe. E o estudo diz "SQPOLL was never tested" sem
citar que a árvore **já analisou** SQPOLL e foi mais pessimista que a pesquisa
externa: *"removes the submit enter, but nbio still enters for `wait_nr>0`
completions … would need pairing with busy-poll reaping, and burns a full
core"* (`perf-wp-multishot-scanner.md:72`). A trilha "levers de syscall não
testados" de §8b precisa ser re-derivada contra o código atual antes de ser
oferecida como caminho — hoje ela persegue um problema que a árvore já
resolveu por outro meio.

## C. §6 arm F — "um handler bloqueante trava um shard inteiro, estritamente pior que hoje" está errado como comparação

O estudo (linhas 474–481): sob thread-per-core *"one blocking handler stalls
every connection on that core — **strictly worse** than today's bounded lanes,
where a blocked lane leaves the others running"*.

A comparação ignora o que o dedicated accept fez do modelo atual:

- **[medido]** Desde a adoção, uma conexão é **afim à lane pelo ciclo de vida
  inteiro**: *"keeps parsing, request dispatch, sends, deadlines, and teardown
  on that lane for the connection's entire lifetime"*
  (`docs/reports/2026-07-25-dedicated-accept-throughput.md:99–106`).
- **[medido]** O handler é síncrono e roda ocupando a lane
  (`docs/supported-profile.md:43–44`).

Logo, **hoje** um handler bloqueado já paralisa todas as conexões atribuídas à
sua lane — o mesmo raio 1/N de um shard bloqueado no thread-per-core. WP69/WP72
provam que as *outras* lanes progridem
(`planning/sync-async-evaluation.md:36–39`), exatamente como os outros shards
progridem no modelo Tina/Seastar. "Estritamente pior" é falso; é **o mesmo
raio de bloqueio**. A diferença residual real é menor e é outra: o acceptor do
Druse faz steering de conexões **novas** para a lane menos carregada
(`…dedicated-accept-throughput.md:102`), enquanto ingress por hash de
`SO_REUSEPORT` não faz — mas a topologia de coordenador do Tina faz (dossiê
`01-arquitetura-do-runtime.md:86–87`: *"um coordenador aceitando conexões e
transferindo FDs"*).

**O que de fato precifica o arm F, e o estudo não diz [inferência, sobre fatos
citados]:** adotar Tina como transporte troca um fork de 43 patches sobre
`odin-http` por dependência (ou fork) de **~53k linhas de runtime** de
mantenedor único, pre-1.0, sem prova de interop com proxies e clientes
diversos (dossiê `10-limitacoes…md:13`), **sem TLS** (dossiê
`05-tina-http.md:6–8` — portanto não remove a limitação 3), com router de scan
linear (dossiê `README.md:34–36`) e sem um único benchmark válido contra o
Druse (dossiê `10:17–20`). Isso recoloca a limitação 6 (pre-1.0, sem LTS) um
nível abaixo da pilha, maior do que era. O arm F não morre de "shard trava";
morre — ou é adiado — porque seu preço é virar co-mantenedor de um runtime,
pelo ganho líquido de duas limitações (4 e 5) que os passos 3–4 do §8b removem
mais barato. Essa é a conta que o §6 deveria fazer.

§3.2 em si (expor transições de dois bytes ao usuário destrói a proposta de
valor) permanece válido — o dossiê o confirma
(`08-comparacao-com-uruquim.md:35–44`) — mas ele responde ao arm E exposto ao
usuário, não ao híbrido do arm F.

## D. `tina/docs/` não está no repositório nem no PR #165

**[medido]** O PR #165 altera exatamente dois arquivos
(`planning/runtime-feasibility-study.md`, `planning/runtime-research-2026-08-03.md`).
Não há `tina/` em nenhum branch do remoto. O estudo cita o dossiê doze vezes,
com aspas verbatim. Pela régua que o próprio PR estabelece —
`planning/runtime-research-2026-08-03.md:5–9`: *"a summary that cannot be
checked against its source is an assertion"* — as seções §0.2 e §3.1–3.4
estavam apoiadas em fonte fora da árvore.

Verifiquei contra o material fornecido pelo dono e contra o clone público:

- dossiê: 3.185 linhas ✓; Tina em `24b2cb9`: 160 arquivos, 121 `.odin` ✓,
  ~53,1k linhas `.odin` (o estudo diz "~51k" — aceitável);
- as três citações de §0.2 são verbatim do dossiê (`README.md:30–34`;
  `10-limitacoes…md:36–37`) ✓;
- backends BSD/Windows existem no código (`src/io_backend_bsd.odin`,
  `src/io_backend_windows.odin`) ✓; `siglongjmp` existe
  (`src/sys_trap_linux.odin`, `src/sys_signals_setup_posix.odin`) ✓.

Nada foi citado errado. Mas a correção é obrigatória: **commitar o dossiê no
PR** (ou registrar proveniência com hash do arquivo), ou o estudo referencia
evidência que um revisor futuro não pode auditar.

## E. §0.2 — julgamento defensável, argumento fraco

As citações são exatas e o dossiê recomenda contra copiar o mecanismo
(`04-supervisao…md:54–55`; `08:85`, lista "O que não trazer"). Dois reparos:

**1. A premissa do "inadequado" do dossiê não se transfere para um runtime
próprio.** O dossiê descarta `siglongjmp` *"para o Uruquim, que usa um backend
e não controla todo o processo"* (`04:54–55`). Um runtime construído do zero
controlaria o processo — a premissa some. E o efeito prático da recuperação de
shard é o **mesmo raio 1/N dos processos worker**: um worker que morre também
perde suas conexões em voo (o controle positivo de R3-WP10 mede exatamente
"as requisições **nos demais** workers não falham",
`planning/readiness/R3-general-maturity.md:313–315`). O que os processos
compram a mais não é raio menor — é **garantia pós-corrupção**: fronteira de
address space contra a pergunta aberta nº 1 do próprio Tina (*"o recovery com
`siglongjmp` preserva quais garantias após corrupção…?"*, `10:36–37`). O
estudo diz "hoping"; a formulação precisa é "raio igual, garantia mais fraca,
custo de prova impossível de fechar" — que continua decidindo pelo worker,
mas sem caricaturar a alternativa que um projeto real usa.

**2. O argumento forte que o estudo não faz.** A recuperação por mass-teardown
de shard só é possível porque **toda** a arquitetura Tina foi desenhada para
reconstrução: arenas por shard, handles geracionais universais, commit
transacional de efeitos (`01-arquitetura…md:57–73`). O estado do Druse —
arena de request, conexões do `odin-http`, loop do `nbio` — não foi. Adotar a
disciplina que torna o `siglongjmp` honesto **é o custo da linha 2 da matriz**
(o modelo de máquinas de estado que muda o produto, §3.2). Ou seja: a linha 1
não é "um runtime não remove"; é "**um runtime só remove ao preço da linha
2**" — e isso fecha o argumento de forma muito mais forte, porque une as duas
piores linhas da matriz sob o mesmo custo proibitivo.

**Evidência que me mudaria de lado** (e o estudo deveria registrar): uma
campanha de fault-injection sobre o Tina — que tem DST e death tests — com
corrupção induzida e **controle negativo vermelho**, mostrando invariantes
preservados pós-`siglongjmp`. Existindo isso, "hoping" vira "engineering" e a
linha 1 precisaria ser re-julgada. Sem isso, e com ADR-020 fechado em
definitivo, o julgamento do estudo fica de pé.

## F. §0.3/§4.5 — "mesmo primeiro passo": verdadeiro em política, inflado em técnica

O que é genuinamente comum: **a decisão de quem é dono do `nbio`** — upstream
ou vendorizar — que ADR-051 já formulou como decisão de política
(`planning/adrs.md:2891–2897`). Tomá-la uma vez para as duas trilhas é correto.

O que a tabela de §4.5 sugere a mais não se sustenta:

- WP10 precisa de um entry point **específico e nomeado**: adotar um socket
  que o loop não criou (`adrs.md:2864–2867`).
- Um executor precisaria de integração de scheduling/wakeup — e `nbio` **já
  tem** wakeup cross-thread em uso: `next_tick` armado de qualquer thread pelo
  stream pump (`planning/closure-async-op-inventory.md:74`, site 13) e o
  handoff do dedicated accept via `next_tick_poly`
  (`…dedicated-accept-throughput.md:103`). *"Would need the same kind of entry
  point"* é inferência não desenvolvida, apresentada em tabela ao lado de
  fatos.
- Pior: se a única forma viável de runtime é thread-per-core (conclusão de
  §3), esse runtime **substitui** o reactor — Tina tem `io_reactor` próprio
  por shard — em vez de estender o `nbio`. Para a trilha runtime, o `nbio`
  vendorizado é andaime descartável.

**[inferência]** O passo 1 continua correto — WP10, WP02 e a abstração de
backend o exigem de qualquer forma. Mas o slogan honesto é *"é o passo exigido
por todos os objetivos que não dependem do runtime, e não conflita com ele"* —
não *"é o mesmo primeiro passo do runtime"*.

## G. §5/§6b-B5 — a necessidade do wire protocol está exagerada

O que está certo e verificado: o driver atual é libpq via crystal
(`planning/phase-6-freeze.md:84`); tokio-postgres/sqlx/pgx reimplementam o
protocolo **[externo]**; pgbouncer/proxy local não resolve nada disto —
multiplexa conexões do lado servidor, não desbloqueia a thread cliente
**[inferência]** — e o estudo faz bem em nem tratá-lo como opção (mas deveria
dizer por quê, numa linha). O worker pool não foi descartado: é o instrumento
da linha 2 da matriz e o arm B.

Dois exageros:

1. **"Async implica reimplementar o protocolo" tem contraexemplo de
   produção [externo, verificar]:** psycopg3 implementa async real sobre a API
   não-bloqueante do próprio libpq (`PQconnectStart`/`PQsendQuery`/
   `PQconsumeInput`/`PQisBusy` + readiness do socket), que a própria pesquisa
   descreve (`planning/runtime-research-2026-08-03.md:289–299`) antes de
   descartá-la como "muito trabalhosa". O Diesel concluiu "não eficientemente"
   **para a arquitetura do Diesel**. Com libpq ≥14 há ainda pipeline mode. O
   caminho é espinhoso (single-row mode, e o cancelamento fraco que B5 nota —
   fraqueza igual em qualquer caminho), mas "trabalhosa" ≠ "exige
   reimplementar o wire". A conclusão de B5 deveria ser: *"ou wire protocol,
   ou libpq não-bloqueante dirigido pelo loop (precedente: psycopg3), ou
   worker pool — custos decrescentes, ganhos decrescentes"*.
2. **"Um segundo projeto de tamanho comparável ao runtime" (§5, linhas
   440–441) é superlativo sem fonte** — e contradiz a própria árvore:
   `planning/phase-6-plan.md:47` registrou *"Odin implementations demonstrate
   protocol viability. WP74 chooses reuse, extraction, libpq or a local
   implementation by evidence"*. O runtime foi orçado em anos-equipe (B6);
   tokio-postgres não é um projeto dessa classe. O ponto qualitativo (custo
   real que deve entrar na conta) sobrevive; o "comparable size" não.

## H. §0.1 — a matriz está quase certa; o que falta e o que está forte demais

**Faltam duas limitações declaradas:**

1. **"Exige reverse proxy revisado na frente"**
   (`docs/supported-profile.md:29–36`) — estava na lista apresentada ao dono e
   sumiu da matriz. Defensável fundi-la na linha 3, mas então que se diga; e a
   resposta é "um runtime não remove" (Tina também não tem TLS, dossiê
   `05:6–8`; e o proxy entrega HSTS/rate-limit/HTTP2-de-borda que ninguém
   planeja nativizar). Nota: como já apontado na conversa com o dono, esta é a
   limitação mais barata da lista — mas omiti-la deixa a matriz aberta à
   acusação de escolher as linhas.
2. **"An application CPU/job runtime" está explicitamente fora do perfil**
   (`docs/supported-profile.md:38–39`) — a limitação mais literal de todas
   para um estudo de runtime, e a matriz não a cita. É a linha 2 por outro
   nome; dizer isso fecharia o ciclo.

**Classificações:**

- Linha 4 (plataformas), "Yes, materially" — **forte demais**. Tina prova
  *compilabilidade* multi-backend; o próprio dossiê lista como não provada a
  *"correção real em FreeBSD/Linux ARM, apenas cross-check local"*
  (`10:7`). E a promessa "supported" custa, por plataforma, a campanha do
  R3-WP03 (corpus, soak, proxy/supervisor equivalentes —
  `R3-general-maturity.md:183–190`) — que é o item caro, runtime ou não. O
  honesto é "abre o caminho; a remoção continua custando a prova por
  plataforma".
- Linha 5 (fork), "retires the fork entirely" — verdadeiro, mas a manutenção
  não desaparece: troca 43 disposições por ~16,5k linhas de HTTP próprio (mais
  o runtime embaixo). A linha está certa; merece a nota de troca.
- Linhas 1, 2, 3, 6 — corretas como classificadas (linha 1 com o reparo da
  seção E acima; linha 3 confirmada na fonte: Tina não tem TLS/HTTP2).

**Achado lateral (fora do escopo do estudo, dentro do escopo "as limitações
declaradas estão certas?"):** o perfil afirma que na saturação de lanes o
acceptor fecha *"without writing an HTTP response"*
(`docs/supported-profile.md:46–49`); o report de adoção e o C-05 do gate dizem
**503 completo com `Retry-After: 1`**
(`…dedicated-accept-throughput.md:112–115, 174–176`). Um dos dois documentos
normativos está desatualizado. Deve virar item próprio, não nota desta
auditoria.

## I. §8b — a ordem está certa; um custo não está declarado

Sem dependência invertida nos passos 1→2 (ADR-051 fixa o bloqueio e o passo 1
o remove) nem em 3/4 (independentes entre si; poderiam ser paralelos). Um
passo não exige o runtime antes. Três reparos:

1. **O conflito de topologia com o R2 não é mencionado.** O R2 pendente
   (WP04–WP08) produzirá soak, capacidade e canário para **N=1**. O passo 2
   adota processos worker — N>1 — e `R3-general-maturity.md:307–309` já exige
   refazer o orçamento de recursos para N>1; por analogia, soak e capacidade
   também descrevem outra topologia. Ou os workers entram como **opt-in**
   preservando o envelope N=1 (e a limitação 1 permanece no perfil default),
   ou parte da campanha R2 se repete para N. O §8b precisa declarar qual dos
   dois está sendo comprado — hoje o custo de re-medição está fora da conta.
2. **Passo 0 ausente da tabela.** O texto trata o R2 como obrigação
   permanente (§8b "And the standing obligation") mas a tabela de ordem não o
   sequencia. Dado que o dono já decidiu "estudo → depois R2", a tabela
   deveria abrir com ele.
3. **Passo 4 pode pagar dois pelo preço de um.** Se o segundo backend que
   prova o seam for escolhido pela limitação 4 (ex.: kqueue/macOS,
   compile-para-runtime-smoke), o passo 4 avança plataformas mesmo que o passo
   5 decida "sem runtime". Um segundo backend descartável só-para-provar-o-seam
   é trabalho que o passo 5 pode jogar fora.

## J. A separação fato/externo/inferência — onde o estudo falha na própria régua

O estudo tenta e em geral consegue (o header de
`runtime-research-2026-08-03.md:10–22` é exemplar). Falhas pontuais:

1. §1.1 apresenta como *settled* dois fatos do código aposentado (achado B);
2. §6b/B3 apresenta um número aposentado como *"our measured problem"*
   (achado B.3);
3. §4.5 apresenta a inferência *"same kind of entry point"* em tabela ao lado
   de fatos medidos (achado F);
4. §5 usa o superlativo *"comparable size"* sem fonte (achado G);
5. as citações do Tina apoiavam-se em fonte fora da árvore (achado D) —
   corretas, verificadas agora, mas inverificáveis por um revisor do PR como
   submetido.

## Recomendação da auditoria

**A recomendação do estudo está certa e não deve mudar:** assumir a
propriedade da camada de I/O, destravar R3-WP10, reconciliar o fork, abstrair
o backend, e decidir o runtime depois, com código na mão — mantendo o R2 como
obrigação. Nenhum achado acima inverte um passo; o achado A **fortalece** a
conclusão (o motivo velocidade fica menor, não maior); o achado C não
ressuscita o arm F (troca o motivo da morte: de "trava um shard" para "custo
de propriedade de um runtime de 53k linhas por duas limitações que os passos
3–4 removem mais barato").

**Correções exigidas antes de o documento virar base de decisão:**

1. Reescrever §1.2: as duas medições descrevem códigos diferentes; a
   divergência está explicada e resolvida em
   `perf-netpoller…md:514–539` + histórico do git; o que resta devido é o
   two-box e uma repetição da carga distribuída no código atual. Rebaixar §1.3
   de "precondição da decisão" para "confirmação devida".
2. Corrigir §1.1: remover "no overhead sobre bare nbio" como settled (fato do
   código aposentado) e rebaixar a refutação do `DEFER_TASKRUN` para
   "proveniência não rastreável" (achado B.2), citando o precedente do
   ADR-051.
3. Corrigir §6b/B3: o problema medido atual é 0,160 enters/req, não ~5;
   incluir a análise doméstica de SQPOLL
   (`perf-wp-multishot-scanner.md:72`).
4. Reescrever o parágrafo do arm F em §6 (achado C): raio de bloqueio igual ao
   atual, não "estritamente pior"; matar/adiar o arm pela conta de propriedade.
5. Commitar `tina/docs/` (ou proveniência com hash) no PR.
6. §0.2: adotar a formulação "linha 1 só é removível ao custo da linha 2"
   (achado E.2) e registrar a evidência que reabriria o julgamento (E, final).
7. §0.1: adicionar as duas limitações omitidas e ajustar a linha 4 para
   "abre o caminho" (achado H).
8. §8b: declarar a escolha opt-in vs re-campanha para N>1 (achado I.1) e
   sequenciar o R2 na tabela.
9. Abrir item próprio para a divergência normativa
   `supported-profile.md:46–49` × C-05/report (503 vs close silencioso).
