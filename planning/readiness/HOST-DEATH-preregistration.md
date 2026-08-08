# Pré-registro: o Druse derruba o host?

**2026-08-06, escrito ANTES do log do terceiro host.** Não temos ainda o console
da AWS, e é exatamente por isso que este documento existe: se eu escrever os
critérios depois de ver o log, qualquer coisa que ele disser vai parecer
confirmar a hipótese que eu já tinha.

---

## 1. A pergunta, em uma frase

**Três hosts morreram sob carga desta campanha e nenhum morreu ocioso.** A
pergunta é se a causa está no ambiente ou no candidato — e a diferença entre as
duas respostas é a diferença entre "perdemos corridas" e "P0 de produção".

## 2. As três hipóteses concorrentes

| | hipótese | o que ela prevê |
|---|---|---|
| **H-A** | **ambiente** — infraestrutura, vizinho, manutenção da AWS | um host **não-Druse** sob carga equivalente morre na mesma proporção |
| **H-B** | **o candidato** — o Druse esgota um recurso de kernel | só o Druse mata; e um contador de kernel cresce sem limite **antes** da morte |
| **H-C** | **a campanha** — o gerador, o taskset, a topologia de pinos | a morte acompanha o **gerador**, não o servidor: trocar o servidor e manter o resto continua matando |

**H-B é a única que bloqueia promoção.** As outras duas custam hosts.

### 2.1 H-D — **acrescentada às 12:15Z de 2026-08-06**, depois do console

O log do console do terceiro host chegou e **não contém nada da morte**: ele é o
boot de 04-08 19:21Z e termina num erro de credencial do SSM em 05-08 02:11Z.
Silêncio absoluto às ~03:06Z de 06-08.

**Marcando a hora em que esta hipótese entrou**, porque ela nasceu de evidência e
não estava no congelamento original. O critério dela (§4.2) está congelado
**antes** de qualquer métrica de volume ser consultada.

Três linhas do próprio log explicam por que o silêncio é informativo:

| linha do boot | consequência |
|---|---|
| `panic=-1` | um panic **reiniciaria na hora** — e não houve boot novo |
| `NMI watchdog: permanently disabled` | um *hard lockup* **não imprimiria nada** |
| `nvme_core.io_timeout=4294967295` | I/O de EBS travado **espera para sempre**, sem erro |

> **H-D — estol de armazenamento.** O volume raiz tem **24 GB**. Se for `gp2`,
> a linha de base é **100 IOPS** (3/GB, mínimo 100), com rajada a 3.000 por
> crédito. A campanha escreve **continuamente**: uma amostra de telemetria por
> segundo mais os CSVs por ciclo — 4,4 GB e ~50 mil arquivos em 12 h. Se o
> consumo sustentado passa da linha de base, os créditos drenam; quando zeram, a
> fila de escrita cresce; e com `io_timeout` infinito **nada devolve erro** — o
> `sshd`, o journal e o servidor simplesmente param. **De fora é indistinguível
> de uma máquina morta, e não imprime uma linha.**

**O que a torna forte:** ela explica a cronologia sem precisar de defeito no
produto. O Final 1 rodou **12 h** e drenou; o Final 2 começou **3h22 depois**,
sem tempo de recarregar, e morreu em **1h15**. Também explica por que nenhum host
morreu ocioso — ociosidade não escreve.

**O que a enfraquece:** se o volume for `gp3`, não há crédito de rajada
(3.000 IOPS fixos) e a explicação cai.

### 2.2 H-D REBAIXADA às 12:40Z — pela aritmética, antes de custar tempo de ninguém

Escrevi a §2.1 com "4,4 GB e ~50 mil arquivos" como se fosse muita escrita. **Fiz
a conta e não é.** Do Final 1, que são números medidos e não estimados:

| | |
|---|---|
| duração | 43.228 s |
| arquivos criados | 49.621 → **1,15 por segundo** |
| dados escritos | 4,4 GiB → **107 KiB/s** |
| vazão usada | **0,08%** do teto de 128 MiB/s de um `gp2` |
| IOPS estimado (dados a 16 KiB + ~5 de metadado por criação) | **~12** |
| linha de base de um `gp2` de 24 GiB | **100 IOPS** |
| **fração da linha de base** | **~12%** |

