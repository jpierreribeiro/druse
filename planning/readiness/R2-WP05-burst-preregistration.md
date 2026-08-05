# Pré-registro — R2-WP05, experimento 1: a rajada é a variável?

**Congelado antes do run, 2026-08-04.** Regra G3: critérios são congelados antes
do run, e a data do commit deste arquivo é anterior ao `started_utc` da medição ou
não é.

**Este arquivo não promove nada.** O portão fica em R1. Ele torna uma medição
*admissível*; não é evidência sobre o Druse.

---

## 1. Por que este experimento existe

O R2-WP04 parou em 2026-08-04 (`evidence/2026-08-04-r2-wp04-ladder/verdict.md`).
Ele mediu que **descer a taxa não move o piso de recusa**: f = 0,10 deu 1 recusa
de carga em 20 ciclos, f = 0,06 deu 8 em 80. E registrou a hipótese que não pôde
testar:

> com `max_handlers = lanes = 2`, o que produz a recusa é a **rajada de ~624
> conexões novas na borda do ciclo**, não a taxa de requisições. Descer a taxa
> reduz o tempo *dentro* do handler; não reduz o tamanho da rajada.

**Se a hipótese for verdadeira, nenhuma taxa converge** e o R2 não avança por
ajuste de carga. Se for falsa, a explicação está em outro lugar e o WP05 precisa
procurá-la antes de propor configuração.

Esta é a pergunta mais barata que responde a mais cara, e é por isso que ela vem
antes do resto do R2-WP05 (`R2-restricted-production.md` §R2-WP05).

## 2. Hipótese

**H1:** o número de recusas de saturação atribuíveis à carga é função do
**número de eventos de reconexão** durante o run, e **não** da taxa de
requisições oferecida.

Falsificável: se as recusas não escalarem com a frequência de rajada a taxa
constante, H1 é falsa.

**H2:** aumentar `max_handlers` reduz as recusas à mesma frequência de rajada.

Falsificável do mesmo jeito, e **H2 pode ser falsa com H1 verdadeira** — nesse
caso a rajada é a variável e mais lanes não é a alavanca, o que muda a
recomendação de produto.

**Não são hipóteses**, escritas agora para o resultado não ser esticado depois:

- **Não é medida de capacidade.** Nenhum número daqui é knee, teto ou envelope.
  Isso é o resto do R2-WP05.
- **Não é comparação com nenhum outro framework, build ou campanha.**
- **Não substitui o R2-WP04.** Nada aqui promove a escada nem reabre os finais;
  se H1 for confirmada, o próximo passo é uma **decisão de produto** do dono.

## 3. Desenho

Quatro braços, mesma duração e mesma taxa agregada. **Só duas coisas variam:** a
frequência de reconexão e o número de lanes.

> ### Primeira emenda — 2026-08-04, antes do run: o desenho estava subdimensionado
>
> **Congelei quatro braços sem fazer a conta de poder.** Um braço de validação de
> 60 s deu zero recusas, o que me levou a fazê-la: a taxa medida no rehearsal do
> WP04 é **7 recusas de carga em 60 rajadas = 0,117 por rajada**, e o desenho
> original previa **0,12 / 0,58 / 1,17 / 0,58** recusas esperadas.
>
> Distinguir 0,58 de 1,17 com contagens de Poisson exige muito mais exposição do
> que 600 s davam. **O experimento teria produzido quatro números pequenos e
> nenhuma resposta** — e o pior desfecho seria eu ler o ruído como dose-resposta.
>
> A emenda dobra a duração e encurta os períodos. **Nada sobre as hipóteses, os
> critérios ou a atribuição muda** — só a exposição. E ela vem antes do run,
> porque depois seria outra coisa.

| Braço | lanes | período de rajada | eventos de reconexão em **1200 s** | esperadas a 0,117/rajada |
|---|---:|---:|---:|---:|
| **A** | 2 | nenhum (um run contínuo) | **1** | **0,12** |
| **B** | 2 | 60 s | **20** | **2,3** |
| **C** | 2 | 20 s | **60** | **7,0** |
| **D** | **4** | 60 s | 20 | 2,3 se lanes não importarem |

**A vs C** é o discriminador: 0,12 contra 7,0. **B vs C** é a dose-resposta —
razão de rajadas 3×, razão esperada 3×, e é ela que separa "a rajada importa" de
"algo acontece no começo do run".

