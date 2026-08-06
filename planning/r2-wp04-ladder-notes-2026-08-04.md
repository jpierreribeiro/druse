# R2-WP04, escada de 2026-08-04 — o que executar ensinou

**Status: REGISTRO OPERACIONAL.** Não é plano e não é evidência. É o que o
`git log` não conta: o que deu errado executando a escada, o que era instrumento,
o que era produto, e o que era eu.

O veredito dos degraus está em
[`../evidence/2026-08-04-r2-wp04-ladder/`](../evidence/2026-08-04-r2-wp04-ladder/).
O contrato é o pré-registro. Este arquivo é a terceira coisa.

---

## 1. Um critério que eu escrevi de manhã reprovou meu run à noite

O C22 foi congelado em 2026-08-04 de manhã (§4.5), emendado à tarde (§4.6) e
disparou contra a escada à noite (§4.7). Vale separar as três, porque só a do
meio é discutível.

**Congelar (§4.5).** A regra do §4.1 exigia que a taxa descesse em commit próprio
antes do final. Ela nunca tinha um piso, e sem piso *"a regra é uma busca por uma
taxa em que nada acontece, e uma taxa suficientemente baixa sempre existe"*. O
C22 pôs o piso em f = 0,06 e uma condição de parada.

**Emendar (§4.6).** O smoke contou 56 recusas e o C22, como escrito, derrubaria a
taxa. A telemetria mostrou as 56 num único salto, no mesmo segundo da injeção
declarada. Emendei o critério para ler recusa **atribuível à carga**.

**Esta é a que precisa de escrutínio, porque me beneficiou.** Duas defesas, as
duas mais velhas que o run: `CRITERIA.md` 14 já mandava contar injetada à parte;
e a escada de derivação do §4.1 tem três ciclos por ponto, logo nenhum dos seus
dez pontos mediu um ciclo de injeção — as injeções rodam no quinto. Comparar um
run com injeção contra aqueles limiares compara coisas diferentes.

**Disparar (§4.7).** No burn-in seguinte o mesmo critério achou 1 recusa de carga
e a taxa desceu para f = 0,06, a 2h40 de custo. Verifiquei antes de aceitar:
ciclo 4, com a injeção mais próxima 128 segundos depois. Não era borda de janela.

**A assimetria que decide isto está no §4.3 e não é minha:** seguir uma regra
escrita antes não exige justificativa, sobrepor exige. Uma regra não vale menos
por ter sido escrita por mim doze horas antes.

## 2. O que a descida mediu, e é o achado técnico da escada

**Com o rehearsal fechado, a tabela final:**

| taxa | agregado | smoke (5) | burn-in (15) | rehearsal (60) | **total** | por ciclo |
|---|---:|---:|---:|---:|---:|---:|
| f = 0,10 | 1.586/s | 0 | 1 | — | **1 / 20** | 0,050 |
| f = 0,06 | 960/s | 1 | 0 | 7 | **8 / 80** | 0,100 |

**Baixar a carga em 40% não moveu o piso.** Com 1 evento em 20 ciclos de um lado,
os intervalos de confiança se sobrepõem largamente e **não dá para afirmar que
piorou** — mas também não sobra nada da alegação que a descida precisava
sustentar. Essa é a assimetria honesta: a descida tinha o ônus da prova e não o
cumpriu.

**As sete do rehearsal estão espalhadas pelas duas horas**, uma de cada vez:
05:45, 06:11, 06:30, 06:36, 07:13, 07:15, 07:45. Não é um evento raro com azar —
é um piso.

**Escrevi isto errado duas vezes, e as correções são o método funcionando.**
Primeiro comparei "1 em 15" contra "1 em 5" e falei em triplicar — exposições
diferentes, aritmética que não sustentava a conclusão. Depois, com 20 ciclos de
cada lado, escrevi "mesmo número dos dois lados" e projetei ~3 para o rehearsal;
vieram 7. **Comparar taxas de eventos raros com exposições diferentes é como se
inventa uma tendência, e projetar de n = 1 é como se inventa precisão.** A
conclusão sobreviveu às duas correções porque nunca dependia da magnitude — só de
o piso não chegar a zero.

