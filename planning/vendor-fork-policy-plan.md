# Plano: assumir o fork do transporte (odin-http + nbio)

**Data:** 2026-08-08 · **Estado:** rascunho de trabalho, não commitado
**Fecha:** limitação 5 do `runtime-feasibility-study.md` (R3-WP02) e a metade
"policy decision" do passo 1 da sequência do R3.

---

## 0. Por que agora

Duas razões, e a segunda é a que decide o timing.

1. **A dívida é real e não está inventariada.** 43 divergências sobre dois
   pacotes de terceiros (`laytan/odin-http` pin `112c49b`, ~6,1k linhas;
   `core:nbio` vendorizado, ~8,8k linhas). Cada patch novo aumenta o custo de
   qualquer reconciliação futura, e ninguém sabe hoje qual é o tamanho real.

2. **É trabalho de escrivaninha, e o R2 está bloqueado em hardware.** O R2 não
   avança sem host; este plano não precisa de host nenhum. Fazer agora usa um
   bloqueio que já existe em vez de competir com trabalho que poderia rodar.

A sequência do R3 lista R3-WP02 como passo 3, depois de "own the I/O layer"
(passo 1) — mas o próprio passo 1 diz **"policy decision first, code second"**,
e a decisão de política é exatamente o que este plano entrega. A decisão
destrava os passos 2, 4 e 5; o código do passo 1 não é pré-requisito dela.

## 1. Premissa, declarada como decisão e não como dúvida

> **O fork é permanente até prova em contrário. A migração para
> `core:net/http` é opcional e condicional, não planejada.**

Fundamento — dois fatos já registrados na árvore:

- A spec de arquitetura é categórica: a API oficial **não é conhecida**, só se
  sabe que será sobre `core:nbio`, **sem API publicada nem prazo**, e proíbe
  assumir seu modelo de threading, ownership ou shutdown. Planejar uma
  migração para alvo desconhecido é planejar sobre ficção.
- Metade do fork conserta vulnerabilidade, não estilo. Nove patches citam
  classe explícita — DoS remoto, request smuggling, memory safety
  (patches 1, 2, 3, 14, 15, 16, 18, 19, 21). Voltar ao upstream puro é
  **regredir para buracos conhecidos**. O patch 14 sozinho: chunk-size
  negativo derrubava o processo, mesmo em handler que ignora o corpo.

Corolário operacional: **parar de escrever "temporário" sobre o vendor.**
O custo de saída já está pago no desenho (nenhum tipo de transporte vaza pela
API pública; a migração fica localizada na fronteira do transporte;
`body_stream.odin` é arquivo separado, deletável em um passo). O que falta não
é a saída — é a decisão.

## 2. Achado que motiva a fase A

**`vendor/nbio/` não tem `VENDOR.md`.** Nenhum registro de proveniência:
sem commit de upstream, sem licença, sem registro de patches. As divergências
existem no código (`impl_linux.odin` cita "DRUSE PATCH 33"; `mpsc.odin` e
`nbio.odin` carregam invariantes de auditoria T1), mas a numeração é contínua
com a do `odin-http` e **só metade dela está documentada**.

Isso é o pior estado possível: dívida real, invisível ao inventário.
`vendor/odin-http/VENDOR.md` é exemplar e serve de molde exato.

## 3. As fases

### Fase A — Inventário (fecha a lacuna, não decide nada)

| # | Entrega | Critério de pronto |
|---|---|---|
| A1 | `vendor/nbio/VENDOR.md` no molde do `odin-http`: upstream, commit fixado, licença, o que foi incluído/omitido, registro de patches | Toda divergência do nbio tem linha com arquivo, invariante e justificativa |
| A2 | Classificação das 43 em três baldes (abaixo), em tabela única | Cada patch em exatamente um balde, sem "a definir" |
| A3 | Teste de deriva: o build falha se o vendor divergir do registro | Roda no gate; conta derivada, **não fixada em número** |

