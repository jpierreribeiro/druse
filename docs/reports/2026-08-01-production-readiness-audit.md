# Auditoria de prontidão para produção — Druse

**Data:** 2026-08-01
**Escopo:** Druse no snapshot local atual, incluindo o trabalho não commitado de
WP123. `druse-crystals` foi considerado apenas como contexto de ecossistema.
**Pergunta:** o Druse está pronto para servir sistemas de produção?

> **Atualização pós-auditoria:** este laudo preserva o veredito do snapshot
> `7d65783`. No baseline posterior `9162f34`, AUD-P0-001 já estava corrigido
> pela separação entre slots `claimed` e `live`. A rodada R0 acrescentou a
> regressão determinística, o controle mutante e ownership de um `serve` ativo
> por App. R0 foi materializado em `main@8852437`, onde o gate integral passou.
> Isso abre R1, mas não muda o veredito deste snapshot nem autoriza produção;
> detalhes e hashes estão em
> `evidence/2026-08-01-r0-lifecycle-closure/README.md`.

## Veredito executivo

**Não neste snapshot.** O estado auditado deve ser tratado como **Tier 0 —
experimental/não implantável**, porque há uma corrida determinística no novo
registro de servidores de WP123. Um slot marcado `live=false` pode ser
reutilizado enquanto o `server_retire` antigo ainda espera seus leitores. Isso
permite que um leitor antigo observe os ponteiros do servidor novo e que a
aposentadoria antiga apague os ponteiros desse servidor já publicado. O defeito
foi reproduzido contra as fontes reais; a suíte existente de dois servidores
permanece verde porque não cobre aposentadoria, leitor ativo e reutilização do
mesmo slot ao mesmo tempo.

O restante do framework está muito acima do que normalmente se chama de
“experimental”: a superfície é pequena, os limites são explícitos, o parser e o
transporte têm corpus real de sockets, há controles de mutação e existe
disciplina incomum de evidência. Isso torna o Druse um candidato plausível a
**piloto controlado após o P0**, mas não elimina as condições operacionais:
Linux x86-64, proxy externo, supervisor, cgroup de memória, limites definidos
pela aplicação, clientes com retry e handlers síncronos, curtos e confiáveis.

Há graceful shutdown, mas ele não é um limite absoluto de encerramento da
aplicação. `web.stop` interrompe admissão e o transporte força o fechamento de
conexões no prazo; um handler bloqueado em código Odin/C continua não
preemptível. O limite final é `TimeoutStopSec`/SIGKILL do supervisor. Portanto,
a deficiência correta é **shutdown cooperativo, não preemptível e dependente de
supervisor**, e não “ausência total de graceful shutdown”.

## Classificação por nível

| Nível | Significado | Estado auditado |
|---|---|---|
| Tier 0 | desenvolvimento; não recebe tráfego de produção | **Atual**, por AUD-P0-001 |
| Tier 1 | piloto interno, carga não crítica, rollback e perda toleráveis | possível após fechar P0 e os gates de entrada do backlog |
| Tier 2 | produção restrita dentro do envelope documentado | exige soak do commit candidato, proxy real, operação e observabilidade validadas |
| Tier 3 | produção geral/multi-plataforma, ecossistema amplo | não é a proposta atual e exigiria mudanças arquiteturais e de maturidade |

Mesmo depois da correção imediata, a promoção recomendada é Tier 0 → Tier 1 →
Tier 2. Um gate verde isolado não autoriza pular níveis.

## Baseline auditada

| Item | Valor |
|---|---|
| commit | `7d6578393398f3538bf391d35e406582f983aea0` |
| branch/descrição | `docs/registry-reconciliation`; `v0.10.0-11-g7d65783-dirty` |
| delta rastreado | 44 arquivos; +958/−286 |
| SHA-256 do diff binário rastreado | `419fb27fbee14985d8c6886acbfd0ca1cd5ab7c070ee5622f1569c8c2054f3c9` |
| WP123 — gate | `ca2c2ba48704f4d3686d908e0497e49450a4877f4c24a9151e9dc6444b7b96c8` |
| WP123 — registro | `e98c4f495153ce1eb6fac88a59bb02b45e84b6e6817cf76c044abe871e67015f` |
| WP123 — suíte | `7f199d77052257ba779637511fafb217389be5a8e56586979d1928492dea3c3c` |
| compilador | `odin version dev-2026-07-nightly:819fdc7` |
| host local | Linux 6.8.0 x86-64; 8 CPUs; 23 GiB; sem swap |
| limites do shell | `nofile=1024`; `memlock=3052280 KiB` |

