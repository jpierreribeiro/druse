# Evidência R0 — registry e ownership de `serve`

**Data:** 2026-08-01
**Base do workspace:** `9162f346e4bc59c93888bae131ad2f0f16f7a3ce`
**Candidato limpo temporário:** `0f45d2c1d0b74f266ef5988d88dcdc397e6fca2e`
**Integração real em `main`:** `885243786944afc8acd6e717da1c673695a03948`
**Resultado:** R0.1–R0.4 concluídos; entrada em R1 aberta.

Este pacote registra o fechamento técnico dos riscos de lifecycle encontrados
na auditoria. O commit candidato foi criado somente em um clone sob `/tmp` para
permitir que controles destrutivos usassem `git checkout --` sem tocar no
worktree do usuário. Depois dessa prova, os mesmos nove arquivos foram
integrados no commit real `8852437` e o gate foi repetido sobre ele.

## O que já existia no baseline

O `HEAD` atual já continha a correção central de AUD-P0-001: `Server_Entry`
separa `claimed` de `live`; publishers só reutilizam o slot depois de
`server_retire` drenar leitores, limpar ponteiros e liberar `claimed`.

A reprodução histórica da auditoria foi executada contra esse código e ficou
vermelha nos três sintomas que antes confirmavam o defeito:

```text
expected new_slot to be 0, got 1
an already-acquired old reader now observes the new server pointer
old retire erased the live new server pointer
```

O vermelho é o resultado correto para um teste que afirma o comportamento
defeituoso antigo.

## Trabalho desta rodada

1. Criado fixture privado determinístico que segura um reader durante retire e
   prova que o novo publish usa outro slot.
2. Adicionado mutante que troca o gate de publisher de `claimed` para `live`;
   ele fica vermelho em `RETIRING-SLOT-REUSED`.
3. Adicionado claim CAS privado para permitir um único `serve` ativo por App.
4. Fechada a corrida `stop` durante startup: um handle publicado depois de o
   drain ter sido pedido recebe `request_stop` imediatamente.
5. Cobertos: serve concorrente no mesmo App, bind failure seguido de retry,
   preservação do servidor vencedor e recusa de restart depois do drain.
6. Adicionado mutante sem CAS; ele fica vermelho em
   `SERVE-CLAIM-MULTIPLE-WINNERS`.
7. Reconciliado o contrato em `docs/canonical-patterns.md` e
   `docs/operations.md`.

Não houve mudança na API pública. A rejeição usa o erro público congelado
`Serve_Listen_Failed`, pois a chamada retorna antes do bind e um novo membro em
`Framework_Error` exigiria alteração de superfície.

## Execuções

| Execução | Resultado |
|---|---|
| reprodução histórica AUD-P0-001 | exit 1, três sintomas antigos recusados |
| `tests/wp123-two-servers` | 4/4 PASS |
| `build/check_wp24_controls.sh` | PASS, controles 1–6 incluindo 5/5b |
| `build/check_wp123_controls.sh` | PASS, quatro mecanismos sob controle |
| registry lifetime repetido | 30/30 PASS |
| same-App claim repetido | 30/30 PASS |
| `build/check_docs.sh` | PASS |
| primeiro gate com fontes sobrepostas e não commitadas | recusado pelo safety check, como projetado |
| gate no candidato limpo `0f45d2c` | exit 0 |
| gate no commit real `main@8852437` | exit 0 |

O gate final começou aproximadamente às 17:41:48 e terminou às 18:06:13 no
fuso America/Bahia. O log integral, com 1.721 linhas, está em
`raw/full-gate.log`.

Depois da integração, o gate foi repetido no commit real `8852437` entre
18:38:03 e 18:57:30. Ele terminou com exit 0; o log de 1.721 linhas está em
`raw/main-8852437-full-gate.log`. Uma tentativa anterior parou no baseline do
controle WP21 porque este laudo ainda continha um link para fora da miniárvore
de documentos copiada pelo controle. A referência foi tornada textual,
`check_wp21_controls.sh` passou isoladamente e a repetição integral ficou verde.

## Decisão de promoção

- **R0.1:** concluído e sob controle mutante.
- **R0.2:** concluído e documentado; um App tem um único `serve` ativo.
- **R0.3:** concluído em `main@8852437`, com gate integral verde no próprio
  commit e log identificado por SHA-256.
- **R0.4:** concluído; WP24 rejeita perda do contrato multi-server e do teto 16.

R1 pode começar sobre `main` a partir de `8852437`. A promoção para produção
continua proibida até cumprir os gates R1 e R2; R0 prova o lifecycle local, não
o envelope operacional completo.

## Limites desta evidência

Este pacote não prova shutdown de processo real sob SIGTERM/systemd, proxy real,
budgets de FD/memória ou soak do candidato. Esses trabalhos pertencem a R1 e
R2. O gate prova corretude e controles locais do lifecycle, não prontidão geral
para produção.
