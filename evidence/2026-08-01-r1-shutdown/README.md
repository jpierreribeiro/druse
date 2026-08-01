# Evidência R1-WP01 — shutdown de processo real

**Data:** 2026-08-01

**Base:** `73534857faf3eee1edc0ac598c2be03a77ea8876`

**Branch:** `r1/controlled-pilot`

**Resultado:** R1-WP01 verde; R1 ainda não promove produção.

O drill compila um servidor real, abre sockets TCP, entrega `SIGTERM`, observa
readiness e arquivos de lifecycle de conteúdo fixo, espera o processo filho e
confere seu exit status. O cenário bloqueado aplica `SIGKILL` explicitamente,
como um supervisor ao vencer `TimeoutStopSec`.

## Matriz executada

| Braço | Resultado observado |
|---|---|
| S0 | `is_draining` publicado antes do retorno de `serve`; readiness 503 |
| S1 | keep-alive idle fechado; processo saiu com status 0 |
| S2 | handler curto concluiu resposta 200 durante o drain |
| S3 | slow reader não sobreviveu aos limites de escrita/drain |
| S4 | stream escreveu o chunk terminador e o processo saiu limpo |
| S5 | spool em andamento foi cancelado e nenhum temporário permaneceu |
| S6 | handler infinito sobreviveu a `max_drain_time`; supervisor matou com 137 |
| S7 | dois sinais de stop mantiveram um encerramento limpo |
| S8 | parar App A não alterou health/tráfego de App B |

## Controles

- o corpo do signal handler é checado como contexto default + `web.stop`, sem
  vocabulário de alocação, log, espera ou mutex;
- a publicação de `draining` precisa preceder `transport.request_stop`;
- `TimeoutStopSec` precisa ser inteiro e maior que o drain default de 10 s;
- uma unit mutante sem `TimeoutStopSec` é recusada;
- retirar a publicação de `draining` faz S0 ficar vermelho;
- S4 exige o terminador chunked, distinguindo drain cooperativo de force-close.

## Comandos

```sh
bash ops/verification/run-shutdown-drill.sh
bash build/check_r1_shutdown_controls.sh
```

O gate integral também passou sobre este worktree: 1.738 linhas e 126.952
bytes, preservados em `raw/full-gate.log`, SHA-256
`2833065e4ac3a9778aa8c7dd5ccb9ff0e92ded995c2ace86eea29b671a92101f`.

A primeira tentativa de pre-push encontrou uma race pré-existente no oracle
WP87: três testes paralelos compartilhavam globals de resultado, e o braço de
body oversized podia sobrescrever o resultado do JSON válido. O oracle foi
isolado com um `app_with_state` por teste; a suíte corrigida passou 30/30
repetições paralelas e `build/check_wp87_controls.sh` permaneceu verde. Esse
bloqueio do hook e a correção fazem parte da evidência, não foram contornados.

## Limitação provada

`max_drain_time` limita o transporte; não preempta um `Handler` síncrono preso
em código arbitrário. O prazo absoluto pertence ao supervisor. A configuração
canônica mantém `TimeoutStopSec=30` acima do default de 10 s, mas o orçamento e
o exercício sob systemd real pertencem ao R1-WP02.

Esta evidência não prova proxy real, orçamento de FD/memlock/memória, crash-loop,
rollback ou soak. Esses itens continuam bloqueando a promoção R1.
