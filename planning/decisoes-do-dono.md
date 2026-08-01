# Decisões do dono — registro e delegação

**O que é este documento:** o registro, em linguagem simples, de como as
decisões deste projeto são tomadas e do que foi decidido em nome do dono.
O registro técnico permanente de cada decisão é o `adrs.md`; este arquivo é o
resumo legível. Atualizado em **2026-07-21**.

---

## A missão, e como ela decide

> *A web framework for the Joy of Programming.*

Em 2026-07-20 o dono definiu essa linha — que já era a do README — como o
critério do projeto, e delegou as decisões pendentes e as aprovações futuras
ao agente executor. O **ADR-029** registra o regime completo. Em resumo:

1. **Disciplina primeiro.** Medição decide performance; na dúvida de
   segurança, desconfiar; os guardrails e os ledgers nunca são atropelados.
2. **Joy em segundo.** Quando a disciplina não decide, vence a opção que torna
   escrever um programa mais agradável: menos conceitos, diagnóstico na hora
   do registro/boot (nunca às 3h da manhã), menos cerimônia.
3. **Conveniência por último.** "Joy" nunca justifica crescer a API pública —
   isso continua exigindo evidência (G-09).

Na dúvida entre duas opções, vale a **mais fácil de desfazer**.

## O que continua parando no dono (sempre)

- Lançar qualquer versão, tag ou release.
- Mudar a licença (`LICENSE`).
- Mudar a própria missão.
- Tornar Tina uma dependência, ou commitar `tina/`.
- Reescrever histórico já publicado no git.
- Qualquer coisa que o agente julgue difícil de reverter **e** incerta.

Para revogar ou ajustar a delegação, basta dizer — uma frase em qualquer
sessão resolve.

---

## Decisões já tomadas sob a delegação (2026-07-20)

| Decisão | O que ficou decidido, em uma linha |
|---|---|
| **ADR-028** — estado por requisição | **Não existe.** O "porteiro" valida e o valor é passado adiante como parâmetro comum; o custo de revalidação é aceito e documentado. Reabre só com um programa real, medido neste repositório, que não consiga ser escrito de forma limpa. |
| **ADR-010** — API avançada | Fica desenhada, **não lançada**, até um usuário externo real pedir. Nunca aparece no Quick Start. |
| **ADR-013** — proxies confiáveis | Por padrão, vale o endereço da conexão; confiar em proxy é configuração explícita do operador. Detalhes de API ficam para a Fase 4. |
| **CI no GitHub** — ⚠️ **superada; ver a nota abaixo da tabela** | **Continua sem CI** — o gate roda local/VPS, decisão reconfirmada pelo dono em 2026-07-20. |
| **Fase 3, todas as aprovações** | Resolvidas de antemão no plano (§2b do `phase-3-plan.md`): diagnóstico de conflito com poison (WP30); nenhuma normalização de caminho, permanente, params crus (WP31a); HEAD e OPTIONS automáticos, sem 501 (WP32a); acessor de rota aprovado (WP34); limites configuráveis com runtime derivado no boot e registro-durante-serving rejeitado (WP36); WP37 só implementa o ADR-004; o freeze (WP38) é aprovado pelo próprio gate — e qualquer violação para e volta ao dono. |
| **Fase 4, escopo** — ⚠️ **parcialmente revertida em 2026-07-21, ver a tabela da Fase 5 abaixo** | Plano rascunhado (`phase-4-plan.md`, §2b): CORS, uploads e arquivos estáticos ficam **fora do núcleo** (pacotes opcionais futuros) — *esta parte foi revertida*; TLS é terminado no proxy reverso — esse é o jeito suportado de rodar; a decisão de concorrência fica **deliberadamente aberta** até haver protótipos e medição (ADR-030, procedimento já escrito). O rascunho é obrigatoriamente re-revisado contra os resultados da Fase 3 antes de começar. |

Toda pré-aprovação é condicional: se o trabalho de especificação de um pacote
contradisser o que foi decidido, o agente **para e registra o achado** em vez
de seguir.