E as duas recusas têm a mesma forma: 34 s dentro do ciclo 4, 15,7 s dentro do
ciclo 2. Ambas em **rajada de reconexão**, que é onde o §4.1 já dissera que elas
se concentram.

**Hipótese, nomeada e não testada:** o que produz essas recusas não é a taxa de
requisições — é a rajada de ~624 conexões novas na borda do ciclo. Com
`max_handlers = lanes = 2`, descer a taxa reduz o tempo *dentro* do handler, não
o tamanho da rajada.

**Por que não a testei agora:** o instrumento não existe. O `run-soak.sh` fixa as
conexões por carga e reabre todas por ciclo, então taxa e concorrência de
reconexão não são variáveis separáveis nele. Construir essa separação mudaria o
hash do instrumento no meio da escada e criaria candidato novo (G1). Entrada do
R2-WP05, e a mais valiosa que esta escada produziu.

**O resultado:** o C22 parou o R2-WP04 em 2026-08-04. Veredito completo em
`evidence/2026-08-04-r2-wp04-ladder/verdict.md`; decisão registrada como
`HOLD AT R1` na seção `Result` do pré-registro.

## 3. Três hosts, três taxas — o que isso diz e o que não diz

| host | kernel | taxa de registro |
|---|---|---|
| `184.72.201.140` | `7.0.0-1006-aws` | f = 0,15 → 0,10 |
| `44.212.50.252` | `6.17.0-1017-aws` | f = 0,10 → 0,06 |

**Diz:** o limiar de recusa é propriedade do framework **num ambiente**, não do
framework sozinho. Uma taxa derivada num host não se transfere para outro, e o G1
já dizia isso em geral — aqui está medido.

**Não diz** que o Druse piorou. Nenhuma dessas taxas é capacidade; são cargas
oferecidas escolhidas para um teste de estabilidade. O envelope é o R2-WP05, e o
§1 do pré-registro proíbe explicitamente citar esta campanha para ele.

## 4. Erros meus nesta sessão, porque são mais instrutivos que os do código

1. **`git checkout` num arquivo com trabalho não commitado.** Rodei o mutante do
   C23 apagando a linha com `sed`, depois `git checkout` para restaurar — e
   levei junto a emenda §4.6 inteira, que ainda não estava commitada. Refiz.
   **A correção do processo:** commitar antes de rodar mutante, e restaurar por
   cópia de backup, nunca por `git checkout`.

2. **Deixei um servidor escutando na 8080.** O primeiro teste de build terminou
   com `server --help`; o soak-server não tem `--help` — ele sobe e escuta. O SSH
   expirou e o processo ficou. **O preflight pegou**, e essa é a parte boa: um
   listener órfão teria envenenado a campanha inteira, e o instrumento o achou
   antes do primeiro degrau em vez de depois de doze horas.

3. **Escrevi um runbook com as taxas coladas dentro.** Em 2026-08-03 ele nasceu
   com f = 0,10; em 2026-08-04 elas eram f = 0,06. Eu tinha escrito, no próprio
   arquivo, o aviso sobre o `commands.txt` do pacote antigo estar desatualizado
   pela mesma razão. **Corrigido para apontar para a emenda vigente em vez de
   copiá-la.**

4. **A cadeia de degraus parava mais cedo do que a regra manda.** Escrevi o
   `chain.sh` para parar em qualquer recusa de carga; o C22 julga **no
   rehearsal**, porque 5 ou 15 ciclos não limitam uma probabilidade por ciclo.
   Parar no burn-in seria sobrepor a regra com evidência mais fraca do que ela
   exige. Corrigido antes de rodar.

## 5. Dois defeitos de instrumento que a escada expôs

**O preflight não tinha opinião sobre o host se atualizar sozinho.** Todas as
suas checagens leem o host em repouso; nenhuma era sobre o que ele faria consigo
mesmo durante doze horas. Um unattended-upgrade trocou o kernel do host anterior
entre a qualificação e o run. Agora recusa, nomeando os units, com override
carimbado e mutante.

**O piso de disco era constante fingindo ser estimativa.** Os 100 GiB vinham de
uma aritmética escrita no próprio script cujo *resultado* foi pinado; a campanha
cortou a taxa por dez e o número não se moveu. Agora é derivado da carga
oferecida — e nas taxas históricas pede **113 GiB**, mais que a constante que
substituiu, o que é o controle que prova que não foi afrouxamento.

