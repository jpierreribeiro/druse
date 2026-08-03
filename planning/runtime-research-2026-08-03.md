# Runtime research — external findings, 2026-08-03

**Status: SOURCE RECORD. Verbatim, as delivered by the owner.**

This is the raw material behind `planning/runtime-feasibility-study.md` §6b. It
is kept unedited and separate for one reason: the study *summarises* these
findings and reasons from them, and a summary that cannot be checked against its
source is an assertion. Anyone disputing a conclusion in the study should be able
to read what it was drawn from.

**Provenance.** Web research executed by the repository owner against the
research plan in the study, on 2026-08-03. Claims below are the researcher's
words. Where a quotation is attributed (Ginger Bill, Carl Lerche, the Diesel
issue), the attribution is theirs and has not been independently re-verified
against the primary source by this repository.

**How to read it.** The study treats these as *external evidence*, at a lower
tier than this project's own measurements. Where an external claim and a local
measurement disagree, the local measurement wins and the disagreement is
recorded — that is why, for example, the study still calls `SQPOLL` untested
here rather than adopting the "zero syscalls per request" figure as ours.

---

## Bloco 0 — Odin: async/await e coroutines

Odin **não tem** suporte nativo a `async/await`, geradores ou closures movidas
por valor. Como Ginger Bill (criador do Odin) afirma explicitamente, Odin nunca
adotará goroutines no estilo Go com *millions-of-threads* e GC pesado: *"Odin's
planned non-blocking IO stuff will not be akin to Go's 'go' routine… channels
are easy; go routines are heavy… Odin will NEVER do this"*. Em vez disso, Odin
oferece a biblioteca `core:nbio` para I/O não bloqueante, baseada em loop de
eventos e callbacks. O autor observa que **sem um runtime pesado**, só restam
callbacks ou filas de resultados: ele *"ended up picking the callback system"* e
admite que, para quem quiser coroutines, terá que implementá-las à parte (por
exemplo usando Lua ou pacotes nativos).

Não há issues oficiais nem planos de linguagem para coroutines *stackful* em
Odin. Usuários no fórum discutem que implementar coroutines em C/assembly é
complexo (exige `longjmp` ou código em assembleia) e cedem que *"Userspace
coroutines aren't exactly easy… defers won't work"*. Há projetos de terceiros:
por exemplo, o repositório **oasync** (foldcat/oasync) tenta um **escalonador de
tarefas cooperativas**, mas sofre limitações como não suportar `time.sleep`
dentro das "tarefas". Até agora não há código estável de coroutines em Odin,
apenas experimentos que reforçam o quanto é difícil sem suporte de compilador.

Em resumo, **nenhum suporte oficial** de coroutines/fibers stackful em Odin
existe hoje. Ginger Bill confirma que Odin manterá I/O assíncrono baseado em
polling (io_uring, IOCP, etc.) e **eventos com callbacks**, não goroutines estilo
Go. A bibliografia oficial do Odin menciona a possibilidade de se criar "um
sistema de coroutine via Lua ou pacote nativo", mas isso é externo e artesanal.
Diante disso, se concluirmos que Odin **não oferecerá coroutines built-in**,
então arquiteturas alternativas (por exemplo um modelo *thread-per-core*
share-nothing) ficarão obrigatórias (ver Bloco 2).

## Bloco 1 — Tokio: arquitetura e pontos dolorosos

Tokio (Rust) é de fato um *runtime* composto de componentes acopláveis: um
**reator de I/O** (baseado em epoll/kqueue/iouring), um **executor de tasks**
(M:N com *work-stealing*), um **timers wheel**, e primitivas síncronas (Mutex
assíncronos, canais, etc.). O executor multi-thread do Tokio espelha o modelo
M–P–G do Go: cada thread possui uma *Local Queue* (run-queue) de tasks e há um
"thread-pool" com *work-stealing* para balancear carga entre CPU threads. Existe
também uma alternativa *current-thread runtime* (Single-threaded executor) e uma
abstração `LocalSet` para tarefas não-`Send` restritas a uma thread. Em resumo,
Tokio implementa escalonamento cooperativo onde tasks só rendem voluntariamente
ao usar `await` ou APIs assíncronas.