**A3 é a lição de [gates pinned to numbers]**: três controles já reprovaram
mudanças legítimas por fixar contagem. O teste confere *registro vs árvore*,
nunca "devem existir 43".

Os três baldes:

- **`UPSTREAM`** — conserto de segurança/correção que serve a qualquer usuário
  do pacote. Candidatos: 1, 2, 3, 14, 15, 16, 18.
- **`DRUSE`** — desenho do framework, que o upstream provavelmente não quer:
  admissão limitada, lanes, shutdown, deadlines, accept dedicado.
  Inclui 8, 11, 12, 19, 20, 21, 24.
- **`BRIDGE`** — existe só porque o adapter precisa; deletável quando/se o
  transporte mudar. Já marcados no registro: 9, 10, 11, 12, 13, 22, 23.

Um patch pode ser `UPSTREAM` e ter sido motivado pelo Druse — o balde diz para
onde ele vai, não de onde veio.

### Fase B — O ADR (a decisão)

`ADR-0NN: política do transporte vendorizado`, com quatro seções:

1. **Posição.** Fork assumido; migração condicional. O texto do §1 acima.
2. **Condições de reabertura**, explícitas e verificáveis — o ADR só volta à
   mesa se **todas** ocorrerem: (a) `core:net/http` existe com API publicada;
   (b) passa a suíte de conformidade de transporte; (c) cobre os invariantes
   dos baldes `DRUSE` e `BRIDGE` ou os torna desnecessários.
3. **Procedimento de re-vendor.** Já descrito em prosa no `VENDOR.md`
   (re-copiar upstream, preservar `body_stream.odin`, re-aplicar o gancho de
   compactação do `scanner.odin`) — vira procedimento numerado e testável.
4. **Regra de patch novo.** Todo patch declara seu balde no momento em que
   entra. Sem balde, não entra.

### Fase C — Upstream dos patches de segurança

Levar o balde `UPSTREAM` para `laytan/odin-http`, **um PR por classe de
defeito**, não um PR só. Cada um traz o teste que o pina — a árvore já tem
esses testes.

Isso reduz superfície mantida por nós e é a única parte do plano com prazo
fora do nosso controle. Por isso vem depois de A e B: **o valor do plano não
depende de o upstream aceitar.** Se aceitar, a fase D encolhe; se não, o
inventário e o ADR continuam válidos e o balde vira `DRUSE`.

### Fase D — Encolher o que sobra

Só depois de C responder. Para cada patch `DRUSE`/`BRIDGE` restante, uma
pergunta: *isto poderia viver no adapter em vez de no vendor?* O que puder,
migra — o `body_stream.odin` é a prova de que dá, e o critério é o mesmo:
deletável em um passo.

## 4. Não-objetivos

- **Não migrar para `core:net/http`.** Não há alvo.
- **Não otimizar performance aqui.** Os "~5 `io_uring_enter`/req" estão
  **aposentados desde 2026-07-25**: caíram para **0,160/req (31×)** com o
  accept dedicado (patch 24). Qualquer trilha de "levers de syscall" precisa
  ser re-derivada contra o código atual antes de ser oferecida — hoje ela
  persegue um problema que a árvore já resolveu.
- **Não desfazer patch nenhum nesta rodada.** Fase D decide, com inventário
  na mão.

## 5. Ordem, e o que cada fase destrava

```
A (inventário) ──> B (ADR) ──> C (upstream) ──> D (encolher)
   sem host         sem host      externo         depende de C
```

A e B são desbloqueadas hoje. C tem prazo externo. D espera C.
Nenhuma das quatro compete com o R2 por hardware.

## 6. Ligação com a investigação dos hosts mortos

Fora do escopo deste plano, mas a fase A serve à hipótese H-B das três mortes
de host: o `io_uring` vendorizado é candidato, e a versão "memória fixada por
anéis" **já foi refutada** (`VmPin = 0` nos dois braços do A/B). Se algum
patch do nbio toca submissão, colheita ou registro de buffers, o inventário
A1 é o que torna essa lista enumerável em vez de adivinhada.
