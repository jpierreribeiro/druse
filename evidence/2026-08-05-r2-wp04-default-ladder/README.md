# R2-WP04, candidato do default — a escada pré-final passou **inteira**

**2026-08-05.** Três degraus, três PASS, **zero recusa de carga em oitenta
ciclos**. Os finais estão liberados e o Final 1 está em curso.

Isto é o que a escada anterior nunca conseguiu, e a diferença é **uma linha de
configuração**.

**Este pacote não promove nada.** O portão fica em R1 até o R2-WP08.

---

## 1. A escada

Candidato: `max_handlers = 0` (o default do produto) a 1.118 req/s, oitava
emenda do pré-registro (§4.8).

| degrau | ciclos | analisador | recusas: total / injetadas / **carga** | `handler_capacity` |
|---|---:|---|---|---:|
| smoke | 5 | **PASS** | — / — / **0** | **4** |
| burn-in | 15 | **PASS** | — / — / **0** | **4** |
| **rehearsal** | **60** | **PASS** | 5 / 5 / **0** | **4** |

O rehearsal, em detalhe:

| | |
|---|---|
| `/health`, erros de transporte | **0** em 60 ciclos |
| p99 mediano | **1.165 µs** |
| inclinação de RSS | **10,2 KiB/h**, **avaliada**, contra teto de 1 MiB/h |
| recusas atribuíveis à carga | **0** |

## 2. A comparação que importa

| | escada anterior (`lanes = 2`) | esta (`lanes = 0` → **4**) |
|---|---|---|
| smoke | PASS, 0 recusas de carga | PASS, **0** |
| burn-in | PASS, **1** recusa de carga → C22 desceu a taxa | PASS, **0** |
| smoke (f = 0,06) | PASS, **1** | — |
| burn-in (f = 0,06) | PASS, 0 | — |
| **rehearsal** | **PASS, 7 recusas de carga → C22 PAROU o WP04** | **PASS, 0** |

**A escada anterior morreu no rehearsal. Esta passou.** Nada no produto mudou
entre as duas — nenhuma linha de código. O que mudou foi a campanha **parar de
sobrepor o default do produto**.

## 3. `handler_capacity = 4`, e por que o número importa

O produto resolve `max_handlers = 0` como `clamp(núcleos físicos, 4, 32)`. Neste
host isso é **4**.

**A campanha vinha rodando com 2 — metade do que o produto escolhe, e abaixo do
piso do próprio default.** A §3.4 do pré-registro escreveu o raciocínio: *"dois
núcleos físicos não hospedam quatro lanes mais um gerador"*. O R2-WP05 mediu que
esse raciocínio está errado, e esta escada confirma na prática.

**O mecanismo:** uma lane bloqueada num handler **não consome CPU** — ela segura
um slot de concorrência. Dimensionar lanes por núcleo trata lane como worker
ligado a CPU, e ela não é.

E há uma concordância que vale notar: o experimento 3 mediu **4 lanes** como
limpo nos três pontos de stress, e é exatamente o valor que o produto escolhe
sozinho. **A medição e o default do produto concordam sobre um número que a
campanha tinha sobreposto sem medir.**

## 4. O que isto NÃO significa

- **Não promove nada.** Faltam os dois finais de 12 h em dias diferentes, e é o
  R2-WP08 que decide.
- **Não invalida o R2-WP04 anterior.** Ele mediu o que mediu na configuração que
  tinha, e o veredito continua correto **para aquela configuração**. O que se
  aprendeu é que aquela configuração não era a do produto.
- **Não diz que a taxa é um limite do Druse.** 1.118 req/s foi escolhido pelo
  **disco do host** (§4.8): a escada inteira precisa caber em 19 GiB. O R2-WP05
  mediu **10.000 req/s** entregues a 99,99% nesta mesma máquina.
- **Não fecha o C22.** Ele continua armado para os finais. Se a recusa de carga
  aparecer num final, a regra vale como escrita.

## 5. Conteúdo

```
steps/{smoke,burnin,rehearsal}/
  manifest.txt        identidade: commit, tree, binários, AS SEIS TAXAS, lanes=0
  verdict.json        a graduação do analisador
  attribution.json    a divisão injetada/carga exigida pelo C23
  cycles.csv          status e p99 por ciclo
  final-state.txt     como o run terminou
  final-stats.json    contadores do servidor
  injected.txt        as falhas deliberadas, declaradas
  snapshot.txt        o snapshot da ADR-050 — carrega `handler_capacity` (C24)
  preflight.txt       a qualificação em que o run se apoiou
```
