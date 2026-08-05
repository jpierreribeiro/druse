# R2-WP05, experimento 2 — **H3 REFUTADA**: mais lanes não custou nada aqui

**2026-08-05.** Oito braços. **O critério de refutação que escrevi contra a
minha própria expectativa disparou nas duas repetições.**

O contrato é
[`../../planning/readiness/R2-WP05-lanes-preregistration.md`](../../planning/readiness/R2-WP05-lanes-preregistration.md),
congelado antes da primeira medição.

**Este pacote não promove nada.** O portão fica em R1.

---

## 1. O resultado

Mesma taxa (960/s), mesma duração (600 s), mesma estrutura de rajada. **Só
`max_handlers` variou.**

| lanes | p50 (µs) | **p99 (µs)** | recusas | 2xx completados |
|---:|---:|---:|---:|---:|
| **1** | 709 / 709 | **34.174 / 33.313** | 0 / 0 | 576.000 / 576.000 |
| **2** | 673 / 674 | 1.250 / 1.254 | 2 / 1 | 575.998 / 575.999 |
| **4** | 674 / 674 | 1.257 / 1.260 | **0 / 0** | 576.000 / 576.000 |
| **8** | 674 / 673 | 1.254 / 1.258 | **0 / 0** | 576.000 / 576.000 |

## 2. Os critérios, aplicados

| # | Critério | Resultado |
|---|---|---|
| **X1** | vazão cai monotonicamente L2→L4→L8 nas duas | **NÃO satisfeito** — vazão idêntica |
| **X2** | p99 sobe >20% de L2 para L8 nas duas | **NÃO satisfeito** — subiu **0,32%** |
| **X3** | **refuta H3** se L8 ficar a ±5% de L2 em vazão **e** ±20% em p99 | **DISPARA nas duas** (0,0003% e 0,32%) |
| **X4** | inválido se um braço ficar abaixo de 90% do planejado | menor braço: 575.998 = **99,9996%** |
| **X5** | recusas do snapshot, `injected.txt` vazio | 8 de 8 |
| **X6** | L1 fora da monotonicidade | respeitado — e a §4 mostra por quê |

**H3 está REFUTADA.** Eu esperava reproduzir o achado do relatório de
2026-07-25 — mais lanes custando vazão e cauda — e não reproduzi.

## 3. A interpretação, que importa mais que o número

**Isto não diz "mais lanes é grátis".** Diz que **neste ponto de operação** o
custo não existe, e o ponto de operação é leve por construção:

| | |
|---|---|
| carga oferecida | 960 req/s |
| teto livre de recusa medido pelo R2-WP04 (§4.1, outro host) | ~2.350 req/s |
| **fração do teto** | **~40%** |
| vazão entregue em todos os oito braços | **100% da oferecida** |

**Todos os braços serviram tudo.** Quando nenhuma configuração está saturada, a
diferença entre elas não pode aparecer na vazão — e é por isso que o X1 era
praticamente intestável aqui. **Registrei essa limitação antes de o último braço
fechar**, não depois de ver o resultado.

O relatório de julho mediu perto da capacidade; este mediu longe dela. **Os dois
não se contradizem — respondem pontos diferentes da mesma curva.**

## 4. O achado lateral: uma lane é catastrófica para a cauda

| lanes | p99 |
|---:|---:|
| 1 | **34,2 ms / 33,3 ms** |
| 2 | 1,25 ms |

**Vinte e sete vezes pior**, com a mesma vazão e zero recusas. A carga
`/wait/40ms` monopoliza a única lane, e tudo que chega atrás dela espera.

Isto é o que o critério **X6** mandou excluir da monotonicidade, e ver o número
justifica a exclusão em vez de assumi-la: com uma lane o regime é outro, e
incluí-lo faria a série "melhorar depois piorar" — de onde se conta qualquer
história.

**E é uma medição útil por si só:** confirma, com número, o argumento que a
limitação **L2** do perfil suportado faz em prosa — *handlers síncronos; um
ocupa uma lane*. Com uma lane e uma carga bloqueante, o efeito é de 27×.

## 5. O que isto autoriza, pelo §6 do pré-registro

O pré-registro previa três desfechos. Este é o segundo:

> **H3 refutada** → mais lanes é ganho quase puro neste ponto de operação, e a
> recomendação é subir `max_handlers` — **com a ressalva de que 960/s não é o
> knee**.

**A ressalva é a parte operativa.** A decisão de produto (ADR-052 → direção B3,
`planning/readiness/DECISOES-2026-08-05.md` §3) manda medir o knee **antes** de
congelar a escolha, e este resultado é exatamente por quê: ele torna o **B2**
defensável num regime e silencioso no outro.

## 6. O que isto **não** estabelece

- **Não é medida de capacidade.** 960/s é ponto de operação, não knee.
- **Não vale perto da saturação.** É a medição que falta, e é a próxima.
- **Não decide `max_handlers`.** Produz metade da conta; o knee produz a outra.
- **Não vale para outra topologia.** Dois núcleos físicos para o servidor é este
  host.

## 7. Conteúdo

```
arms/rep{1,2}-L{1,2,4,8}.manifest   por braço: lanes, rajadas, taxa, commit,
                                     sha256 dos binários, recusas, 2xx, não-2xx,
                                     falhas de transporte, p50/p99/p999
arms/sweep.log                       a execução, com os instantes de cada braço
```
