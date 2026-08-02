# R1 — plano para piloto controlado

**Status:** PROMOTED TO R1 em 2026-08-02 — piloto interno não crítico somente;
produção crítica, produção geral e R2 continuam bloqueados.
**Objetivo:** permitir tráfego interno e não crítico, com perda tolerável,
rollback imediato e domínio de falha conhecido.
**Não autoriza:** produção crítica, exposição direta sem proxy, SLO externo ou
declaração de estabilidade geral.

## 1. Entrada obrigatória

R1 só começa quando R0 fornecer:

- correção de AUD-P0-001 e teste de regressão determinístico;
- lifecycle de `App` decidido e guardado;
- meta-controle WP24 atualizado;
- commit limpo, binários identificados e `build/check.sh` integral verde;
- zero P0 aberto.

Criar `evidence/YYYY-MM-DD-r1-entry/manifest.txt` com a identidade descrita em
`README.md` deste diretório. Se qualquer requisito faltar, registrar `BLOCKED`
e voltar a R0; não executar uma campanha “informativa” e depois promovê-la.

## 2. Entregáveis

| ID | Entregável | Tipo |
|---|---|---|
| R1-WP01 | contrato real de shutdown e drill de processo | análise + implementação + teste |
| R1-WP02 | unit systemd e preflight de recursos | operação + teste |
| R1-WP03 | topologia de proxy real | integração + campanha |
| R1-WP04 | documentação normativa reconciliada | documentação + gate semântico |
| R1-WP05 | perfil suportado e runbook do piloto | contrato + operação |
| R1-WP06 | exercício de implantação, crash e rollback | campanha |
| R1-WP07 | freeze e decisão de promoção | freeze |

### Estado de execução em 2026-08-02

| ID | Estado | Evidência |
|---|---|---|
| R1-WP01 | implementado; gate dedicado verde | `evidence/2026-08-01-r1-shutdown/` |
| R1-WP02 | implementado; gate e drill systemd verdes | `evidence/2026-08-01-r1-resource-budget/` |
| R1-WP03 | implementado; Caddy real e controles verdes | `evidence/2026-08-02-r1-real-proxy/` |
| R1-WP04 | implementado; perfil e nove mutantes verdes | `docs/supported-profile.md` |
| R1-WP05 | implementado; policy, runbooks e controles verdes | `docs/runbooks/` e `ops/verification/pilot-checklist.md` |
| R1-WP06 | implementado; campanha oficial e hashes verdes | `evidence/2026-08-02-r1-pilot-exercise/` |
| R1-WP07 | implementado; freeze e decisão verdes | `planning/readiness/R1-freeze.md` e `evidence/2026-08-02-r1-freeze/` |

## 3. Etapa A — contrato de shutdown

### R1-WP01 — distinguir drain de transporte de término de processo

**Achado:** AUD-P1-002.

#### Perguntas da análise

1. Quanto tempo passa entre sinal, `is_draining=true`, fim de admissão e retorno
   de `web.serve`?
2. Quais estados são forçados por `max_drain_time` e quais dependem do handler?
3. O que ocorre com keep-alive, slow reader, stream e upload quando o prazo
   termina?
4. Como o processo reporta um handler que nunca retorna?
5. Qual componente possui o prazo absoluto: framework, aplicação ou supervisor?

#### Arquivos a revisar

- `web/lifecycle.odin`
- `web/serve.odin`
- `web/internal/transport/odin_http_adapter.odin`
- `vendor/odin-http/server.odin`
- `tests/wp58-drain/`
- `tests/wp95-drain/`
- `examples/09-graceful-shutdown/`
- `docs/operations.md`
- `docs/guide/06-cookbook/graceful-shutdown.md`
- `ops/deploy/druse.service`

#### Arquivos previstos

- criar `tests/r1-process-shutdown/` para o contrato sem systemd;
- criar `ops/verification/run-shutdown-drill.sh` para o exercício real;
- criar `build/check_r1_shutdown_controls.sh`;
- atualizar os documentos e o exemplo listados acima.