- **A vs B** testa H1: mesma taxa, mesma duração, mesma carga total; só muda se
  as conexões são reabertas.
- **B vs C** é a **dose-resposta**, e é o que separa "a rajada importa" de "algo
  acontece no começo do run". Sem ela, um único ponto poderia ser aquecimento.
- **B vs D** testa H2.

**Taxas:** as da §4.7 do pré-registro do soak (f = 0,06, agregado 960/s), as
mesmas seis cargas. Manter a mistura importa: a carga bloqueante é a que ocupa
lane, e trocá-la mudaria o mecanismo em estudo.

**Duração:** 1200 s por braço (ver a emenda acima). Total ~2h40 mais o build de
cada braço.

**Repetições:** cada braço roda **2 vezes**, alternando a ordem (A B C D / D C B A).
Um braço só não distingue efeito de deriva do host.

## 4. Critérios, congelados aqui

| # | Critério | Limiar |
|---|---|---|
| **W1** | H1 é sustentada se as recusas de carga crescerem monotonicamente de A para B para C, nas duas repetições | monotônico nas duas |
| **W2** | H1 é **refutada** se A e C ficarem dentro de ±1 recusa uma da outra | qualquer repetição |
| **W6** | um braço cujo servidor não foi o processo medido é **inválido**: a porta tem de estar livre antes do start e o snapshot da ADR-050 tem de aparecer antes da carga | qualquer ocorrência |
| **W3** | H2 é sustentada se D < B nas duas repetições | as duas |
| **W4** | o run é **inválido** se qualquer braço registrar falha de instrumento — gerador que não subiu, servidor que morreu, snapshot ausente ou obsoleto | qualquer ocorrência |
| **W5** | a atribuição injetada/carga usa `ops/soak/attribute-refusals.py`; **este experimento não injeta falhas**, então toda recusa é de carga por construção, e o `injected.txt` vazio tem de estar no artefato para provar isso | presente e vazio |

**W2 existe porque eu quero que H1 seja verdadeira.** Um critério de refutação
escrito antes é a única defesa contra ler quatro números a favor da própria
hipótese.

## 5. Instrumento

**Novo**, em `ops/wp05/burst-sweep.sh`. **Não toca nada de `ops/soak/`** — aqueles
arquivos são pinados por sha256 na §2.1 do pré-registro do soak, e mudá-los
criaria candidato novo sob G1, invalidando os cinco degraus já rodados.

Ele **reusa sem modificar**: o `soak-server` e o `openload` (mesmas fontes,
mesmos binários), o canal de snapshot da ADR-050, e a affinity de registro.

**O que ele faz de diferente do `run-soak.sh`:** o `run-soak.sh` reinicia os seis
geradores a cada ciclo, sempre. Aqui o período de reinício é **parâmetro**, e é
essa a variável que o WP04 não conseguiu isolar.

### 5.1 O instrumento prova a si mesmo antes de medir (G2)

Antes de qualquer braço valer:

- **controle positivo** — o braço B tem de reproduzir a ordem de grandeza do
  degrau equivalente do WP04 (o smoke a f = 0,06 contou 1 recusa de carga em 5
  ciclos). Um instrumento que mede zero em toda parte não distingue hipótese de
  bug;
- **controle negativo** — com o servidor parado, o harness tem de **falhar**, não
  reportar zero recusas. Ausência de medição não pode virar resultado limpo
  (INS-013).

## 6. O que o resultado autoriza

| Resultado | O que decorre |
|---|---|
| H1 sustentada, H2 sustentada | a alavanca é `max_handlers`; vira proposta de configuração e um novo candidato de WP04 |
| H1 sustentada, H2 refutada | a rajada é a variável e mais lanes não resolve; a saída provável é tirar a sonda de liveness das lanes de aplicação — **decisão de produto, com ADR** |
| H1 refutada | a hipótese do WP04 morre; o WP05 procura a causa antes de propor qualquer configuração |

**Nenhum desses caminhos reabre os finais sozinho.** Reabrir exige um candidato
novo e a escada inteira, e isso é decisão do dono.

## 6.1 Segunda emenda — host novo, e o piso de disco que não é deste experimento

**2026-08-04, antes de qualquer braço do reinício.**

