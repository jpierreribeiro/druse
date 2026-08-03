# Provenance of the Tina dossier cited by the runtime feasibility study

**Why this file exists.** `planning/runtime-feasibility-study.md` cites
`tina/docs/` twelve times with verbatim quotations, and that directory is
**not in the repository** — it is excluded by `.git/info/exclude`, a LOCAL
exclusion rather than a project policy (`.gitignore` does not mention it).

The audit's rule, taken from this study's own companion file: *"a summary
that cannot be checked against its source is an assertion"*. Committing a
third party's 188 KB dossier into this tree is one way to fix that; recording
its provenance so any reviewer can obtain the same bytes and verify them is
the other, and it is the one taken here — the exclusion was somebody's
decision and this study is not the place to overturn it.

**The subject.** `github.com/pmbanugo/tina`, Apache-2.0, studied at commit
`24b2cb9ba2eee96e5deb9a3b7952cd02723ddd68` (2026-07-14). The dossier is a
study OF that repository, not part of it.

**How to verify a citation.** Obtain the dossier, hash the file, compare
below. A mismatch means the quotation in the study cannot be trusted.

```text
087ca2a3014eb4e71b2bb905aee196a966fdc5cada62ae137fc37690fd12ec79  tina/docs/00-metodo-e-estado-da-fonte.md
131aa215ac8ec3aa0ecb127b34fb46b2d007ada0f10264efdd6ac2c6af72bed6  tina/docs/01-arquitetura-do-runtime.md
e54714fdf49ed8adf21ec67110dad6bd4cba414b2e9574458914b36b478660ac  tina/docs/02-memoria-ownership-e-backpressure.md
878547754f5d88d7926921bcf3dbd57a006bc4175e6c6fe69d3a4fb5219d6eac  tina/docs/03-io-scheduler-e-lifecycle.md
8449a67141979dbdc468aae99409818d004dc4ce8f100bee5de16837b1388ab8  tina/docs/04-supervisao-falhas-e-dst.md
d6e9e4cf45949693a97da7a44f4d3cc56ef452521b933ad7f7a7df7809a3209f  tina/docs/05-tina-http.md
5c2388b1a2e3ddef0bc45d802d6cf4cdda388d23652db1b898a84b4331246ca2  tina/docs/06-testes-portabilidade-e-maturidade.md
09a36f98226beaeaa45c8500883578e97dace7a13d3dbb33b015ec75588ada10  tina/docs/07-catalogo-de-padroes.md
98ae8037e11dec08fbf205bc8bb213692d7cdad470f977239bae861ee4fe31f8  tina/docs/08-comparacao-com-uruquim.md
2163ca8b782331e33b749045e5c0a717be10da27eba84f62d7fe67e79894cde0  tina/docs/09-propostas-para-o-planejamento.md
22d12466ec9f1a5480f999450513a7392a96f6ae1dcd91f0a8213a0a7c86cdc2  tina/docs/10-limitacoes-e-questoes-abertas.md
7c94815568b766b3b63be9c3d571394dfb7d1c400c273ef0a5b65fb81b0f1b6d  tina/docs/11-impacto-no-roadmap-do-uruquim.md
5eccc5328cdc8c7f783cd147546f6de6bae5134bb0bde89a2625277f0ed90fd0  tina/docs/evidence/cobertura-de-arquivos.md
bfa43f85b1bdb793affd7475b817704d7451a48e95ecdca354220daabd7ab1f7  tina/docs/evidence/experimentos.md
e7ce3f6c373385108b06458c1431735c69ab38158037d380f597717455065874  tina/docs/evidence/historico-e-releases.md
336c8285a51ea4ab9856d718b3d6908cd1228f1cda7b713cfbb4c89b5a720f5d  tina/docs/evidence/inventario-de-testes.md
cd7264b903145e9a37f08473e3746a3e0aac19ffc324783898f906190113b715  tina/docs/evidence/matriz-de-alegacoes.md
8b1b31390cfef9a3c1ccbf2d2c4a0c76f9ec1093893697b1e730f218561c1063  tina/docs/evidence/uruquim-tina-impact-assessment.md
6515c991a01d0f3ea05caa28d828f2af6d4b6e4336de46e71434933d3f4aee13  tina/docs/PROMPT-AGENTE-MELHORAR-URUQUIM-COM-TINA.md
753e11ddcdbc818234ef9851d437589cf951cab60956e1c8eaa2f70b66d3f231  tina/docs/README.md
42902bfbdd1bf6aeb923bd8d6d6fee9a8620ff3cc8d5c0ea9a1b391e212bb153  tina/docs/UPDATING.md
```

Total: 21 files, 3185 lines.
