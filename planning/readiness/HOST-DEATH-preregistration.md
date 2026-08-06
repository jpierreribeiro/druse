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
(3.000 IOPS fixos) e a explicação cai. **Isto é a primeira coisa a verificar, e
não dá para verificar de dentro da instância.**

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

## 6. A ordem de execução

0. **VERIFICAR O TIPO DO VOLUME E O `BurstBalance`** (§2.1/§4.2). É a checagem
   mais barata que existe, não precisa de host de pé, e pode encerrar a
   investigação inteira. **Vem antes de tudo.**
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