O teste de package não deve fingir ser o drill. O primeiro prova estados e
ordem em processo filho; o segundo prova signal delivery, supervisor, exit code
e kill externo no ambiente de implantação.

#### Matriz mínima

| Braço | Trabalho em voo | Resultado esperado |
|---|---|---|
| S0 | nenhum | readiness false imediatamente; `serve` retorna limpo |
| S1 | keep-alive idle | conexão fecha; processo sai antes do limite externo |
| S2 | handler curto ativo | resposta termina dentro do drain |
| S3 | slow reader | deadline de escrita/drain encerra o socket e incrementa métrica correta |
| S4 | stream aberto | admission fecha, frame final quando possível, force-close no prazo |
| S5 | upload em spool | nova admission recusada; temporário limpo ou ownership persistido |
| S6 | handler bloqueado | `max_drain_time` não é chamado de preempção; supervisor mata no limite externo |
| S7 | stop repetido/coincidente | hook e cleanup exatamente uma vez |
| S8 | dois Apps | parar A não altera readiness, stats ou tráfego de B |

#### Controles

- mutar a publicação de `draining` para depois do shutdown e exigir falha de
  ordem;
- retirar o hook de stream/upload e exigir que S4/S5 falhem pelo mecanismo;
- retirar `TimeoutStopSec` do fixture de supervisor e exigir que S6 seja
  recusado pelo checker;
- controle positivo do signal handler sem alocação/mutex;
- nenhuma asserção de tempo sem margem registrada e relógio monotônico.

#### Aceite

- a documentação usa “drain de transporte com deadline” e afirma explicitamente
  que handler arbitrário não é preemptível;
- todos os braços produzem exit/status e timeline explicáveis;
- `TimeoutStopSec > max_drain_time` é verificado automaticamente;
- o drill bloqueado prova a ação do supervisor, não um timeout do harness;
- logs/evidência não carregam request body, header ou token.

## 4. Etapa B — unidade operacional e recursos

### R1-WP02 — fechar FDs, memlock, memória e restart

**Achados:** AUD-P1-005 e AUD-P1-006.

#### Análises antes da edição

- contar FDs de baseline por processo, listener, lane/event loop, conexão e
  arquivo de spool;
- medir locked memory por `max_handlers` e número de servidores;
- medir pico de memória com respostas concorrentes e slow readers;
- decidir o perfil canônico: valores de `max_connections`, `max_handlers`,
  `max_response_bytes`, `MemoryMax`, `LimitNOFILE` e `LimitMEMLOCK`;
- decidir se um ou vários listeners compartilham o mesmo processo no piloto.

Para múltiplos servidores, o orçamento é agregado. A fórmula inicial a provar é:

```text
LimitNOFILE >= soma(max_connections por servidor)
               + listeners
               + FDs fixos medidos
               + FDs de spool/log/telemetria
               + margem operacional explícita
```

Não transformar essa fórmula em constante antes da medição.

#### Arquivos previstos

- modificar `ops/deploy/druse.service`;
- criar `ops/deploy/check-runtime-limits.sh`;
- criar `ops/deploy/runtime-limits.example` se a unit não puder expressar a
  configuração da aplicação;
- modificar `build/check_supervisor_contract.sh`;
- modificar `docs/operations.md` e `docs/quick-start.md` apenas por referência;
- criar `ops/verification/run-resource-drill.sh`;
- preservar resultados em `evidence/YYYY-MM-DD-r1-resource-budget/`.

#### Preflight

O preflight deve falhar antes do bind quando:

- soft nofile não cobre orçamento + margem;
- memlock não cobre lanes configuradas;
- `TimeoutStopSec <= max_drain_time`;
- diretório de spool não existe, não é gravável ou está fora de
  `ReadWritePaths`;
