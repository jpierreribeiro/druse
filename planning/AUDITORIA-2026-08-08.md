# Auditoria profunda — 2026-08-08

**Método:** seis agentes em paralelo sobre áreas distintas, cada achado
reverificado por leitura direta do código antes de entrar aqui. **Nenhum teste
foi executado: não há toolchain Odin neste ambiente** (`which odin` vazio), então
tudo abaixo é análise estática mais aritmética sobre artefatos já commitados. Os
achados marcados SUSPEITO precisam de máquina.

**Escopo respeitado:** nada em `web/` ou `ingest/` foi modificado. O §11 do
briefing é explícito — sob G1 isso criaria candidato novo e descartaria as horas
do Final 1. Os consertos de produto estão aqui como **patch proposto**, para
serem aplicados depois do freeze do WP08.

---

## 0. O que eu confirmei do briefing (e o que não bate)

| afirmação | veredito |
|---|---|
| `web/` ~15.500 linhas, 48 arquivos | **confere** — 15.483 em 48 |
| 122 suítes de teste | **confere** — 122 diretórios em `tests/` |
| SHADOW-001: `serve` sem endereço | **confere** — `web/serve.odin:30`, `serve :: proc(a: ^App, port: int)`; bind fixo em `odin_http_adapter.odin:329-335` |
| Final 1: 334 ciclos, p99 mediano 1.165 µs | **confere** — `verdict.json`: `cycles=334`, `health.median_p99_us=1165.0` |
| Final 1: zero erro de transporte no `/health` | **confere, e a qualificação "no /health" é necessária** — `workloads.health.transport_errors=0`, mas `failures_counted=4` no total (1 em `json-decode`, mais 3) |
| Final 1: RSS 0,99 KiB/h | **confere** — `rss_kib.tail_slope_kib_per_hour=0.988`, `rss_slope_evaluated=true` |
| "zero recusa de carga" | **confere e é robusto** — `refusals_attributable_to_load=0`; as 147 recusas caem todas em janela de injeção. Janelas cobrem 19,8% dos ciclos; 12 rajadas independentes caírem todas dentro por acaso tem probabilidade 3,5×10⁻⁹ |
| §6.4: o harness do knee descarta a dimensão por workload | **confere** — `ops/wp05/lanes-sweep.sh:262` |
| §6.4: o `p999=40.249 µs` do K1 não mede degradação | **confere, e é aritmeticamente exato** — ver §1 |
| todos os 7 documentos do §10 existem | **confere** |

**Uma imprecisão do briefing:** o §8.1 item 4 fala em `ingest/`. Não existe
`ingest/` na raiz — é `web/internal/ingest/`.

---

## 1. O p999 do K1 mede um `sleep`, e dá para provar sem rodar nada

Do `K1.manifest` (números publicados, não estimados):

```
health=20  tiny=600  json_encode=90  json_decode=240  bytes_64k=9  wait_40ms=1
aggregate_rate=960          latency_p999_us=40249
```

`/wait/40ms` = 1/960 = **0,10417%** das amostras, e é o mais lento **por
construção** (piso de 40 ms contra ~1 ms dos outros). Logo ele ocupa exatamente
os percentis **99,89583 a 100**.

- `p99` = percentil 99 → **fora** do bloco. O `1.272 µs` é limpo.
- `p999` = percentil 99,9 → **dentro** do bloco. O `40.249 µs` é o piso de 40.000
  µs mais 249 µs de framework.

**O p999 agregado do WP05 não é um número ruim; é um número de outra coisa.**
Qualquer SLO derivado dele prometeria sobre um `time.sleep`.

---

## 2. Achado novo: uma excursão de 27 ms no Final 1 que o agregado escondeu

Não está em nenhum documento do projeto. Saiu de reprocessar
`cycles-json.tgz` do Final 1, por workload:

| workload | p99 mediano | p99 máximo |
|---|---:|---:|
| tiny | 1.144 µs | 1.171 µs |
| health | 1.165 µs | 1.563 µs |
| json-encode | 1.246 µs | **27.269 µs** |
| bytes-64k | 1.311 µs | 1.380 µs |
| json-decode | 1.282 µs | 1.324 µs |

Um único ciclo — o **225** — com p99 de **27.269 µs**. O segundo pior de todos os
334 é **1.415 µs**. É um fator **19×** sobre o vizinho.

O ciclo 225 é ciclo de injeção (`c0225-rst.json` existe; injeções ocorrem a cada
5 ciclos, 66 no total). Mas **injeção não explica**:

```
COM injecao: n=66  mediana=1250  max=27269  2o_maior=1415
SEM injecao: n=268 mediana=1246  max=1327   2o_maior=1326
```

As medianas são indistinguíveis (1250 vs 1246). A injeção não desloca a
distribuição; 65 dos 66 ciclos injetados ficaram em ~1,4 ms. **O ciclo 225 é um
evento singular sem causa conhecida.**

**Por que ninguém viu:** `cycles.csv` só carrega `health_p99_us`. O critério de
passagem é `health.cycles_over_250ms == 0`. Um pico de 27 ms em `json-encode` não
cruza 250 ms e não aparece em `/health`. **O Final 1 passou legitimamente — e
essa excursão continua sem explicação.**

**Recomendação:** investigar o ciclo 225 antes do WP08. É barato (o dado já está
em disco) e é exatamente o tipo de coisa que um piloto encontra em produção.

---

## 3. Erro factual no pré-registro do SLO — relevante para G3

`R2-SLO-derivation-preregistration.md` §4 afirma, como base da proteção G3:

> **Não vi nenhum percentil por workload** — eles não existem em lugar nenhum
> hoje

**Isso é falso.** O `verdict.json` do Final 1 carrega `median_p99_us` e
`max_p99_us` para **os seis workloads** (tabela do §2 acima). O `analyze-soak.py`
já faz a análise por workload que o harness do knee não faz.

Não estou afirmando que o autor olhou — a alegação de não ter olhado é sobre um
estado mental e não é auditável. O que é auditável é a alegação **"eles não
existem em lugar nenhum"**, e ela não se sustenta. A proteção que o §4 oferece é
mais fraca do que o texto declara, e um revisor futuro que encontrar esses
números vai concluir que o pré-registro estava errado sobre o próprio material.

**Correção sugerida (documental, não de código):** emendar o §4 para dizer o que
é verdade e continua protetivo:

