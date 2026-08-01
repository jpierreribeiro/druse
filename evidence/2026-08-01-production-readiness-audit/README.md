# Pacote de evidência — auditoria de prontidão para produção

Este diretório contém a evidência nova produzida pela auditoria de 2026-08-01.
Ele não altera o framework e não deve ser confundido com uma correção.

## Atualização posterior

Este pacote permanece imutável como evidência do snapshot auditado
`7d65783`. O baseline posterior `9162f34` já separa slots `claimed/live`, e a
rodada R0 provou a correção de AUD-P0-001, fechou ownership concorrente do App e
foi integrada em `main@8852437`, onde o gate integral passou. A evidência
posterior está em
[`../2026-08-01-r0-lifecycle-closure/README.md`](../2026-08-01-r0-lifecycle-closure/README.md).
R0.3 está concluído; R1 pode começar, mas produção continua fora do escopo desta
evidência.

## Baseline

```text
head=7d6578393398f3538bf391d35e406582f983aea0
branch=docs/registry-reconciliation
describe=v0.10.0-11-g7d65783-dirty
tracked_changed_files=44
tracked_insertions=958
tracked_deletions=286
tracked_binary_diff_sha256=419fb27fbee14985d8c6886acbfd0ca1cd5ab7c070ee5622f1569c8c2054f3c9
odin=dev-2026-07-nightly:819fdc7
kernel=Linux 6.8.0-86-generic x86_64
cpus=8
memory=23GiB
swap=0
nofile_soft=1024
memlock_kib=3052280
```

Arquivos WP123 não rastreados incorporados ao baseline:

```text
ca2c2ba48704f4d3686d908e0497e49450a4877f4c24a9151e9dc6444b7b96c8  build/check_wp123_controls.sh
e98c4f495153ce1eb6fac88a59bb02b45e84b6e6817cf76c044abe871e67015f  web/internal/transport/server_registry.odin
7f199d77052257ba779637511fafb217389be5a8e56586979d1928492dea3c3c  tests/wp123-two-servers/two_servers_test.odin
```

## Reprodução AUD-P0-001

O teste precisa pertencer ao package `transport` para acessar as rotinas
privadas. Ele é copiado para um clone temporário do diretório do package:

```sh
audit_tmp="$(mktemp -d -t druse-audit-registry-XXXXXXXX)"
cp web/internal/transport/*.odin "$audit_tmp/"
cp evidence/2026-08-01-production-readiness-audit/server_registry_slot_reuse_test.odin "$audit_tmp/"
odin test "$audit_tmp" \
  -collection:druse="$PWD" \
  -out:/tmp/druse-audit-registry-test
```

Resultado observado:

```text
Finished 1 test in 3.383062ms. The test was successful.
sha256=bbe18501093478a3149452b5f787d49a14bde7d3a645cea13ec3d85938bc6e21
```

O verde aqui confirma o defeito: o teste afirma que o leitor antigo vê o
servidor novo e que o retire antigo apaga o ponteiro novo. Depois da correção,
preservar este arquivo como reprodução histórica e criar uma regressão positiva
que afirme a exclusão entre `Retiring` e `Free`.

## Evidência preexistente consultada

- `evidence/2026-07-29-release-candidate/soak-final/manifest.txt`: soak de 12 h,
  commit `9b46a46f...`, 332 ciclos.
- `evidence/2026-07-29-release-candidate/soak-analysis-new-rule.json`: `FAIL`,
  pois 1.085 falhas contadas não foram classificadas pelo instrumento original.
- `docs/reports/2026-07-30-soak-failure-attribution.md`: campanha posterior
  atribui as falhas a acceptor saturation, sem reescrever a evidência antiga.
- `docs/reports/2026-07-30-own-marshal.md`: comparação de desempenho de um
  endpoint/host/commit anterior.

Não houve novo soak em host dedicado: o workspace não forneceu credenciais ou
alvo remoto. Consequentemente, nenhuma evidência histórica é apresentada como
validação do snapshot WP123 atual.

Durante a decomposição do plano R2 foi identificado também um defeito no
instrumento atual: `ops/soak/run-soak.sh` avalia `stats_curl_exit=$?` depois de
um comando protegido por `|| true`. O valor registrado corresponde ao `true`,
e não ao `curl`, podendo mascarar falhas do scrape de `/stats`. Esse defeito
deve ser corrigido e coberto por fixtures/mutantes antes de qualquer novo soak
ser aceito como evidência de promoção.

## Inventário de testes

No escopo `tests`, `web` e `experiments`:

```text
files_with_odin_tests=133
odin_test_procedures=799
web_odin_lines=15186
vendor_odin_lines=14963
tests_odin_lines=39589
build_scripts=79
build_scripts_with_mutation_or_negative_control_terms=44
```

O gate de documentação também informou que 28 de 29 pacotes de crystals não
estavam no caminho local e que 264 referências de símbolos não puderam ser
verificadas. Isso foi classificado como contexto não validado, não como falha do
core Druse.

## Gates executados

```text
build/check_docs.sh:
  exit=0
  note=28/29 crystals packages absent; 264 symbol references unchecked

build/check.sh on dirty workspace:
  exit=1
  last_pass=supervisor contract
  reason=merged-fix mutation control refuses to use git checkout on dirty sources

build/check.sh on clean temporary mirror of the audited snapshot:
  exit=1
  last_pass=check_wp23_controls.sh
  failure=check_wp24_controls.sh control 5
  detail=AssertionError: pattern not found
  stale_pattern=## Exactly one server per process
  current_contract=## More than one server in a process; at most sixteen
```

No teste limpo, todos os estágios anteriores à cauda de controles WP24 ficaram
verdes, inclusive WP123 e os dois mutantes que o gate atual conhece. A falha
WP24 é um controle stale, não uma reprovação funcional do parser/servidor; ainda
assim, o gate oficial do snapshot não está verde e a release deve ser recusada.

Os controles posteriores foram então executados isoladamente:

```text
PASS: wp25 wp30 wp36 wp37 wp38 wp39
PASS: wp41, quando repetido com permissão de sockets locais
```

Uma primeira tentativa WP41 dentro do sandbox de rede falhou ao abrir qualquer
porta, e `tests/wp8-socket` falhou do mesmo modo. Repetido fora dessa restrição,
o controle WP41 passou seus quatro braços. A tentativa sandboxed foi classificada
como limitação do ambiente da auditoria, não como finding do projeto.
