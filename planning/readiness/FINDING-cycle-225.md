# O ciclo 225 do Final 1 — uma parada de ~30 ms sem causa conhecida

**2026-08-08.** Achado por auditoria externa, reverificado e **recaracterizado**
aqui. O dado já estava em disco desde 05-08; ninguém tinha olhado por workload.

---

## 1. O fato

De **1.670 pares (workload, ciclo)** do Final 1, **exatamente um** tem p99 acima
de 2 ms:

| | p99 | workload | ciclo |
|---|---:|---|---|
| **maior** | **27.269 µs** | json-encode | **225** |
| 2º maior | 1.563 µs | health | 260 |
| mediana geral | 1.246 µs | — | — |

**O ciclo 225 é 17,4× o segundo pior de toda a corrida de 12 horas.**

## 2. O que a auditoria disse, e o que a medição corrigiu

A auditoria caracterizou como *"um evento singular"* em `json-encode` e observou
que os outros workloads também excursionaram no 225 (max de 16 a 41 ms).

**A segunda parte não se sustenta.** Medindo os 334 ciclos: **todos** têm algum
workload com max > 10 ms. O `tiny` tem **mediana** de max em 40.630 µs — porque
84.240 requisições por ciclo produzem extremos. **Max não distingue nada aqui.**

O que distingue é o **p99**, e por p99 só o 225 se destaca. A conclusão da
auditoria estava certa; o caminho até ela, não.

## 3. O que se sabe

**Não foi o gerador.** `scheduler_lag_p99 = 1.055 µs` e `lag_max = 1.193 µs` no
ciclo 225 — indistinguíveis dos vizinhos. O gerador entregou no horário; **o
atraso foi do lado do servidor**.

**A escala diz "parada", não "requisição lenta".** `json-encode` roda a 105 req/s
por 120 s = 12.600 requisições. Um p99 de 27,2 ms exige **~126 requisições ≥ 27
ms**, e o max é 37,5 ms — então elas estão numa faixa estreita, não numa cauda
longa. **126 requisições a 105/s ≈ 1,2 segundo de chegadas represadas.**

**É ciclo de injeção**, e houve rotatividade de conexão: `conn_fresh` de 4 em
`json-encode` (mediana 1), 25 em `tiny` (mediana 2), 12 em `json-decode`
(mediana 1). Compatível com a injeção `rst` de 128 resets.

**Mas injeção não basta como explicação:** os outros **65 ciclos de injeção**
ficaram em ~1,4 ms de p99. Sete dos dez maiores p99 da corrida são de ciclos de
injeção, e todos os sete estão abaixo de 1,42 ms.

## 4. Por que o Final 1 passou legitimamente

O critério é `health.cycles_over_250ms == 0`, e `cycles.csv` carrega **só**
`health_p99_us`. No ciclo 225 o `/health` marcou **1.163 µs** — perfeitamente
normal, porque a 20 req/s o p99 dele é a 24ª pior de 2.400, e só ~1 requisição
de `/health` pegou a parada.

**O Final 1 não escondeu nada: o instrumento de graduação não olha para lá.** É
uma lacuna de cobertura, não uma falha de veredito.

## 5. O que isto NÃO é

- **Não é falha.** Zero erros de transporte no ciclo 225, zero não-2xx.
- **Não é recusa de saturação.** As 147 do Final 1 estão todas atribuídas a
  janela de injeção, e o C22 não disparou.
- **Não é vazamento.** RSS a 0,99 KiB/h de cauda ao longo das 12 h.
- **Não é regressão conhecida.** Nenhum documento do projeto o menciona.

## 6. Hipóteses, nenhuma testada

Em ordem do que eu investigaria primeiro. **Nenhuma tem evidência ainda.**

1. **Uma lane presa ~30 ms** com as 128 conexões do `json-encode` enfileiradas
   atrás. Explica a faixa estreita e o número de afetadas.
2. **Tempestade de reconexão** da injeção `rst` competindo por lane com o
   `json-encode`, que é o workload com mais conexões por req/s (128 conexões a
   105 req/s).
3. **Custo de alocação** — crescimento de arena ou de buffer sob a rotatividade
   de conexão do ciclo.
4. **Estorvo do host** — mas o `scheduler_lag` normal do gerador argumenta
   contra: os dois processos disputam a mesma máquina.

## 7. O que fazer

**Não é bloqueante para o WP08**, e não deve virar motivo para segurar o portão
sozinho. Mas **tem de estar no pacote de decisão como achado aberto**, porque é
exatamente a classe de coisa que aparece num piloto de produção.

**Barato e sem host:** o Final 2 está rodando com os mesmos workloads. Se um
segundo p99 fora de faixa aparecer lá, deixa de ser singular e passa a ser
comportamento — e aí há duas amostras para correlacionar.

**Recomendação de instrumento:** `analyze-soak.py` já calcula `median_p99_us` e
`max_p99_us` por workload; ele **não** os gradua. Um critério do tipo
"`max_p99_us` de qualquer workload acima de N× a mediana dele é reason" teria
pegado isto automaticamente. Fica como proposta — **não** aplicar antes do WP08,
porque muda `analyzer_sha256` e quebra a comparabilidade dos finais.