> Existem p99 por workload no `verdict.json` do Final 1, a ~1.118 req/s
> agregados. Eles **não** servem à regra da §3, que exige o topo da zona verde
> (2.500 req/s) e três percentis (p50/p95/p99); o Final 1 dá um percentil só, num
> ponto de operação diferente. As 15 células seguem inexistentes; o que eu já vi
> está listado aqui para que a regra possa ser julgada sabendo disso.

Isso preserva o G3 **e** fica factualmente correto.

---

## 4. Defeitos de produto confirmados por leitura

Ordenados por consequência. Nenhum foi corrigido — §11 proíbe tocar `web/` agora.

### P1 — `upload_max_conc` sai 1 em vez de lanes−1 (contrato publicado quebrado)

`web/serve.odin:94-97`:

```odin
if cfg.upload_max_conc <= 0 {
    lanes := a.private.limits.max_handlers
    cfg.upload_max_conc = max(1, lanes - 1)
}
```

`DEFAULT_LIMITS.max_handlers = 0` (`web/limits.odin:306`). Com o default:
`max(1, 0 - 1)` = **1**.

O comentário três linhas acima diz *"resolved here where the lane count is
known"* — **não é conhecido aqui**. `resolve_handler_concurrency` só roda dentro
do adapter, depois. O contrato publicado (`web/upload.odin:25` e
`docs/reference/uploads.md`) promete **"handler-lanes − 1 concurrent spools"** —
3 num host de 4 lanes.

**Consequência:** um app que chama `enable_upload` sem setar `max_concurrent`
recebe 1 spool concorrente em vez de 3+. O segundo upload simultâneo leva **503**
a um terço da capacidade documentada. Silencioso, sem teste.

**Patch:**

```odin
// serve.odin — resolver as lanes ANTES de derivar o teto de upload.
// `a.private.limits.max_handlers` e o valor CRU: 0 significa "politica
// automatica", e `max(1, 0-1)` = 1 entrega um terco do contrato publicado.
// A resolucao e do transporte, entao peca a ele em vez de reimplementar o
// clamp aqui (reimplementar seria a segunda copia da politica a divergir).
if a.private.upload_enabled {
    ...
    if cfg.upload_max_conc <= 0 {
        lanes := transport.resolve_handler_concurrency(a.private.limits.max_handlers)
        cfg.upload_max_conc = max(1, lanes - 1)
    }
}
```

Exige tornar `resolve_handler_concurrency` visível ao pacote `web` (hoje é
`@(private)` no transporte). Alternativa que não mexe na visibilidade: mover a
derivação inteira para dentro do adapter, onde o número já existe — é
estritamente melhor, porque a regra passa a morar no único lugar que conhece o
valor resolvido.

**Teste que faltava** (e que teria pego): subir um app com `enable_upload` e
`max_handlers = 0` num host de ≥4 CPUs e afirmar que **dois** uploads simultâneos
são aceitos.

### P2 — `web.stats()` lê `server.threads` depois do free

`vendor/odin-http/server.odin:453`, dentro de `serve :: proc(s: ^Server, h:
Handler)` (que começa em `:402`):

```odin
delete(s.threads)      // e o slice NAO e zerado depois
```

Isso roda quando `http.serve` retorna — **antes** de `transport.serve` retornar e
portanto **antes** do seu `defer server_retire(handle)`
(`odin_http_adapter.odin:281-286`). Nessa janela o registro ainda nomeia o
servidor, e `_server_stats` faz:

```odin
handler_capacity = len(server.threads),          // adapter:448
handlers_active  = count_active_handlers(server) // adapter:449 — itera server.threads
```

sobre memória liberada.

O comentário do `defer` argumenta que o retire acontece antes dos destroys — e
acontece, **dos destroys do adapter**. O `delete(s.threads)` é do *backend* e é
anterior. **A ordenação que o comentário garante não é a que protege este
campo.**

`web.stats` é documentada como segura de qualquer thread, e
`boundary.odin:204-218` promove exatamente o uso que dispara isto: uma thread de
monitoramento fazendo poll. Janela de poucas instruções, mas é use-after-free
incondicional.

**Patch (no vendor, com nota em `VENDOR.md`):**

```odin
	delete(s.threads)
	// DRUSE PATCH — zerar o slice. `_server_stats` resolve o servidor pelo
	// registro, e o registro so para de nomea-lo no defer do adapter, que roda
	// DEPOIS deste retorno. Entre os dois, `len(s.threads)` e
	// `count_active_handlers` leem memoria liberada. Zerar torna a janela um
	// `handler_capacity = 0` honesto em vez de um UAF.
	s.threads = nil
```

`s.threads = nil` faz `len()` devolver 0 e o loop de `count_active_handlers` não
executar. Custa uma store no caminho de shutdown.

### P3 — todo diagnóstico de boot fail-closed é mudo no contexto default

`web/limits.odin:508-516`:

```odin
limits_poison :: proc(a: ^App, message: string, loc := #caller_location) {
	a.private.poisoned = true
	logger := context.logger
	if logger.procedure == nil { return }
	logger.procedure(logger.data, .Error, message, logger.options, loc)
}
```

A guarda é `procedure == nil`. Mas o default do Odin **não é nil** — é
`default_logger_proc`, um procedimento vazio, instalado incondicionalmente. Então
a mensagem é escrita para o vazio, não suprimida.

Somando com `serve` retornando `void`: limites inválidos → app envenenado →
`serve` retorna em `web/serve.odin:35-39` sem bindar → `main` cai fora →
**processo sai 0, sem imprimir nada e sem escutar nada.**

O exemplo shippado `examples/10-config-and-health/main.odin:85` lê
`MAX_HANDLERS` do ambiente. Suba-o com `MAX_HANDLERS=1000`: o contêiner inicia,
sai 0 imediatamente, não imprime nada, e o supervisor registra parada limpa.

> **Não verifiquei no commit fixado.** A afirmação sobre `default_logger_proc`
> vem do `core`/`base` do Odin em master, não no `819fdc7` de
> `odin-version.txt`. É código estável de longa data, mas é uma checagem de um
> minuto que vale fazer com o toolchain em mãos antes de agir.

**Patch:**

