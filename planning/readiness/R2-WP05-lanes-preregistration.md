# Pré-registro — R2-WP05, experimento 2: o que mais lanes custa

**Congelado antes do run, 2026-08-05.** Regra G3: critérios são congelados antes
do run, e a data do commit deste arquivo é anterior ao `started_utc` da medição
ou não é.

**Este arquivo não promove nada.** O portão fica em R1.

---

## 1. Por que este experimento existe

O experimento 1 (`evidence/2026-08-04-r2-wp05-burst/`) estabeleceu que a recusa
de saturação é função da **rajada de reconexão**, não da taxa, e que dobrar
`max_handlers` de 2 para 4 **elimina** as recusas: zero em 40 rajadas contra 7,7
previstas.

E registrou, na §5, o que ele **não** estabelecia:

> **Não diz que 4 lanes é a configuração certa.** Quatro lanes em dois núcleos
> físicos é sobreassinatura, e o relatório de 2026-07-25 mediu que mais lanes
> reduz recusa **e custa vazão e cauda**. Este experimento mediu um lado da
> troca; o outro lado é o resto do R2-WP05.

**Este é o outro lado.** Sem ele, a recomendação de produto sobre `max_handlers`
seria feita com metade da conta — e a metade que falta é justamente a que dói.

## 2. Hipótese

**H3:** aumentar `max_handlers` acima do número de núcleos físicos disponíveis ao
servidor **degrada vazão e cauda**, e a degradação cresce com a
sobreassinatura.

Falsificável: se vazão e p99 ficarem estáveis de 1 a 8 lanes, H3 é falsa e mais
lanes é ganho puro — o que mudaria a recomendação para "suba as lanes e pronto".

**Não é hipótese**, escrito agora para o resultado não ser esticado depois:

- **Não é medida de capacidade.** A carga é fixa em 960/s, que é o ponto de
  operação do R2-WP04, não o knee. Este experimento mede *o efeito das lanes
  naquele ponto*, não o teto.
- **Não é comparação com nenhum outro framework.**
- **Não decide a configuração.** Ele produz a conta; a escolha é do dono, e
  mudar `max_handlers` cria candidato novo de R2-WP04 sob G1.

## 3. Desenho

Quatro braços, **mesma taxa (960/s), mesma duração, mesma estrutura de rajada**.
Só `max_handlers` varia.

| Braço | lanes | contra os 2 núcleos físicos do servidor |
|---|---:|---|
| **L1** | 1 | subassinado |
| **L2** | 2 | **um por núcleo — a configuração atual** |
| **L4** | 4 | 2× sobreassinado |
| **L8** | 8 | 4× sobreassinado |

O L2 é a âncora: é a configuração do R2-WP04 e do experimento 1, então tudo é
lido como diferença contra ele.

**Duração: 600 s por braço.** Metade do experimento 1, e a razão é medida: a
600 s e 960/s cada braço completa ~576.000 requisições, o que é exposição de
sobra para um p99 — enquanto o experimento 1 precisava de 1200 s porque contava
**eventos raros** (recusas a 0,19 por rajada). Perguntas diferentes, exposições
diferentes.

**Rajada: período de 60 s**, a mesma do braço B/D do experimento 1, para que as
contagens de recusa sejam comparáveis com aquele resultado.

**Repetições: 2**, em ordem alternada (L1 L2 L4 L8 / L8 L4 L2 L1). Um braço só
não distingue efeito de deriva do host.

**Total: 8 braços × 10 min ≈ 1h30** com o build e a folga.

## 4. Critérios, congelados aqui

| # | Critério | Limiar |
|---|---|---|
| **X1** | H3 é sustentada se a **vazão completada** cair monotonicamente de L2 para L4 para L8, nas duas repetições | monotônico nas duas |
| **X2** | H3 é sustentada, por cauda, se o **p99** subir de L2 para L8 em mais de 20% nas duas repetições | as duas |
| **X3** | H3 é **refutada** se L8 ficar dentro de ±5% de L2 em vazão **e** dentro de ±20% em p99 | qualquer repetição |
| **X4** | o run é **inválido** se um braço perder requisições por falha de instrumento — gerador que não subiu, servidor morto, ou `completed` abaixo de 90% do planejado por razão não classificada | qualquer ocorrência |
| **X5** | as recusas continuam sendo lidas do snapshot da ADR-050 e o `injected.txt` vazio acompanha cada braço, como no experimento 1 | presente e vazio |
| **X6** | **L1 não entra em X1 nem em X2.** Ele é contexto, não tratamento: com uma lane a recusa é outra coisa, e incluí-lo na monotonicidade misturaria dois regimes | — |

**O X3 existe porque eu já tenho uma expectativa.** O relatório de 2026-07-25
mediu que 8 lanes em 4 CPUs custam vazão e cauda, e eu espero ver o mesmo aqui.
Um critério de refutação escrito antes é o que impede eu ler qualquer queda como
confirmação.

**E o X6 existe porque eu poderia ter sido esperto do jeito errado:** incluir L1
faria a série "melhorar depois piorar" e daria para contar qualquer história.

## 5. Instrumento

`ops/wp05/lanes-sweep.sh`, novo, ao lado do `burst-sweep.sh`. **Não toca nada de
`ops/soak/`.**

A diferença para o experimento 1: ele passa `-raw` ao gerador e **preserva o CSV
por requisição**, que é de onde saem vazão e percentis. O experimento 1 mandava
tudo para `/dev/null` porque só contava recusas no servidor.

Herda do `burst-sweep.sh` as três defesas que aquele ganhou apanhando:

- **recusa começar se a porta estiver ocupada** — senão mede o processo errado;
- **espera o snapshot da ADR-050 aparecer** antes da carga — `/health` responder
  não prova que o canal de métrica funciona;
- **`trap EXIT` mata o servidor em todo caminho de saída**, não só nos previstos.

### 5.1 O instrumento prova a si mesmo (G2)

- **positivo** — o braço L2 tem de reproduzir a ordem de grandeza de recusas do
  braço B do experimento 1 (3 em 20 rajadas). Um harness que mede zero em toda
  parte não distingue hipótese de bug;
- **negativo** — com o servidor parado, sai != 0 em vez de reportar vazão zero.

## 6. O que o resultado autoriza

| Resultado | O que decorre |
|---|---|
| H3 sustentada | a troca é real: mais lanes compra ausência de recusa e paga em vazão/cauda. A recomendação passa a ser **tirar a `/health` das lanes de aplicação**, que não paga esse preço |
| H3 refutada | mais lanes é ganho quase puro neste ponto de operação, e a recomendação é subir `max_handlers` — com a ressalva de que 960/s não é o knee |
| misto (vazão cai, cauda não, ou o inverso) | a conta é entregue como está, com as duas metades nomeadas, e a escolha é do dono |

**Nenhum caminho reabre os finais do R2-WP04.** Mudar `max_handlers` é candidato
novo sob G1, e a escada reinicia.

## 7. Owner e janela

| Campo | Valor |
|---|---|
| owner | o dono do repositório; execução autorizada em 2026-08-04 |
| host | `98.92.141.100` / `i-0dc43a340e9ab0388`, o mesmo do experimento 1, `preflight=pass` |
| affinity | servidor `0,1,4,5`, gerador `2,3,6,7` — inalterada |
| artefatos | `evidence/2026-08-05-r2-wp05-lanes/` |

## Resultado

Preenchido **depois** do run.

| Campo | Valor |
|---|---|
| H3 | — não medida |
| decisão | — |