- `MemoryMax` está ausente no perfil produtivo;
- limites críticos continuam herdados sem aceite explícito.

Evitar parser paralelo da configuração. Se Druse não expõe os valores
resolvidos fora do processo, o binário de aplicação deve emitir um manifesto de
boot ou o deploy deve usar um arquivo canônico consumido pelo app e preflight.

#### Drills

- atingir `max_connections` e provar recusa/recovery;
- provocar memlock insuficiente e exigir falha de serve observável;
- provocar OOM no cgroup e provar restart/backoff/alerta;
- preencher spool até limite controlado e provar cleanup/alerta;
- iniciar crash loop e provar `StartLimitBurst` levando a `failed`;
- executar stop limpo e provar que `Restart=on-failure` não relança.

#### Aceite

- unit passa verificação estrutural e, onde disponível, `systemd-analyze verify`;
- números canônicos derivam de uma medição preservada;
- `LimitNOFILE` aparece na unit e no checker;
- texto não promete que `max_response_bytes` evita OOM durante construção;
- runbook contém diagnóstico para bind, memlock, OOM, crash loop e spool.

#### Resultado executado em 2026-08-01

O perfil controlado ficou fixado em um listener/processo, 1.024 conexões,
oito handlers, resposta de 8 MiB, `LimitNOFILE=2048`, `LimitMEMLOCK=64M`,
`MemoryMax=1G` e `TimeoutStopSec=30`. A derivação e os resultados brutos estão
em `evidence/2026-08-01-r1-resource-budget/`:

- 22 FDs e nove threads em repouso; orçamento total derivado de 1.213 FDs;
- pico de 316.908 KiB no run válido com oito slow readers, abaixo de 1 GiB
  mesmo após aplicar 200% de headroom;
- oito probes recusados na saturação e recovery para 200 após liberar slots;
- quota de spool respondeu 503, deixou zero temporários e recuperou para 201;
- preflight systemd recusou `LimitMEMLOCK` reduzido a 16 KiB antes do bind;
- OOM do cgroup reiniciou uma vez, crash loop parou em `failed` com três
  restarts, e stop limpo terminou com zero restarts.

O run também congelou uma limitação de plataforma: Linux 6.8 não contabilizou
os mapas do io_uring em `VmLck`, embora o host kernel 7.0 registrado anteriormente
os contabilize. Por isso 64 MiB permanece piso conservador do perfil, e não uma
promessa universal de bytes por lane.

## 5. Etapa C — proxy real

### R1-WP03 — tornar a topologia delegada auditável

**Achado:** AUD-P1-004.

#### Decisão de entrada

Escolher um proxy de referência e fixar versão/hash. Caddy é um bom candidato
por configuração pequena; se a implantação real usar Nginx, HAProxy ou outro,
esse proxy real também precisa de um braço. O fixture C-06 continua no gate
rápido e não é substituído.

#### Arquivos previstos

- criar `ops/proxy/<proxy>/` com configuração completa e versão;
- criar `ops/verification/run-real-proxy-contract.sh`;
- criar `build/check_proxy_config.sh` para invariantes estáticos;
- atualizar `planning/closure-proxy-contract.md`;
- atualizar `docs/operations.md` para apontar à configuração versionada;
- preservar `evidence/YYYY-MM-DD-r1-real-proxy/`.

Não versionar chave privada. O harness gera CA/certificados efêmeros e preserva
apenas certificados públicos, fingerprints e comandos.

#### Matriz mínima

| Área | Braços/asserções |
|---|---|
| TLS | cadeia válida aceita; self-signed/host errado recusados |
| protocolo | HTTP/2 cliente→proxy; HTTP/1.1 keep-alive proxy→Druse |
| pooling | muitas requisições cliente com número de conexões upstream medido |
| streaming | primeiro byte direto, buffering off e buffering on |
| limites | header/body/timeouts menores e maiores em cada camada, sem respostas ambíguas |
| identidade | XFF confiável, spoof direto, cadeia com múltiplos hops |
| saturação | recusa TCP upstream traduzida/propagada conforme contrato; retries limitados |
| shutdown | SIGTERM durante conexões upstream reutilizadas; sem enviar tráfego após not-ready |
| headers | HSTS/CSP/secure cookies pertencem à camada que conhece TLS/aplicação |

