# R2-WP03 — pré-registro dos critérios e do budget de overhead

**Regra G3.** Este arquivo é commitado **antes** do primeiro run válido. Alterar
qualquer número abaixo depois de ver um resultado invalida aquele run para a
decisão de braço, ainda que ele continue útil como diagnóstico.

**Escopo.** Fechar AUD-P2-009: observabilidade que não compete com a carga
observada. Este WP **não promove nada**; o gate continua em R1.

**Campanha:** `evidence/2026-08-02-r2-observability-arms/`.
**Commit do pré-registro:** este arquivo, no commit imediatamente anterior ao
que adiciona o experimento.

---

## 1. O que está sendo comparado

Três arranjos, medidos no mesmo processo-alvo e sob a mesma saturação:

| Arranjo | Como a métrica sai do processo |
|---|---|
| `baseline` | `/stats` como rota comum, nas mesmas lanes da carga — **o que existe hoje** |
| `arm-a` | `/stats` num segundo `web.App`, porta própria, lanes próprias, admissão própria |
| `arm-b` | snapshot escrito por uma thread dedicada num arquivo local; amostrador lê o arquivo |

`baseline` não é um braço candidato. Ele é o **controle negativo**: se ele não
falhar, a saturação não foi estabelecida e o run inteiro é nulo (G2).

## 2. Taxonomia fechada de ausência

Toda amostra que não produz um valor precisa sair da campanha com **uma** destas
causas. Uma amostra ausente sem causa é uma falha do instrumento, não um dado.

| Causa | Significado |
|---|---|
| `ok` | valor obtido |
| `http_refused` | conexão recusada (curl 7) — a rede ou a admissão |
| `http_timeout` | tempo esgotado sem resposta (curl 28) |
| `http_empty` | conectou e o par fechou sem escrever (curl 52) |
| `http_recv_error` | erro de recebimento (curl 56) |
| `missing` | arquivo de snapshot não existe |
| `unreadable` | arquivo existe e a leitura falhou |
| `malformed` | schema ausente, versão diferente ou registro truncado |
| `stale` | snapshot lido, porém mais velho que `max_age` |

`http_*` são indistinguíveis entre si quanto à **origem**: qualquer uma delas
pode ser saturação de aplicação **ou** perda de rede. Essa ambiguidade é o
achado AUD-P2-009, não um defeito do amostrador — e é ela que os critérios
abaixo exigem eliminar.

## 3. Critérios de aceite, congelados

| ID | Critério | Limite | Reprova quando |
|---|---|---|---|
| **B1** | disponibilidade de amostra do braço escolhido, na janela de ocupação total de lanes | ≥ 99,9% | abaixo disso |
| **B1n** | *controle negativo:* disponibilidade do `baseline` na mesma janela | < 99,9% | igual ou acima — a saturação não foi estabelecida e o run é **nulo** |
| **B2** | causa registrada para amostras ausentes | 100% | qualquer ausência sem causa da tabela §2 |
| **B3** | p99 de latência da leitura da métrica sob saturação, braço escolhido | ≤ 10 ms | acima disso |
| **B4** | ambiguidade estrutural: o braço escolhido admite ausência atribuível a perda de rede | **zero caminhos de rede** entre métrica e amostrador | se existir um |
| **B5** | overhead de CPU do mecanismo de export, em processo ocioso, 60 s a 1 Hz | ≤ 60 ms de CPU total (≤ 0,10% de um core) | acima disso |
| **B6** | overhead de memória: `VmHWM` com export menos sem export | ≤ 2048 KiB | acima disso |
| **B7** | overhead de **lane**: `handler_dwell_ns` de um servidor ocioso com export ativo | exatamente 0 | qualquer valor > 0 |

### Por que B7 é o critério de overhead que importa

AUD-P2-009 é sobre a métrica competir com a carga. O recurso disputado é a
**lane**, não a CPU do host. Um mecanismo cujo custo de lane é exatamente zero
fecha o achado mesmo que custe CPU em outro lugar; um que custe uma fração de
lane não o fecha por mais barato que seja em CPU. B5 e B6 existem para limitar o
resto, não para substituir B7.

### Regra de INCONCLUSIVO para vazão — declarada antes, não depois

A comparação de **vazão** (requests/s com e sem export) roda como diagnóstico,
em ≥ 7 repetições pareadas alternadas. Ela **não** é critério de aceite, e o
motivo é G4: este host tem 4 CPUs compartilhadas e não responde perguntas de
capacidade.

Regra congelada: se a dispersão do próprio braço sem-export — `(max − min) /
mediana` sobre suas repetições — exceder **1,0%**, o host não resolve um efeito
de 1% e o resultado da vazão é **INCONCLUSIVE**. Inconclusivo é registrado como
inconclusivo. Não vira PASS e não vira budget novo.

## 4. Condição de saturação, definida antes do run

A janela de medição é aquela em que **todas** as lanes do servidor-alvo estão
comprovadamente ocupadas dentro de handlers, estabelecida por barreira
determinística (o mesmo mecanismo de `tests/c05-saturation`), não por rampa
probabilística. Um run cujo precondição de ocupação total não é atingida é
**nulo**, não vermelho: ele não mediu nada.

Amostras são agendadas a intervalo fixo dentro dessa janela. Uma amostra
agendada e não entregue conta como ausente, com causa.

## 5. O que este WP não vai medir

Declarado antes para que o diretório de evidência não seja lido depois como se
falasse do produto:

- **nenhum soak.** 12 h é R2-WP04 e exige host dedicado (R2-WP02).
- **nenhum envelope de capacidade.** Os números de vazão aqui são de um
  container de 4 CPUs e descrevem o container.
- **nenhuma promoção.** O gate continua em R1.
- **nenhuma medição com N > 1 processos.** A pergunta de agregação de ADR-049 é
  respondida por **desenho**, não por medição: o WP03 estabelece se o mecanismo
  escolhido *admite* agregação honesta e a que custo. Medir N > 1 é R3-WP10.

## 6. Decisões que este pré-registro deliberadamente não toma

Qual braço vence. O pré-registro fixa os critérios; o ADR registra o resultado.
Escrever os dois no mesmo commit seria escolher antes de medir.
