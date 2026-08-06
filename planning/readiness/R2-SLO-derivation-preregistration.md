# Pré-registro da derivação do SLO por workload

**2026-08-06, escrito ANTES de olhar qualquer percentil por workload.**

O §6.2 do pré-registro do soak deixa **15 de 18 células de latência `open`** e é
um critério de saída do R2-WP08. Este documento congela **como** elas serão
preenchidas, antes que os números existam — que é a única proteção do G3 ainda
disponível, pelas razões da §1.

---

## 1. Duas coisas quebradas que este documento não esconde

### 1.1 O prazo do §6.2 já foi perdido

O §6.2 diz, textualmente:

> The SLO is set from WP05's knee, at a stated fraction of it, and committed **as
> an amendment to this file in its own commit, before the final run**.

**Os dois finais rodaram sem ele.** O Final 1 fechou em 2026-08-05T22:29Z e o
Final 2 começou em 2026-08-06T01:51Z; nenhuma emenda de SLO foi commitada antes
de nenhum dos dois. Ninguém notou, inclusive eu, que montei o pacote do WP08 e
listei o critério como "parcial" sem ver que o prazo dele já tinha vencido.

**Consequência, e ela é dura:** um SLO escrito agora **não pode graduar o Final 1
nem o Final 2**. Se graduasse, seria um limiar escolhido depois de ver a
distribuição que ele julga — o que o próprio §6.2 chama de "G3 read backwards".
O que este documento produz **vale do próximo candidato em diante**.

### 1.2 A fonte que o plano designa não produz o dado que o SLO precisa

O §6.2 manda derivar o SLO do knee do R2-WP05. O harness do knee
(`ops/wp05/lanes-sweep.sh`) roda **seis geradores separados**, um por workload,
cada um com seu CSV — e então o resumo faz:

```python
for path in glob.glob(os.path.join(out, "raw", "*.csv")):   # os SEIS juntos
    ...
    lat.append(int(row["latency_ns"]))
```

**Ele coleta a dimensão por workload e a joga fora ao agregar.** Os manifestos do
knee carregam um `latency_p50/p99/p999` só, de uma distribuição misturada.

E a mistura tem um efeito que torna o agregado inutilizável como promessa: o
`/wait/40ms` tem **piso de 40 ms por construção**. A 1 req/s contra 600 do
`/tiny`, ele responde por ~0,1% das amostras — e é exatamente por isso que o
`latency_p999_us=40249` do K1 não mede degradação nenhuma. **É o `/wait/40ms`
aparecendo no percentil onde o peso dele o coloca.**

**Portanto:** o caminho prescrito pelo §6.2 **não é executável** com o dado que o
experimento prescrito produziu. Não é um erro de quem rodou o WP05 — o harness
foi desenhado para achar knee, e para isso o agregado serve. É um descasamento
entre dois documentos que ninguém tinha cruzado.

## 2. De onde os números virão

**Fonte:** os CSVs `raw/` por workload de uma corrida de medição dedicada, lidos
**sem agrupar**. O dado bruto por workload já é produzido hoje; falta só não
descartá-lo.

**Ponto de operação:** o topo da zona verde de `docs/safe-operating-region.md` —
**2.500 req/s agregados**, com o mesmo mix e as mesmas conexões dos experimentos
do WP05. A zona verde é onde o R2 recomenda operar; um SLO derivado de outro
ponto prometeria sobre um regime que não é o recomendado.

**Duração:** ≥ 300 s por ponto, como no WP05.

**Requisito de instrumento (G2):** a corrida só vale com **controle positivo e
mutante** — o mutante obrigatório aqui é injetar latência conhecida num único
workload e verificar que **só a célula dele** se move. É o controle que teria
pego o agrupamento do §1.2.

## 3. A regra, congelada antes dos números

Para cada workload *w*, com `D(w)` = atraso deliberado de projeto
(`D = 40 ms` para `/wait/40ms`, `D = 0` para todos os outros):

```
SLO_p(w) = D(w) + 2 × ( medido_p(w) − D(w) )      para p ∈ {p50, p95, p99}
```

arredondado **para cima** ao próximo número redondo (1, 2, 5 × 10ⁿ µs).

**Por que a folga se aplica ao custo do serviço e não ao atraso de projeto.**
Dobrar o número cru do `/wait/40ms` prometeria 80 ms para um handler cujo tempo é
40 ms de `sleep` mais alguns micros de framework. A promessa que importa é sobre
**o que o framework acrescenta**, e é sobre isso que a folga tem de incidir.

**Por que 2×.** É folga de 100% sobre o medido no **topo** da região recomendada.
A zona verde inteira fica abaixo desse ponto, então o SLO é uma promessa sobre a
pior condição recomendada, e não sobre a média. Não é derivado de teoria; é uma
escolha declarada, e está aqui **antes** dos números justamente para poder ser
julgada sem eles.

**Disponibilidade e orçamento de erro:** não são derivados aqui — permanecem
`inherited` do `CRITERIA.md`, como o §6.2 já registra.

## 4. O que eu já vi, e por que ainda assim isto vale

**Honestidade sobre contaminação.** Eu já vi, antes de escrever isto:

- os percentis **agregados** do WP05 (p50 684 µs, p99 1.272 µs a 960/s);
- os percentis **agregados** do Final 1 (p99 mediano 1.165 µs, máximo 1.563 µs).

**Não vi nenhum percentil por workload** — eles não existem em lugar nenhum hoje,
porque o §1.2 explica que foram agregados na origem. As 15 células que este
documento governa são exatamente as que eu não tenho como ter visto.

**O que isso significa na prática:** a regra da §3 é auditável. Um revisor pode
aplicá-la aos números quando eles existirem e chegar às mesmas 15 células. Se
chegar a outras, a regra foi violada — e é para isso que ela está congelada aqui,
num commit próprio, antes da medição.

## 5. O que fazer com o R2-WP08 enquanto isto não roda

**O critério "SLO e safe operating region publicados" não pode ser fechado.** A
região segura está escrita; o SLO por workload não, e agora se sabe **por quê** —
não por falta de trabalho, mas porque a fonte prescrita não produz o dado.

As três saídas honestas para a §4 do pacote de decisão:

1. **Rodar a medição da §2 antes de decidir.** Custa uma corrida de ~30 min por
   ponto num host qualificado, não toca o produto e não cria candidato novo sob o
   G1. **É a saída que eu recomendo.**
2. **Decidir com o critério declarado aberto**, registrando que o SLO por
   workload não existe e que a operação em R2 se apoia só na região segura.
3. **Segurar em R1** até (1) fechar.

**Não é saída:** preencher as células com os agregados do WP05 ou dos finais. Os
agregados não são promessa de workload nenhum, pela §1.2 — e usá-los seria
publicar como SLO um número que mistura um `sleep` de 40 ms com um `/tiny`.