#### Aceite

- configuração sem buffering para endpoints de stream;
- IP do cliente nunca deriva de header vindo de peer não confiável;
- duplicação de limites tem owner e precedência documentados;
- nenhuma retry storm; número máximo de tentativas e métodos retryable fixados;
- proxy e Druse têm logs correlacionáveis sem vazar dados sensíveis;
- campanha repetível a partir do repositório.

#### Resultado executado em 2026-08-01

Caddy 2.11.4 foi fixado por tag, digest e plataforma em
`ops/proxy/caddy/image.env`; a configuração completa está no `Caddyfile` ao
lado. O fixture C-06 continua como gate rápido, enquanto
`ops/verification/run-real-proxy-contract.sh` executa a imagem real.

A campanha provou cadeia/hostname TLS e HTTP/2 até Caddy, HTTP/1.1 e pool
limitado até Druse, stream incremental contra um braço deliberadamente
bufferizado, precedência de body/header/timeout nas duas camadas, XFF direto,
spoofado e multi-hop, saturação/recovery e shutdown após readiness negativa.
HSTS ficou no terminador TLS; CSP/cookie attributes no aplicativo. Os logs
preservaram somente o request ID validado e descartaram mapas de headers.

Retries do balanceador são zero. O transporte Go ainda pode substituir conexão
pooled stale para métodos/requisições replay-safe; com o pool de quatro, o teto
derivado é quatro tentativas stale mais uma fresh. Essa exceção está no contrato
operacional e não autoriza retry de trabalho não idempotente.

## 6. Etapa D — documentação normativa

### R1-WP04 — uma fonte de verdade para capabilities

**Achado:** AUD-P1-007.

#### Estratégia

Criar `docs/supported-profile.md` como documento normativo curto. Outros
documentos apontam para ele e evitam repetir listas. Onde repetição for
necessária, um checker compara a afirmação com a fonte normativa.

#### Arquivos a reconciliar

- `README.md`
- `SECURITY.md`
- `docs/ai-context.md`
- `docs/canonical-patterns.md`
- `docs/operations.md`
- `docs/platform-contract.md`
- `docs/standards-registry.md`
- `planning/release-readiness.md`
- `planning/wp123-per-server-state-spec.md`
- `vendor/odin-http/VENDOR.md`
- `planning/vendor-policy.md`

#### Conteúdo obrigatório do perfil

- plataforma e toolchain;
- HTTP suportado e responsabilidades do proxy;
- modelo síncrono/lane e comportamento de saturação;
- shutdown cooperativo e supervisor;
- domínio de falha recomendado;
- multi-server: capacidade até 16, sem confundir com recomendação operacional;
- limites default-on/default-off;
- memória, response cap e cgroup;
- protocolos/features fora do escopo;
- política de versão e suporte;
- status de druse-crystals como contexto opcional.

#### Gate semântico

Criar `build/check_supported_profile.sh` e ligá-lo a `build/check.sh`. Controles
negativos mínimos:

- reintroduzir “graceful shutdown não existe”;
- reintroduzir “não há API pública de upload”;
- reintroduzir “apenas um servidor por processo”;
- remover o teto 16;
- afirmar que response cap evita OOM;
- alterar número de patches sem atualizar a fonte canônica;
- anunciar HTTP/2, TLS nativo ou runtime não Linux.

Cada mutante precisa falhar na afirmação correspondente, não em link quebrado.

#### Resultado executado em 2026-08-02