O artigo "Making the Tokio scheduler 10x faster" (Carl Lerche) descreve como
escalar e otimizar esse escalonador multi-thread, confirmando a complexidade:
redesenhos completos do *scheduler*, filas locais e stealing foram necessários
para melhorar latência. Lerche enfatiza que **thread-pool + stealing** são caros
para fazer bem: são necessárias filas por CPU, locks leves, notificação
cross-thread, etc.

Críticas surgem principalmente dos custos semânticos do modelo Rust async. São
citados:

- **"Função colorida"**: em Rust, funções async se comportam como tipos
  separados (`async fn` vs `fn`), o que complica composição com código síncrono e
  geração de futuro.
- **`Pin`/`Unpin`**: as `Future`s podem ser auto-referenciais e precisam de
  garantia de endereço fixo; isso leva a APIs complicadas de pinning. Não há
  citação direta acima, mas é um custo de ergonomia bem conhecido.
- **Envio de estado (`Send`/`Sync`)**: o modelo multi-thread do Tokio requer que
  *todas* as futures e objetos compartilhados sejam `Send`+`Sync` para migrá-los
  entre threads. Um desenvolvedor aponta: *"tokio is a thread-per-core
  work-stealing architecture, which requires Send+Sync bounds everywhere"*. (Em
  single-thread ou `LocalSet`, a restrição relaxa, mas padrões e bibliotecas
  muitas vezes assumem `Send`.)
- **Cancelamento por drop de futuro**: no Rust, cancelar uma operação async
  equivale a **dropar o `Future`**. Isso foi chamado de "footgun": cair (`drop`)
  de um futuro inesperadamente pode "matar" a operação subjacente de forma
  silenciosa. Como um autor nota, *"the idea that cancellation should be done by
  dropping the Future" foi o erro mais prejudicial do design do async Rust*. Esse
  modelo implica que todo código async precisa ser cuidadosamente escrito
  "cancel-safe", e APIs como `tokio::select!` podem inadvertidamente descartar
  campos internos.

Além disso, há discussão sobre por que a comunidade caiu em massa no Tokio em vez
de outras runtimes (async-std, etc.): provavelmente por melhor manutenção,
performance e integração com ecossistema, mas reflete que há **fragmentação de
APIs** (embora hoje principalmente Tokio seja "o padrão").

**Em síntese**, o ecossistema Tokio provê um sistema completo de runtime async
moderno, porém **caro em complexidade**: exige o compilador async/await do Rust e
o trait `Future`, organiza tasks em múltiplas filas com *work-stealing* e requer
imposição global de `Send`/`Sync` para escalonamento multi-thread. Após pronto,
alguns problemas emergem: a ergonomia de Pin e drop-cancellation, e bugs
clássicos de runtimes cooperativos (*e.g.* wakeups perdidos na threadpool). Esses
são custos invisíveis no papel mas reais em produção.

## Bloco 2 — Modelo *thread-per-core* (share-nothing)

Sem coroutines stackful, uma abordagem realista é executar **uma thread por CPU**
(pinning) *modo share-nothing*, abolindo o M:N. Sistemas como Seastar/ScyllaDB
(C++) e Glommio (Rust) adotam isso. Em Seastar, cada *shard* (que tipicamente
mapeia para um core) gerencia seu próprio loop e estado; não há compartilhamento
de filas ou objetos sem locks. Como ScyllaDB explica, isso elimina a necessidade
de locks globais e minimiza *cache coherence*, pois nenhum dado é compartilhado
por múltiplos shards. Glommio segue filosofia parecida no Linux com io_uring,
atribuindo um loop exclusivo por thread e **sem** stealing no escalonador. Ambas
as arquiteturas visam **máximo desempenho e determinismo** em sistemas de baixa
latência.