Arquivos e evidências não rastreados que não fazem parte de WP123 foram lidos
como contexto, não incorporados silenciosamente ao produto auditado. Como o
snapshot é sujo, qualquer decisão de release precisa primeiro materializar um
commit candidato reproduzível.

## Execução dos gates

| Comando | Resultado | Leitura |
|---|---|---|
| reprodução isolada de AUD-P0-001 | exit 0; 1 teste em 3,383 ms | confirmou a interleaving defeituosa |
| `bash build/check_docs.sh` no workspace | exit 0 | core/documentos ativos verdes; crystals ficou parcialmente `UNCHECKED` |
| `bash build/check.sh` no workspace | exit 1 após WP123 | proteção correta recusou um controle que usa `git checkout` sobre worktree sujo |
| `bash build/check.sh` em espelho Git limpo do snapshot | exit 1 em `check_wp24_controls.sh` | o controle 5 ainda procura “Exactly one server per process”; WP123 mudou o contrato e o controle ficou stale |

Antes da falha WP24, o espelho limpo passou pelas suites funcionais e de socket,
corpus raw-wire, documentação, API/freeze, segurança, fault campaigns, memória,
saturação, proxy fixture, shutdown, WP123 e seus controles. Isso é evidência
forte dos subsistemas alcançados, mas **não equivale a gate completo verde**.

## Fluxo de funcionamento

```text
cliente
  -> proxy/TLS/rate limit (externos ao Druse)
  -> acceptor io_uring
  -> limite de conexões e admissão de lanes
  -> parser HTTP vendorizado e limites de leitura
  -> Inbound neutro
  -> Context + middleware + router + handler síncrono
  -> finalização/limite do corpo
  -> Outbound copiado para armazenamento do transporte
  -> escrita, deadline e keep-alive

SIGTERM -> handler da aplicação -> web.stop(App)
  -> bit de draining + shutdown atômico
  -> hook de drain de streams/uploads
  -> conexões ociosas fechadas; ativas drenadas ou forçadas no prazo
  -> web.serve retorna
  -> supervisor aplica o limite externo se um handler não retornar
```

O `App` contém rotas, limites e estado já congelados. Cada requisição recebe um
contexto e arenas próprias; o backend não vê tipos públicos do framework. No
trabalho WP123, o `App` também carrega um handle para uma tabela global de até
16 servidores, usada por stop, stats, streams e upload admission. É nessa ponte
de lifetime que está o P0.

## Pontos fortes confirmados

- **Testes como especificação executável.** No conjunto principal há 133
  arquivos de teste e 799 procedimentos `@(test)`, com 39.589 linhas em
  `tests/`. Há 44 scripts de build que mencionam mutantes ou controles
  negativos. A suíte distingue teste semântico, socket real e corpus de wire.
- **Controle de regressões pelo mecanismo.** Vários gates não exigem apenas
  verde; removem a propriedade relevante numa cópia e exigem vermelho pelo
  motivo correto.
- **Limites e ownership explícitos.** Corpo, request line, headers, conexões,
  handlers, JSON, drain, resposta, escrita e idle têm disposições documentadas.
  Streams e uploads possuem admissão e memória limitadas.
- **Transporte defensivo.** Há campanhas para RST, disconnect, deadline,
  saturação, parsing ambíguo, smuggling, backpressure e fechamento.
- **Backlog de segurança rastreável.** Os 14 achados da varredura registrada
  constam como corrigidos; 12 têm teste nomeado e dois têm cobertura indireta
  justificada. Uma segunda série de attack-lab documenta mecanismo e alcance.
- **Superfície pequena e congelada.** A API é legível e o isolamento do backend
  reduz o custo de uma futura substituição do transporte.
- **Desempenho competitivo no envelope medido.** Na matriz preservada de
  2026-07-30, em um endpoint JSON de 4.310 bytes a 20k req/s, o Druse ficou em
  quarto de sete em p50 (150 µs) e primeiro em p99 (384 µs), sem falhas. É uma
  medição de um host, uma carga e um commit anterior; não é promessa universal.
- **Evidência de estabilidade útil.** O soak de 12 h processou 624.890.400
  chamadas com threads e FDs estáveis e baixa inclinação de RSS. A análise
  posterior atribuiu os erros de transporte à recusa documentada por saturação.
  Essa evidência é valiosa, embora não qualifique o snapshot atual.

## Achados

### AUD-P0-001 — reutilização prematura no registro de servidores

**Severidade:** P0, bloqueador de release.
**Estado:** confirmado por reprodução determinística.