`docs/supported-profile.md` passou a ser a fonte normativa. O checker deriva o
teto de 16 servidores e as 43 disposições do vendor e recusou nove afirmações
semanticamente falsas, incluindo TLS/HTTP/2 nativos, plataforma não Linux,
preempção de Handler e garantia de OOM pelo limite de resposta.

### R1-WP05 — perfil e runbook do piloto

Criar:

- `docs/runbooks/pilot-deployment.md`;
- `docs/runbooks/incident-response.md`;
- `docs/runbooks/rollback.md`;
- checklist de entrada/saída versionado em `ops/verification/`.

O perfil do piloto deve fixar carga máxima inicial, rotas permitidas, dados não
críticos, janela, owner de plantão, dashboards, alertas, rollback e critérios de
abort. Não usar o piloto como soak disfarçado.

#### Resultado executado em 2026-08-02

O perfil fixa owner, janela de 60 minutos, máximo de 10 rps/20 concorrentes,
rotas `/pilot/`, dados reconstruíveis, alertas, abort e rollback em cinco
minutos. Três runbooks e o checklist versionado passaram controles que tentam
remover owner/abort ou permitir carga, migração e rollback inseguros.

## 7. Etapa E — exercício do piloto

### R1-WP06 — deploy, crash, drain e rollback

Executar em ambiente semelhante ao destino:

1. instalar binário por hash;
2. verificar preflight e unit;
3. iniciar atrás do proxy real;
4. executar smoke funcional e wire subset;
5. aplicar carga baixa representativa;
6. executar stop/drain normal;
7. injetar fault de handler e verificar core/restart;
8. executar rollback para o artefato anterior;
9. verificar integridade e tráfego após rollback.

O rollback precisa trocar artefato e configuração juntos. Migração de dados
irreversível está fora de R1; se existir, o piloto não pode depender dela.

Preservar:

- timelines UTC do proxy, service manager e aplicação;
- hashes antes/depois;
- exit status/signal e `systemctl show`;
- resultados de health/readiness;
- decisão final e qualquer intervenção manual.

### Resultado executado em 2026-08-02

O candidato `350eefb` passou o gate integral e a campanha com Caddy e systemd
reais: 50/50 respostas a 10 rps, zero erros, p99 de 65,43 ms, drain com zero
restarts, fault SIGABRT com um restart e rollback atômico do binário e da
configuração para o pai real `489421d` em três segundos. A campanha terminou
sem listener, processo candidato ou spool órfão. O pacote completo e seus
hashes estão em `evidence/2026-08-02-r1-pilot-exercise/`.

## 8. R1-WP07 — freeze

### Comandos mínimos

```sh
bash build/check.sh
bash build/check_supported_profile.sh
bash build/check_supervisor_contract.sh
bash build/check_r1_shutdown_controls.sh
bash build/check_proxy_config.sh
```

Os drills que exigem systemd/proxy rodam no host de verificação e seus manifests
citam o mesmo commit/binário do gate local.

### Critérios de saída

- zero P0/P1 sem mitigação aceita;
- full gate verde em clone limpo;
- shutdown e supervisor provados em todos os braços;
- recursos e unit fechados por preflight;
- proxy real provado;
- documentos normativos coerentes e mutation-tested;
- rollback executado;
- piloto limitado, alertado e com owner.

### Resultado permitido

- **PROMOTE TO R1:** piloto interno não crítico;
- **HOLD:** evidência incompleta ou risco sem aceite;
- **ROLL BACK TO R0:** regressão funcional, gate vermelho ou identidade do
  candidato quebrada.

### Resultado executado em 2026-08-02

**PROMOTE TO R1 — internal, non-critical controlled pilot only.** O ledger de
riscos, as limitações que continuam bloqueando R2, o índice de evidências e o
comando repetível estão congelados em `planning/readiness/R1-freeze.md`. O
checker `build/check_r1_freeze.sh` impede que a decisão seja alargada, que um
P0/P1 desapareça ou que evidência/hashes deixem de verificar.