**Doze por cento da linha de base não drena crédito de rajada — crédito só drena
acima de 100%.** E rajadas momentâneas no fim de cada ciclo são exatamente o que
o crédito existe para absorver, com uma média de 12 IOPS para recarregar.

**H-D é implausível quantitativamente.** Continua valendo conferir o tipo do
volume porque custa dois minutos e zero risco, mas **não é a explicação
principal** e o dono não deve gastar tempo atrás dela achando que é.

**O que isto não refuta:** um estol de EBS por causa *externa* (degradação do
lado da AWS) continua consistente com o silêncio do console e com o
`io_timeout` infinito. O que a aritmética derruba é a versão "a campanha
esgotou o próprio volume", que era minha.

**Consequência prática:** o experimento A/B da §6 volta a ser o caminho decisivo,
e não há atalho barato antes dele.

### 2.3 H-E — **acrescentada às 15:45Z de 2026-08-08**, depois da quarta morte

**Marcando a hora**, como fiz com H-D: esta nasceu de evidência e não estava no
congelamento original. O critério (§4.3) está congelado **antes** de qualquer
teste dela.

**As quatro mortes compartilham um kernel que não é o do sistema.**

| host | kernel | morreu com |
|---|---|---|
| 1 — `184.72.201.140` | **`7.0.0-1009-aws`** (derivou sozinho de `-1006`) | sob carga |
| 2 — `3.208.73.168` | não registrado | sob carga |
| 3 — `98.92.141.100` | **`6.17.0-1017-aws`** | **1h15** |
| 4 — `100.58.224.180` | **`6.17.0-1017-aws`** | **~9h30** |

Todos rodam **Ubuntu 24.04 LTS**, cuja série de kernel de suporte longo é a
**6.8**. Um `6.17` — e mais ainda um `7.0` — é kernel de ponta sobre distro LTS.

> **H-E — o kernel.** A carga da campanha é **pesada em io_uring**, que é o
> subsistema do kernel que mais muda entre versões. Uma instabilidade em
> io_uring num kernel de ponta produziria exatamente o que se vê: a máquina para
> sem imprimir nada (o `NMI watchdog` está desligado), sem panic (não houve
> reboot, e `panic=-1` reiniciaria), e **sem contador nenhum se mover** — porque
> não é esgotamento, é travamento.

**O que a torna forte, e é o argumento novo:** ela explica o que as outras quatro
não explicam — **as durações até a morte são radicalmente diferentes**
(1h15 contra ~9h30). Um recurso que enche a taxa constante mataria em tempos
parecidos. **Um defeito de código dispara quando o caminho é executado**, e isso
é compatível com qualquer duração.

E é consistente com o que os contadores dizem: em 5h15 de Final 2, **nada
caminhava para um limite** (`mem_available` plana, `SUnreclaim` a 2,07 MiB/h =
307 dias até esgotar).

**O que a enfraquece:** não confirmei que `6.17.0-1017-aws` é kernel fora do
suporte padrão do 24.04 — isso é uma checagem de um minuto com máquina em mãos,
e **deve ser feita antes de tratar H-E como principal**. Se a AMI usada entrega
6.17 como default, a hipótese perde a premissa.

### 4.3 O critério de H-E, congelado antes de qualquer teste

**H-E é declarada se as duas valerem:**

1. a campanha roda no **kernel padrão da série LTS** (`6.8.x-aws`), com carga,
   taxa e duração idênticas, e o host **sobrevive a ≥ 2 corridas de 12 h**;
2. os hosts de kernel de ponta morreram em **≥ 3 de 3** tentativas comparáveis
   (hoje: 3 de 3 com kernel registrado).

**H-E é refutada** se um host no kernel `6.8` também morrer sob a mesma carga.

**É a hipótese mais barata de testar de todas as cinco**, e a única que se testa
**sem** um segundo host: basta uma máquina com o kernel da série LTS. Por isso
ela passa à frente do A/B na ordem de execução — **não** por ser mais provável,
mas por custar menos para eliminar.