```odin
limits_poison :: proc(a: ^App, message: string, loc := #caller_location) {
	a.private.poisoned = true

	// Um app envenenado nunca binda, e `serve` devolve void: se esta mensagem
	// nao sair, o operador ve um processo que iniciou e saiu 0. O logger
	// default do Odin NAO e nil — e um proc vazio — entao a guarda por nil
	// escreve para o vazio e acha que reportou. stderr e o unico canal que
	// nao depende de o app ter instalado nada.
	fmt.eprintln("druse: FATAL:", message, "em", loc)

	logger := context.logger
	if logger.procedure != nil {
		logger.procedure(logger.data, .Error, message, logger.options, loc)
	}

	// O observador PODE estar vivo: `web.observe` e legal antes de qualquer
	// registro (`observer.odin:79-85`) e `web.limits` e legal depois do
	// registro (`limits.odin:414-416`). A justificativa escrita em
	// `errors.odin:1030-1034` — "an observer cannot be alive to see a
	// boot-time rejection" — esta errada.
	framework_observe_app(App, a, .Invalid_Limits)
}
```

### P4 — a mensagem de limites inválidos diagnostica o caso errado

`web/errors.odin:1045-1050` começa com *"web.limits was given a zero or negative
budget"*, e é a mensagem emitida também para `max_handlers = 257`
(`web/limits.odin:453`). Quem digitou um número **grande demais** é informado de
que digitou zero ou negativo, e é aconselhado a "start from
`web.DEFAULT_LIMITS`" — que foi o que fez.

É a mesma classe do wp123 (§6.3 do briefing): **a mensagem nomeia um defeito que
não é o que aconteceu, e manda a investigação para o lugar errado com
confiança.** Vale separar as duas mensagens.

### P5 — o clamp protege só o caminho que não precisa