O trade-off principal é a **fragmentação de carga**: se um thread (shard) fica
sobrecarregado (e.g. pesado trabalho de GC ou uma conexão lenta), as outras não
podem tomar sua carga automaticamente. Em Seastar/Scylla isso é encorajado pelo
particionamento estático de dados; a equipe do Scylla equilibra shards
manualmente durante configuração. Glommio e similares assumem que o programador
lidará com balanceamento via design (p.ex., distribuir conexões uniformemente).
Em resumo, *"share-nothing"* pode render ganhos de latência e throughput (menos
sincronização interna), mas exige cuidado com desequilíbrios.

Medidas concretas mostram a vantagem de eliminar overhead de agendamento: em
Glommio, por exemplo, latências de 99º percentil caíram até 71% em comparação a
modelos M:N (e.g. Tokio) nos mesmos workloads. Em contrapartida, testes de
Seastar na ScyllaDB evidenciam que a comunicação *entre* shards (share-nothing)
deve ser cuidadosamente projetada, pois operações que cruzam cores custam mais
(eles empregam estruturas de dados duplicadas ou roteiam via mensagem local para
evitar esperas).

**Conclusão**: modelos *thread-per-core* (Seastar, Glommio) demonstram alto
desempenho, chegando próximo ao máximo da CPU/IO, justamente porque não
desperdiçam ciclos com locks e agendamento M:N. Mas, quando a carga não é
perfeitamente balanceada, ou há trabalho bloqueante inesperado em um core, não há
work-stealing interno: o sistema se subutiliza. Em ambientes de produção,
costuma-se sobreprovisionar ou partilhar carga de forma estática. Esses sistemas
medem ganhos grandes em cenários onde a carga naturalmente se divide (cada
conexão em seu shard), mas reconhecem o risco de "cores ociosas vs. cores
sobrecarregadas" como fragilidade intrínseca do modelo.

## Bloco 3 — io_uring: recursos-chave e overhead

O io_uring moderno oferece várias **flags e recursos** para cortar drasticamente
chamadas de syscall. Importante destacá-las e suas versões:

- **IORING_SETUP_SQPOLL**: cria uma *thread kernel* que escuta a Submission
  Queue, permitindo que o usuário não chame `io_uring_enter()` a cada operação.
  Disponível desde Linux 5.3 (uso restrito a root/CAP_SYS_NICE antes do 5.11,
  depois liberalizado). Com SQPOLL ativo, as submissões ocorrem apenas uma vez;
  após isso, o kernel "polls" a SQ em loop, zerando syscalls por I/O. De fato, um
  exemplo prático reduziu para **zero chamadas de sistema por requisição** em um
  servidor de eco (com SQPOLL ativado, em modo polling). Em outras palavras,
  *"nearly no syscalls are ever performed"* em comparação a epoll. Empiricamente,
  sistemas usando SQPOLL relatam throughput muito superior, essencialmente
  limitado pelo hardware, não pelas syscalls.

- **IORING_SETUP_DEFER_TASKRUN + IORING_SETUP_SINGLE_ISSUER**: flags adicionadas
  no kernel ~6.1 para controlar quando tarefas internas de background
  (`task_work`) são executadas. Por padrão, o kernel processa work imediatamente
  ao final de cada syscall, mas com DEFER_TASKRUN isso só acontece quando o
  usuário chama `io_uring_enter(..., IORING_ENTER_GETEVENTS)` explicitamente. O
  benefício é maior controle de batch (processar completions em lotes maiores),
  às custas de complexidade adicional de polling manual. SINGLE_ISSUER
  (normalmente usado junto) diz que apenas uma thread submeterá I/Os,
  simplificando sincronização.

- **IORING_SETUP_COOP_TASKRUN**: desde 5.19, evita que o kernel interrompa
  forçadamente o usuário para processar tarefas. Útil em SQPOLL contexts: reduz
  interrupções e permite completar múltiplos requests antes de voltar ao usuário.
  Para usar, a aplicação deve ocasionalmente verificar completions para não
  atrasá-las indefinidamente.