**O padrão comum:** os dois números eram verdadeiros quando escritos. Nenhum
tinha instrumento que os obrigasse a continuar verdadeiros.

## 6. A lição operacional, que custou duas respostas

**Nenhum pacote de burn-in ou rehearsal tinha sido commitado antes de hoje.** As
conclusões do §4.2 e do §4.3 sobreviveram ao host que morreu; os dados que as
sustentavam, não. Por isso a dúvida do §4.6 — se aquelas recusas eram injetadas —
**não é verificável**, e provavelmente nunca será.

Um degrau cujo artefato vive só no host é um degrau que um host leva embora. O
pacote desta escada existe desde o primeiro degrau por essa razão.

## 7. O gate ficou vermelho no `wp123-two-servers`, e não consegui reproduzir

**Aberto em 2026-08-04. Não é bloqueio da escada — é outro assunto que apareceu
enquanto ela rodava, e está aqui para não sumir.**

Rodei `build/check.sh` durante o rehearsal e ele reprovou em:

```
test_wp123_two_servers.wp123_stopping_a_server_does_not_drain_another_servers_uploads
  server A answered 507 (ok=true) after server B was stopped:
  B's drain closed A's upload admission, which A never asked for
```

**Não é timeout — é semântico.** O servidor A respondeu 507 a um upload que devia
aceitar, depois que o servidor B (outro `App`, mesmo processo) foi parado.

### O que a medição diz

| contexto | execuções | falhas |
|---|---:|---:|
| `origin/main` limpo, isolado | 3 | 0 |
| HEAD, isolado | 5 | 0 |
| HEAD, sob 6 processos de carga de CPU | 8 | 0 |
| HEAD, repetição isolada | 25 | 0 |
| **`build/check.sh` completo** | **1** | **1** |

**41 verdes contra 1 vermelho, e o vermelho só no gate completo.**

### O que não pode ser

**Não pode ser minha mudança.** Esta sessão tocou `ops/soak/`, `build/check_soak_controls.sh`,
`evidence/` e documentos — **zero** arquivos em `web/`, `ingest/` ou `vendor/`. O
teste exercita `web/internal/transport`.

### De onde vem o 507, que estreita a busca

`web/internal/transport/odin_http_adapter.odin:645`: o 507 sai quando
**`ingest.begin` falha ao abrir o arquivo de spool** — não quando a admissão
recusa (essa dá 503). O spool do teste é um caminho **fixo**,
`/tmp/druse-wp123-uploads`.

Isso casa com uma classe de defeito que este repositório já documentou, no
relatório de auditoria de subsistemas: *"`ingest.begin` fails to open the spool...
A briefly unwritable spool directory retired `max_concurrent` slots
permanently."* Uma falha transitória de abertura tem consequência persistente.

### Por que NÃO estou chamando isso de flake

Porque o próprio gate já decidiu essa questão antes de mim.
`build/check_test.sh:132`, sobre estas duas suítes paralelas:

> *"If they became flaky, the fault is in the per-server state, not in the
> runner."*

A linha existe para impedir exatamente a saída fácil — serializar a suíte e
declarar resolvido. Um teste que reprova uma vez em quarenta e duas e nomeia um
mecanismo específico é candidato a corrida rara, não a ruído.

### O gate limpo respondeu, e a resposta não encerra o assunto

Rodei `build/check.sh` de novo sem nenhuma atividade concorrente minha:
**`GATE2_EXIT=0`, 249 passes, zero falhas**, `wp123` inclusive.

**Então a hipótese sobrevivente é a que eu tinha escrito antes de rodar:** o
`wp123` reprova sob **contenção de I/O local**. Isso é uma resposta sobre *quando*
e continua sem resposta sobre *o quê* — e a diferença importa, porque as duas
leituras levam a lugares opostos:

- **"É o teste."** O caminho de spool é fixo, `/tmp/druse-wp123-uploads`, e sob
  pressão de fd ou de `/tmp` a abertura pode falhar por razões que não são do
  produto. Nesse caso o reparo é isolar o spool por run.