`server_retire` publica `live=false` e espera `readers==0` sem deter
`g_servers.claim`. `server_publish`, protegido por esse mutex, interpreta
`live=false` como slot livre e sobrescreve ponteiros, geração e `live` antes de
o leitor antigo sair. Quando ele sai, o retire antigo zera os ponteiros da nova
geração.

Impactos possíveis:

- `web.stop`, `web.stats` ou contadores agirem sobre outro servidor;
- stream token ou upload admission atravessarem a fronteira entre servidores;
- handle novo validar com ponteiro nulo;
- leitura de ponteiro de objeto já aposentado e comportamento indefinido.

A reprodução está em
`evidence/2026-08-01-production-readiness-audit/server_registry_slot_reuse_test.odin`.
Ela passa porque codifica a sequência defeituosa observada. O conserto deve
fazê-la falhar e sua versão de regressão deve afirmar a propriedade correta.

### AUD-P1-002 — shutdown não limita handler bloqueado

**Severidade:** P1, limitação estrutural obrigatória no contrato operacional.

O transporte tem drain com deadline e os testes WP58/WP95 o exercitam. Porém,
o handler síncrono não é cancelável nem preemptível. Se estiver bloqueado, sua
lane pode não alcançar a rotina que conclui o shutdown. `max_drain_time` limita
o transporte, não execução arbitrária de Odin, FFI ou uma chamada de banco.

Padrão exigido: handler com deadline próprio; chamadas externas com timeout;
supervisor com `TimeoutStopSec > max_drain_time`; readiness retirada antes do
drain; teste de SIGTERM no binário real. Para shutdown absolutamente limitado,
usar isolamento por processo ou redesenhar execução/cancelamento de handlers.

### AUD-P1-003 — evidência de release não corresponde ao snapshot

**Severidade:** P1, bloqueador de promoção para Tier 2.

O soak de 12 h é do commit `9b46a46f...`, anterior a WP123. Pelo analisador
mais novo, ele também retorna `FAIL`: 1.085 falhas foram contadas, mas o
instrumento original descartou suas causas. A campanha posterior atribuiu a
saturação em outro commit, mas não pode reconstituir causalidade evento a
evento nem validar o registro novo. Não foi possível executar um soak remoto
novo porque este workspace não contém acesso a um host dedicado.

Há ainda uma deficiência concreta no instrumento atual: `ops/soak/run-soak.sh`
executa o `curl` de `/stats` com `|| true` e só depois lê `$?`. Assim,
`stats_curl_exit` registra o sucesso de `true`, não o código real do `curl`.
Antes de produzir nova evidência R2, o coletor precisa ser corrigido e provado
com fixtures e controles negativos para scrape bem-sucedido, timeout, conexão
recusada e resposta HTTP inválida.

### AUD-P1-004 — topologia de proxy é mandatória, mas a prova local é um fixture

**Severidade:** P1 para produção exposta à Internet.

TLS, HTTP/2, compressão e rate limiting são delegados ao proxy. O gate C-06
prova buffering e endereço confiável com um proxy de teste, e registra que um
proxy real com pooling/keep-alive ainda é devido. Sem uma campanha reproduzível
com Caddy/Nginx/HAProxy, a topologia que fornece propriedades críticas não está
fechada ponta a ponta.

### AUD-P1-005 — orçamento de FDs não está codificado na unit canônica

**Severidade:** P1 operacional.

O padrão é `max_connections=1024`, enquanto o soft `nofile` local é 1024 e o
processo ainda precisa de sockets de escuta, rings, arquivos e telemetria. A
documentação manda manter o limite de conexões abaixo do limite de FDs, mas
`ops/deploy/druse.service` define `LimitMEMLOCK` e não `LimitNOFILE`. A unit
canônica deve codificar uma margem comprovada ou exigir um valor calculado.

### AUD-P1-006 — limite de resposta ocorre depois da construção

**Severidade:** P1 de contrato/memória.

`max_response_bytes` substitui uma resposta já construída e grande demais por
500 antes do copy-out. Ele não impede OOM ou grandes temporários durante o
handler. A documentação reconhece parte disso, mas também diz que o limite
“converte um out-of-memory” em erro tipado, afirmação mais forte que o código
pode garantir. O cgroup é a contenção real do processo; streaming é a solução
para corpos grandes.

### AUD-P1-007 — consistência documental não é semanticamente protegida

**Severidade:** P1 de governança e adoção.

Os gates documentais ficaram verdes apesar de contradições verificáveis:

- `docs/ai-context.md` diz que graceful shutdown ainda não existe e depois
  documenta `web.stop` e `max_drain_time`;