- **Registered buffers/files**:
  - `IORING_REGISTER_BUFFERS` e `IORING_REGISTER_FILES` permitem pré-registrar
    (pin) buffers de memória e descritores de arquivo. Disponível desde 5.1, isso
    elimina sobrecarga de setup por operação. Usar buffers registrados com
    `IORING_OP_READ_FIXED`/`WRITE_FIXED` evita cópias repetidas, acelerando o I/O.
  - **Zero-copy send** (`IORING_OP_SEND_ZC`): opcode disponível desde Linux 6.0.
    Envia dados na rede sem cópia de usuário-para-kernel-buffer: o kernel DMA
    direto do buffer do usuário, retornando dois completions (um de envio, outro
    notifica liberação). Para grandes payloads, reduz latência ~0.2ms por pacote
    grande.

- **Outras flags** (menos críticas para velocidade pura): `SQ_AFF`,
  `TASKRUN_FLAG`, entre outras, conforme manpages. Em kernels 6.x/7.x há ainda
  melhorias de polling interno (ex. `IOPOLL` aprimorado no 7.0).

**Overhead e números**: frameworks rápidos geralmente atingem zero a poucos
syscalls por request usando SQPOLL/Batching. *wjwh* reportou um "servidor que faz
zero syscalls por conexão". Em benchmarks comparativos, redes baseadas em epoll
requerem *uma syscall por evento* (por ex. um accept e um read requerem 2
syscalls), enquanto com io_uring os *SQEs* são escalados ao kernel em lote, e
apenas *periodicamente* uma syscall é feita para enfileirar ou despertar a
completions. Como resumido num fórum Rust, *"nearly every epoll call is a
syscall, io_uring only has to drop into a syscall periodically … nearly no
syscalls ever performed"*. Em sistemas reais de alta performance (e.g. monoio,
RingCore), relatam-se números de syscalls por requisição próximos de 0 (com
SQPOLL) ou baixo dígito, em oposição a dezenas por loop epoll.

**Em suma**: as flags modernas do io_uring eliminam a maior parte do overhead de
syscall que explica o "×250" relatado. Um servidor bem afinado pode chegar
**próximo de zero syscalls/request** (via SQPOLL e batching). Portanto, antes de
decidir criar um runtime async complexo em Odin, é crucial testar: talvez ativar
SQPOLL, DEFER_TASKRUN, buffers registrados e send_zc feche boa parte da
desvantagem de performance sem novo runtime. Se sim, a necessidade de um runtime
pesado diminui.

## Bloco 4 — Go: goroutines reais custam caro

O modelo de goroutines do Go é um estudo de caso completo de runtime M:N:

- **G-M-P**: o agendador do Go usa objetos `G` (goroutine), `M` (thread do SO) e
  `P` (contexto de execução com fila de run-local). Há work-stealing simples das
  filas locais dos processadores (P), e um **sysmon** que monitora bloqueios de
  threads, preempção, etc. O runtime tenta manter P sempre atrelado a um M livre.

- **Stacks crescentes**: cada goroutine começa com pilha pequena (~2 KB). Quando
  estoura, o runtime aloca um novo segmento maior e *copia* a pilha inteira para
  ele, atualizando todos os ponteiros empilhados. Isso **exige cooperação do
  compilador/GC**: em tempo de compilação o Go deve saber onde estão todos os
  ponteiros nas pilhas para poder ajustar e para o GC rastrear. *Exemplo*: cada
  função gera mapa de ponteiros em suas localidades, e o stack-copy faz *pointer
  adjustment* nos endereços relocados (ou referências a ele). Esse mecanismo
  impede que Go adote pilhas vinculadas a uma thread sem ajuda da linguagem: um
  compilador desconhecido ao runtime não saberia realocar pilhas ou informar o GC.

