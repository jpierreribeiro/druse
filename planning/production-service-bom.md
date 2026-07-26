# Bill of Materials de um serviço de produção

**Status: LIVING DOC, 2026-07-22.** Origem: auditoria composicional do dono
(2026-07-22). O programa inteiro vinha fazendo perguntas voltadas para dentro
("o que um *servidor* precisa para aceitar, decodificar, responder, saturar e
drenar com segurança?") e nunca a pergunta composicional ("o que um *serviço
entre serviços* precisa?"). O cliente HTTP de saída escapou por esse ângulo
morto. Este documento converte a pergunta composicional em checagem permanente.

**A regra:** cada item recebe **exatamente uma** classificação:

- **CORE** — capacidade do `web`, com gate e ledger;
- **CRYSTAL** — pacote opcional em `uruquim-crystals` (CE-E3: custo zero se
  não importado);
- **DELEGADO** — responsabilidade declarada do proxy reverso, do supervisor ou
  da infraestrutura, com a linha correspondente em `docs/operations.md`;
- **RECUSADO** — decisão registrada de não fazer, com o ADR/racional;
- **ABERTO** — ainda sem dono, **obrigatoriamente com gatilho registrado**.

Nenhum item pode ficar sem classificação. Este documento é **gate de entrada
do WP102**: a Fase 8 não começa com item ABERTO sem gatilho. Todo item
composicional novo entra aqui com classificação no mesmo PR que o menciona.

---

## 1. Entrada (HTTP inbound)

| Item | Classificação | Onde/gatilho |
|---|---|---|
| Rotas, middleware, JSON estrito, envelope de erro | CORE | congelado (Fases 1–3) |
| CORS, arquivos estáticos, multipart bufferizado | CORE | congelado (Fase 5) |
| Limites, admissão, drain, concorrência limitada | CORE | congelado (Fases 4–6) |
| Response streaming, corpo grande/spool | CORE (opt-in) | Fase 7, metade core (WP85–WP101) |
| TLS de entrada | DELEGADO (proxy) | `docs/operations.md` §1 — decisão congelada |
| CSP e HSTS | DELEGADO (proxy) | `docs/operations.md` §8 |
| Compressão de resposta (gzip/br) | DELEGADO (proxy) | nomear em `docs/operations.md` (WP100) |
| Rate limiting / fairness por cliente (borda: por IP, flood, conexões) | DELEGADO (proxy) | nomear em `docs/operations.md` (WP100) |
| Rate limiting **semântico** (por usuário, por API key, por operação) | ABERTO | a linha acima cobre a borda e só ela; um limite como "100 e-mails por usuário/dia" precisa de identidade e de domínio, que o proxy não tem. Gatilho: a primeira aplicação que precise limitar por sujeito em vez de por IP |
| `application/x-www-form-urlencoded` | ABERTO | gatilho: demanda de aplicação real (ledger de fricção da Fase 8) |

## 2. Saída (outbound)

| Item | Classificação | Onde/gatilho |
|---|---|---|
| Cliente HTTP de saída | CRYSTAL | `http_client`, metade Crystals da Fase 7: HTTP/1.1 sobre `core:net`, pool de conexões limitado, timeouts, cancelamento integrado ao drain, retry limitado; substituição declarada = cliente do futuro `core:net/http` (espelho do ADR-033 lado servidor). **ENTREGUE e CONGELADO** na Fase 7.5-A1..A3 (`uruquim-crystals` PR #13; `docs/phase-7.5-composition-freeze.md`) — **satisfaz E8-7** |
| TLS de saída + verificação de certificado | CRYSTAL | parte **inseparável** do `http_client` (FFI OpenSSL ou lib futura do core); nunca prometido separado — chamar uma API HTTPS externa sem verificação real é pior que não chamar. **ENTREGUE** (7.5-A3): FFI OpenSSL fail-closed — self-signed recusa, host-errado recusa, cadeia+host confiável aceita; provado contra peers `s_server` reais |
| Orçamento de deadline (request → pool → query → chamada de saída) | ABERTO | gatilho: existência do `http_client` — **DISPAROU** (7.5-A1..A3). A porção da chamada de saída está entregue (orçamento connect+request no `http_client`); a composição fim-a-fim (deadline de request → query de DB → chamada de saída como um só orçamento) permanece ABERTO para a Fase 8; linha no evidence backlog §7 |
| gRPC | RECUSADO no core | Crystal somente com evidência da Fase 8 |
| Clientes de fila/mensageria | RECUSADO no core | ABERTO como Crystal; gatilho: ledger de fricção da Fase 8 |
| Service discovery | DELEGADO (infra) | DNS/proxy; instâncias permanecem substituíveis |

## 3. Observado de fora

| Item | Classificação | Onde/gatilho |
|---|---|---|
| Health/readiness | CORE (padrão) | handler comum da aplicação; a Fase 8 exige o endpoint |
| Exposição de métricas (formato Prometheus) | CRYSTAL | `metrics`, metade Crystals da Fase 7, sobre os hooks de observer existentes; regras de redação preservadas. **ENTREGUE e CONGELADO** na Fase 7.5-A4/A5 (`uruquim-crystals` PR #13; `web/metrics`): counters por `Framework_Error` (saída limitada pelo enum) + `refused_connections`; redação WP20 preservada por construção (só nomes de enum, zero bytes de request) — **satisfaz E8-7** |
| Logs estruturados | CORE | `context.logger` + redação (Framework_Event não carrega bytes de request) |
| Tracing distribuído / OpenTelemetry | RECUSADO no core | ABERTO; gatilho já registrado: um incidente da Fase 8 que as métricas redigidas não expliquem (evidence backlog §7) |
| Recuperação de crash | DELEGADO (supervisor) | ADR-020; `docs/operations.md` — o abort é a política, o restart é o mecanismo |

## 4. Dados

| Item | Classificação | Onde/gatilho |
|---|---|---|
| PostgreSQL: pool, transações, migrations, validação | CRYSTAL | congelado (Fase 6, metade Crystals) |
| Backups, réplicas, particionamento | DELEGADO (infra) | fora do escopo do framework, sempre |

## 5. Configuração e segredos

| Item | Classificação | Onde/gatilho |
|---|---|---|
| Carregamento e validação de config | CRYSTAL | `config` (`uruquim-crystals` PR #14): env vars → valores tipados, todas as falhas agregadas antes do boot, `Secret` com redação estrutural (guarda um índice de slot, nunca a credencial), parsing estrito de duration/tamanho/enum. **Reclassificado de ABERTO**: o gatilho registrado era o ledger de fricção da Fase 8, que fechou sem registrar fricção de configuração — a promoção NÃO vem daí, vem de decisão do dono (2026-07-25) de construir o lote de identidade. Registrado assim para não fingir uma evidência que não existe. **NÃO CONGELADO** |
| Segredos | DELEGADO (supervisor/ambiente) | env vars via systemd/orquestrador; nunca em config versionada |

## 5.1 Identidade e sessão

**Origem:** lote de identidade em `uruquim-crystals` (PR #14 + track ID),
construído por decisão do dono em 2026-07-25. Toda esta seção é **NÃO CONGELADA**:
os ledgers são verificados pelo gate, as superfícies ainda podem mudar.

| Item | Classificação | Onde/gatilho |
|---|---|---|
| Hashing de senha | CRYSTAL | `auth/password`: Argon2id sobre `core:crypto`, formato PHC padrão (corpus portável nos dois sentidos, verificado contra vetor de referência do `phc-winner-argon2`), `Valid_Needs_Rehash` para migrar custo, parâmetros de um hash armazenado tratados como entrada não confiável. Custo calibrado por medição (`cmd/password-bench`), não por citação |
| Cookies | CRYSTAL | `web/cookie` sobre `web.set_header` (C2/F8-2). Existe porque o core barra CR/LF/NUL mas não pode saber que `;` num VALOR de cookie abre um atributo novo |
| Sessão server-side | CRYSTAL | `auth/session` (engine) + `auth/session_memory` + `auth/session_postgres` (stores) + `web/session` (adaptador). Só `sha256(token)` é armazenado; TTL absoluto e por inatividade no relógio do servidor; `rotate` serializado por claim atômico |
| Proteção CSRF | CRYSTAL | `csrf` + `web/csrf`: token assinado e **vinculado** à sessão (`nonce \|\| HMAC(key, nonce \|\| binding)`), não double-submit ingênuo. Não é opcional para quem usa `web/session`: a sessão por cookie é o que cria a exposição |
| Limpeza da tabela de sessões | CRYSTAL (Tool) | `cmd/session-purge`, ao lado do `cmd/migrate`. Nunca uma thread dentro do servidor |
| Autorização (policies) | ABERTO | `auth/session` responde "quem é você", nada responde "você pode". Gatilho: a primeira aplicação que espalhe checagem de papel por mais de um handler |
| API keys / bearer tokens de serviço | ABERTO | sessão de navegador e autenticação de serviço são problemas distintos. Gatilho: a primeira integração servidor-a-servidor |
| Idempotência de operações | ABERTO | gatilho: a primeira operação com efeito externo não repetível (pagamento, cobrança, envio) |
| **Prova por uso** | ABERTO | **item ID-9.** Nenhuma aplicação fora do repo usa estes pacotes. A epistemologia do programa é que teste não prova composição — a Fase 8 existe por isso. Gatilho: a primeira aplicação externa que adote `config` ou `auth/session` abre um ledger de fricção; só então se discute freeze |

## 6. Ciclo de vida e plataforma

| Item | Classificação | Onde/gatilho |
|---|---|---|
| Stop, drain com deadline, admissão reservada | CORE | congelado (WP44/47/59) |
| Deploy sem downtime | DELEGADO (proxy+supervisor) sobre o drain do CORE | provado nos drills da Fase 8 (WP110) |
| Preempção de código FFI bloqueante | RECUSADO | limitação permanente e documentada (Fase 6); o supervisor é o limite externo |
| Linux x86-64 | CORE | única plataforma validada pelo gate |
| Outras plataformas | ABERTO | gatilho: decisão de suporte; linha já existe no evidence backlog §7 |

---

## Como emendar

Item novo → entra nesta tabela com classificação e (se ABERTO) gatilho, no
mesmo PR. Reclassificação (ex.: ABERTO → CRYSTAL) → cita a evidência que
disparou o gatilho. O WP85 ancora a metade Crystals da Fase 7 neste documento;
o WP102 verifica, na entrada da Fase 8, que nenhum item está sem classificação
ou ABERTO sem gatilho.
