# Região segura de operação

**2026-08-05.** Escrita a partir de medição, não de estimativa. Fecha um dos dois
critérios de saída em aberto do R2-WP08.

**Leia a §5 antes de aplicar qualquer número daqui.** Ela diz sobre que máquina
isto vale e o que não foi medido.

---

## 1. A configuração recomendada

**Não sobreponha `max_handlers`.** O default —
`Limits.max_handlers = 0` → `clamp(núcleos físicos, 4, 32)` — é a recomendação, e
ela vem de medição, não de princípio.

| configuração | p99 a 960 req/s | recusas a 5.000 req/s |
|---|---:|---:|
| `max_handlers = 1` | **34.174 µs** | 0 |
| `max_handlers = 2` | 1.250 µs | **214** |
| **`max_handlers = 4`** (o default aqui) | 1.257 µs | **1** |
| `max_handlers = 8` | 1.254 µs | **0** |

**Escolher um valor abaixo do default custa caro e não compra nada.** Uma
campanha interna deste projeto fixou 2 "porque dois núcleos físicos não hospedam
quatro lanes", e essa escolha produziu as recusas que travaram um work package
por dois dias. Nos **mesmos** dois núcleos, 4 lanes deram cauda menor e recusa
quase zero.

**O mecanismo, porque a intuição erra aqui:** uma lane bloqueada dentro de um
handler **não consome CPU** — ela segura um slot de concorrência. Dimensionar
lanes por núcleo trata lane como worker ligado a CPU, e ela não é. Se a sua
aplicação tem qualquer handler que espera (I/O de banco, chamada upstream,
`sleep`), **menos lanes que o default é a decisão que mais dói**.

**Sobreassinar acima do default:** medido até 8 lanes em 2 núcleos físicos (4×) e
não custou vazão nem cauda até 10.000 req/s. Não é recomendação — é a ausência de
um custo que se esperava encontrar.

## 2. A região medida

Uma `c5.2xlarge` com **dois núcleos físicos dedicados ao servidor**, mix de seis
perfis (§4 do pré-registro do soak), 300 s por ponto.

| taxa oferecida | entregue | p99 | recusas de saturação |
|---:|---:|---:|---:|
| 960/s | 100,00% | 1.272 µs | 0 |
| 1.497/s | 100,00% | 1.252 µs | 1 |
| 1.996/s | 100,00% | 1.263 µs | 0 |
| 2.498/s | 100,00% | 1.271 µs | 2 |
| 3.498/s | 100,00% | 1.268 µs | 6 |
| 4.997/s | 100,00% | 1.398 µs | 69 |
| 6.997/s | 100,00% | 1.451 µs | 63 |
| **9.997/s** | **99,99%** | 1.786 µs | 318 |

**Não há knee na faixa medida.** O goodput acompanha a oferta até 10.000 req/s;
a cauda sobe 43% ao longo de um fator de dez na carga. Isso é degradação suave.

## 3. As três zonas

| zona | taxa | o que esperar |
|---|---|---|
| **verde** | **até ~2.500/s** | goodput integral, p99 estável em ~1,27 ms, recusas raras (≤ 2 em 300 s) |
| **amarela** | 2.500 – 7.000/s | goodput integral, p99 até ~1,45 ms, **recusas crescem** (6 → 69 em 300 s) |
| **laranja** | 7.000 – 10.000/s | goodput 99,99%, p99 até ~1,79 ms, **recusas 318 em 300 s** — ~0,011% das requisições |
| **desconhecida** | acima de 10.000/s | **não medida.** Não opere aqui sem medir |

**A fronteira verde/amarela não é o servidor quebrando.** É onde a recusa de
saturação deixa de ser rara, e recusa é uma **conexão fechada sem resposta HTTP**
— o cliente vê um fim de conexão, não um status.

## 4. As duas consequências operacionais que importam

### 4.1 Sonda de liveness

**Uma sonda de liveness compartilha as lanes da aplicação.** Sob rajada de
reconexão, ela pode receber a mesma recusa de saturação que qualquer outra
conexão — e um orquestrador que recebe recusa no liveness **tira de rotação um
processo saudável**.

Nas zonas verde e amarela isso é raro o bastante para não ter aparecido em 80
ciclos de campanha. **Na zona laranja, planeje para isso**: tolerância de falhas
consecutivas no probe (não 1), ou período de probe maior que o intervalo entre
rajadas.

Um reparo estrutural — tirar a sonda das lanes de aplicação — está identificado e
**não implementado** (`planning/readiness/DECISOES-2026-08-05.md` §3.1).

### 4.2 Rajadas de reconexão importam mais que a taxa média

A recusa de saturação é função de **duas** variáveis, e as duas foram medidas
separadamente:

- **a rajada de reconexão** — com a taxa parada, as recusas escalam linearmente
  com o número de eventos de reconexão (0,19 por rajada com 2 lanes);
- **a taxa** — com a rajada parada, as recusas sobem com a carga.

**Consequência prática:** um cliente que abre e fecha conexões agressivamente
estressa mais que um que mantém keep-alive na mesma taxa. **Prefira keep-alive**,
e desconfie de balanceadores que reciclam conexões em bloco.

## 5. O que esta região NÃO cobre

Isto vale para o que foi medido, e a lista do que não foi é a parte que protege
quem lê:

- **Uma classe de máquina.** `c5.2xlarge`, dois núcleos físicos para o servidor,
  kernel `6.17.0-1017-aws`. Outra topologia precisa da própria medição — o que
  generaliza é o **mecanismo** (lane bloqueada não gasta CPU), não os números.
- **Um mix.** Seis perfis com **um** handler bloqueante a 1–2 req/s. Uma
  aplicação com mais I/O bloqueante por requisição desloca tudo isto para baixo.
- **Sem recuperação depois de sobrecarga.** Não foi medido o que acontece quando
  a carga passa de 10.000/s e volta. **É a lacuna mais importante desta página.**
- **Sem matriz fatorial.** `max_connections` e o pool upstream ficaram no default.
- **Sem comparação com pares.** Deliberadamente: o §8 do pré-registro do soak
  proíbe comparar sem um harness que prove trabalho equivalente.
- **Sem TLS.** Toda medição é HTTP direto ou através do Caddy fixado; o custo do
  TLS não está aqui.
- **Corridas de 300 s.** A estabilidade de 12 h é o R2-WP04, e está em curso.

## 6. Como reproduzir

```
evidence/2026-08-05-r2-wp05-knee/     a escada de taxa e a matriz de lanes
evidence/2026-08-05-r2-wp05-lanes/    o efeito das lanes a 960 req/s
evidence/2026-08-04-r2-wp05-burst/    a rajada como variável
ops/wp05/lanes-sweep.sh               o harness
```

Cada manifesto carrega a taxa agregada, as lanes, o commit, o sha256 dos dois
binários e os percentis. **Um número desta página que você não conseguir achar
num manifesto é um erro meu** — reporte-o.