- **Preempção assíncrona**: Antes do Go 1.14, o Go só preemptava a goroutine em
  chamadas de sistema, permitindo loops infinitos em código puro. Desde 1.14 (com
  inserção de checagens de preempção no código compilado), goroutines longas
  podem ser interrompidas a qualquer tempo (por sinais do sistema), garantindo que
  o scheduler recupere a thread ocasionalmente. Esse pré-emptor resolve latências
  ligadas a bloqueios em bucles, mas custa ciclo extra (check de preempção
  inserido nas iterações) e complexifica o compilador.

- **GOMAXPROCS e netpoller**: `GOMAXPROCS` define quantos M (threads) simultâneos
  o programa terá — por padrão, ≈#CPUs. Cada M tem uma pilha de goroutines locais
  (P). O netpoller fica rodando em background para goroutines do tipo I/O,
  integrando-se ao scheduler para reinserir Gs em P.

- **Chamadas C bloqueantes (cgo)**: se uma goroutine invoca código C via cgo,
  aquela goroutine fica atrelada ao M/subjacente OS-thread. O runtime então cria
  *outros* Ms (threads) se necessário para manter as outras P ocupadas. Ou seja,
  cgo implica que **um thread fica "preso"** até o fim da chamada; mas o scheduler
  do Go lida criando threads extras ou deixando P ociosos. Na prática, chamadas C
  prolongadas são vistas como "motores de thread" fora do controle do runtime.
  Isso é bastante parecido com usar uma threadpool de sistema: você executa C em
  threads independentes.

**Resumo do custo para Odin**: replicar goroutines verdadeiras exigiria:

- Alterar linguagem/compilador para gerar *pilhas móveis* (stack copying), com
  metadados de GC sobre cada frame (stack maps). Sem isso, não dá para copiar o
  stack e manter GC estável.
- Ter um scheduler global (G-M-P) com *work-stealing*, ou ficar refém de threads
  fixas. O suporte ao GC e runtime do Go já inclui saber onde estão ponteiros em
  cada frame, algo que Odin não possui atualmente.
- Preempção em nível de instrução (o Go insere checks em loops): sem um mecanismo
  semelhante (sinais + reescrita de código) não dá para interromper uma função
  arbitrária em Odin. Go usou reescrita do compilador e GC de tri-color para fazer
  isso.
- Gestão de `GOMAXPROCS`, netpoller incorporado e lógica especial ao usar
  pthread/cgo.

Em conclusão, **quase nada disso é viável no Odin atual sem reescrever grande
parte do compilador/GC**. Cada uma dessas peças – pilhas expansíveis, metadados
de GC, preempção – foi adicionada ao Go *na linguagem* e não em runtime puro.
Portanto, repensar goroutines "como em Go" em Odin exigiria mudanças de linguagem
comparáveis ao próprio impacto do Go. Provavelmente inviável sem tornar Odin
outra linguagem, por isso é muito custoso (ou impossível) ter goroutines
completas no Odin hoje.

## Bloco 5 — FFI/Bloqueio de bibliotecas C (ex.: Postgres)

Este bloco ressalta que **nenhum runtime async resolve sozinho funções
bloqueantes via FFI**. Tomando Postgres:

- **libpq assíncrono**: o libpq C oferece API não-bloqueante. Há
  `PQconnectStart`/`PQconnectPoll` para conexão não bloqueante;
  `PQsendQuery`/`PQgetResult` para envio assíncrono de queries; e funções
  auxiliares `PQconsumeInput` e `PQisBusy` para integrar ao loop de eventos. Em
  teoria, um app pode fazer `PQconsumeInput()` quando o socket estiver pronto e
  então checar `PQisBusy()` até que a query seja completada. Mas **não basta**:
  chamar `PQgetResult` eventualmente bloqueia se o servidor ainda não acabou, a
  menos que você tenha micro-controlado todo o ciclo (chamado getResult somente
  quando PQisBusy diz 0). Em suma, usar libpq de forma 100% não-bloqueante é
  muito trabalhosa e restritiva.

