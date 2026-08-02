# R3-WP10 — pré-registro dos critérios de contenção de falha

**Regra G3.** Este arquivo é commitado **antes** do primeiro run válido. Alterar
qualquer número ou regra abaixo depois de ver um resultado invalida aquele run
para a decisão de braço.

**Entrada, verificada e não suposta:** ADR-049 existe (PROPOSED, 2026-08-02) e
R2-WP03 fechou em 2026-08-02 (`main` em `87723fc`). O bloqueio que ADR-049
registrou — `web.stats()` vira por processo — caiu com ADR-050, e **só ele**.

**Escopo.** Reduzir o raio de explosão de um fault de handler. Hoje ele custa
100% da capacidade e toda conexão em voo. ADR-020 fecha a recuperação em
definitivo e ADR-047 já decidiu o diagnóstico; isto trata apenas do **raio**.

**Campanha:** `evidence/2026-08-02-r3-worker-budget/`.
**Este WP não promove nada. O gate continua em R1.**

---

## 1. A ordem é obrigatória, não preferida

`R3-general-maturity.md` §6 diz, com todas as letras: **o que precisa ser medido
antes de escolher** é o orçamento de recursos para N>1. Portanto:

1. medir o custo de recursos de N processos;
2. **só então** escolher o braço, num ADR, com esse custo visível;
3. só então implementar;
4. só então rodar a campanha de fault.

Escrever a escolha antes da medição é escolher antes de medir, e o ADR-049
existe precisamente porque `SO_REUSEPORT` é a mudança que alguém faz numa tarde
sem ver o preço.

## 2. Etapa 1 — orçamento de recursos, medido

`evidence/2026-08-01-r1-resource-budget/` foi produzida para **N=1**: 22 FDs,
9 threads, 9 pares io_uring/eventfd, `LimitNOFILE` derivado 1213 contra 2048
configurado, `MemoryMax=1G`, `LimitMEMLOCK=64M`. **Nada disso transfere.**

Medir, para N ∈ {1, 2, 4} com o mesmo número de lanes por worker:

| Grandeza | Por worker | Agregado |
|---|---|---|
| FDs abertos | sim | sim |
| threads | sim | sim |
| mapeamentos `anon_inode:[io_uring]` | sim | sim |
| `VmLck` | sim | sim |
| bytes mapeados de io_uring | sim | sim |
| `VmRSS` / `VmHWM` | sim | sim |

### Critérios congelados

| ID | Critério | Reprova quando |
|---|---|---|
| **W1** | rings, FDs e threads por worker são **constantes em N** | qualquer um deles varia com N — significaria acoplamento entre processos que ninguém desenhou |
| **W2** | o agregado é reportado contra cada limite do unit R1 (`LimitNOFILE`, `LimitMEMLOCK`, `MemoryMax`), e **todo limite que N>1 estouraria é nomeado** | um limite estourado que não aparece no veredito |
| **W3** | a natureza de cada limite é declarada: **por processo** ou **por cgroup** | tratar `LimitMEMLOCK` (RLIMIT, por processo) e `MemoryMax` (cgroup, agregado) como se fossem a mesma coisa |

**W3 é o que decide o unit template**, e é a armadilha real: `LimitMEMLOCK` é um
RLIMIT e cada worker recebe o seu, então o número **não** precisa crescer;
`MemoryMax` é do cgroup e o mesmo 1 GiB passa a ser dividido por N workers, o
que é uma redução silenciosa de 1/N na memória de cada um. Confundir os dois
produz um unit que parece correto e mata workers sob carga.

## 3. Etapa 2 — a decisão de braço

Um ADR, com a medição da Etapa 1 citada, escolhendo entre A (`SO_REUSEPORT`),
B (listener herdado) e C (pre-fork) — **ou** registrando **manter N=1**, que
`R3-general-maturity.md` lista explicitamente como resultado permitido quando o
custo não se paga.

Se o braço escolhido tocar `vendor/odin-http`, ele entra no ledger de vendor com
disposição, como patch 44, e não como uma linha.

## 4. Etapa 3 — a campanha de fault

Só existe depois de um braço implementado. Critérios congelados agora:

| ID | Critério | Limite | Reprova quando |
|---|---|---|---|
| **F1** | *controle positivo:* matar um worker sob carga; requisições atendidas pelos **workers sobreviventes** durante a janela | **zero falhas** nos sobreviventes | qualquer falha atribuível a um sobrevivente |
| **F1n** | *controle negativo:* a mesma campanha com **N=1** | tem de ficar **VERMELHA** | se ficar verde, a campanha não mediu contenção — mediu que o serviço estava de pé, e o run inteiro é **nulo** |
| **F2** | perda de capacidade na morte de um worker | ≈ 1/N, **não** 100% | perda de 100% |
| **F3** | toda requisição perdida é **atribuída**: worker morto, ou sobrevivente | 100% atribuídas | qualquer perda sem atribuição |
| **F4** | drain de um worker não fecha admissão nos outros | zero recusas nos outros | qualquer recusa |
| **F5** | rollback para N=1 **sem rebuild** | o mesmo binário | exigir recompilação |

### F1n é o critério mais importante deste documento

Uma campanha de contenção cujo controle negativo passa não mediu contenção. É
exatamente o defeito que R2-WP01 removeu do instrumento de soak — um artefato de
doze horas sem telemetria alguma graduado PASS — e ele reaparece aqui numa forma
nova: matar um worker de N e ver o serviço de pé **não prova nada** se o serviço
também fica de pé quando o único worker morre, porque então o instrumento está
medindo o supervisor, não a contenção.

## 5. Regras de validade, declaradas antes

- **Host.** Este container tem 4 CPUs compartilhadas e `nofile` hard 4096. Ele
  responde perguntas de **contabilidade de recursos** — quantos FDs, quantos
  rings, quantos bytes travados — porque essas são determinísticas. Ele **não**
  responde perguntas de capacidade ou de cauda (G4).
- **Se um limite de recurso impedir N>1 neste host**, o resultado é esse fato,
  escrito. Não se reduz N para caber, e não se afrouxa um limite para caber.
- **Se a Etapa 1 mostrar que o custo não se paga**, o resultado permitido é
  **manter N=1**, com o custo escrito. Isso é uma conclusão, não uma falha.

## 6. O que este WP não vai medir

- **Nenhum soak.** 12 h é R2-WP04 e exige host dedicado (R2-WP02).
- **Nenhum envelope de capacidade.** Vazão com N workers num container de
  4 CPUs descreve o container.
- **Nenhuma promoção.** O gate continua em R1.
- **Nada sobre `workers_expected`** além do que ADR-050 já exige: o supervisor
  publica esse número e o sidecar o usa. Provar um agregado honesto com N
  workers reais é trabalho desta trilha somente se um braço for adotado.