- **"É o produto."** `ingest.begin` falhando ao abrir tem consequência
  documentada: o slot de admissão pode não voltar. Um servidor real num host sob
  pressão veria a mesma coisa, e aí 507 sob contenção é comportamento, não ruído.

**Não dá para escolher entre as duas com os dados que tenho**, e escolher a
primeira porque é mais confortável seria exatamente o que o `check_test.sh:132`
proíbe. Fica aberto.

### O que fica devido

1. **Reproduzir sob contenção de I/O**, não de CPU — foi o que eu testei e não
   era a variável certa. `scp` de arquivos grandes concorrente, ou `fio` contra
   `/tmp`, com o teste em laço.
2. **Instrumentar `ingest.begin`** para distinguir "abriu e falhou" de "não
   abriu", e verificar se o slot de `max_concurrent` volta em cada caminho. Essa
   é a pergunta que decide entre teste e produto.
3. **Isolar o spool por run** — `/tmp/druse-wp123-uploads` fixo é frágil por
   construção e nada impede dois gates concorrentes de compartilhá-lo. Barato, e
   vale mesmo se a causa for outra.

**Não fiz nenhum dos três agora** porque nenhum é sobre a escada, e mexer em
`web/` ou `ingest/` durante a campanha criaria candidato novo (G1) e jogaria fora
os degraus já rodados. O item 3 é o único seguro de fazer durante ela — toca só
`tests/` — e mesmo assim esperei, porque `tests/` entra no hash da árvore que o
`manifest.txt` grava.

## 8. Segundo achado da mesma família: `ingest-leak` sob janela de 600 ms

**Aberto em 2026-08-04, e é irmão do §7.**

`build/check.sh` reprovou em
`test_ingest_leak.upload_admission_survives_an_unopenable_spool` com
`FAIL: server did not start`.

### O que a medição diz

| momento | contexto | resultado |
|---|---|---|
| ~06:45Z e ~08:00Z | gates completos verdes | **PASS**, 6,0 s |
| ~14:56Z | gate completo | **FAIL** |
| ~14:58–15:00Z | isolado, 4 execuções | **FAIL 4/4** |
| a partir de ~15:01Z | isolado, 9 execuções | **PASS 9/9** |

**Descartado, por medição e não por argumento:**

- **não é a minha mudança** — reprova igual na `origin/main`, e passa igual nas
  duas;
- **não é colisão de portas** com a suíte `trust001-anchoring` que acrescentei
  hoje: aquela usa `34811`–`34938`, esta usa `41985`/`41986`;
- **não é a porta ocupada** — bind direto nas duas funciona, e não há socket em
  estado nenhum sobre elas;
- **não é o spool sujo** — os dois diretórios estão vazios e em `0700`, que é o
  que o `defer chmod` do próprio teste garante;
- **não é `RLIMIT_MEMLOCK`** (F-C03-2) — o limite local é ~3 GiB.

### O que sobra, e é o que o achado nomeia

A janela de prontidão do fixture é **600 ms** — `300` tentativas a `2 ms`
(`ingest_leak_test.odin:93`). O servidor sobe rings de io_uring antes de aceitar,
e numa máquina carregada 600 ms é apertado. A janela de falha coincidiu com um
período em que esta máquina tinha acabado de rodar um gate completo, duas suítes
e dois mutantes.

### O que NÃO fiz, e por quê

**Não alarguei a janela.** Seria o conserto de trinta segundos, e seria
goalpost-moving: o mesmo movimento que recusei hoje no C22 e no piso de disco.
Uma janela alargada porque falhou esconde a pergunta que interessa — **por que a
inicialização às vezes passa de 600 ms** — e essa pergunta é sobre o produto, não
sobre o teste.

**Não declarei flake.** Pela mesma regra do §7: o `build/check_test.sh:132` diz
que a falha estaria no estado por servidor, não no runner.

### O que fica devido

1. **Medir o tempo de inicialização sob carga** em vez de supor. Se o p99 real
   for 400 ms, 600 ms é fixture apertado e a janela pode subir com justificativa
   medida. Se for 2 s, é achado de produto.
