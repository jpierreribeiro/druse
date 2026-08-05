# R2-WP05, experimento 1 — **COMPLETO**: a rajada é a variável, e lanes é a alavanca

**2026-08-04/05.** Oito braços, dois critérios de hipótese satisfeitos, e um
critério de refutação que não disparou.

O contrato é
[`../../planning/readiness/R2-WP05-burst-preregistration.md`](../../planning/readiness/R2-WP05-burst-preregistration.md),
congelado **antes** da primeira medição e emendado duas vezes, sempre antes do
run que a emenda governa.

**Este pacote não promove nada.** O portão fica em R1.

---

## 1. O resultado

Oito braços, **mesma taxa agregada (960/s) e mesma duração (1200 s) em todos**.
Só duas coisas variaram: a frequência de reconexão e o número de lanes.

| braço | lanes | rajadas | rep 1 | rep 2 |
|---|---:|---:|---:|---:|
| **A** | 2 | 1 | 0 | 1 |
| **B** | 2 | 20 | 3 | 3 |
| **C** | 2 | 60 | **15** | **9** |
| **D** | **4** | 20 | **0** | **0** |

## 2. Os critérios, aplicados um a um

| # | Critério (congelado antes) | Resultado |
|---|---|---|
| **W1** | monotônico A<B<C **nas duas** repetições | `0<3<15` e `1<3<9` → **SATISFEITO**, H1 sustentada |
| **W2** | **refuta** H1 se A e C ficarem a ±1 | diferenças de 15 e 8 → **não disparou** |
| **W3** | `D < B` **nas duas** | `0<3` e `0<3` → **SATISFEITO**, H2 sustentada |
| **W4** | inválido se algum braço falhar por instrumento | 8 de 8 com exit 0 e manifesto → sem invalidade |
| **W5** | `injected.txt` presente e vazio | 8 de 8, 0 bytes → toda recusa é de carga **por construção** |
| **W6** | porta livre e snapshot antes da carga | nenhum `FATAL`; o harness sai != 0 se falharem |
| §6.1 | disco usado ≤ 2 GiB | **159 MiB** — a justificativa da emenda se confirma |

**O W2 existia porque eu queria que H1 fosse verdadeira** — a hipótese é minha,
do §4.6 do pré-registro do soak. Ele não disparou, e é isso que separa "medi" de
"torci".

## 3. O que está estabelecido

**A recusa de saturação é função do número de eventos de reconexão, não da taxa
de requisições.** Com carga total idêntica, um único evento de conexão produziu
0 e 1 recusa; sessenta produziram 15 e 9.

**Dobrar `max_handlers` de 2 para 4 elimina as recusas** na mesma densidade de
rajada.

| | |
|---|---|
| com 2 lanes | **31 recusas em 162 rajadas = 0,191 por rajada** |
| com 4 lanes | **0 em 40 rajadas** |
| previsto pelo modelo de 2 lanes | 7,7 |
| P(observar 0 se a taxa fosse a mesma) | **0,00047** |

## 4. E isto explica por que o R2-WP04 parou

O WP04 desceu a taxa duas vezes — f = 0,15 → 0,10 → 0,06 — e o piso de recusa
**não se moveu**: 1 recusa de carga em 20 ciclos nas duas taxas medidas. Ele
parou porque o C22 não permitia uma terceira descida.

**Agora se sabe por que não se movia.** A taxa nunca foi a variável. O
`run-soak.sh` reabre ~624 conexões a cada ciclo, sempre — então descer a taxa
reduzia o tempo *dentro* do handler e deixava a rajada intacta. **Nenhuma taxa
teria convergido**, que é literalmente o cenário para o qual o C22 foi escrito:

> *"sem piso, a regra do §4.1 é uma busca por uma taxa em que nada acontece, e
> uma taxa suficientemente baixa sempre existe."*

O C22 parou a busca antes que ela consumisse dois finais de 12 h. Ele custou 2h40
quando disparou contra o meu próprio run; poupou muito mais.

## 5. O que isto **não** estabelece

- **Não é medida de capacidade.** Nenhum número aqui é knee, teto ou envelope.
- **Não diz que 4 lanes é a configuração certa.** Quatro lanes em dois núcleos
  físicos é **sobreassinatura**, e o relatório de 2026-07-25 mediu que mais lanes
  reduz recusa **e custa vazão e cauda**. Este experimento mediu um lado da
  troca; o outro lado é o resto do R2-WP05.
- **Não reabre os finais.** Mudar `max_handlers` é candidato novo sob G1: a
  escada inteira reinicia.
- **Não vale para outra topologia.** Duas lanes em dois núcleos físicos é este
  host. O que generaliza é a *forma* — rajada, não taxa —, não os números.

## 6. Replicação, e o que ela custou

Uma primeira tentativa rodou cinco de oito braços em `44.212.50.252` antes de o
host ficar inacessível. Aqueles braços **não entram neste resultado** (G1: outro
ambiente, e os artefatos ficaram na máquina perdida).

Mas foram observados, e a forma bate:

| braço | rajadas | host perdido | host de registro |
|---|---:|---:|---:|
| A | 1 | 0 | 0 / 1 |
| B | 20 | 4 | 3 / 3 |
| C | 60 | 13 | 15 / 9 |
| D (4 lanes) | 20 | 0 | 0 / 0 |

**Duas máquinas físicas diferentes, a mesma forma.** Isso não soma sob G1 — e é
exatamente o tipo de coisa que dá confiança num achado.

## 7. Os hosts que caíram, que continua sem explicação

Duas máquinas ficaram inacessíveis em 2026-08-04, ambas sob esta carga. O
diagnóstico de linha de base no host de registro **eliminou três suspeitos**:

| | medido | leitura |
|---|---|---|
| `nf_conntrack_max` | 1.048.576 (uso 34) | margem de um milhão — não é o gargalo |
| `tcp_max_tw_buckets` | 65.536 | o pico desta carga é ~1.900 |
| portas efêmeras | 28.231 | idem |

**A terceira máquina completou os oito braços** com 60 s de folga entre eles. Não
credito isso à folga — é n=1, e a folga foi a única variável que mudei de graça.
Fica aberto.

## 8. Entrada para o resto do R2-WP05

1. **A troca completa de `max_handlers`**: vazão e cauda contra recusa, medidas
   juntas. Este experimento tem metade da conta.
2. **`/health` fora das lanes de aplicação** — a saída que não custa vazão. A
   ADR-050 já fez esse argumento para a métrica; agora há medição para o mesmo
   argumento na sonda de liveness.
3. **O tamanho da rajada como variável separada da frequência.** Aqui só a
   frequência variou; `-connections` por carga ficou fixo.

## 9. Conteúdo

```
arms/rep{1,2}-{A,B,C,D}.manifest   identidade e contagem de cada braço: lanes,
                                    rajadas, taxa agregada, commit, sha256 dos
                                    dois binários, recusas antes e depois
arms/sweep.log                     a execução, com os instantes de cada braço
preflight-wp05.txt                 a qualificação do host de registro
```
