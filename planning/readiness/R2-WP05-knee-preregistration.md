# Pré-registro — R2-WP05, experimento 3: o knee, e a troca onde ela dói

**Congelado antes do run, 2026-08-05.** Regra G3.

**Este arquivo não promove nada.** O portão fica em R1.

---

## 1. Por que este experimento existe

Os experimentos 1 e 2 mediram, respectivamente, que a recusa é função da rajada
e que mais lanes não custa nada — **a 960 req/s**. E o experimento 2 registrou,
no próprio veredito, por que isso não basta:

> Todos os braços serviram tudo. Quando nenhuma configuração está saturada, a
> diferença entre elas não pode aparecer na vazão.

A decisão de produto que o ADR-052 destravou
([`DECISOES-2026-08-05.md`](DECISOES-2026-08-05.md) §3) manda medir o knee
**antes** de congelar a escolha entre B2 e B3, e é isto.

**O que muda conforme o resultado:** se a troca aparecer perto da saturação, o
B2 (subir lanes) cai de paliativo a descartado. Se não aparecer, o B2 vira
paliativo legítimo para destravar o R2 enquanto o B3 é desenvolvido. **Nos dois
mundos a medição muda o que se faz** — que é o único motivo aceitável para
gastar três horas de host.

## 2. Hipóteses

**H4 (o knee existe e é localizável):** há uma taxa oferecida acima da qual o
goodput deixa de acompanhar a carga. Falsificável: se o goodput acompanhar a
oferta até o topo da escada, o knee está acima da faixa medida e o experimento
**não** o encontrou — o que é um resultado, não um fracasso.

**H5 (a troca aparece perto do knee):** ao redor do knee, `max_handlers` maior
degrada vazão **ou** cauda em relação a `lanes = 2`. Falsificável: se a 8 lanes
o goodput e o p99 no knee ficarem equivalentes a 2 lanes, H5 é falsa e o custo
de sobreassinar não existe **nem** onde dói.

**Não são hipóteses:**

- **Não é o envelope do R2-WP05.** O envelope pede seis perfis, matriz fatorial
  e recovery; isto é uma escada de taxa em um mix. É entrada para o envelope.
- **Não é comparação com nenhum outro framework.**
- **Não autoriza configuração sozinho.** Ele fecha a conta que a decisão B usa.

## 3. Desenho — duas fases, porque a segunda depende da primeira

### Fase 1 — localizar o knee a `lanes = 2`

Escada de taxa, **300 s por ponto**, mix e conexões idênticos aos experimentos
1 e 2, rajada de 60 s.

| ponto | taxa agregada | fração do teto do WP04 (~2.350/s) |
|---:|---:|---|
| K1 | 960/s | 41% — a âncora, o ponto já medido |
| K2 | 1.500/s | 64% |
| K3 | 2.000/s | 85% |
| K4 | 2.500/s | 106% |
| K5 | 3.500/s | 149% |
| K6 | 5.000/s | 213% |

**A escada é grosseira de propósito.** Encontrar o intervalo em que o goodput se
descola basta para a Fase 2; resolver o knee com precisão é trabalho do
envelope, não desta pergunta.

**As taxas escalam o mix inteiro proporcionalmente**, exceto `/health`, que fica
em 20/s pela mesma razão dos experimentos anteriores — é sonda, não carga, e
reduzi-la tiraria amostras do que mais interessa observar sob saturação.

### Fase 2 — a troca, nos três pontos que importam

Escolhidos **a partir do resultado da Fase 1**, não antes: o ponto imediatamente
abaixo do knee, o knee, e o imediatamente acima. Em cada um, `lanes ∈ {2, 4, 8}`.

Nove braços de 300 s. **Uma repetição** — e a razão de não ser duas está dita:
a Fase 1 já entrega seis pontos que servem de controle de deriva, e o efeito
que a Fase 2 procura (H5) é de magnitude, não de evento raro. Se o resultado
ficar em cima do limiar de X7, a repetição vira obrigatória antes de qualquer
conclusão.

## 4. Critérios, congelados aqui

| # | Critério | Limiar |
|---|---|---|
| **K-A** | o knee é o primeiro ponto em que `2xx completados` fica **abaixo de 97%** da carga oferecida | 97% |
| **K-B** | **H4 é refutada** se todos os seis pontos ficarem ≥ 97%: o knee está acima de 5.000/s e este experimento não o mediu | — |
| **X7** | **H5 é sustentada** se, no knee ou acima, `lanes = 8` entregar goodput ≥ 5% menor **ou** p99 ≥ 20% maior que `lanes = 2` | 5% / 20% |
| **X8** | **H5 é refutada** se, nos três pontos da Fase 2, `lanes = 8` ficar dentro de ±5% em goodput **e** ±20% em p99 de `lanes = 2` | os três |
| **X9** | o run é **inválido** se um braço falhar por instrumento — gerador que não subiu, servidor morto, snapshot ausente | qualquer |
| **X10** | recusas continuam vindo do snapshot da ADR-050; `injected.txt` vazio acompanha cada braço | 8/8 |

**O X8 repete a forma do X3 porque o X3 funcionou:** ele disparou contra a minha
expectativa no experimento 2, e é o que impede eu ler qualquer diferença como
confirmação de uma troca que eu já acho que existe.

**O K-B existe porque "não achei o knee" é um resultado legítimo** e precisa ter
nome antes, senão vira "a escada foi mal escolhida" depois.

## 5. Instrumento

`ops/wp05/lanes-sweep.sh`, **sem modificação** — ele já aceita lanes, período e
duração, e já grava goodput e percentis no manifesto. As taxas entram por
ambiente, como nos experimentos anteriores.

**Nada de `ops/soak/` é tocado.**

### 5.1 O que o instrumento tem de provar antes (G2)

- **positivo** — o ponto K1 (960/s, 2 lanes) tem de reproduzir o braço L2 do
  experimento 2: ~576.000 × (300/600) ≈ 288.000 2xx e p99 na casa de 1,25 ms. Se
  não reproduzir, a escada não é comparável com o que já foi medido e o run é
  inválido antes de começar;
- **negativo** — o mesmo do experimento 2: servidor parado sai != 0.

## 6. O que o resultado autoriza

| Resultado | O que decorre |
|---|---|
| H5 sustentada | **B2 descartado.** Sobreassinar custa onde importa, e a saída é B3 sozinho |
| H5 refutada | **B2 vira paliativo legítimo**: destrava o R2 agora enquanto o B3 é desenvolvido. A recomendação passa a incluir a taxa acima da qual ele deixa de valer |
| H4 refutada (knee acima de 5.000/s) | o servidor não satura na faixa medida; a decisão B fica com a conta do experimento 2 e a ressalva de que o knee é mais alto do que se pensava |

**Nenhum caminho reabre os finais.** Mudar `max_handlers` cria candidato novo
sob G1.

## 7. Owner e janela

| Campo | Valor |
|---|---|
| owner | dono do repositório; execução autorizada em 2026-08-05 |
| host | `98.92.141.100` / `i-0dc43a340e9ab0388`, `preflight=pass`, qualificação válida até 2026-08-11 |
| affinity | servidor `0,1,4,5`, gerador `2,3,6,7` — inalterada |
| custo | Fase 1 ~40 min, Fase 2 ~60 min |
| artefatos | `evidence/2026-08-05-r2-wp05-knee/` |

## Resultado

Preenchido **depois** do run.

| Campo | Valor |
|---|---|
| knee | — não medido |
| H4 | — |
| H5 | — |
| decisão | — |
