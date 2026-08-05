# As decisões que esperam por você — contexto, alternativas e consequências

**2026-08-05.** Escrito porque você pediu contexto, e porque "decidir" sem saber
o que cada caminho custa não é decidir.

**Regra deste arquivo:** ele não decide nada. Ele mostra o mapa. Onde eu tenho
recomendação, ela está marcada como minha e vem com o motivo — e com o que me
faria mudar de ideia.

> **RESOLVIDO em 2026-08-05.** O dono respondeu a decisão A: **A2 — "quero um
> framework para outras pessoas usarem."** A ratificação está no **ADR-052**
> (`planning/adrs.md`) e o caminho decorrente — C vira GO, B vira B3 com o knee
> medido antes — está em [`DECISOES-2026-08-05.md`](DECISOES-2026-08-05.md).
> Este arquivo permanece como o mapa que informou a decisão; ele não é mais uma
> lista de pendências.

---

## 0. O mapa: o que depende do quê

```
   A. Para que serve o Druse?        <-- decide se as outras importam
        |
        +--> B. max_handlers          <-- destrava o R2 (portão de produção restrita)
        |
        +--> C. publicar a v0.11.0    <-- destrava a L6 (adoção externa)
```

**A decisão A é a única que não pode ser adiada sem custo**, porque as outras
duas mudam de valor dependendo dela. As decisões B e C são baratas e reversíveis;
a A é a que define se vale a pena continuar gastando nelas.

---

# A. Para que serve o Druse?

Esta é a "ratificação da ambição por ADR" que o programa R3 exige. Não é
burocracia: é a pergunta que determina quanto rigor o projeto precisa.

### A1 — É seu, para você usar

Você roda seus próprios serviços nele. Ninguém externo adota.

| | |
|---|---|
| **precisa** | R2 (produção restrita) e nada mais |
| **não precisa** | política de suporte, 1.0, backports, janela de depreciação, documentação de consumidor |
| **o que fica sem sentido** | boa parte do R3 — as Fases 3 a 6 existem para adoção externa e portabilidade |
| **custo daqui até lá** | decidir B, rodar os finais (24 h de máquina em 2 dias), fechar o WP08 |
| **risco** | nenhum novo. O que hoje é limitação declarada continua declarada, e você é quem convive com ela |

### A2 — É para outras pessoas usarem

Alguém que não é você constrói produção em cima disso.

| | |
|---|---|
| **precisa** | tudo do A1 **mais** a L6 completa (feito, falta publicar), a L1 (falha de handler mata o processo — Fase 2 do R3), documentação de consumidor validada por quem não a escreveu, e um caminho de upgrade testado |
| **o que muda de natureza** | cada quebra de compatibilidade passa a ter custo para terceiros; hoje custa zero |
| **custo daqui até lá** | as Fases 0 a 2 do programa R3 — "baixo, baixo-médio, médio" na tabela de custo, mas em semanas, não horas |
| **risco real** | **um adotante externo confia numa base sem revisão humana de código.** Está declarado na política de integridade, mas declarar não elimina — transfere |

### A3 — É um artefato de pesquisa / demonstração

O valor está no *método* — o programa de prontidão, os controles com mutante, as
hipóteses refutadas por medição — mais do que no servidor HTTP.

| | |
|---|---|
| **precisa** | nada além do que já existe. O R2 sendo executado com rigor **é** o produto |
| **o que fica sem sentido** | 1.0, política de suporte, portabilidade |
| **custo daqui até lá** | zero. Já está lá |
| **o que ganha valor** | os documentos que ninguém escreve: as notas de execução, as decisões registradas com alternativa, os critérios que dispararam contra o autor |

### Minha leitura, e ela não substitui a sua

**O A2 é o único caminho caro, e é o único que traz risco novo.** As outras duas
opções são estados de encerramento válidos — e o programa de prontidão diz isso
explicitamente sobre o R3: *"produção restrita saudável é um estado final
válido"*.

Se eu tivesse que apostar no que descreve melhor a realidade hoje: **A1 com um
pé no A3.** Você tem um framework que roda seus serviços e um método de
verificação que é mais raro que o framework.

**O que me faria mudar:** alguém externo pedindo para usar. Isso é evidência, e
o §3 da política de integridade já nomeia esse pedido como gatilho.

---

# B. `max_handlers` — a decisão que destrava o R2

## O que está medido

O R2-WP04 rodou a escada inteira e **parou**: descer a taxa duas vezes não fez a
recusa de saturação chegar a zero.

O R2-WP05 explicou por quê e mediu a saída:

| medida | resultado |
|---|---|
| a recusa é função da **rajada de reconexão**, não da taxa | 8 braços, monotônico nas duas repetições |
| dobrar as lanes **elimina** as recusas | 0 em 40 rajadas contra 7,7 previstas (P = 0,0005) |
| e **não custa nada mensurável** neste ponto de operação | p99 de 1.250 µs com 2 lanes contra 1.254 µs com 8 |

**A ressalva que vale mais que os números:** tudo isso foi medido a **960 req/s**,
que é onde o servidor entrega 100% da carga oferecida em qualquer configuração.
Ou seja, **longe da capacidade**. O relatório de julho mediu custo de vazão em
taxas muito mais altas, e esta medição não contradiz aquela — mede outro ponto.

## Os caminhos

### B1 — Não mexer