- **Drivers Rust/Go reimplementam**: De fato, principais bibliotecas async evitam
  libpq. O *issue* do Diesel nota que usar libpq bloqueante é "impraticável" para
  async; a solução comum em Rust é *"roll their own protocol layer"* usando crates
  como `postgres-protocol`. Em Rust, o tokio-postgres e sqlx de fato falam
  diretamente o protocolo de sockets do Postgres. Em Go, o driver `pgx` também
  implementa nativamente o protocolo sem libpq. Isto confirma: para I/O de DB
  verdadeiramente async, **reimplementa-se o protocolo ou usa thread pool**.
  Confirmação textual: Diesel concluiu que async em libpq era impossível
  *"efficiently"*; aplicativos passam a usar `postgres` (sync) ou `tokio-postgres`
  (async puro) ou escrever seu próprio driver.

- **Cancelamento de query**: libpq tem `PQcancelStart/PQcancelPoll` para
  cancelamento não-bloqueante, mas **mesma advertência do sincronismo**: se a
  query já finalizou no servidor, o cancelamento não faz nada útil. O cancelamento
  é um pedido enviado numa conexão separada (PGcancelConn). Isso significa: nem
  sempre é possível abortar a tempo. Dessa forma, mesmo implementando via libpq,
  cancelamento de queries não é garantido – serve apenas como "pedido", sujeito a
  delay de rede.

- **Abordagens gerais de FFI bloqueante**: se uma biblioteca C só fornece APIs
  bloqueantes (ex: uma GUI toolkit, uma velha API de IO, ou mesmo o libpq dentro
  do driver padrão), as opções são restritas. Geralmente usam threads dedicadas ou
  processos auxiliares. Ex.: um runtime async pode delegar chamadas bloqueantes
  para um threadpool (`spawn_blocking` do Tokio faz isso) ou a outro processo. A
  desvantagem é a sobrecarga de threads extras, perda de eficiência e mais
  sincronização. Em bancos de dados isso pode ser um overhead sério se cada query
  acionasse threads de polimento. Em suma, **a "saída esperada" ao enfrentar
  bibliotecas C bloqueantes** é: *thread-per-call* ou *subprocesso*, e isso
  penaliza throughput.

**Conclusão**: se "banco de dados assíncrono" quer dizer consultas não-bloqueantes,
com libpq isso só é possível com grande esforço (e nem totalmente). Ferramentas
populares não usam libpq internamente no modo async, mas sim implementam o
protocolo manualmente. Logo, para sermos verdadeiramente async com Postgres
teríamos que reimplementar o protocolo do zero (um projeto do tamanho do
runtime!). Se isso for necessário, é um trabalho gigantesco que deve entrar no
custo do projeto.

## Bloco 6 — Custo real de implementar um runtime async

Prover um runtime completo não é trivial. Exemplos históricos:

- **Tokio (Rust)**: começou em ~2016, só atingiu 1.0 em janeiro de 2021, após
  **4-5 anos de desenvolvimento ativo**. Foi produto de dezenas de contribuidores
  (o repositório principal tem centenas de forks e dezenas de mantenedores
  frequentes). O scheduler central já passou por vários *rewrites* (vide o artigo
  do bloco 1). O 1.0 só foi possível consolidando APIs e promovendo
  compatibilidade. Apesar do enorme esforço, bugs sutis (como deadlocks ou
  vazamento de waker) às vezes aparecem em produção.

- **Seastar/Scylla (C++)**: Seastar surgiu em 2013 (Cloudius) e tornou-se o
  núcleo do banco NoSQL ScyllaDB. O time da Scylla investiu intensamente (vários
  engenheiros dedicados por anos). Manter Seastar exige atenção – exigências do
  C++ moderno, bugs em ambiente share-nothing, refinamento de allocators e do
  reactor. ScyllaDB frequentemente relata que AOT (C++20) e suporte exigem
  retrabalho de compatibilidade (o blog da Scylla fala de backports em cada novo
  padrão C++). Em termos de esforço, não há dados públicos claros, mas ficou claro
  que até times maduros (Diesel, Scylla) preferem envolver seus desenvolvedores no
  uso de soluções existentes em vez de reescrever clientes de DB.