2. **A relação com o §7 vale investigar junto:** os dois são fixtures que
   quebram sob contenção local, os dois envolvem `ingest`, e o `wp123` falhou
   com **507**, que é exatamente `ingest.begin` não conseguindo abrir o spool.
   Podem ser o mesmo defeito visto de dois ângulos.
3. **E uma lição de processo que é minha:** rodei trabalho pesado em paralelo com
   o gate **duas vezes hoje**, depois de as notas de 2026-08-03 já dizerem para
   não fazer isso. As duas vezes produziram um vermelho que não reproduziu.

## 9. `wp123` e `ingest-leak`, investigados por leitura — três achados, nenhum resolvido

**2026-08-05.** Investigação feita **sem tocar `web/` nem `ingest/`**: mexer ali
cria candidato novo sob G1 e jogaria fora os finais de 24 h que estão rodando.
Ler o caminho de código não custa nada e rendeu mais que as medições.

### 9.1 O 507 tem duas causas e o adapter não as distingue

`web/internal/transport/odin_http_adapter.odin:644` responde **507** para
**qualquer** retorno não-`Ready` de `ingest.begin`. E `begin` tem dois caminhos
de falha com naturezas opostas:

| retorno | quando | o que significa |
|---|---|---|
| `.Refused_Admission` | `!a.initialized` | **configuração** — upload nunca foi habilitado |
| `.Disk_Full` | `os.open` do spool falhou | **ambiente** — o filesystem recusou |

**Os dois viram 507.** Um operador vendo 507 não sabe se falta configuração ou se
o disco recusou, e **eu passei duas rodadas de investigação perseguindo a causa
errada por causa disso.** É defeito de observabilidade, e da mesma família do
F-005 que esta campanha já corrigiu: dois estados diferentes com uma resposta só.

### 9.2 A mensagem de falha do `wp123` descreve um defeito que o código não tem mais

O teste falha dizendo:

> *"B's drain closed A's upload admission, which A never asked for"*

**Isso não pode acontecer no código atual**, e dá para mostrar por leitura:

- `admission` é **por runtime** (`runtime.admission`), e o WP123 foi exatamente o
  trabalho que separou isso — `odin_http_adapter.odin:253`;
- `admission_drain` marca `draining = true` e **nunca** mexe em `initialized`;
- `initialized` é escrito **uma vez**, no init. Nenhuma linha o zera;
- e um `draining` marcado é recusado em **`admit`**, que responde **503**, não
  507.

**Então o 507 do `wp123` não é a admissão de A fechada — é `os.open` falhando.**
A mensagem é uma interpretação escrita quando o defeito histórico era o slot
compartilhado, e ela sobreviveu à correção.

**Uma mensagem de falha que nomeia a causa errada é pior que uma genérica**,
porque manda o investigador para o lugar errado com confiança. Foi o que fez
comigo.

### 9.3 O que sobrou, e é uma pergunta melhor

A falha do `ingest-leak` (`server did not start`) e a do `wp123` (507) apontam
agora para o **mesmo lugar**: uma operação de filesystem em
`/tmp/druse-wp123-uploads` e `~/.cache/uru-ingest-f2` que falha transitoriamente
sob contenção local.

E as medições já eliminaram o que não é:

| hipótese | estado |
|---|---|
| inicialização lenta | **refutada** — 48 medições, pior caso 174 ms contra janela de 600 ms |
| lentidão por `enable_upload` | **refutada** — com upload é *mais* rápido |
| colisão de nome de spool | **refutada por leitura** — o M8 pôs o pid no `spool_name`, e `O_TRUNC` não falharia de qualquer forma |
| slot vazado por `os.open` | **já corrigido** — o F2 chama `release_slot` no caminho de falha |

### 9.4 Os três reparos, nomeados e NÃO feitos

**Nenhum é seguro antes do R2-WP08** — os três tocam produto ou o hash da árvore,
e sob G1 isso é candidato novo.

1. **Separar os dois 507.** `.Refused_Admission` de `begin` é configuração e
   merece 503 ou uma mensagem própria; `.Disk_Full` é ambiente. Um status que
   cobre os dois não diagnostica nenhum.
2. **Corrigir a mensagem do `wp123`**, que nomeia um defeito corrigido.
3. **Isolar o spool por run** em vez do caminho fixo — e este é o único que toca
   só `tests/`.