**O host mudou, então o experimento reinicia pelos oito braços.** O de
`44.212.50.252` ficou inacessível durante a segunda repetição e não voltou; os
cinco braços medidos lá pertencem àquele ambiente e **não se juntam** aos novos
(G1). O `ops/wp05/resume-sweep.sh` recusa retomar pelos três justamente por isso.

**Host de registro: `98.92.141.100` / `i-0dc43a340e9ab0388`.** Ele é
comparável ao anterior nas coisas que decidem — mesmo `c5.2xlarge`, mesmo **Xeon
Platinum 8275CL**, mesmo kernel **`6.17.0-1017-aws`**, mesma topologia de irmãos
`(0,4) (1,5) (2,6) (3,7)`, mesma RAM. Isso não faz os braços antigos valerem
aqui; faz o resultado novo ser lido no mesmo contexto do R2-WP04.

### O piso de disco, e por que ele não se aplica a este experimento

O host tem **20 GiB livres** e o `preflight.sh` exigiria **25**, então ele
recusaria.

**O piso de 25 GiB foi derivado para a escada do soak**, e a justificativa está
escrita lá: *"o disco guarda a escada inteira e não um run: smoke, burn-in,
rehearsal e os dois finais ficam lado a lado… nas taxas do §4.5 isso é ~17 GiB de
artefato"*. Aqueles 17 GiB são **CSV por requisição**, que o `run-soak.sh`
escreve e este experimento **não escreve**.

O `burst-sweep.sh` grava por braço: um manifesto de ~1 KB, um `server.log`, um
snapshot, e os dois binários (~8 MB). **Oito braços somam menos de 100 MB.** Com
o repositório e o toolchain, o total fica abaixo de 1 GiB — contra 20 GiB
livres, **vinte vezes de margem**.

**Então o piso é aplicado com o valor deste experimento, não o da escada:**
`DRUSE_SOAK_LADDER_FLOOR_GIB=2`, que é duas vezes o pior caso estimado.

**Por que isto não é afrouxar um controle para admitir um host.** O piso é um
parâmetro que eu criei hoje justamente para separar "o que este run escreve" de
"o que a escada guarda", e a derivação por taxa continua intacta — ela prevê
11 GiB para o soak a f = 0,06 e continua prevendo. O que muda é o piso, e ele
está sendo aplicado ao workload para o qual foi medido.

**E o critério que isto cria, congelado agora:** o uso real de disco dos oito
braços é **medido e registrado no pacote de evidência**. Se passar de 2 GiB, a
justificativa acima está errada e o run é inválido — não "quase certo".

## 7. Owner e janela

| Campo | Valor |
|---|---|
| owner | o dono do repositório; **execução autorizada em 2026-08-04** |
| host | ⟶ **`98.92.141.100`** / `i-0dc43a340e9ab0388` (§6.1). O anterior foi perdido |
| affinity | servidor `0,1,4,5`, gerador `2,3,6,7` — inalterada |
| artefatos | `evidence/2026-08-04-r2-wp05-burst/` |

## Resultado

Preenchido **depois** do run.

| Campo | Valor |
|---|---|
| H1 | **SUSTENTADA** — W1 satisfeito nas duas repetições (`0<3<15`, `1<3<9`); W2 não disparou |
| H2 | **SUSTENTADA** — W3 satisfeito nas duas (`D=0 < B=3`) |
| validade | W4, W5, W6 e o critério de disco da §6.1 todos satisfeitos |
| decisão | pelo §6: **a alavanca é `max_handlers`** → proposta de configuração e candidato novo de R2-WP04 |
| evidência | `evidence/2026-08-04-r2-wp05-burst/` |

**A recusa é função da rajada de reconexão, não da taxa.** Com carga idêntica, um
evento de conexão deu 0 e 1 recusa; sessenta deram 15 e 9. E dobrar as lanes
zerou: 0 em 40 rajadas contra 7,7 previstas pelo comportamento de 2 lanes
(P = 0,00047 se a taxa fosse a mesma).

**Isto explica por que o R2-WP04 parou.** Ele desceu a taxa duas vezes e o piso
não se moveu, porque a taxa nunca foi a variável — o `run-soak.sh` reabre ~624
conexões por ciclo qualquer que seja a carga. Nenhuma taxa teria convergido, e o
C22 parou a busca antes de gastar dois finais de 12 h nela.