**Nota (2026-07-31) — a linha "CI no GitHub" está superada pelos fatos.** Existe
`.github/workflows/gate.yml`, ele roda `build/check.sh`, e o próprio
`build/check.sh` hoje **exige** que esse workflow exista — falha se o arquivo
sumir ou deixar de chamar o gate, porque senão o badge do README prometeria algo
sem nada atrás. O gate local/VPS continua sendo o gate; o do GitHub é o mesmo
gate em público. Nenhum documento da árvore registrava a mudança, e ela fica
registrada aqui.

---

## Decisões do dono (2026-07-21) — Fase 5

Estas cinco **revertem ou estreitam** algo já escrito. Estão aqui, e não só no
`adrs.md`, porque a cláusula de condicionalidade logo acima exige que uma
contradição do que foi decidido **pare e seja registrada** — nunca seguida em
silêncio. O registro técnico é o `planning/phase-5-spec.md` §1.

| Decisão | O que ficou decidido, em uma linha |
|---|---|
| **Mesa posta vai para o núcleo** | **Reverte a linha "Fase 4, escopo" da tabela acima.** CORS, uploads e arquivos estáticos entram em `web/`, com crescimento de ledger e pagando G-09 por inteiro. Um microframework sem os três não é um microframework, é uma biblioteca de rotas. **TLS, OpenAPI, WebSocket e streaming continuam fora** — a emenda nomeia três itens e nenhum outro. |
| **Critério "demand-driven" dispensado, só para esses três** | O roadmap exige "um pedido real de usuário" por item da Fase 5. Isso é insatisfazível com zero usuários: não há demanda sem gente, e não haverá gente sem as features que a demanda pediria. Dispensa-se a **espera pelo pedido**, nunca a evidência G-09. Não se estende a WebSocket, streaming, HTTP/2, OpenAPI, templates, banco de dados ou API avançada. |
| **`core:net/http` chega em janeiro de 2027** | A stdlib do Odin ganha um `net/http` oficial (esperado com limitações). Duas consequências: o braço C da ADR-033 (**possuir** a camada de conexão) fica economicamente morto, e **todo trabalho da Fase 5 ganha um segundo critério de aceitação — não dificultar a troca**. Os patches de drenagem no vendor são declaradamente **ponte descartável**. |
| **Portão CE-E4 abriu** | A ADR-032 condicionou trabalho de ecossistema a "depois do WP44". O WP44 mergeou em 2026-07-21 (PR #77). A condição está cumprida e **nenhum documento da árvore registrava isso**. Registrado. O CE-E3 continua intacto: nada da Fase 5 é trabalho de ecossistema. |

## Decisões do dono (2026-07-21) — programa das Fases 6 a 8

O dono pediu que o projeto deixe de apenas enumerar limitações e prepare as
implementações que tornam o Druse um framework completo para aplicações
reais, preservando a filosofia do Odin e *The Joy of Programming*. O registro
técnico normativo da próxima fase é `phase-6-spec.md`.

| Decisão | O que ficou decidido, em uma linha |
|---|---|
| **Fase 6 é a classe “primeira aplicação real”** | A espera por demanda externa é dispensada para JSON honesto, dependências bloqueantes seguras, PostgreSQL, migrations, validação e o app de referência. G-09 e todos os gates continuam. A dispensa não inclui ORM, DI, GraphQL, OpenAPI, WebSocket, TLS in-process ou um runtime genérico. |
| **ADR-030 reabre por liveness** | O resultado antigo sobre throughput continua válido. O novo teste é binário e diferente: com uma dependência bloqueada, uma requisição independente consegue terminar? O candidato é servir Handlers síncronos em lanes limitadas; só entra se segurança, shutdown e as features da Fase 5 continuarem verdes. |
| **SQL-first, fora de `web`** | PostgreSQL, pool, transações, migrations, validação e checker vivem como Crystals; `web` nunca os importa. SQL, ownership e lifecycle ficam explícitos. Não haverá GORM, Active Record, DI container, geração obrigatória nem migration automática no boot. |
| **Streaming se justifica como HTTP** | Respostas incrementais/SSE e corpos maiores que o orçamento de memória podem ser avaliados na Fase 7 por utilidade própria. Nenhum produto, sistema de renderização ou runtime cliente especulativo pode fazer o core crescer. |
| **Migrations: dois caminhos explícitos, um engine** | Emenda de 2026-07-22: CLI e chamada deliberada da aplicação antes de `web.serve` são caminhos de produção de igual valor sobre o mesmo engine. Importar package, construir App ou chamar `web.serve` nunca migra implicitamente. O padrão é SQL numerado, imutável, forward-only, checksum, advisory lock, recusa dirty/ahead-of-binary e disciplina expand-contract; diretório e `#load` geram o mesmo manifest. |
| **`core:net/http` não é bloqueador nem API imaginária** | O contrato continua acima do adapter. A implementação atual é ponte. Quando a stdlib existir, ganha spike e corpus de conformidade próprios; nada será escrito hoje contra formas ainda inexistentes. |
| **Fase 7 cobre os dois sentidos do streaming** | Não basta server push: a Fase 7 planeja response streaming e um caminho opt-in de request body grande, spool seguro e multipart incremental. O caminho bufferizado simples permanece canônico para corpos pequenos. |
| **Fase 8 é o sistema de validação que faltava** | Um produto multiusuário em repositório separado usa apenas APIs públicas, sofre deploys, migrations, falhas e evolução reais e transforma fricção em evidência antes de qualquer 1.0. |

Essas decisões aprovam o **programa e seus gates**, não nomes públicos futuros.
WP66–WP113 ainda devem medir, recusar braços inseguros e congelar cada
superfície antes de ela virar promessa.

## Decisões do dono (2026-07-22) — composição, o BOM e a metade Crystals da Fase 7

| Decisão | O que ficou decidido, em uma linha |
|---|---|
| **A Fase 7 tem duas metades** | Como a Fase 6 (concorrência no core, dados nos Crystals), a Fase 7 ganha uma metade Crystals: **composição** — Crystal `http_client` (HTTP/1.1 de saída com TLS e verificação real de certificado, pool limitado, orçamento de deadline, cancelamento no drain, retry limitado; substituição declarada = cliente do futuro `core:net/http`, espelho do ADR-033) e Crystal `metrics` (exposição Prometheus sobre os hooks de observer). Roda contra o core congelado da Fase 6, em paralelo ao streaming. **Sem renumeração de fases**: o gate congelado da Fase 6 afirma a numeração WP85–WP101/WP102–WP113, e renumerar seria churn sem capacidade. |
| **O BOM composicional é obrigatório** | `planning/production-service-bom.md` classifica cada item que um serviço de produção precisa como CORE / CRYSTAL / DELEGADO / RECUSADO / ABERTO-com-gatilho. Nenhum item sem classificação; é gate de entrada do WP102. Causa-raiz corrigida: o programa só fazia perguntas voltadas para dentro, e o cliente de saída escapou por esse ângulo morto. |
| **A app da Fase 8 chama para fora** | O sistema de referência faz pelo menos uma chamada HTTP de saída real (entrega de webhook com timeout, retry limitado e cancelamento no drain), exigida pela nova condição de entrada E8-7. Prova por uso sem chamada de saída provaria só metade de um microserviço. |

Essas decisões seguem a regra de sempre: aprovam **escopo e gates**, não nomes
públicos. `http_client` e `metrics` ainda passam por spec, RED-under-control,
gates e freeze próprios no repositório Crystals antes de qualquer promessa.

## Decisões do dono (2026-07-27) — Campaign C

| Decisão | O que ficou decidido, em uma linha |
|---|---|
| **Campaign C: Opção 4 + limpeza da Opção 3** | `lane_collisions` está morto sob dedicated-accept e é REMOVIDO de `Server_Stats`; entra `handler_dwell_ns: i64` (total de nanossegundos dentro dos handlers, running total). A utilização é derivada pelo operador (Δdwell / (lanes × Δwall)); `web.stats()` continua uma struct de inteiros. `tests/c05-saturation` foi reescrito para o novo contrato e está verde, com controle (acumulador zerado → vermelho). Registro: `planning/phase-1-freeze.md` Amendment 33. |

Justificativa registrada: o contador removido só podia relatar zero — nenhum
consumidor viável dependia dele — e deixá-lo ao lado de um contador vivo daria
aos operadores um número que por construção não se move (R-14: um caminho
canônico, não dois).

## Decisões do dono (2026-07-31) — três registros que envelheceram

Estas três saem de uma auditoria de **registro**, não de código: nos três casos
a implementação está certa e o que ficou para trás foi o que a árvore diz sobre
ela. O gatilho foi a pergunta do dono sobre o que um CI verde prova — ver a
regra 4 de `planning/diagnosability.md`.

| Decisão | O que ficou decidido, em uma linha |
|---|---|
| **ADR-018 — estado por servidor** | **ENTREGUE em 2026-08-01** (Amendment 44). Registro do que era a decisão, mantido abaixo: **ACEITO**, com o WP123 agendado. É a aprovação do dono que o próprio ADR-018 exigia ("requires owner approval when implemented"). O WP43 já removeu o `g_config`; resta o `g_server`. O WP123 muda **assinatura pública congelada** — `web.stats` e `web.refused_connections` passam a receber o servidor — e paga **G-09 por inteiro**. O `web.stop` **não** muda: receber `^App` desde o WP44 foi exatamente o que comprou essa saída. Até o WP123 entregar, a limitação continua verdadeira; o que muda hoje é a **razão** registrada — contrato congelado, não o global removido. |
| **`Restart=` reconcilia na direção da unidade** | `ops/deploy/druse.service` entrega `Restart=on-failure` e está **certa**: uma falha sai não-zero, `on-failure` reinicia, e um `systemctl stop` deliberado fica em paz. Dez documentos diziam `always` — incluindo duas linhas do próprio `docs/operations.md`, que contradizia a si mesmo. Os documentos mudam, não a unidade. A partir de agora um controle no gate confere os dois, com controle negativo. |
| **Os 8.250 bytes ficam registrados, não reproduzidos** | O número que justifica a política de processo imutável (ADR-020) vem de um protótipo que viveu inteiramente em `/tmp/wp13-probe/` e nunca foi commitado; nenhum script o recria, o que contraria a regra permanente do projeto — todo número publicado tem de ser regenerável por um script commitado. (O documento dessa regra, `planning/verification-campaign-plan.md`, também não está no repositório; ver OQ-34.) A decisão **não reabre** — a forma do vazamento (linear, ilimitada, sem sinalizar o supervisor) é o argumento, e ela se sustenta sem o valor exato. O que muda é o registro dizer a verdade sobre a origem do número. |
| **A licença é MIT** | Decidido pelo dono em 2026-07-31, resolvendo um conflito que a auditoria achou: `LICENSE` e `CHANGELOG.md` diziam **MIT**, o `README.md` dizia **BSD-3-Clause** no badge e no rodapé. O `LICENSE` estava certo e não muda; o README foi corrigido. Não confundir com as duas menções a BSD-3 em `phase-1-freeze.md`, que são corretas e falam do `$ODIN_ROOT/LICENSE` — a licença do **Odin**, não a do Druse. |

Matéria reservada: mudar `LICENSE` para sempre no dono, e este registro é a
decisão dele. Nenhum arquivo de licença foi alterado — o conflito era de
documentação, não de licenciamento.

## Fila de decisões abertas

- **ADR-030 — concorrência.** Reaberta apenas para o workload de liveness da
  Fase 6. WP72 decide entre manter uma lane ou entregar lanes limitadas depois
  dos protótipos e do fault gate; nenhum ganho de throughput é presumido.
- **ADR-033 — FECHADA.** WP65 fechou em **manter e remendar, com a transição de
  janeiro como saída declarada**. Só reabre por nova evidência, não por
  desconforto geral com o vendor.
- **Lançar tag ou versão.** Continua parando no dono, como sempre. Nada a
  decidir hoje — o roadmap não permite tag antes do M2.
