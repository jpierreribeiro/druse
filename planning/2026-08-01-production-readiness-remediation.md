# Backlog de remediação da auditoria de produção — 2026-08-01

Este backlog transforma o laudo em gates de promoção. Prioridade expressa risco
e ordem; não é uma autorização para alterar contratos públicos sem ADR.

## Gate R0 — voltar a ter um candidato testável

**Status em 2026-08-01:** R0.1–R0.4 implementados e validados. O conjunto
técnico foi integrado em `main` no commit `8852437`; o gate integral passou
nesse commit real. R0 está concluído e R1 pode começar, sem que isso constitua
aprovação para produção. Evidência:
[`../evidence/2026-08-01-r0-lifecycle-closure/README.md`](../evidence/2026-08-01-r0-lifecycle-closure/README.md).

### R0.1 — impedir reutilização durante retire

**Achado:** AUD-P0-001.
**Dono sugerido:** transporte/lifecycle.
**Saída:** slot indisponível até o último leitor antigo sair.

Implementação recomendada de menor superfície:

1. `server_retire` adquire o mesmo `g_servers.claim` usado por
   `server_publish` antes de validar e invalidar o handle;
2. mantém o mutex enquanto publica `live=false`, avança a geração, espera
   `readers==0` e limpa os três ponteiros;
3. libera o mutex somente depois de o slot estar realmente reutilizável.

Leitores continuam lock-free e podem executar `server_leave`, portanto a
espera não cria dependência circular. Uma alternativa aceitável é um estado
atômico `Free/Live/Retiring`, desde que `publish` só aceite `Free`. Não usar
apenas `live=false` para significar simultaneamente “não adquirível” e “livre”.

**Aceite:**

- teste determinístico segura um reader, inicia retire e tenta publish;
- enquanto o reader estiver ativo, publish usa outro slot ou retorna cheio;
- o reader nunca observa ponteiros da nova geração;
- retire antigo nunca apaga ponteiros novos;
- teste de geração stale continua verde;
- mutante que reintroduz reutilização prematura fica vermelho pelo motivo
  correto;
- suíte WP123 e gate completo verdes em pelo menos 30 repetições do teste de
  lifecycle.

**Implementado:** o baseline atual já escolhe a alternativa atômica
`claimed/live`; foi acrescentado o fixture determinístico, o mutante que volta
a confundir os estados e a repetição 30/30. O gate integral ficou verde no
candidato limpo temporário e novamente em `main@8852437`.

### R0.2 — guardar serve concorrente no mesmo App

**Achado:** AUD-P2-011.
**Saída:** contrato inequívoco e falha observável antes do bind.

Escolher e documentar uma das duas políticas:

- suportar no máximo um `serve` ativo por `App`, com CAS de estado privado; ou
- criar handles independentes, o que exige nova decisão de API.

A primeira é recomendada para preservar a superfície. Cobrir serve concorrente,
serve após falha de bind, serve após stop e tentativa de restart de App já
draining.

**Implementado:** claim CAS privado por App, liberação após bind failure,
recusa antes do bind para concorrência/restart e fechamento da corrida
stop-durante-startup. Fixture interno, socket suite e mutante sem CAS estão
verdes/vermelho pelos motivos pré-registrados; repetição do claim 30/30.

### R0.3 — materializar baseline limpa

Criar um commit candidato com WP123 e as correções, sem incluir por acidente
`bundle/`, `tina/` ou campanhas históricas não relacionadas. Registrar commit,
toolchain, diff, fontes vendorizadas e SHA-256 dos binários.

**Concluído:** o snapshot técnico foi materializado em `main` como
`885243786944afc8acd6e717da1c673695a03948`. O gate integral passou nesse
commit, com log e SHA-256 registrados no pacote de evidência R0. Os artefatos
históricos volumosos do worktree não foram incluídos.

### R0.4 — reparar o meta-controle WP24

**Achado:** AUD-P1-007.

- substituir o controle WP24 de “um servidor por processo” por duas mutações:
  remover suporte multi-server e remover o teto de 16; ambas devem ser
  rejeitadas pelo docs gate pelo motivo correto;