### 2.4 O console do 4º host — e o que fazer para o 5º não ser mudo

**2026-08-08.** O console do host 4 chegou e **também não contém a morte**: é o
boot de `05:33:54Z` e termina no prompt de login. **Dois de dois com console
capturado, ambos vazios.**

Isso deixou de ser ausência de dado e virou **observação repetida**, e ela
descarta bastante coisa:

| causa | imprimiria? | vimos? |
|---|---|---|
| kernel panic | **sim**, e com `panic=-1` reiniciaria | não — e não houve reboot |
| OOM killer | **sim** | não |
| reset do driver ENA | **sim** | não |
| soft lockup / hung task | **sim** | não |
| **hard lockup** | **não** — `NMI watchdog permanently disabled` | compatível |
| parada externa (hipervisor) | não | compatível |
| estol de I/O com `io_timeout` infinito | não | compatível |

**E o NMI watchdog não dá para ligar nestes hosts:** o log diz
`Performance Events: unsupported CPU family 6 model 85 no PMU driver, software
events only`. Sem PMU, não há watchdog por NMI.

#### A mudança que torna a 5ª morte diagnosticável

**O detector de tarefa travada é por software e funciona sem PMU.** Hoje ele
apenas *avisa*; se ele **entrar em pânico**, o pânico **imprime no console serial
antes de reiniciar** — e o silêncio vira diagnóstico.

Proposto para o próximo host, na linha de comando do kernel:

```
hung_task_panic=1  softlockup_panic=1  panic=30
```

- `hung_task_panic=1` — tarefa em D-state além de `hung_task_timeout_secs`
  (120 s por padrão) vira pânico **com o stack trace da tarefa travada**;
- `softlockup_panic=1` — CPU presa em kernel sem ceder vira pânico;
- `panic=30` em vez de `-1` — dá **trinta segundos** para o texto sair pelo
  console serial antes do reboot. Com `-1` o reboot é imediato e a janela de
  captura é mínima.

**Isto não é hipótese, é instrumentação.** Não decide entre H-A, H-B, H-C ou
H-E — mas transforma a próxima morte de "silêncio" em "stack trace", e é o que
faltou nas quatro.

**Custo:** uma linha no GRUB e um reboot, antes de qualquer carga.

**Risco declarado:** se a morte for causa externa, nada mudará — o pânico só
dispara para travamento dentro do kernel. Um quinto silêncio, **com o detector
armado**, passa a ser evidência a favor de causa externa em vez de ausência de
dado.

## 3. Por que o RSS não teria visto H-B

O soak vigia RSS. O RSS do Final 1 ficou em **0,99 KiB/h** e nos deu confiança.

**Memória fixada por anéis de io_uring é memória de kernel e não entra no RSS.**
Ela aparece em `VmPin` do processo e em `Unevictable`/`Mlocked` do
`/proc/meminfo`, e **nenhum dos dois é amostrado hoje**. O indicador que mais nos
tranquilizou é cego exatamente onde H-B moraria.

Este é o ponto cego que o instrumento novo (§5) fecha.

## 4. O critério, congelado

**Só H-B é declarada se as DUAS condições valerem:**

1. **O braço mutante mata só com o Druse.** Em ≥ 2 pares (Druse × não-Druse) no
   mesmo tipo de host, com carga equivalente e mesma duração: **o host do Druse
   morre e o do controle sobrevive**, nos dois pares.
2. **Existe um contador de kernel monotônico** que cresce durante a corrida do
   Druse e não cresce no controle, e cujo valor **projetado** alcança um limite
   do sistema dentro da ordem de grandeza do tempo até a morte.

**H-A é declarada** se os dois braços morrerem em proporção parecida.

**H-C é declarada** se o braço de controle — mesmo gerador, mesmo taskset, outro
servidor — matar o host com a mesma frequência.

### 4.1 O que NÃO conta como evidência

- **Um único par.** Um host morto em cada braço não distingue nada com n = 1.
- **Ausência de log.** Um host que some sem deixar `dmesg` não é evidência a
  favor de H-B; é ausência de dado. As duas primeiras mortes já foram assim.
- **Correlação com uso alto de qualquer contador.** Alto não é o critério;
  **monotônico rumo a um limite** é.
