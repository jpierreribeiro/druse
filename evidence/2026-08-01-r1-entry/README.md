# Entrada R1 — piloto controlado

**Data:** 2026-08-01

**Branch:** `r1/controlled-pilot`

**Base:** `73534857faf3eee1edc0ac598c2be03a77ea8876`

**Resultado:** entrada aceita para executar R1; produção continua proibida.

A base contém a correção de lifecycle integrada em
`885243786944afc8acd6e717da1c673695a03948`, seguida pelo pacote de auditoria e
planejamento em `73534857faf3eee1edc0ac598c2be03a77ea8876`. A evidência R0 registra
o gate integral verde no commit real, os controles mutantes do registry e do
ownership de `serve`, e zero P0 pendente no escopo de entrada.

Essa aceitação só abre a execução do plano. Ela não significa que o Druse está
pronto para produção: os contratos de recursos, proxy real, perfil suportado,
runbooks, exercício de rollback e freeze R1 permanecem obrigatórios.

## Referências de entrada

- `evidence/2026-08-01-r0-lifecycle-closure/`
- `evidence/2026-08-01-production-readiness-audit/`
- `planning/readiness/R1-controlled-pilot.md`
- `planning/readiness/IMPLEMENTATION-MAP.md`

## Decisão

**OPEN R1.** R1-WP01 pode produzir mudanças e evidência na branch dedicada.
Qualquer regressão no gate, identidade quebrada ou reaparecimento de P0 devolve
o projeto a R0.
