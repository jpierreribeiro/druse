# R2-WP04 — a escada, no host `44.212.50.252`

**Status: EM EXECUÇÃO.** Este arquivo é atualizado quando um degrau fecha.
Ele **não promove nada**; o portão continua em R1.

O contrato do run é
[`ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md`](../../ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md).
Se este arquivo o contradisser, o pré-registro é a verdade.

---

## Por que esta escada existe, se já houve uma ontem

A de 2026-08-03 pertence a **outro candidato**, por duas razões independentes:

1. **Taxa.** A quinta emenda (§4.5) desceu a carga agregada de 2.352/s para
   1.586/s. G1 conta configuração load-bearing como identidade.
2. **Ambiente.** O host de registro foi perdido e a terceira emenda (§3.7) o
   substituiu: OS e kernel diferentes.

Qualquer uma sozinha já reiniciaria a escada. Nada de 2026-08-03 carrega.

## Identidade

| | |
|---|---|
| host | `44.212.50.252` / `i-08c31e483e890fd16`, c5.2xlarge, us-east-1a |
| CPU / topologia | Xeon Platinum 8275CL, 4 núcleos, irmãos `(0,4) (1,5) (2,6) (3,7)` |
| OS / kernel | Ubuntu 24.04.4 LTS / `6.17.0-1017-aws` |
| affinity | servidor `0,1,4,5`, gerador `2,3,6,7`, `DRUSE_SOAK_LANES=2` |
| taxas | **§4.7, f = 0,06 — agregado 960/s** a partir do degrau 3. Os degraus 1 e 2 rodaram a §4.5, f = 0,10 (1.586/s) |
| qualificação | `preflight=pass`, `smoke=pass`, **sem** `smoke_on_unqualified_host` |

`preflight-qual.txt` e `smoke-qual.txt` são os relatórios de qualificação do
host, anexados na raiz deste pacote.

## Degraus

| # | Degrau | Ciclos | Veredito | Recusas: total / injetadas / **carga** |
|---|---|---:|---|---|
| 1 | smoke | 5 | **PASS** | 56 / 56 / **0** |
| 2 | burn-in | 15 | **PASS** pelo analisador, **C22 DISPAROU** | 105 / 104 / **1** |
| 3 | rehearsal | 60 | — (cancelado a f=0,10; a escada reinicia a f=0,06 — §4.7) | — |
| 4 | Final 1 | ~360 | — | — |
| 5 | Final 2 | ~360 | — | — |

A coluna que decide é a última. O C22 desce a taxa por recusa **de carga**; o
C23 exige que a divisão exista em vez de um total ambíguo. Ela é produzida por
[`ops/soak/attribute-refusals.py`](../../ops/soak/attribute-refusals.py) e vem em
`steps/<degrau>/raw/refusal-attribution.{txt,json}`.

## O que cada pacote de degrau contém

```
raw/manifest.txt              identidade do run — commit, tree, binários, AS SEIS TAXAS (C21)
raw/cycles.csv                status e p99 por ciclo
raw/final-state.txt           como o run terminou
raw/final-stats.json          contadores do servidor, incl. saturation_refusals
raw/injected.txt              as falhas deliberadas, declaradas com instante
raw/preflight.txt             a qualificação em que este run se apoiou
raw/process.csv               telemetria de processo por segundo
raw/verdict.json              a graduação do analisador
raw/refusal-attribution.txt   a divisão injetada/carga exigida pelo C23
raw/refusal-attribution.json  a mesma, legível por máquina
SHA256SUMS                    de tudo acima
```

## O achado do degrau 1, que mudou um critério

O smoke passou e **o servidor contou 56 recusas**. Pelo texto original do C22 —
"recusa do servidor > 0" — a taxa desceria para f = 0,06, a 2h40 de custo.

A telemetria por segundo desmontou a leitura: **522 amostras em zero, 153 em 56,
um único salto** na série inteira, às `04:01:58.81Z`; e `injected.txt` declara os
24 leitores lentos às `04:01:58Z`. O mesmo segundo. A carga oferecida produziu
**zero** recusas em 522 segundos de regime.

A sexta emenda (§4.6) corrigiu o C22 para ler recusa **atribuível à carga**, com
as duas razões que já existiam antes do run: `CRITERIA.md` 14 manda contar falha
injetada à parte, e a escada de derivação do §4.1 tem três ciclos por ponto — não
tem quinto ciclo, então nenhum dos seus dez pontos mediu injeção.

**A emenda favorece continuar a escada, e está escrita em vez de aplicada em
silêncio exatamente por isso.**

## Uma dúvida que este pacote não pode resolver

O §4.2 (3 recusas em 3 ciclos de injeção) e o §4.3 (345 em 12) podem ter
disparado sobre falhas injetadas — 29 por ciclo de injeção é a mesma ordem das 56
medidas aqui. Se sim, a descida de f = 0,15 para f = 0,10 respondeu a um sinal
que não era sobre a taxa.

**Não é verificável:** aqueles artefatos viviam no host perdido e nunca foram
commitados. É a razão de este pacote existir desde o primeiro degrau em vez de
esperar o último.

A taxa não foi revertida para f = 0,15 por essa suspeita: rodar mais devagar
enfraquece a alegação de estresse, que é o erro seguro. A re-derivação neste host
é entrada do R2-WP05.

## O achado do degrau 2, que custou a escada

O burn-in também passou pelo analisador — 15 ciclos, `/health` com zero erros,
p99 mediano 1.546 µs. E a atribuição encontrou **uma** recusa de carga entre 105.

**Verifiquei antes de aceitar o custo, porque uma recusa é o limiar inteiro.**
Ela caiu às `04:24:56.449`, com o run começando às `04:18:22` — 394 s, portanto
ciclo 4. A injeção mais próxima é a do ciclo 5, **128 segundos depois**. Nenhum
alargamento defensável da janela a alcança. As outras três subidas (12, 50, 42)
caem nos ciclos 5, 10 e 15 dentro de um segundo das declarações.

**Então o C22 disparou contra a regra que eu mesmo congelei nesta manhã, e a
taxa desce para f = 0,06** (§4.7). A escada reinicia no smoke: ~2h40.

Vale dizer por que uma recusa não é pedantismo. 1 em 15 ciclos é 0,067/ciclo;
num final de ~360 ciclos são ~24, e `/health` leva 2,6% das conexões novas —
cerca de 0,6 evento esperado contra um critério que permite zero. Meio evento
esperado não é um final que se aposta.

**O que este número diz, e é a entrada mais útil da escada para o WP05:** o
limiar de recusa é propriedade do framework **num ambiente**, não do framework
sozinho. Três hosts, três taxas de registro.
