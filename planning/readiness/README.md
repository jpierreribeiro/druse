# Programa de prontidão para produção — R1, R2 e R3

**Status:** R1 PROMOTED em 2026-08-02 para piloto interno não crítico. R2 em
execução — WP01, WP02 e WP03 fechados; WP04 na escada (smoke e burn-in PASS nas
taxas re-derivadas, rehearsal em curso, finais bloqueados pelo pré-registro
§4.2); WP06 executado com duas cláusulas abertas; WP07 degrau 1 entregue e
degraus 2–6 como risco aceito a assinar; WP05 e WP08 abertos. R3 continua como
plano bloqueado por seu próprio gate.

**O gate permanece em R1, e nada nesta linha o move.** WP01 tornou o instrumento
capaz de explicar uma falha; WP03 tornou o servidor observável enquanto ele
falha; WP04 até aqui produziu um teto de carga medido e nenhuma evidência de
estabilidade — os degraus que promovem são dois finais de ≥12 h em dias
diferentes, e nenhum rodou. Regra G2 é explícita: uma falha do instrumento
reprova a campanha, não o produto.
**Origem:** `docs/reports/2026-08-01-production-readiness-audit.md`.
**Pré-condição absoluta:** R0 concluído, commit limpo e `build/check.sh`
integralmente verde.

Este diretório detalha os três níveis posteriores à correção dos bloqueadores.
Os nomes R1/R2/R3 são **readiness gates**, não novas fases de produto: nenhum
deles autoriza adicionar features sem relação com a evidência que o gate pede.

## Documentos

**Se você está voltando ao projeto depois de um tempo, comece por
[`ESTADO.md`](ESTADO.md)** — o mapa: onde o portão está, o que falta, e quais
decisões esperam pelo dono. Os documentos abaixo são precisos e densos; aquele é
para se orientar antes de precisar deles.

| Gate | Objetivo | Plano |
|---|---|---|
| R1 | liberar piloto controlado | [`R1-controlled-pilot.md`](R1-controlled-pilot.md) |
| R2 | liberar produção restrita | [`R2-restricted-production.md`](R2-restricted-production.md) |
| R3 | alcançar maturidade geral, se essa ambição for aceita | [`R3-general-maturity.md`](R3-general-maturity.md) |

**A ambição foi declarada em 2026-08-03**, e o R3 §1 exige que ela seja
registrada por ADR antes de qualquer implementação.
[`R3-programa-sem-limitacoes-bloqueantes.md`](R3-programa-sem-limitacoes-bloqueantes.md)
é essa instanciação: ele **não contorna o R3**, escolhe quais trilhas dele o
gatilho do dono autoriza e em que ordem. Sua tese é que *"sem limitações
bloqueantes" é muito mais barato que "sem limitações"* — as três limitações
bloqueantes têm instrumento nomeado e medido, e as caras não são bloqueantes.
**A Fase 0 dele é terminar o R2**, então ele não compete com este diretório: o
sequencia.

O instrumento por limitação vem de
[`../runtime-feasibility-study.md`](../runtime-feasibility-study.md), auditado
adversarialmente em
[`../runtime-feasibility-audit-2026-08-03.md`](../runtime-feasibility-audit-2026-08-03.md);
a conclusão de ambos é que **o runtime não é o instrumento** para a maioria
delas.

O backlog resumido continua em
[`../2026-08-01-production-readiness-remediation.md`](../2026-08-01-production-readiness-remediation.md).
Os planos deste diretório são a decomposição executável daquele backlog.

O veredito e o ledger de risco do nível atual estão congelados em
[`R1-freeze.md`](R1-freeze.md). “R1 promoted” não significa produção geral:
significa somente o perfil limitado descrito naquele documento.

## Progressão

```text
R0 — candidato testável
  |
  v
R1 — piloto controlado
  |  shutdown real, unit operacional, proxy real, contrato documental
  v
R2 — produção restrita
  |  instrumento confiável, soak do candidato, capacidade, segurança, canário
  v
R3 — maturidade geral (opcional)
     backend/plataforma/runtime/ecossistema/release com decisões por evidência
```

Não há promoção parcial. Um item pode ser:

- **concluído**, com evidência e hash;
- **risco aceito**, com owner, escopo, validade e mitigação;
- **fora do perfil**, explicitamente excluído do produto suportado.

“Existe um teste”, “funcionou na máquina do autor” ou “o resultado histórico é
parecido” não são estados de encerramento.

## Regras globais

### G1 — um candidato é uma identidade, não um diretório

Toda campanha registra:

