# R2-WP04 — veredito: **PARADO**, com achado de capacidade

**2026-08-04.** O portão **continua em R1**. Os finais de 12 h **não rodaram** e
não vão rodar neste candidato.

Isto não é uma reprovação do produto. **Todo degrau passou em todos os critérios
pré-registrados**, inclusive o rehearsal de 2 h. O que parou o WP04 é uma regra
de campanha — o C22 — sobre qual taxa pode ser certificada para um final, e ela
disparou porque a recusa não chega a zero.

---

## 1. A escada, inteira

| # | Degrau | Taxa | Ciclos | Analisador | Recusas: total / injetadas / **carga** |
|---|---|---|---:|---|---|
| 1 | smoke | f = 0,10 | 5 | PASS | 56 / 56 / **0** |
| 2 | burn-in | f = 0,10 | 15 | PASS | 105 / 104 / **1** ← C22 desce a taxa |
| 3 | smoke | f = 0,06 | 5 | PASS | 1 / 0 / **1** |
| 4 | burn-in | f = 0,06 | 15 | PASS | 72 / 72 / **0** |
| 5 | **rehearsal** | f = 0,06 | 60 | **PASS** | 461 / 454 / **7** ← **C22 PARA** |

O rehearsal, em detalhe: `/health` com **zero** erros de transporte em 60 ciclos,
p99 mediano 1.196 µs, e **inclinação de RSS de 49,0 KiB/h avaliada** contra um
teto de 1 MiB/h — vinte vezes de margem, e desta vez o run foi longo o bastante
para o critério de memória ser realmente avaliado (`rss_slope_evaluated=true`).

**As sete recusas de carga estão espalhadas pelas duas horas**, uma de cada vez:
05:45, 06:11, 06:30, 06:36, 07:13, 07:15, 07:45. Não é um evento; é um piso.

## 2. Por que o WP04 para, em uma conta

| | |
|---|---|
| recusas de carga a f = 0,06 | 8 em 80 ciclos = **0,100/ciclo** |
| projetado num final de ~360 ciclos | **~36** |
| fração das conexões novas que é `/health` | 16 de 624 = 2,56% |
| esperadas em `/health` num final | **~0,9** |
| critério 1 permite | **0** |

Um final de doze horas nesta taxa tem cerca de uma recusa esperada exatamente no
workload que não pode ter nenhuma. **Gastar doze horas para descobrir isso seria
gastar doze horas.**

E não há para onde descer: o C22 permitiu **uma** descida, usada no degrau 2. O
piso existe justamente para impedir que a campanha vire uma busca por uma taxa em
que nada acontece — *"uma taxa suficientemente baixa sempre existe"*.

## 3. O achado, que é o que este WP entrega ao R2-WP05

**Descer a taxa não move o piso de recusa.**

| taxa | agregado | ciclos | recusas de carga | por ciclo |
|---|---:|---:|---:|---:|
| f = 0,10 | 1.586/s | 20 | 1 | 0,050 |
| f = 0,06 | 960/s | 80 | 8 | 0,100 |

Os intervalos de confiança se sobrepõem largamente — 1 evento em 20 ciclos não
distingue 0,05 de 0,10. **O que não se sustenta é a alegação contrária:** não há
qualquer evidência de que baixar a carga em 40% tenha reduzido as recusas.

**E a forma das recusas diz por quê.** Todas as medidas caem em **rajada de
reconexão**, não em carga permanente — as duas primeiras foram cronometradas
dentro do ciclo (34 s e 15,7 s após a virada). É onde o §4.1 já dissera que elas
se concentram: *"os picos nos instantes em que os seis geradores reabrem suas
~624 conexões"*.

**A hipótese que o WP05 tem de testar:** com `max_handlers = lanes = 2`, o que
produz a recusa é a **rajada de conexões novas**, não a taxa de requisições.
Descer a taxa reduz o tempo *dentro* do handler; não reduz o tamanho da rajada.
Se for isso, **nenhuma taxa converge** — e a resposta não é uma taxa, é mais
lanes, ou uma admissão que não recuse a sonda.

**Por que este WP não testou:** o instrumento não separa as variáveis. O
`run-soak.sh` fixa as conexões por carga e reabre todas por ciclo, e alterá-lo
mudaria o hash do instrumento (§2.1) criando candidato novo sob G1 — jogando fora
os cinco degraus acima. É trabalho do WP05, com instrumento próprio.

## 4. O que este pacote NÃO autoriza

- **Não promove nada.** O portão fica em R1.
- **Não é medida de capacidade.** Estas são cargas oferecidas escolhidas para um
  teste de estabilidade, e o §1 do pré-registro proíbe citá-las como envelope.
- **Não diz que o Druse regrediu.** Três hosts produziram três taxas de registro;
  o limiar de recusa é propriedade do framework **num ambiente**. Este host tem
  dois núcleos físicos para o servidor.
- **Não fecha a alegação de estabilidade.** O rehearsal de 2 h passou em tudo,
  inclusive na inclinação de memória avaliada. O que falta é a corrida de 12 h,
  e ela não é rodável nesta taxa por uma regra escrita antes de qualquer número.

## 5. O que fica para o R2-WP05

1. **Separar taxa de concorrência de reconexão.** A pergunta central, e ela
   precisa de um gerador que reuse conexões entre ciclos ou escalone a reabertura.
2. **`max_handlers = lanes` como parâmetro, não como constante.** Se a rajada é a
   variável, a resposta é lanes ou uma admissão que trate a sonda de liveness
   fora da fila da aplicação — recomendação que o §4.1 já tinha registrado e que
   agora tem uma segunda medição atrás dela.
3. **A `/health` fora das lanes de aplicação.** É o mesmo argumento que a ADR-050
   já fez para a métrica.
4. **Um envelope honesto.** O knee e a curva de degradação, que é o que o WP05 é.

## 6. Proveniência

Cada degrau tem seu pacote em `steps/<nome>/`, com manifesto (as seis taxas que o
C21 lê), `cycles.csv`, `final-state`, os contadores do servidor, as injeções
declaradas, o preflight em que o run se apoiou, a telemetria de processo, o
veredito do analisador e a **atribuição de recusas** exigida pelo C23 — em prosa
e em JSON. `SHA256SUMS` por degrau.

A qualificação do host está em `preflight-qual.txt` e `smoke-qual.txt`.
A identidade e as regras estão no pré-registro §3.7, §4.5, §4.6 e §4.7.