**O que eu NÃO faria:** alargar janela ou serializar suíte. Os dois consertos
óbvios escondem a pergunta, e recusá-los é o que produziu a refutação útil da §8.

## 10. O Final 1 fechou, e o caminho até o Final 2 (2026-08-06)

**Final 1: `result=PASS`, `reasons=[]`, `refusals_attributable_to_load=0`.** 334
ciclos, 12h04, p99 mediano 1.165 µs, RSS 0,99 KiB/h **avaliada**, zero erro de
transporte no `/health`, 4 falhas de workload todas classificadas.

### 10.1 As 147 recusas que eu tinha chamado de "material"

Às 20:08Z sinalizei `saturation_refusals=147` contra as 5 do rehearsal e escrevi
que 0,55/ciclo contra 0,083/ciclo era uma diferença **material**. Estava errado.

As injeções não são por ciclo — são por campanha: **66 `rst` + 66
`slow_readers`, 8.448 faltas injetadas**. A atribuição do C23 pôs as 147 dentro
das janelas, e **zero** sobrou para a carga.

O que salvou a leitura não foi eu ter sido cuidadoso na aritmética: foi eu ter
**recusado medir na hora**. Ler 34 mil arquivos de telemetria consome os mesmos
núcleos que a campanha, e uma recusa induzida pela minha própria medição seria
atribuída à carga. **Eu teria fabricado a falha que estava procurando.**

### 10.2 Três instrumentos meus reportaram desastre para um run saudável

No mesmo dia, três comandos meus mentiram — todos **devolvendo um número
plausível** em vez de gritar:

| comando | disse | era |
|---|---|---|
| `ls .../stats-*.json \| wc -l` | `0` amostras | 34.526 — estourou o `ARG_MAX` |
| `pgrep -f "[s]oak-server"` | servidor morto | vivo há 9h37; o binário é `bin/server` |
| verificação do `MANIFEST.sha256` | `conferem=0` | 15 conferem; o manifesto usa caminho **absoluto** |

**Zero é a resposta mais perigosa que um instrumento pode dar aqui**, porque é
exatamente o que a falha real produziria. Os três estão corrigidos, e o primeiro
estava **dentro do handoff** como a forma recomendada de conferir o progresso.

### 10.3 O smoke recusa o host se você não passar as taxas da campanha

`smoke.sh` roda o `preflight.sh` por dentro. Sem os `DRUSE_SOAK_*_RATE`
exportados, o preflight assume os **defaults** (15.685/s), estima disco para
essa taxa e recusa. A mensagem fala de qualificação e **não** menciona ambiente
— eu li "host não qualificado" para um host que tinha passado no preflight
trinta segundos antes.

**Exporte o ambiente da campanha inteiro antes de chamar o smoke.**

### 10.4 A poda, e uma estimativa 3,9x conservadora

O preflight recusou o Final 2 com 13 GiB livres contra 17 estimados — para um
run que tinha acabado de consumir **4,4 GiB**. A estimativa usa
`DRUSE_CSV_ROW_BYTES ≈ 252`; a linha real mede **~65 bytes**.

Podei `cycles/*.csv` do Final 1 e do rehearsal (4,25 GiB de raw por requisição,
atestado pelo `MANIFEST.sha256`), guardando antes os **resumos por ciclo** — 2
MiB que iriam junto por descuido e que são o que permitiria comparar os dois
finais ciclo a ciclo se eles discordarem.

**Não corrigi o `row_bytes`.** Mexer no qualificador porque ele me barrou, logo
depois de ver que ele me barrou, é a manobra que o G3 existe para impedir. Fica
como achado para depois do WP04.

### 10.5 Por que o Final 2 só às 10:28Z

A §9 pede "on different days". O Final 1 terminou 22:29Z; começar às 01:30Z
satisfaria "outro dia" pelo calendário UTC e seria **a mesma noite** — e a §9 usa
essa palavra exata ao recusar "a que falhou teve uma noite ruim". Alvo escolhido:
**10:28Z, 24 h depois do início do Final 1**, sem ambiguidade.

O custo é 9 h de relógio. O benefício é um artefato que ninguém pode contestar
no único critério que os dois finais existem para satisfazer.