- provar que a mutação realmente alterou o documento e falha no padrão
  multi-server/bound, não apenas em qualquer erro do checker.

**Concluído:** `build/check_wp24_controls.sh` passou os controles 5 e 5b pelo
motivo correto, além do controle positivo final.

**Gate de saída R0:** nenhum P0 aberto; reprodução corrigida; WP24 atualizado;
`build/check.sh` integral verde; snapshot limpo e identificável.

## Gate R1 — piloto controlado

**Status em 2026-08-02:** R1.1–R1.5 concluídos e promovidos exclusivamente para
piloto interno não crítico. Evidência e riscos aceitos estão em
[`readiness/R1-freeze.md`](readiness/R1-freeze.md); R2 continua bloqueado.

Plano executável detalhado: [`readiness/R1-controlled-pilot.md`](readiness/R1-controlled-pilot.md).

### R1.1 — reconciliar shutdown real

**Achado:** AUD-P1-002.

- manter a promessa como “drain do transporte com deadline; handler
  cooperativo”; retirar linguagem que sugira preempção;
- testar o binário real recebendo SIGTERM sob idle, keep-alive, stream, upload,
  escrita lenta e handler deliberadamente bloqueado;
- provar ordem: readiness false → recusa de nova admissão → drain → retorno de
  `serve`; no braço bloqueado, provar ação do supervisor;
- definir timeout de DB, HTTP cliente, filesystem e FFI no template de aplicação.

### R1.2 — fechar unit operacional

**Achados:** AUD-P1-005 e AUD-P1-006.

- adicionar `LimitNOFILE` calculado e comentário ligando-o a
  `max_connections`, listeners e margem operacional;
- manter `LimitMEMLOCK`, `MemoryMax` e `TimeoutStopSec` explícitos;
- fornecer um verificador de pré-voo que compare limites configurados com
  RLIMITs e falhe antes de receber tráfego;
- medir memória concorrente; não prometer que `max_response_bytes` evita OOM;
- incluir cgroup OOM e restart no exercício operacional.

### R1.3 — contrato com proxy real

**Achado:** AUD-P1-004.

Executar ao menos Caddy e o proxy oficial da implantação com:

- TLS e HTTP/2 do cliente até o proxy, HTTP/1.1 até Druse;
- keep-alive e connection pooling;
- streaming com buffering ligado/desligado;
- limites de header/body e timeouts em ambos os lados;
- `X-Forwarded-For` com hop confiável e spoof direto;
- saturação, retry e shutdown durante conexões reutilizadas.

Preservar versões, configuração, pcaps ou logs, comandos e hashes.

### R1.4 — documentação como contrato

**Achado:** AUD-P1-007.

Reconciliar, no mínimo:

- `docs/ai-context.md` e `docs/canonical-patterns.md` sobre shutdown;
- `docs/operations.md` sobre upload;
- `docs/platform-contract.md`, `planning/release-readiness.md` e checklist de
  operações sobre um versus vários servidores;
- status de `planning/wp123-per-server-state-spec.md`;
- `vendor/odin-http/VENDOR.md` com a política de 43 patches;
- afirmação sobre OOM e limite de resposta.

Adicionar gate semântico com uma única fonte de capability/status. O teste deve
injetar pelo menos uma frase obsoleta e exigir falha; busca por uma frase exata
isolada não é suficiente.

### R1.5 — declarar perfil suportado

Publicar uma página curta com plataforma, protocolo, proxy, supervisor,
toolchain, política de retry, limites ligados/desligados, modelo síncrono e
features explicitamente fora de escopo. Separar “capacidade de vários
listeners” de “recomendação de um processo por domínio de falha”.

**Gate de saída R1:** piloto interno pode receber carga não crítica com rollback,
dashboards, alertas de scrape ausente e runbook de crash/kill testado.

## Gate R2 — produção restrita

Plano executável detalhado: [`readiness/R2-restricted-production.md`](readiness/R2-restricted-production.md).

