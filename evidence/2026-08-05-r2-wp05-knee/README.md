# R2-WP05, experimento 3 — Fase 1: **não há knee até 10.000 req/s**

**2026-08-05.** Oito pontos de taxa a `lanes = 2`. **H4 refutada.**

O contrato é
[`../../planning/readiness/R2-WP05-knee-preregistration.md`](../../planning/readiness/R2-WP05-knee-preregistration.md),
congelado antes da medição e emendado uma vez, antes da Fase 2.

**Este pacote não promove nada.** O portão fica em R1.

---

## 1. A escada

Mix e conexões idênticos aos experimentos 1 e 2, rajada de 60 s, 300 s por
ponto, `lanes = 2`.

| ponto | taxa ofertada | **entregue** | p99 | recusas |
|---|---:|---:|---:|---:|
| K1 | 960/s | 100,00% | 1.272 µs | 0 |
| K2 | 1.497/s | 100,00% | 1.252 µs | 1 |
| K3 | 1.996/s | 100,00% | 1.263 µs | 0 |
| K4 | 2.498/s | 100,00% | 1.271 µs | 2 |
| K5 | 3.498/s | 100,00% | 1.268 µs | 6 |
| K6 | 4.997/s | 100,00% | 1.398 µs | 69 |
| K7 | 6.997/s | 100,00% | 1.451 µs | 63 |
| **K8** | **9.997/s** | **99,99%** | 1.786 µs | 318 |

**K-A** define o knee como o primeiro ponto abaixo de 97%. Não existe.
**K-B dispara: H4 refutada** — o knee está acima de 10.000 req/s e este
experimento não o mediu.

## 2. O achado que muda a leitura do R2-WP04

**O "teto" de ~2.350 req/s que o R2-WP04 mediu não era capacidade.**

Aquele número era o **teto livre de recusa** — a taxa acima da qual o acceptor
começa a recusar alguma conexão. Aqui, a **quatro vezes** aquela taxa, o
servidor entrega **99,99%** da carga oferecida.

| | |
|---|---|
| recusas a 9.997/s | 318 |
| requisições entregues | 2.998.900 |
| **fração recusada** | **0,011%** |

**O R2-WP04 desceu a taxa três vezes** — f = 0,15 → 0,10 → 0,06 — para fugir de
recusas que, na pior taxa aqui medida, custam um décimo de um por cento do
goodput. E ele estava certo em descer *dado o critério que tinha*: o critério 1
exige **zero** erro de transporte na sonda de liveness, e zero não é 0,011%.

**A conclusão que isto reforça, agora com número:** o problema nunca foi
capacidade. É que a sonda de liveness divide fila com a aplicação, e por isso
uma recusa rara vira uma falha de critério. **É o argumento da direção B3**
(`planning/readiness/DECISOES-2026-08-05.md` §3), e esta medição o sustenta de
um jeito que o argumento sozinho não sustentava.

## 3. O modelo da recusa, refinado

O experimento 1 variou a **rajada** com a taxa parada e concluiu que as recusas
são função das rajadas. Esta fase variou a **taxa** com a rajada parada:

| taxa | recusas (5 rajadas) |
|---:|---:|
| 960 | 0 |
| 2.498 | 2 |
| 3.498 | 6 |
| 4.997 | 69 |
| 9.997 | 318 |

**Não se contradizem — refinam.** A recusa acontece quando uma conexão nova
chega com **todas** as lanes ocupadas. Mais rajada é mais chegadas; mais taxa é
lanes mais ocupadas. **As duas variáveis entram**, e cada experimento mediu uma
com a outra parada.

O modelo que sobrevive aos dois é melhor que o de qualquer um sozinho — e é o
que se ganha ao rodar o segundo experimento em vez de generalizar o primeiro.

## 4. O que a p99 mostra, e o que não

A cauda sobe **de 1,25 ms a 1,79 ms** entre 960/s e 9.997/s — 43% ao longo de
um fator de dez na carga. Isso é degradação suave, não colapso.

**O que isto não é:** o envelope do R2-WP05. O envelope pede seis perfis,
matriz fatorial, recovery depois de sobrecarga e comparação com pares. Isto é
uma escada de taxa num mix, e serve de entrada para aquele trabalho.

## 5. O bug de instrumento que quase virou conclusão

A primeira execução desta escada reportou o segundo ponto entregando **64,13%**
— o que teria sido "achei o knee entre 960 e 1.500 req/s", um resultado
plausível, com evidência, e errado.

**O harness tinha as taxas hardcoded**, herdadas do experimento 2, onde ser fixo
era correto porque lá a taxa era a constante. O experimento 3 inverte o desenho e
a constante virou bug. O segundo ponto ofertou 449.100 e entregou exatamente
288.000 — que é `960 × 300` na unha.

**O manifesto sempre gravou a taxa real.** Eu é que imprimia o valor pretendido,
vindo do meu próprio argumento. O conserto tem duas partes: as taxas passam a vir
do ambiente, e o runner **compara o `aggregate_rate` do manifesto com o que o
plano pediu e invalida o ponto se discordarem** — que é o que o C21 faz no soak,
pela mesma razão.

Registrado aqui porque o defeito é da mesma família dos outros dois que este
experimento encontrou: um harness que lia o servidor de outro processo, e um que
reportava a configuração de outro run. **Os três produzem números confiantes.**

## 6. Conteúdo

```
fase1/K{1..8}.manifest   por ponto: taxa agregada, lanes, rajadas, commit,
                          sha256 dos binários, 2xx, não-2xx, p50/p99/p999,
                          recusas antes e depois
fase1/knee1.log           a escada de seis pontos
fase1/knee2.log           a extensão para 7.000 e 10.000
```