- **"O Final 1 sobreviveu 12 h"** não refuta H-B: acúmulo entre runs e condições
  que o Final 1 não teve continuam abertos.

### 4.2 O critério de H-D, congelado antes de olhar as métricas

**H-D é declarada se as duas valerem:**

1. o volume raiz é **`gp2`** (ou outro tipo com crédito de rajada);
2. o `BurstBalance` do volume no CloudWatch **chega perto de zero antes** de cada
   morte, e a `VolumeQueueLength` sobe na mesma janela.

**H-D é refutada** se o volume for `gp3`/`io1`/`io2`, ou se o `BurstBalance`
estiver alto no momento das mortes.

**Ela é barata de testar e barata de consertar** — trocar para `gp3` custa
centavos — e por isso **vem antes** do experimento A/B da §6, que custa horas de
host. Se H-D se confirmar, o A/B ainda vale, mas deixa de ser urgente.

**Se nenhuma das quatro se sustentar:** o resultado é *indeterminado*, e isso é um
resultado. Fica registrado como limitação, não como "provavelmente ambiente".

## 5. O instrumento que falta, e o mutante dele

`ops/soak/kernel-watch.sh` — vigia **fora** do `run-soak.sh`, deliberadamente:
mudar o runner alteraria `runner_sha256` e quebraria a comparabilidade com o
Final 1, que ainda vale. O sidecar não toca o instrumento pinado.

**Sob o G2, ele não mede nada até provar a si mesmo:**

- **controle positivo:** alocar memória fixada conhecida (`mlock` de N MiB) e
  verificar que `Mlocked` e `VmPin` sobem **por N**;
- **mutante:** apontá-lo para um PID que não existe e verificar que ele **grita**,
  em vez de gravar zeros. É o defeito que me custou nove horas ontem à noite, e
  ele não vai entrar no instrumento novo.

## 5.1 O ensaio local dos dois braços — 2026-08-06, 12:25Z

Rodei os dois braços na minha máquina, 2 min cada, **antes** de gastar hora de
host. Duas coisas saíram, e a segunda mexe com H-B.

**A coluna discrimina, que era o que precisava ser provado:**

| | `proc_iouring_fds` | `proc_vmpin_kib` | threads | fds |
|---|---:|---:|---:|---:|
| control (epoll) | **0** constante | 0 | 5–10 | 6–368 |
| druse (io_uring) | **5** constante | 0 | 6 fixo | 14–69 |

**E o mecanismo que eu tinha proposto para H-B mede zero.** A §3 diz que memória
fixada por anéis de io_uring aparece em `VmPin`. **`VmPin` é 0 no Druse**, e o
número de anéis é **5, constante**, não crescente.

**O que isso autoriza:** a versão específica de H-B que eu escrevi — *"o Druse
esgota memória fixada por anéis"* — **não tem suporte neste ensaio**. Se o Druse
fixasse memória por anel, `VmPin` seria diferente de zero desde o primeiro
minuto, e não é.

**O que não autoriza:** dizer que H-B caiu. Dois minutos não veem acúmulo de
1h15, e H-B fala de *um recurso de kernel*, não necessariamente memória fixada.
Slab, descritores, estruturas de conexão do kernel e buffers de socket continuam
abertos, e o vigia colhe todos.

**Consequência para o experimento:** o vigia continua necessário, mas a coluna
que eu apostava (`VmPin`) provavelmente não é onde a resposta está. Quem analisar
deve olhar `SUnreclaim`, `Slab` e `file_nr` com o mesmo cuidado — e o critério da
§4 já exige **monotônico rumo a um limite**, não "alto".

**Um defeito do roteiro achado pelo ensaio:** o build do braço Druse falhava com
`Unknown library collection: 'druse'` — faltava `-collection:druse=$REPO`. Ele
teria morrido na hora zero do host, depois de subir a máquina e antes de oferecer
carga. Corrigido.

## 5.2 O A/B de 2 h na máquina do autor — 2026-08-06, 14:31Z