- **Bugs de runtime em produção**: são comuns e difíceis de detectar no
  desenvolvimento normal. Por exemplo, o issue #525 do tokio (loss of wakeups in
  threadpool) ou deadlocks sutis em mutexes async (ver discussões em fóruns).
  Vários runtimes foram abandonados ou simplificados depois de encontrar problemas
  complexos em casos reais.

Não há números precisos "pessoa-ano" publicados, mas ordens de grandeza: um
projeto como Tokio levou dezenas de pessoas (core + comunidade) vários anos para
um runtime estável, sem contar manutenção contínua. Seastar/Seastar-based DB
levou provavelmente similar (embora seja comercializado e fechado o team). Bugs
que só aparecem em produção (race conditions, starvation) são comuns; ex: vários
postmortems em artigos de performance mencionam threads perdendo eventos, tasks
'zumbis', etc. Alguns projetos de runtime foram abandonados por "serem difíceis
demais" (notadamente no espaço de linguagens dinâmicas ou C++ recentes, há relatos
em blogs).

## Bloco 7 — Alternativa honesta: sem runtime caro

Existem servidores muito rápidos **sem** runtime de multitasking especial.
Exemplos notáveis:

- **Servidores baseados em processos/event loop**: O Nginx, HAProxy e outros em C
  usam um modelo clássico: N processos worker (ou threads fixas), cada um
  executando um loop epoll/kqueue. Escalam com `SO_REUSEPORT` para balancear
  conexões entre processos. Isso entrega escalabilidade com overhead relativamente
  baixo, sem agendamento user-level complexo. Em Go, *fasthttp* (biblioteca de
  HTTP ultra-otimizada) alcança desempenho comparável a frameworks em C usando
  padrões de bloco de chamadas bem ajustados, não depende de concorrência M:N além
  das goroutines normais (que o Go já provê) – é um exemplo de "focar em I/O
  rápido e boa engenharia de código bloqueante". Em C++, µWebSockets (uWS) e o
  servidor H2O implementam escalonamento eficiente com epoll/engines similares.

- **Batching e uso de io_uring com código síncrono**: Mesmo sem runtime async,
  muito pode ser ganho. Basta agrupar operações e usar flags do io_uring. Por
  exemplo, o blog *wjwh* mostrou como um servidor C simples, usando io_uring com
  SQPOLL e *linking* de SQEs, atingiu "zero syscalls por requisição". Na prática,
  isso significa que sem nenhuma camada de concorrência interna, um servidor muito
  simples consegue ganhar *tudo* do io_uring (mantendo muitas operações em voo)
  sem sacrificar o modelo de programação síncrona simples.

- **Exemplo adversário**: Considerando "framework rápido sem runtime": *wjwh* de
  fato construiu um mini-servidor em C que responde sem syscalls por requisição,
  ilustrando que o overhead pode ser eliminado sem um runtime complicado. Se
  existisse um servidor web completo (HTTP 1.1/2/3) em C/C++ usando apenas
  epoll/io_uring e processos múltiplos, alcançando latências e vazões comparáveis
  a qualquer runtime async, ele seria o "adversário" do plano. Na realidade,
  Nginx/Gunicorn/Uvicorn (ASGI via multiprocessos) ou *fasthttp* (Go puro) já são
  provas de que se pode chegar perto dessa meta sem runtime complexo.

**Em resumo**, há soluções de alto desempenho que **não** criam um scheduling M:N
novo: usam I/O assíncrono do SO e escalam por threads ou processos fixos. Se um
desses casos "sem runtime" entregue o mesmo nível de performance, ele deve ser
vencido em benchmarks antes de justificar o custo de construir algo novo. É a
balança a se bater: se um servidor otimizado por batching/syscalls (como as demos
de io_uring) iguala ou supera nossas necessidades, investir em um runtime custom
será difícil de justificar quantitativamente.