| | |
|---|---|
| **o que acontece** | o R2 fica parado. Não há taxa em que a recusa chegue a zero, e o critério 1 (zero erro de transporte na sonda de liveness) não passa num final de 12 h |
| **custo** | zero agora, e o portão nunca sai do R1 |
| **quando faz sentido** | se a resposta de A for A3 |

### B2 — Subir `max_handlers` (sobreassinar as lanes)

| | |
|---|---|
| **o que acontece** | as recusas somem; a escada do WP04 reinicia com candidato novo (G1) |
| **custo** | 2h40 de escada + 24 h de finais em dois dias. É a rota mais curta até o R2 |
| **o que a medição sustenta** | zero recusas e nenhum custo de cauda **a 960/s** |
| **o que a medição NÃO sustenta** | que continue de graça perto do knee. Esse ponto não foi medido |
| **risco** | uma configuração recomendada com base num ponto de operação leve. Se um serviço real rodar perto da capacidade, a troca pode reaparecer |

### B3 — Tirar a `/health` das lanes de aplicação

| | |
|---|---|
| **o que acontece** | a sonda de liveness deixa de competir com a aplicação. O critério 1 passa **sem** mexer na capacidade |
| **custo** | mudança de produto com ADR, código no core, testes com mutante. Depois, a escada inteira (candidato novo) |
| **o argumento a favor** | a ADR-050 já fez exatamente esse movimento para a **métrica**, pela mesma razão. Há precedente no próprio repositório |
| **o argumento mais forte** | **uma sonda de liveness recusada porque a aplicação está ocupada é um risco de produção de verdade** — o orquestrador tira de rotação um processo saudável. Isso não é um obstáculo de teste; é um defeito que a campanha encontrou |
| **risco** | mais código no core, sem revisão humana |

### B4 — Aceitar as recusas como limitação declarada

| | |
|---|---|
| **o que acontece** | muda-se o critério 1 para tolerar recusa na sonda, e documenta-se |
| **custo** | zero de máquina |
| **por que eu recusaria** | é mudar o critério depois de ver o resultado, que é o que o G3 proíbe. E o problema é real: um orquestrador que recebe recusa no liveness mata o processo. Documentar não faz o processo sobreviver |

## Minha recomendação

**B3, e B2 como paliativo se você quiser o R2 rápido.**

O B3 ataca a causa — a sonda não devia estar na fila da aplicação — e tem
precedente interno. O B2 é mais barato e funciona no ponto medido, mas apoia a
recomendação num regime leve.

**O que me faria mudar:** medir o mesmo experimento perto do knee. Se lá o custo
de vazão aparecer, o B2 fica frágil e o B3 vira o único caminho.

---

# C. Publicar a v0.11.0

## O que está pronto

As três políticas (release, compatibilidade, integridade), o release ensaiado com
oito dos nove passos executados, e o verificador provado por três mutantes. Falta
uma linha: a tag.

## Os caminhos

### C1 — Publicar

| | |
|---|---|
| **o que fecha** | a **L6**, uma das três limitações bloqueantes do R3 |
| **o que entrega** | a correção do TRUST-001, que é de segurança |
| **o que começa** | o relógio do suporte. A política diz "só a linha corrente", sem backport |
| **o que a nota tem de dizer** | *verificado por hash, **não assinado***, e que o código é gerado por IA sem revisão humana |
| **risco** | a v0.11.0 carrega **quebra de compatibilidade**. Se alguém já usa entrada truncada em `trust_proxies`, o comportamento muda — para o correto, mas muda |

### C2 — Não publicar

| | |
|---|---|
| **o que acontece** | a L6 fica aberta e o R3 fica bloqueado nela |
| **custo** | zero agora |
| **quando faz sentido** | se a resposta de A for A1 ou A3 — sem adotantes externos, a política de release existe no papel e não precisa ser exercida |

## Minha recomendação

**Publicar, se a resposta de A for A2. Se for A1 ou A3, tanto faz — e "tanto
faz" é um resultado, não um adiamento.**

Uma observação que vale independente: **a correção do TRUST-001 é de segurança**,
e o `main` já a tem. Quem consome por commit fixado já pode pegá-la sem tag.

---

# D. O que custa cada caminho, em máquina

| Ação | Tempo de máquina | Meu tempo |
|---|---|---|
| decidir A | zero | zero |
| B2 (subir lanes) + escada + finais | **~27 h** em 2–3 dias | conduzo |
| B3 (liveness fora das lanes) | idem, **mais** o desenvolvimento | conduzo |
| C (publicar) | zero | minutos |
| medir o knee (que fortalece B) | ~3 h | conduzo |

**Nada disso exige você presente além da decisão.**

---

# E. O que eu faria, se a decisão fosse minha

1. **Responder A primeiro**, mesmo que a resposta seja "não sei ainda" — porque
   isso já elimina caminhos.
2. **Medir o knee** antes de decidir B. São 3 h e transformam a recomendação de
   "vale no ponto leve" em "vale onde importa".
3. **Fazer B3**, porque a sonda de liveness na fila da aplicação é um defeito de
   produção e não um obstáculo de campanha.
4. **Publicar a v0.11.0** só se A = A2.

E uma coisa que não é decisão sua e eu digo mesmo assim: **o programa de
prontidão parou o WP04 antes de ele gastar 24 h numa busca que nunca convergiria,
e o experimento seguinte provou que ele estava certo.** Isso é o método
funcionando, e é a parte do projeto que eu consideraria mais difícil de
reconstruir.