`odin_http_adapter.odin:33-41` limita a [4,32] **apenas** quando
`requested == 0`. O caminho explícito aceita qualquer valor em [0,256]
(`web/limits.odin:453`). E `max_handlers = 1` não só é aceito como é
**anunciado** em `web/limits.odin:211-213` ("one is the explicit compatibility
mode"), enquanto `docs/safe-operating-region.md:19` registra 1 lane em **34.174
µs de p99 — 27× o default**.

O erro que custou dois dias a este projeto (§6.1) foi exatamente um operador
raciocinando "dois núcleos físicos não hospedam quatro lanes" e escrevendo 2. **O
framework aceita isso em silêncio.**

Não recomendo transformar em erro — é configuração legítima em casos raros. Mas
um aviso é barato:

```odin
// limits.odin, dentro de `limits()`, depois da validacao
// Nao e erro: 1 lane e modo de compatibilidade declarado. Mas o pre-registro do
// R2-WP04 fixou `max_handlers = 2` por um raciocinio ("dois nucleos fisicos nao
// hospedam quatro lanes") que a campanha depois mediu como ERRADO, e custou dois
// dias. Um valor abaixo do piso automatico e quase sempre engano; dize-lo alto
// custa uma linha e teria economizado a corrida.
if l.max_handlers != 0 && l.max_handlers < AUTO_HANDLER_CONCURRENCY_MIN {
    framework_warn(App, FRAMEWORK_MESSAGE_HANDLERS_BELOW_AUTO_FLOOR)
}
```

### P6 — `reserved_conns` é silenciosamente ignorado quando `max_connections = 0`

`web/limits.odin:460-463` só aplica a regra de reserva quando
`max_connections > 0`; `:179-180` documenta o no-op. Um operador que pede pool
ilimitado **e** reserva de drenagem expressou precisamente a intenção que o campo
existe para servir (`:174-177`, "um servidor cheio que não consegue drenar") e
recebe nada, sem aviso.

### P7 — XFF: linhas de cabeçalho separadas invertem a direção da caminhada

A caminhada da cadeia em `web/client_address.odin:160-205` está **correta**:
direita para esquerda, para no primeiro hop não confiável, nunca pega o mais à
esquerda. O conserto do TRUST-001 também está correto e ancorado
(`:246-268`).

O problema está na **entrada**. `vendor/odin-http/http.odin:264-269` junta
cabeçalhos repetidos **em ordem de chegada**:

```odin
value = strings.concatenate({value_ptr^, ", ", value}, allocator)
```

E o próprio fixture de proxy do projeto **prepende** a sua linha, em
`tests/c06-proxy-contract/proxy_contract_test.odin:244-255`:

```odin
// Insert X-Forwarded-For after the request line, exactly as a proxy does.
rewritten := strings.concatenate(
    {head[:idx + 2], "X-Forwarded-For: 203.0.113.7\r\n", head[idx + 2:]}, ...)
```

Se o cliente mandar o próprio `X-Forwarded-For: 1.2.3.4`, a ordem de chegada
vira `proxy` e depois `cliente`, o join produz `"203.0.113.7, 1.2.3.4"`, e a
caminhada da direita devolve **`1.2.3.4`** — escolhido pelo atacante.

**Contenção real:** a borda suportada é o Caddy fixado, e
`ops/proxy/caddy/Caddyfile:20` usa `client_ip_headers X-Forwarded-For`. Um proxy
conforme **acrescenta** ao XFF existente em vez de prepender, então sob o perfil
suportado isto provavelmente não é explorável — **mas eu não medi isso**, e o
fixture do próprio projeto modela um proxy que prepende.

O que é certo é a **cegueira**: `neutral_headers`
(`odin_http_adapter.odin:1191-1206`) lê o mapa já fundido, então o framework
**não consegue nem saber** que chegaram duas linhas. Não há como falhar fechado.

**Patch (defesa em profundidade, no boundary):** contar as linhas de campo antes
da fusão e expor a contagem, para que `client_ip` possa recusar a cadeia quando
mais de uma linha chegou de um peer confiável:

```odin
// boundary.odin — Inbound ganha um campo
// Quantas LINHAS DE CAMPO `X-Forwarded-For` chegaram. O backend funde
// repeticoes por virgula em ordem de chegada (RFC 9110 5.3), e depois disso a
// contagem e irrecuperavel — mas a decisao de confianca precisa dela: um proxy
// que PREPENDE em vez de acrescentar (o fixture do c06 faz isso) coloca o valor
// do cliente a DIREITA, que e onde a caminhada procura o hop mais proximo.
// Zero ou um = cadeia interpretavel. Mais de um = ambigua.
xff_field_lines: int,
```

```odin
// client_address.odin — falhar fechado na cadeia ambigua
if ctx.private.xff_field_lines > 1 {
    // Duas linhas de campo e ambiguidade que nao da para resolver depois da
    // fusao: nao da para saber qual foi escrita pela infra e qual pelo cliente.
    // O peer e a unica atribuicao que o atacante nao escolhe.
    return peer
}
```

**Teste que faltava:** cliente manda `X-Forwarded-For: 1.2.3.4`, proxy prepende a
sua, e a asserção é que `client_ip` **não** devolve `1.2.3.4`. O `c06` passa hoje
só porque o cliente dele não manda XFF nenhum.

### P8 — `trust_proxies({"10."})` faz de qualquer vizinho um forjador

`trusted_prefix_match` usa o **mesmo conjunto** para duas perguntas diferentes:
"este peer pode falar pelos clientes dele?" e "este hop é interno, pule". Com o
exemplo documentado no próprio arquivo (`client_address.odin:58`,
`trust_proxies(&app, {"10."})`) — a configuração normal em qualquer VPC — todo
host em 10/8 é ao mesmo tempo locutor autorizado e hop invisível.

Um vizinho em `10.7.7.7` manda `X-Forwarded-For: 1.2.3.4`; a cadeia vira
`"1.2.3.4, 10.7.7.7"`; `10.7.7.7` casa com `"10."` e é pulado; `client_ip`
devolve `1.2.3.4`.

Isto **não é regressão do TRUST-001** — é o alargamento que o operador escreve
deliberadamente, e `"10."` é a única grafia que a API oferece para uma rede
(`:80` registra que `10.0.0.0/25` "não tem grafia"). O conserto de fundo é
**separar os dois conjuntos** (quem pode falar ≠ quem é hop interno) ou aceitar
CIDR. Ambos são mudança de API pública e vão para depois do freeze.

**Mitigação documental imediata, que não muda API:** `docs/supported-profile.md`
deveria dizer que `trust_proxies` deve listar **o endereço exato do proxy**, e
que um prefixo de rede compartilhada transforma qualquer host da rede em
forjador de `client_ip`.

### P9 — `client_ip` devolve bytes não validados e sem limite

Nada entre o fio e o retorno afirma que o resultado é um endereço.
`X-Forwarded-For: unknown` devolve `"unknown"`; 7.900 bytes de `A` devolvem 7.900
bytes. CR/LF/NUL são recusados no transporte (sem injeção de log), mas o resto
passa. `docs/guide/05-recipes/rate-limit.md:51` manda usar o valor como chave de
bucket — cardinalidade ilimitada escolhida pelo cliente.

---

## 5. Contabilidade de recusas — o que o contador não vê

`saturation_refusals` é **exato no que conta**: um único sítio de incremento
(`vendor/odin-http/server.odin:1225-1235`), thread única, `atomic_add` seq-cst,
leitura atômica. Não achei caminho que incremente sem fechar.

O problema é o **denominador**. Estes caminhos fecham a conexão sem resposta HTTP
e **não contam em lugar nenhum**:

| caminho | linha |
|---|---|
| pendente órfã fechada no shutdown | `server.odin:1375-1380` |
| aceita com `closing` setado | `server.odin:1278-1283` |
| handoff já enfileirado, `closing` setado | `server.odin:1250-1256` |
| erro de accept, **inclusive EMFILE** | `server.odin:1284-1303` |
| falha ao parsear a request-line | `server.odin:1650, 1671, 1685` |
| falha no scanner do bloco de headers | `server.odin:1742` |
| deadline de leitura | `server.odin:1997` |

**Todos têm a assinatura de fio idêntica à recusa de saturação:** conexão
estabelecida, zero bytes escritos, EOF.

Dois deles importam para a campanha:

1. **`server.odin:1375-1380`** — a pendente órfã só existe porque
   `accept_choose_lane` não conseguiu colocá-la, ou seja, **exaustão de lane**. É
   a recusa que o contador existe para tornar visível, e ela é fechada sem
   contar. Limitado a 1 por corrida, mas `ops/soak/analyze-soak.py:816` reprova
   a corrida quando os geradores veem mais EOFs do que o servidor contou.

2. **EMFILE invisível** (`server.odin:1284-1303`). O único estado é
   `s.accept_failures`, um `int` comum, exposto por nenhum campo do boundary. Um
   servidor saturado e um servidor sem descritores **têm o mesmo aspecto em
   `web.stats`**. Isto é diretamente relevante ao `ingest-leak` (§6.3 do
   briefing) e à investigação de morte de host: se o processo perde descritores,
   nenhum contador se move.

**Patch mínimo e de alto retorno** — expor `accept_failures`:

```odin
// boundary.odin, Server_Stats
// Quantas vezes o accept FALHOU. EMFILE/ENFILE entram aqui. Sem este campo, um
// servidor sem descritores e um servidor saturado sao indistinguiveis de fora:
// os dois param de completar requisicoes com todos os contadores parados.
accept_failures: u64,
```

```odin
// server.odin:1375-1380 — a pendente orfa e recusa de saturacao
if s.pending_accept.valid {
	net.close(s.pending_accept.socket)
	_ = sync.atomic_add(&s.active_connections, -1)
	// DRUSE PATCH — esta pendente so existe porque `accept_choose_lane` nao
	// conseguiu coloca-la: exaustao de lane. Fecha-la sem contar e o descarte
	// silencioso que este contador existe para tornar visivel, e faz
	// `analyze-soak.py:816` reprovar a corrida por um drop do proprio servidor.
	_ = sync.atomic_add(&s.refused_saturation_total, 1)
	s.pending_accept = {}
	sync.atomic_store_explicit(&s.pending_waiting, false, .Release)
}
```

**Saturação em keep-alive não é contada de forma alguma.** `handler_lane_enter`
(`odin_http_adapter.odin:844`) só devolve false quando `td.handler_active`, que
só é verdadeiro *dentro* de um dispatch síncrono — e uma lane não roda callback
de event loop enquanto está dentro de um dispatch. **O ramo é inalcançável**
(o comentário do vendor em `server.odin:227-232` diz isso, e
`tests/c05-saturation` afirma `total_lane_503 == 0`). Uma requisição keep-alive
que chega com o pool saturado **enfileira na lane**, limitada só por
`max_request_time`. Não move contador nenhum.

**Consequência para a região segura:** `saturation_refusals` mede pressão de
**conexão nova**, não saturação. A "recusa de saturação é função da rajada de
reconexão e da taxa" do briefing está certa — e agora se sabe *por que* a rajada
domina: é a única metade que o contador enxerga.

### Cobertura de teste da contabilidade

Existe **uma** asserção de contagem exata: `tests/c05-saturation:353-358`,
`saturation_after - saturation_before == 8`. Mas ela roda sob uma barreira que
estaciona todas as 4 lanes antes de medir — as lanes nunca oscilam. Todo o resto
é `>=` ou unilateral (`tests/c03-fault-campaign:228-236` afirma
`bad <= saturation_refusals`, que passa se houver contagem a mais).

Nada na suíte detecta contagem a mais, contagem a menos no shutdown, drops de
erro de accept, ou saturação em keep-alive.

---

## 6. SHADOW-001 — o patch, já que a necessidade está nomeada há dias

O G5 impede um **plano** de inventar assinatura. Uma implementação não tem essa
restrição, e a necessidade está registrada desde 2026-08-03
(`evidence/2026-08-03-r2-wp07-shadow/verdict.md:46`).

Hoje: `web/serve.odin:30` recebe só a porta, e
`odin_http_adapter.odin:329-335` fixa o endereço em Any.

```odin
// serve.odin — sobrecarga aditiva; `serve` existente nao muda de assinatura.

// serve_on roda o servidor amarrado a UM endereco.
//
// `serve(a, port)` continua significando "toda interface" e permanece o
// caminho normal. Isto existe porque conter um processo hoje e trabalho do
// firewall do host: nao havia como pedir a uma aplicacao Druse que escutasse
// so em loopback, o que o R2-WP07 registrou como SHADOW-001 e o shadow
// precisou contornar.
//
// `address` e textual e aceita as formas que `net.parse_address` aceita —
// "127.0.0.1", "::1", "10.0.0.5". Um endereco que nao parseia e recusado
// ANTES do bind, com diagnostico, como uma porta invalida.
serve_on :: proc(a: ^App, address: string, port: int) {
	addr := net.parse_address(address)
	if addr == nil {
		framework_report(App, .Invalid_Serve_Address)
		framework_observe_app(App, a, .Invalid_Serve_Address)
		return
	}
	serve_internal(a, addr, port)
}

serve :: proc(a: ^App, port: int) {
	serve_internal(a, nil, port)   // nil = Any, o comportamento historico
}
```

```odin
// odin_http_adapter.odin — o bind passa a honrar um endereco pedido.
// `cfg.address == nil` mantem a politica dual-stack de hoje intacta.
endpoint := net.Endpoint{ port = cfg.port }
if cfg.address != nil {
	endpoint.address = cfg.address.?
} else {
	endpoint.address = net.IP4_Address{0, 0, 0, 0}
	if ipv6_available() {
		endpoint.address = net.IP6_Address{}   // `::`
	}
}
```

**Custo:** um campo `address: Maybe(net.Address)` em `transport.Config`, um valor
novo em `Framework_Error` — e `Framework_Error` **está congelado** pelo contrato
da Fase 1 (é a mesma razão pela qual `Too_Many_Servers` reporta como
`Serve_Listen_Failed`, `web/serve.odin:102-107`). Ou se emenda o enum, ou
`serve_on` reusa `Serve_Listen_Failed` com a mesma imprecisão declarada. **É
decisão do dono, não minha.**

**O que resolve:** faz o `docs/supported-profile.md` poder enunciar contenção
como propriedade da aplicação em vez de "trabalho do firewall"; e dá ao shadow do
WP07 a contenção natural que o K1b teve de substituir por uma observação mais
fraca em espécie.

---

## 7. Instrumento novo, qualificado: percentis por workload

`ops/wp05/percentis-por-workload.py` — **novo, e não toca `lanes-sweep.sh`**
(o §5 de `R2-WP05-knee-preregistration.md` registra aquele harness como usado
"sem modificação"; reescrevê-lo tornaria as corridas anteriores incomparáveis
sem necessidade).

O dado por workload **já está em disco**: `launch_generators`
(`lanes-sweep.sh:165-191`) escreve `raw/w%03d-<workload>.csv`, um por gerador. O
que falta é não misturá-los.

Estados, os três, com o terceiro barulhento:

| situação | saída | exit |
|---|---|---|
| tudo medido | tabela por workload | 0 |
| célula sem amostra | `unknown` (**nunca** `0`) | 1 |
| gerador entregou menos que o planejado | `shortfall` + fração | 1 |
| `raw/` ausente ou vazio | `NAO CONSEGUI MEDIR` em stderr | **2** |
| linha truncada (corrida morta no meio) | contada e reportada | 1 |

Também corrige a definição de percentil: nearest-rank (`ceil(p·N)−1`) em vez do
`floor(N·p)` do resumo embutido, e marca `/wait/40ms` com o piso sintético para
que ninguém derive SLO de latência dele por distração.

**G2 — o instrumento prova a si mesmo.** Rodado neste ambiente, verde:

```
$ python3 ops/wp05/percentis-por-workload.py --self-test
== controle positivo: dois workloads separados TEM de sair separados ==
  PASS  health p99 = 1000us (nao contaminado)
  PASS  wait-40ms p99 = 40000us (isolado)
== mutante 1: celula VAZIA tem de virar 'unknown', nunca 0 ==
== mutante 2: gerador que morreu cedo tem de virar 'shortfall' ==
== mutante 3: raw/ ausente tem de GRITAR, nao devolver zero ==
== mutante 4: linha truncada e CONTADA, nao engolida ==
== mutante 5: nearest-rank, nao floor ==
SELF-TEST OK: controle positivo verde, 5 mutantes vermelhos pela razao esperada.
```

O mutante 1 é o defeito da §8.4 em forma pura, e o mutante 2 é o controle que o
§2 do pré-registro do SLO pede ("injetar latência conhecida num único workload e
verificar que só a célula dele se move") na sua forma de volume.

**O que isto NÃO resolve:** os CSVs brutos do WP05 **não sobreviveram**.
`evidence/2026-08-05-r2-wp05-knee/` tem 108 KiB, só manifestos — as 4,6 M linhas
foram descartadas. Então as 15 células **continuam precisando de máquina**; o
item 3 do §7 do briefing permanece de pé. O que muda é que quando houver máquina,
o instrumento existe e está qualificado.

**Recomendação de política:** preservar `raw/` no artefato de evidência, ou pelo
menos um resumo por workload. Foi o descarte que tornou este item irrecuperável.

---

## 8. Ordem recomendada

O briefing diz que o par A/B vem primeiro e que isso não é negociável. Concordo e
não estou propondo reordenar. O que segue é o que dá para fazer **sem máquina**,
em paralelo com a espera:

| # | ação | custo | por que agora |
|---|---|---|---|
| 1 | investigar o ciclo 225 do Final 1 (§2) | horas, dado em disco | é a única anomalia não explicada que já se pode perseguir |
| 2 | emendar o §4 do pré-registro do SLO (§3) | minutos | é um erro factual num documento que existe para ser auditado |
| 3 | qualificar `percentis-por-workload.py` sob o crivo de outra pessoa | minutos | já verde; falta revisão |
| 4 | escrever os testes que faltam (P1, P7, contabilidade) sem aplicar os patches | horas | testes novos em `tests/` não tocam o candidato; ficam prontos para o pós-freeze |
| 5 | mitigação documental de P8 em `supported-profile.md` | minutos | não muda API e fecha a exposição mais provável |

**Nada em `web/` até o WP08 fechar.** Os patches P1–P9 e o SHADOW-001 são para
depois do freeze, e cada um cria candidato novo sob G1.

**Para a investigação de morte de host:** o achado do §5 é diretamente relevante.
Um processo que perde descritores de arquivo **não move contador nenhum** —
`accept_failures` é um `int` privado. Se a hipótese H-B (recurso de kernel
crescendo por conexão) for real, o A/B pode muito bem observar exatamente essa
assinatura: tudo parado, nada contado. **Expor `accept_failures` antes de rodar o
A/B é barato e pode ser a diferença entre um resultado e outro silêncio
informativo.** É a única mudança de produto que eu consideraria fazer antes dos
finais — e mesmo assim, ela cria candidato novo, então provavelmente vale mais
adicionar a leitura de `/proc/<pid>/fd` ao `kernel-watch.sh`, que não toca o
candidato.

---

## 9. Achados adicionais confirmados (segunda leva de agentes)

### P10 — `no_content` não tem a guarda de commit, e corrompe o cabeçalho do primeiro

`web/respond.odin:348-350`:

```odin
no_content :: proc(ctx: ^Context) {
	response_commit(&ctx.private.response, .No_Content, response_headers_finish(ctx, 0), nil)
}
```

Todos os irmãos têm a guarda. `text` (`:313`) e `json` (`:179`) começam com
`if ctx.private.response.committed { return }`. **`no_content` não.**

Odin avalia o argumento primeiro, então `response_headers_finish(ctx, 0)` **roda e
reescreve `ctx.private.response_headers` a partir do slot 0** mesmo quando
`response_commit` depois devolve `false`. E `response.headers` da resposta já
comprometida é uma **view** sobre esse mesmo array.

Cenário concreto, com `secure_headers` ligado (configuração normal):

```
web.bad_request(ctx, "nope")   // compromete 400, headers = [Content-Type, XCTO, XFO, RP][:4]
web.no_content(ctx)            // "recusado" — mas finish(0) reescreve o array
```

Resultado no fio: o 400 sai **sem `Content-Type`** e com `Referrer-Policy`
duplicado. Com `set_header` em jogo, sai **`Set-Cookie` duas vezes**.

O próprio repositório documenta exatamente este perigo para o buffer do corpo
(`web/errors.odin:299-304`: *"THE GUARD COMES FIRST, and that ordering is
load-bearing… an already-committed response holds a VIEW over it"*) e
`web/logger.odin:39-45` chama as guardas de "audit R-9 … six hand-written
guards". **`no_content` é o sétimo sítio, sem guarda.**

**Patch (uma linha, igual aos irmãos):**

```odin
no_content :: proc(ctx: ^Context) {
	// A guarda vem PRIMEIRO e a ordem e load-bearing: `response_headers_finish`
	// reescreve `ctx.private.response_headers` a partir do slot 0, e uma
	// resposta ja comprometida segura uma VIEW sobre esse array. Sem isto, um
	// `no_content` recusado corrompe os cabecalhos de quem comprometeu antes.
	if ctx.private.response.committed {
		return
	}
	response_commit(&ctx.private.response, .No_Content, response_headers_finish(ctx, 0), nil)
}
```

Mesma classe, mesmos dois sítios irmãos: `miss_terminal`
(`web/middleware.odin:222-241`) e `static_serve` (`web/static.odin:441-481`) — o
segundo ainda faz um `os.read_entire_file_from_path` inteiro antes de a alocação
ser jogada fora.

**Por que nenhum teste pegou:** `wp6_responding_after_commit_neither_allocates_nor_modifies`
e `wp17_post_next_static_attempt_…` montam o app **sem** `secure_headers`, sem
request-ID, sem CORS e sem `set_header`. Com os quatro desligados,
`response_headers_finish(ctx, 0)` não escreve nada e `count` fica 0 — **o defeito
é estruturalmente invisível para esses testes.**

### P11 — upload: hook de teardown de vida-de-conexão apontando para memória de vida-de-requisição

`odin_http_adapter.odin:591` aloca `exchange := new(Exchange, context.temp_allocator)`
— a **arena da conexão**. Em `:667-669` arma-se um hook de **conexão**:

```odin
conn.on_teardown_user = rawptr(exchange)
conn.on_teardown = upload_conn_torn_down
```

`vendor/odin-http/response.odin:395-400` faz `free_all(context.temp_allocator)` ao
fim de **cada** requisição, e em keep-alive reaproveita a arena. **O caminho de
sucesso nunca desarma o hook** — `spool_active` só é limpo em `:684` (o próprio
teardown) e `:855` (recusa de lane).

No teardown seguinte, `upload_conn_torn_down` lê `exchange.spool_active` de bytes
reciclados (texto de header/request-line, quase sempre não-zero) e chama
`ingest.cancel` sobre lixo: `os.close` num `^os.File` arbitrário e `os.remove`
numa string arbitrária.

**Isto é exatamente o STREAM-001, que o projeto já achou, mediu e consertou — para
streams.** `stream_forget_teardown` existe em
`odin_http_adapter.odin:1141-1172` justamente para isso, com a reprodução medida
no cabeçalho. **Não há `upload_forget_teardown`** (confirmado por grep: só os
três sítios de stream). E `stream_open` (`:970-971`) ainda **sobrescreve** o hook
de um upload na mesma conexão — um slot, dois donos.

**Patch:** espelhar o que os streams já fazem — um `upload_forget_teardown(conn)`
chamado no caminho de sucesso (`on_upload_done(.Complete)`), e uma verificação em
`stream_open` de que o slot não está ocupado por um upload.

### P12 — o 507 colapsa oito causas distintas, e o errno é destruído na origem

`web/internal/ingest/ingest.odin:208-221`:

```odin
f, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.perm_number(0o600))
if err != nil {
	delete(path)
	release_slot(a)
	return .Disk_Full
}
```

`err` é **checado e descartado** — nunca guardado, logado, tipado ou propagado.
Colapsam em `.Disk_Full` → 507: `ENOSPC`, `EDQUOT`, `EACCES`, `ENOENT`,
`ENOTDIR`, **`EMFILE`/`ENFILE`**, `EROFS`, `ENOMEM`.

E há um **segundo sítio de 507** que o projeto não considerou —
`ingest.odin:281-282`, meio-corpo:

```odin
written, werr := os.write(s.file, chunk)
if werr != nil || written != len(chunk) {
```

**Um write curto é tratado como fatal, sem retry.** Um `write` parcial num chunk
de 64 KiB transforma um upload saudável em 507, indistinguível do primeiro sítio.

**Consequência direta para o wp123:** a atribuição *"`ingest.begin` não abriu o
spool"* **não é sustentada pelo código** — o Sítio B produz um 507
byte-idêntico. Foi suposição, e é a segunda vez que este status manda a
investigação para o lugar errado. (O §6.3 do briefing já diz que a mensagem
nomeia um defeito que o código não tem mais; confirmo, e o alcance é maior do que
o registrado: a string de falha do `two_servers_test.odin:363` descreve o mundo
pré-WP123, onde a admissão era compartilhada.)

**O conserto que não esconde nada** — e que não é "alargar janela" nem
"serializar a suíte":

```odin
// ingest.odin — separar as causas em vez de colapsa-las
Ingest_Result :: enum { ..., Open_Failed, Write_Failed, Disk_Full }

f, err := os.open(path, ...)
if err != nil {
	delete(path)
	release_slot(a)
	// O errno E a informacao. Descarta-lo foi o que tornou o wp123
	// irrastreavel: EACCES, EMFILE, ENOSPC e ENOENT viram o mesmo 507 mudo, e
	// `upload_refuse` so escreve a linha de status — nenhum envelope, nenhum log.
	log.errorf("druse ingest: open(%s) falhou: %v", path, err)
	return .Open_Failed
}
```

**Uma corrida do gate depois disso responde a pergunta em definitivo.**

### P13 — `EMFILE` explica os DOIS achados abertos com um mecanismo só

`tests/ingest-leak/ingest_leak_test.odin:93-98` detecta prontidão com
`net.dial_tcp` num laço de 300 tentativas. **`err != nil` confunde "nada
escutando" com "este processo não conseguiu criar socket".** `ECONNREFUSED` e
`EMFILE` são o mesmo booleano.

Cliente e servidor são **o mesmo processo**. Então exaustão de descritores
produz, simultaneamente:

- `dial_tcp` falhando 300× → **"server did not start"** (ingest-leak)
- `os.open` do spool falhando → **507** (wp123)

E o padrão registrado — 4 falhas consecutivas, depois 9 passes — é variável de
estado de máquina que persiste entre processos e depois limpa. Isso **argumenta
contra** bug de lógica em processo e **a favor** de teto de recurso.

**Descriminador barato, sem tocar produto:** amostrar
`len(os.read_directory_by_path("/proc/self/fd"))` no topo de `start()` e antes de
cada `post`. Se a contagem estiver longe do limite, a hipótese morre.

**Refutado por leitura, não por argumento:** TIME_WAIT / `SO_REUSEADDR` ausente —
`vendor/nbio/impl.odin:115` faz `net.set_option(socket, .Reuse_Address, true)`
antes do bind. **Risque essa hipótese.**

Isto liga de volta ao §5: **`accept_failures` não é exposto por campo nenhum.** Um
processo sem descritores e um processo saturado são indistinguíveis em
`web.stats`. É a mesma cegueira, e é relevante para a morte de host.

---

## 10. Os instrumentos da campanha — o A/B não está tão pronto quanto o §7.1 diz

O §7.1 do briefing lista seis instrumentos como "prontos e qualificados". A
varredura achou 25 defeitos da classe §8.4 neles. Os que mudam a decisão:

### I1 — `kernel-watch.sh:129-140`: todo `die` está dentro de substituição de comando

`printf ... "$(meminfo_kib MemFree)" ... "$(count_fds "$PID")"`. O `exit 1` do
`die` mata **só o subshell**. O arquivo tem `set -u` mas **não `-e`** (linha 21),
e uma substituição que falha não faz o `printf` falhar.

**Resultado:** a linha é escrita com **campos vazios** e o laço continua. Um
kernel trocado no meio da corrida — o matador de host documentado — remove um
campo do `/proc/meminfo` e produz **12 h de `1754…,,,,,,,,,`** sem uma palavra em
stderr. O comentário de cabeçalho do próprio arquivo (linhas 17-20) promete os
três estados; é falso em todo lugar menos nas três checagens de pré-voo.

### I2 — `analyze-kernel-watch.py`: falha do instrumento no braço de CONTROLE fabrica o achado

Encadeado com I1. As colunas vêm do braço **druse** (`linhas_d[0].keys()`). Uma
coluna faltando ou em branco no **controle** → `len(vc) < 3` → `sc = None` →
`cresce_no_controle = sc is not None and sc > 0` = **False**, que é exatamente a
condição (b) do §4.

**Uma leitura ruim de `/proc` no braço de controle produz
`"condicao_2_do_paragrafo_4": "satisfeita"` para a H-B — isto é, declara que o
Druse vaza memória de kernel e o controle não.** É o pior modo de falha possível
para este experimento: o instrumento inventa a conclusão que a campanha procura.

E quando as duas colunas ficam curtas, o veredito imprime **`condição 2 do §4:
NAO satisfeita`** — "não há vazamento" — para uma vigilância que não mediu nada.

### I3 — as três alegações de qualificação do §7.1, conferidas

| alegação | veredito |
|---|---|
| `kernel-watch.sh`: "`mlock` de 4 MiB moveu `Mlocked` em **exatos** 4.096 KiB" | **o número está errado.** A asserção real é `if (( delta < 3072 ))` — piso de 3072 KiB, **sem teto**. `Mlocked` é contador do sistema: um mlock concorrente de outro processo satisfaz. E o controle exercita **1 das 17 colunas**, não toca `VmPin`/`VmLck` (onde a H-B mora) nem `proc_iouring_fds`, e não passa pelo laço de amostragem — que é onde o I1 vive |
| `analyze-kernel-watch.py`: "1 controle + 4 mutantes" | **contagem confere, cobertura não.** Os 4 são todos de inclinação sobre CSVs sintéticos bem-formados. **Nenhum** exercita campo em branco, CSV truncado, ou coluna faltando no controle. **Os mutantes não conseguem falhar em I1 nem em I2** |
| `host-death-ab.sh`: "84.240 planejadas = completadas, 0 erro" | **não se sustenta como ensaio do par.** 702 × 120 s = **84.240 exatamente** — é a fase única de 120 s do perfil `/tiny` (`host-death-ab.sh:176`). Um ciclo do mix completo é 1.118 × 120 = **134.160**, e um ensaio dos dois braços seria ordens de grandeza maior. **Não há artefato commitado**: nenhum `evidence/*host-death*`, nenhum `kernel-watch.csv` na árvore |

Além disso: **`grep -rn -- "--self-test" build/ .github/` não devolve nada.**
Nenhum gate roda nenhum dos self-tests. Os três instrumentos que o handoff chama
de "prontos e qualificados" têm **zero cobertura de regressão**; a qualificação é
um resultado manual registrado em prosa que nada re-estabelece.

### I4 — `host-death-ab.sh`: o `trap cleanup` é instalado depois da janela que protege

Servidor sobe na linha 101; `trap cleanup EXIT` na linha 124. Os `die` das linhas
104, 110 e 117 **vazam servidor vivo e kernel-watch vivo** — que é exatamente o
risco que o comentário do próprio arquivo (linhas 55-57) diz ter custado sete
medições em 2026-08-04.

E em `:185`, o status de saída de **todo** gerador de carga é descartado, os
`cycles/*.err` nunca são inspecionados, e nenhum `load-errors.txt` é escrito (ao
contrário de `run-soak.sh:514`). Um braço em que o `openload` falhou em subir em
todo ciclo ainda escreve `cycles.csv` completo com `health_status=200` e imprime
`AB_ARM_druse_DONE`.

### I5 — `watch-remote.sh`: o controle positivo redefine a função sob teste

Linha 68: `probe() { echo "1234"; }`, e então afirma `$(probe) == "1234"`. O
self-test imprime **`watch-remote: QUALIFICADO`** tendo exercitado **zero linhas**
do `probe()` real. O mutante (linha 62) é legítimo; o controle é uma tautologia —
e o G2 exige os dois.

Ainda em `:50`, o comando remoto termina em `find … 2>/dev/null | wc -l` sem
`pipefail` no shell remoto: um `find` que falha devolve `0`, que é numérico, passa
a validação das linhas 53-55, e imprime **`OK 0 amostras`** seguido de `STALL` —
**nunca `UNREACHABLE`**. O conserto anterior fechou o lado da falha de ssh e
deixou o lado da falha de `find` aberto.

### I6 — o `MANIFEST.sha256` com caminho absoluto **continua sendo produzido**

`run-soak.sh:617-618` usa `find "$OUT" -type f -print0 | xargs -0 sha256sum` com
`$OUT` absoluto. Confirmado na árvore, no artefato do Final 1:

```
657fbbb…  /home/ubuntu/soak-runs/soak/bin/SHA256SUMS
```

O briefing lista este como um dos defeitos "já encontrados". **Ele foi
diagnosticado, não consertado** — todo artefato futuro continua inverificável
fora do caminho original do host.

### I7 — `openload/main.go:138-143`: percentil vazio devolve 0, o melhor valor possível

```go
func percentile(values, fraction) { if len(values)==0 { return 0 }; ... }
```

Vazio → `latency_p99_us: 0` — a melhor latência possível — para um workload em que
nada completou. `run-soak.sh:526` faz `jq -r '.latency_p99_us // 0'` e o teste de
`-gt 250000` na linha 553 não levanta violação nenhuma.

O mesmo `floor` do §7: `wait-40ms` a 1 req/s × 120 s = 120 amostras →
`int(119*0.99) = 117` → o "p99" reportado é a 118ª de 120, ou seja **p98,3**.
`ops/wp05/percentis-por-workload.py` já usa nearest-rank — **o conserto existe no
repositório e nunca foi aplicado ao gerador que alimenta o soak.**

---

## 11. Conclusão

**O programa de prontidão está funcionando.** As medições que existem são sólidas:
reverifiquei os números do Final 1 no artefato e eles conferem, e a atribuição de
"zero recusa de carga" é robusta a um teste que o projeto não fez (as 12 rajadas
caírem todas em janela de injeção por acaso tem probabilidade 3,5×10⁻⁹).

**Mas o bloqueio não é só falta de máquina.** Três coisas mudam a ordem
recomendada:

1. **Os instrumentos do A/B não estão qualificados no sentido que o §7.1
   afirma.** O I2 é decisivo: uma leitura ruim de `/proc` no braço de controle
   **fabrica exatamente o achado que a campanha procura**. Rodar o A/B com o
   `analyze-kernel-watch.py` de hoje arrisca produzir um "o Druse mata o host"
   que é do instrumento. **Consertar I1 e I2 vem antes de pedir máquina** — e é
   trabalho de horas, não de dias.

2. **Há uma anomalia não explicada em dado que já está em disco.** O ciclo 225 do
   Final 1, `json-encode` a 27.269 µs contra 1.415 µs do segundo pior. Não custa
   máquina nenhuma perseguir.

3. **`EMFILE` é um mecanismo único que explica os dois achados abertos** (wp123 e
   ingest-leak) e é invisível a toda a observabilidade atual, porque
   `accept_failures` não é exposto. Também é uma assinatura plausível para a
   morte de host — se o processo perde descritores, **nenhum contador se move**.

**O que eu entrego:** um instrumento novo e qualificado
(`ops/wp05/percentis-por-workload.py`, self-test verde com 1 controle + 5
mutantes) e este documento com 13 defeitos de produto e 7 de instrumento, cada um
com patch e com o teste que faltava.

**O que eu não fiz, deliberadamente:** nada em `web/` nem em `web/internal/`. O
§11 é claro, e sob o G1 qualquer um desses patches cria candidato novo e descarta
o Final 1. **Eles são para depois do freeze do WP08.**
