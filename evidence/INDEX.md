# Índice persistente de evidências

Atualizado em 2026-07-29 após integração, correções e campanhas AWS.

Conclusões consolidadas, revisão por revisão:
`RELATORIO-FINAL-2026-07-29.md`.

## Campanhas preservadas

| Campanha | Relatório | Arquivo | SHA-256 |
|---|---|---|---|
| Soak misto de 12 horas | `2026-07-28-vps-campaign/soak-live-v2/analysis/README.md` | `archives/uruquim-soak12h-20260729.tar.gz` | `ec2228f9bcea22c92dfd7d0809120c8acb44201e00fc1c090e3a0ffbdf17de54` |
| Reactor/pool bloqueante | `2026-07-29-blocking-pool-lab/20260729T182328Z/analysis/README.md` | `archives/uruquim-blocking-pool-lab-20260729.tar.gz` | `d2eef5dd2f0814a8a1283983ea6ab9c9d656328a036a341f694fc9384f4dcac1` |
| Histórico local antes do pull | — | `archives/uruquim-main-local-d2d3a97.bundle` | `6d9d90cc57bd58d2d9216f7ec3b0b553b36a7c9b3c2b7fb185ed7f102549846d` |
| JSON fused-target AWS | `2026-07-29-json-fused-target-aws/README.md` | `2026-07-29-json-fused-target-aws/uruquim-json-target-20260729.bundle` | `8c5cea9bd25019fae768f4ab0175508f0eded80035058fccae9f5774091d66f3` |
| Integração e gate de produção | `2026-07-29-integration-gate/README.md` | `2026-07-29-integration-gate/source-9b46a46.bundle` | `e3d07c1c1992ef1aaeba54efc20746c1ee6fa2010640fbb3992df772270d9852` |
| Offload bloqueante seletivo | `2026-07-29-selective-blocking-offload/README.md` | `2026-07-29-selective-blocking-offload/source.bundle` | `c57bc29f3017912f90db8002aa60e79eb2e9884ac7d35f917c618d62e72cb070` |

## Campanhas de 2026-07-28 a 2026-07-30, sem arquivo separado

Estas campanhas ficam no repositório como **relatório por corrida**, não como
fluxo bruto: o dado bruto que as gerou foi apagado do host de benchmark em
2026-07-30 (18,3 GB; o inventário completo dos 8.142 arquivos está commitado em
`2026-07-30-host-cleanup/inventory-before-delete.txt`). O que permanece é o que
permite recomputar cada número publicado.

| Campanha | Relatório | Diretório |
|---|---|---|
| Validação local | — | `2026-07-28-validacao-local/` |
| Release candidate | `2026-07-29-release-candidate/` | idem |
| Experimento de saturação (seis braços) | `docs/reports/2026-07-30-soak-failure-attribution.md` | `2026-07-30-saturation-experiment/` |
| Matriz open-loop de aplicação | `docs/reports/2026-07-30-open-loop-application-matrix.md` | `2026-07-30-application-matrix/` |
| Joelho do JSON aninhado | `docs/reports/2026-07-30-nested-json-knee.md` | `2026-07-30-json-knee/` |
| Profile do encode | `docs/reports/2026-07-30-encode-profile.md` | `2026-07-30-encode-profile/` |
| Protótipo do portão de tipo | `docs/reports/2026-07-30-encode-type-gate.md` | `2026-07-30-encode-prototype/` |
| Matriz de seis frameworks | `docs/reports/2026-07-30-six-framework-matrix.md` | `2026-07-30-six-framework-matrix/` |
| Marshal próprio | `docs/reports/2026-07-30-own-marshal.md` | `2026-07-30-own-marshal/` |
| Limpeza do host | — | `2026-07-30-host-cleanup/` |

**Duas campanhas de A/B estão preservadas e são inutilizáveis como medida de
teto**, de propósito: `2026-07-30-own-marshal/ab-30k-censored/` e
`ab-45k-censored/`. Nas duas o braço `ownmarshal` serviu 100% da taxa oferecida,
então a coluna de goodput reporta a configuração do gerador e não a capacidade
do servidor. Ficam porque o relatório explica por que foram descartadas, e uma
campanha descartada sem o descarte visível é uma campanha que alguém repete.

Os diretórios extraídos são a cópia de trabalho dos resultados. Os arquivos em
`archives/` são a segunda representação local, autocontida e verificada por
hash. Nada listado aqui depende de `/tmp` ou de uma VPS continuar disponível.

## Revisões

- Core usado no soak de 12 horas: `d2d3a972077135f9b12557c61d306f3fdd5c42fa`.
- Branch experimental do pool: `research/blocking-pool`, preservada também no
  arquivo da campanha.
- Toolchain do soak: `dev-2026-07-nightly:819fdc7`; cópia e hash estão no
  pacote da campanha.
- `origin/main` integrado: `ebb551b`.
- `main` local após o gate AWS completo: `9b46a46`.
- Pesquisa de offload seletivo permanece na branch
  `experiment/selective-blocking-offload`, em `43af29b`; ela contém a
  integração de `9b46a46`, mas não foi incorporada à `main`.
- Campanha do marshal próprio: commit `528ae6a`, branch `perf/encode-prototype`,
  mesmo toolchain `dev-2026-07-nightly:819fdc7`. As duas variantes diferem por
  um único `-define` sobre esse commit e seus sha256 estão no manifesto da
  campanha.