- commit e tree hash, com working tree limpo;
- Odin version/commit e hash do compilador ou bundle;
- hash do binário servidor e de cada gerador;
- kernel, CPU, memória, governor, NUMA, limites e afinidade;
- configuração efetiva de Druse, proxy, supervisor e carga;
- início/fim UTC e comando exato.

Qualquer mudança em código, toolchain, configuração load-bearing ou instrumento
cria um candidato novo. Evidência não é transferida por semelhança.

### G2 — instrumento precisa provar a si mesmo

Antes de medir o produto, cada instrumento tem:

- controle positivo que precisa ficar verde;
- mutante/controle negativo que precisa ficar vermelho;
- razão esperada da falha;
- accounting fechado: contados = classificados + explicitamente injetados;
- resultado automático, não decidido depois de olhar gráficos.

Uma falha do instrumento reprova a campanha, não o produto. Ela precisa ser
corrigida e a campanha repetida desde o início.

### G3 — critérios são congelados antes do run

SLOs, tolerâncias, exclusões e regras de abort são commitados antes do primeiro
run válido. Alterar critério depois do resultado invalida o run anterior para a
decisão de promoção, ainda que ele continue útil como diagnóstico.

### G4 — local, host dedicado e produção respondem perguntas diferentes

| Ambiente | Responde | Não responde |
|---|---|---|
| gate local | corretude determinística, API, mutações | estabilidade longa e capacidade da máquina-alvo |
| host dedicado | capacidade, leak, tail, kernel, proxy | comportamento do tráfego/infra reais |
| canário | composição real, operação e rollback | capacidade máxima isolada |

Nenhum ambiente substitui outro.

### G5 — mudanças públicas exigem decisão

Planos podem nomear uma necessidade pública, mas não inventam assinatura. Toda
mudança em `web` exportado passa pelos guardrails existentes, ADR, ledger,
documentação, exemplo, teste comportamental, custo e rollback.

### G6 — evidência fica fora do artefato distribuído

Resultados vão para `evidence/YYYY-MM-DD-<campaign>/`, com `manifest.txt`,
`SHA256SUMS`, logs brutos e análise derivada. Código de gate fica em `build/`,
harness em `ops/` ou `bench/`, e documentação ativa em `docs/`. O release
continua pequeno e respeita `.gitattributes`/`export-ignore`.

## Dependências entre work packages

| Item | Depende de | Por quê |
|---|---|---|
| R1 inteiro | R0 | não se mede um candidato com P0 ou gate vermelho |
| proxy real R1 | perfil suportado preliminar | timeouts, TLS, headers e buffering precisam de uma promessa concreta |
| soak R2 | R1 operacional + instrumento R2.1 | o run deve exercitar a topologia candidata e conseguir explicar falhas |
| capacidade R2 | artefato idêntico ao soak | números de outra build não definem o envelope do candidato |
| canário R2 | soak, segurança e rollback | produção não é o lugar de descobrir que o rollback não existe |
| qualquer R3 | decisão explícita de ambição | R3 aumenta custo permanente e não é necessário para produção restrita |

## Estrutura de execução por gate

Cada plano segue a mesma sequência:

1. **Entrada:** provar que as pré-condições existem.
2. **Análise:** responder as perguntas que ainda poderiam mudar o desenho.
3. **Implementação:** editar os menores arquivos capazes de fechar o achado.
4. **Controles:** fazer os testes distinguirem presença de mecanismo.
5. **Campanha:** medir no ambiente apropriado.
6. **Evidência:** preservar bruto, manifesto, hashes e análise.
7. **Revisão:** classificar riscos e decidir promoção.
8. **Freeze:** atualizar contrato, ledger, runbook e gate principal.

## Convenção de evidência

Cada campanha cria, no mínimo:

```text
evidence/YYYY-MM-DD-<campaign>/
  manifest.txt
  SHA256SUMS
  commands.txt
  environment.txt
  config/
  raw/
  analysis/
  verdict.md
```

`verdict.md` cita arquivos de `raw/` e `analysis/`; não substitui nenhum deles.
Segredos, certificados privados, tokens e dados de cliente nunca entram no
pacote.

## Board de promoção

Ao final de cada gate, uma revisão responde somente:

1. O candidato é exatamente o que foi medido?
2. Todos os critérios pré-registrados foram avaliados?
3. Toda falha foi classificada e toda exclusão estava pré-registrada?
4. Existe P0/P1 aberto sem mitigação formal?
5. O rollback foi executado, não apenas descrito?
6. O perfil suportado corresponde ao que foi provado?

Qualquer “não” mantém o nível anterior.