- `docs/canonical-patterns.md` repete que graceful shutdown ainda está adiante;
- `docs/operations.md` diz que não há API pública de upload e depois documenta
  `enable_upload`, `upload` e `upload_persist`;
- `docs/platform-contract.md` e `planning/release-readiness.md` fixam um servidor
  por processo, enquanto WP123 declara até 16;
- `planning/wp123-per-server-state-spec.md` diz “não iniciado” após a
  implementação local;
- `vendor/odin-http/VENDOR.md` enumera 24 patches, mas as fontes e a política
  carregam 43 disposições.

O gate de paridade verifica presença e padrões, não coerência entre afirmações.
Uma release não deve usar documentação contraditória como contrato normativo.
Além disso, o gate integral no espelho limpo falhou de fato em
`build/check_wp24_controls.sh`: os controles 1–4 passaram, mas o controle 5
abortou com `AssertionError: pattern not found` ao procurar o antigo título
“Exactly one server per process”. Portanto, a migração WP123 atualizou o docs
checker principal, mas não atualizou o seu próprio meta-controle de mutação.

### AUD-P2-008 — custo de manutenção do backend vendorizado

**Severidade:** P2 estratégico.

O backend fixado recebeu mais de 40 disposições locais, incluindo correções de
corretude, segurança, observabilidade e bridges específicas do Druse. Isso foi
bem documentado em `planning/vendor-policy.md`, mas aumenta o custo de upgrade,
rebase e auditoria. O arquivo de manutenção do vendor está desatualizado e não
há segundo adapter de produção que prove a independência prometida pela
fronteira interna.

### AUD-P2-009 — observabilidade compete com a carga observada

**Severidade:** P2, podendo virar P1 conforme SLO.

`/stats` é uma rota comum nas mesmas lanes. No soak, 111 de 8.611 scrapes (1,3%)
não responderam sob saturação. Os contadores cumulativos são úteis, mas não
substituem gauges de ocupação, capacidade resolvida e telemetria fora do caminho
saturável. Um alerta por scrape ausente funciona; interpolar silenciosamente
esconde pressão.

### AUD-P2-010 — linguagem, plataforma e modelo de concorrência limitam o uso

**Severidade:** P2, limitação conhecida.

- Linux x86-64 e io_uring são o alvo real; builds não Linux não equivalem a
  suporte de runtime.
- O compilador é um nightly fixado; linguagem e ecossistema são menores que
  Go/Rust/Node e elevam risco de contratação, bibliotecas e upgrade.
- Handlers são síncronos; DB/FFI/blocking I/O ocupam uma lane inteira.
- Odin não tem panic recuperável; uma falha do handler aborta o processo e cria
  destino compartilhado entre listeners do mesmo processo.
- Não há HTTP/2 ou WebSocket nativos. TLS e compressão pertencem ao proxy.
- Defaults de write timeout, idle timeout e response cap são desligados; uma
  implantação segura precisa configurar limites explicitamente.

### AUD-P2-011 — ciclo de vida de um mesmo App precisa de guarda explícita

**Severidade:** P2.

WP123 permite servidores distintos com Apps distintos. Não foi localizada uma
guarda que rejeite duas chamadas concorrentes de `serve` sobre o mesmo `App`;
há apenas um handle privado para publicação. O contrato deve proibir isso de
modo explícito e testado, ou introduzir uma transição atômica que retorne erro
antes do bind.

### AUD-P2-012 — druse-crystals não foi validado como parte da release

**Severidade:** P2 contextual.

O gate informou que 28 de 29 pacotes não estavam presentes no caminho local e
que 264 referências de símbolo não foram verificadas. Isso não reprova o core
Druse, porque crystals não é o foco desta auditoria, mas impede usar a integração
do ecossistema como evidência de prontidão.

### AUD-P2-013 — assurance de segurança ainda tem pontos indiretos

**Severidade:** P2, podendo bloquear Tier 2 conforme o threat model.

A reconciliação de segurança é honesta sobre seus limites: não houve nova
varredura por decisão do projeto; F8 e F12 têm pin indireto; o attack-lab F-005
(431 para header block excessivo) não tem caso dedicado de raw wire; F-007 é
argumentado por construção. Além disso, `SECURITY.md` ainda diz que só um
servidor é suportado e que existem 24 patches locais. Isso não demonstra uma
vulnerabilidade nova, mas reduz a força da afirmação “toda correção relevante
regredirá de forma observável” e deixa a política pública desatualizada.

## Limitações conhecidas que devem aparecer na promessa do produto

O envelope produtivo honesto, hoje, é:

- serviço HTTP/1.1 em Linux x86-64, atrás de proxy que termina TLS;
- handlers síncronos, limitados e sem recuperação in-process de fault;
- um processo por domínio de falha recomendado, mesmo que vários listeners
  sejam tecnicamente suportados após WP123;
- supervisor e cgroup obrigatórios;
- retry do cliente obrigatório para recusas TCP sob saturação;
- timeouts e limites definidos pela aplicação, não apenas os defaults;
- sem promessa de WebSocket, HTTP/2 end-to-end, runtime multi-plataforma ou
  ecossistema comparável ao de Go/Rust/Node;
- API pré-1.0 e toolchain nightly fixada.

## Onde a operação pode surpreender

| Situação | Resultado real | Padrão de projeto/operação |
|---|---|---|
| todas as lanes ocupadas | conexão pode fechar antes de existir request HTTP; não há 503 | cliente idempotente com retry/backoff e métrica de `saturation_refusals` |
| handler bloqueia além do drain | transporte fecha conexões, mas o processo pode não sair | timeout em toda dependência e kill externo do supervisor |
| handler faz fault | todo o processo aborta; com vários listeners, todos caem juntos | processo como domínio de falha, restart e coredump |
| resposta excede `max_response_bytes` | 500 somente depois de o corpo ter sido construído | streaming, medição de pico e cgroup; não usar o campo como prevenção de OOM |
| `/stats` disputa lanes saturadas | scrape pode não responder justamente sob pressão | alertar ausência e preferir plano administrativo separado |
| proxy mantém buffering padrão | stream pode não entregar nenhum chunk até terminar | configuração de proxy versionada e teste ponta a ponta |
| `max_write_time`/`max_idle_time` ficam em zero | slow reader/idle podem reter recursos por mais tempo que o esperado | definir limites explicitamente por perfil de cliente |
| duas chamadas `serve` usam o mesmo `App` | um único handle privado pode ser sobrescrito | proibir/guardar por CAS antes do bind |

## A qual framework ele se compara?

Não existe equivalente único:

| Eixo | Comparação mais útil | Diferença principal |
|---|---|---|
| arquitetura explícita/tipos | Axum | Druse é síncrono, menor e Linux-only; Axum/Tokio têm ecossistema e async maduros |
| ergonomia de handler | Gin / `net/http` | Druse privilegia ownership e limites; Go tem portabilidade, tooling e bibliotecas muito mais maduros |
| filosofia de transporte/performance | Fiber / fasthttp | Druse usa lanes e io_uring, com menos features e muito menos histórico produtivo |
| produtividade de ecossistema | Fastify | Fastify/Node têm plugins e contratação; Druse busca previsibilidade e uma superfície pequena |

Em microbenchmark preservado o Druse é competitivo com esses projetos. Em
prontidão organizacional, suporte de plataforma e battle-hardening, ainda não
está na mesma classe. Performance não compensa um P0 de lifetime nem substitui
evidência operacional do artefato candidato.

## Critérios para a resposta mudar para “sim”

Uma aprovação Tier 2 precisa, no mínimo:

1. corrigir AUD-P0-001 e incluir regressão determinística mais mutante;
2. formar commit limpo e repetir `build/check.sh` com o compilador fixado;
3. executar o novo soak de 12 h no commit candidato, com toda falha classificada
   ou o resultado recusado;
4. validar SIGTERM, readiness, drain e kill externo no binário implantado;
5. executar campanha com proxy real, keep-alive/pooling, buffering, headers,
   limites e IP confiável;
6. fechar FD/memlock/cgroup/systemd e provar falha segura acima dos limites;
7. adicionar o caso raw-wire F-005 e revisar os pins indiretos contra o threat
   model do produto;
8. reconciliar documentos normativos e tornar as contradições detectáveis;
9. publicar o envelope suportado e aceitar formalmente as limitações
   estruturais restantes.

O backlog detalhado está em
`planning/2026-08-01-production-readiness-remediation.md` e o pacote de evidência
em `evidence/2026-08-01-production-readiness-audit/`.

## Conclusão

O Druse tem uma base técnica e uma cultura de testes fortes o suficiente para
justificar investimento continuado. O principal mérito da auditoria é também o
principal alerta: uma suíte numerosa e verde reduz risco, mas não prova uma
interleaving que nunca foi formulada. Neste snapshot há um bloqueador concreto;
após corrigi-lo, ainda faltam evidências do artefato candidato e fechamento da
topologia operacional. A resposta responsável hoje é **não para produção**, com
um caminho curto e verificável até piloto e um caminho maior até produção
restrita.