**Não é o experimento do §6.** É a **condição 2** do §4 — o contador de kernel —
que não precisa de host morrendo, só de duração. Os dois braços rodaram **em
paralelo**, 2 h, 56 ciclos cada, em conjuntos de núcleos separados. Paralelo de
propósito: os dois atravessam as mesmas condições de sistema na mesma janela.

**Veredito pela regra congelada: INDETERMINADA.** Nem satisfeita nem refutada.

| coluna | Druse | controle | leitura |
|---|---|---|---|
| `proc_iouring_fds` | **5, constante** | **0** | o discriminador funciona; não cresce |
| `proc_vmpin_kib` | **0** | 0 | o mecanismo que propus na §3 **não existe** |
| `proc_threads` | **6, fixo** | 5–10 | sem crescimento |
| `proc_fds` | 14–236, inclinação negativa | 6–284, negativa | limitado nos dois |
| `proc_vmrss_kib` | **ver abaixo** | cai | **a única que sobrou** |

### O RSS, e por que ele não decide nada aos 2 h

| janela | Druse | controle |
|---|---:|---:|
| série inteira | +667,9 KiB/h | −449,7 |
| última metade | **+81,7** | −54,7 |
| último quarto | **−69,9** | −6,3 |
| último oitavo | **−391,2** | +63,9 |

**Ele sobe, estabiliza e cai.** É rampa de aquecimento, não vazamento — e o
Final 1 mediu **0,99 KiB/h** de cauda em 12 h no host de campanha, que é o mesmo
servidor sem vazar.

**Aos 2 h a série ainda não assentou**, então a cauda de 50% ainda contém rampa.
**Não vou baixar a fração de cauda até parar de acusar:** isso é ajustar o
instrumento ao dado, que é o que este programa recusa em toda parte. O resultado
correto é *inconclusivo por janela curta*, e isso é um fato sobre o experimento,
não sobre o produto.

**Exigência que isto impõe ao §6:** os braços precisam correr **tempo suficiente
para a cauda ser pós-rampa** — pelas curvas acima, ≥ 4 h, e de preferência as
12 h dos finais. Um par de 2 h responde "o host morreu?" mas **não** responde
"algum contador vaza?".

### Duas armadilhas que este ensaio revelou

1. **Contadores de sistema numa máquina compartilhada não valem nada.**
   `Slab`, `Unevictable` e `MemFree` tiveram inclinações enormes **nos dois
   braços** — é o desktop do autor vivendo a vida dele, não os servidores. No
   host de campanha, dedicado, elas voltam a significar algo. **Quem analisar o
   §6 deve conferir que a máquina estava dedicada antes de ler qualquer coluna
   de sistema.**
2. **Meu analisador exagerava.** Ele imprimia `condição 2: satisfeita` sempre que
   a lista de achados não estava vazia — inclusive quando o único achado estava
   marcado `INDETERMINADO` por não ter limite legível. "Não consegui ler o
   limite" virava "o critério foi atendido". Corrigido: agora só diz *satisfeita*
   se algum achado tem projeção dentro da ordem de grandeza.

## 6. A ordem de execução

0. **Conferir o tipo do volume** (§4.2) — dois minutos, sem host de pé. **Mas
   veja a §2.2 antes:** a aritmética rebaixou H-D, e esta checagem deixou de ser
   a que pode encerrar a investigação. Faça porque é grátis, não porque é
   promissora.
1. ~~Console da AWS do terceiro host~~ — **feito em 2026-08-06**: o log não
   contém a morte. Ausência de dado, e a §4.1 já dizia que isso não é evidência
   a favor de nenhuma hipótese. O que ele deu foram as três linhas da §2.1.
2. `kernel-watch.sh` **qualificado** pelo seu próprio controle e mutante.
3. **Um par** Druse × controle, curto (2 h), com o vigia rodando nos dois.
4. Se ninguém morrer em 2 h, subir para 12 h. **A duração é variável do
   experimento**, não detalhe: o terceiro host morreu em 1h15, o primeiro e o
   segundo em tempos não registrados.
5. Só depois disso, o Final 2.

## 7. O que este documento não decide

Não decide se o R2 é promovível. **Decide o que contaria como resposta** — e o
faz antes de ver o dado, que é a única hora em que isso tem valor.