### R2.1 — soak do artefato candidato

**Achado:** AUD-P1-003.

Executar 12 h ou mais em host dedicado, CPUs separadas para servidor e gerador,
`nofile` registrado e binário exatamente igual ao candidato. O instrumento deve
registrar causa e exemplo de toda falha, timestamps absolutos, FDs, threads,
RSS/HWM, counters, estatísticas do kernel e scrapes ausentes.

**Regra:** `failures_counted != failures_classified` reprova a evidência. Uma
campanha posterior pode explicar uma classe, mas não reclassifica retroativamente
eventos descartados.

### R2.2 — campanha de capacidade e degradação

Medir abaixo do knee, no knee e acima do knee para workloads reais: tiny, JSON,
body grande, slow reader e blocking I/O. Registrar goodput, p50/p95/p99,
recusas, retry amplification e recuperação. Definir SLO e orçamento de
saturação antes de olhar o resultado.

### R2.3 — observabilidade fora da zona cega

**Achado:** AUD-P2-009.

- alertar scrape ausente como sinal, nunca interpolar silenciosamente;
- expor ou registrar capacidade resolvida, lanes ocupadas, conexões ativas e
  estado draining;
- considerar listener/processo administrativo separado para saúde/metrics;
- provar que uma pane do listener de aplicação não torna o monitoramento
  indistinguível de perda de rede.

### R2.4 — segurança e supply chain

- repetir corpus de request smuggling e parsing no proxy real;
- adicionar ao corpus raw-wire um header block excessivo que exija 431 e um
  mutante que restaure o drop silencioso (attack-lab F-005);
- revisar F8, F12 e F-007 contra o threat model da release e registrar teste ou
  aceite explícito onde a cobertura continuar indireta;
- atualizar `SECURITY.md` quanto a WP123 e ao número real de patches;
- inventariar todos os patches do vendor em uma fonte canônica;
- gerar SBOM, hashes e procedimento de rebuild;
- definir cadência de comparação com upstream e owner para cada carry/offer;
- testar imagem/unidade com usuário sem privilégio e filesystem read-only.

**Gate de saída R2:** commit candidato reproduzível, soak aprovado, proxy e
operação ponta a ponta aprovados, zero P0/P1 sem mitigação aceita, limitações
publicadas e aceite de risco assinado.

## Gate R3 — maturidade geral (opcional)

Plano condicional detalhado: [`readiness/R3-general-maturity.md`](readiness/R3-general-maturity.md).

Este gate só é necessário se a ambição mudar de produção restrita para uso
geral comparável a frameworks maduros:

- segundo adapter ou migração para backend oficial, reduzindo o fork;
- política estável de versões do compilador e matriz real de plataformas;
- isolamento/cancelamento de trabalho bloqueante;
- estratégia para HTTP/2 e WebSocket quando forem requisitos;
- releases reproduzíveis, semver e janela de suporte;
- integração validada de `druse-crystals`, sem transformar crystals em condição
  de corretude do core;
- histórico de produção, incidentes, compatibilidade e upgrades.

## Ordem sugerida

| Ordem | Item | Bloqueia |
|---:|---|---|
| 1 | R0.1 registro | qualquer deploy |
| 2 | R0.2 lifecycle do App + R0.3 baseline | release candidate |
| 3 | R1.1 shutdown + R1.2 operação | piloto seguro |
| 4 | R1.3 proxy + R1.4 docs + R1.5 perfil | confiança ponta a ponta |
| 5 | R2.1 soak + R2.2 capacidade | produção restrita |
| 6 | R2.3 observabilidade + R2.4 segurança/supply chain | aceite operacional |
| 7 | R3 | produção geral, se for objetivo |

## Critério de encerramento da auditoria

Este documento pode ser fechado quando todos os itens R0–R2 tiverem um de três
estados auditáveis: concluído com evidência, risco aceito com owner/data/escopo,
ou removido porque o perfil suportado exclui explicitamente o caso. “Teste
verde” sem mecanismo, artefato e versão identificados não é evidência de
encerramento.
