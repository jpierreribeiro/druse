# R2-WP08 — o pacote de decisão

**Status: MONTADO, AGUARDANDO OS FINAIS. 2026-08-05.**

Este é o pacote que o R2-WP08 exige antes de decidir **PROMOVER PARA R2 /
SEGURAR EM R1 / REVOGAR**. Ele está montado com tudo que já existe, e o que falta
está marcado como falta — não como pendência vaga.

**Ele não decide.** A decisão é a §4, e ela fica em branco até os dois finais
fecharem. Montar o pacote antes é o que separa "decidir com o que estava à mão"
de "decidir com o que o plano pediu".

---

## 1. Os dez itens do pacote (§9 do `R2-restricted-production.md`)

| # | Item | Estado | Onde |
|---|---|---|---|
| 1 | identidade do candidato | ✅ | `manifest.txt` de cada degrau; §2 e §2.1 do pré-registro (seis hashes de instrumento) |
| 2 | resultados R1 carregados | ✅ | `R1-freeze.md`, `evidence/archives/` |
| 3 | auditoria do instrumento | ✅ | R2-WP01 + os três defeitos achados nesta campanha (§3 abaixo) |
| 4 | **soak completo e repeats** | ⏳ **FALTA** — Final 1 em curso, Final 2 em outro dia | `evidence/2026-08-05-r2-wp04-default-ladder/` |
| 5 | envelope de capacidade | ⚠️ **parcial** — ver §2 | `evidence/2026-08-05-r2-wp05-knee/` |
| 6 | security / supply-chain | ✅ | R2-WP06 fechado; `evidence/2026-08-03-r2-wp06-assurance/`, BOM, `SECURITY.md` |
| 7 | relatório do canário | ✅ | degrau 1 entregue; degraus 2–6 risco aceito assinado — `evidence/2026-08-03-r2-wp07-shadow/` |
| 8 | riscos aceitos com validade | ✅ | §5 do `ESTADO.md`; canário em `R2-restricted-production.md` §8.1 |
| 9 | perfil suportado final | ✅ | `docs/supported-profile.md` + `build/check_supported_profile.sh` |
| 10 | plano de suporte e próxima revisão | ✅ | `docs/release-policy.md` (janela, sem backport), `docs/compatibility-policy.md` |

**Oito de dez prontos.** O item 4 é o que os finais entregam; o item 5 está
parcial e a §2 diz exatamente quanto.

## 2. O envelope de capacidade — o que existe e o que não

O R2-WP05 pediu seis perfis, matriz fatorial, recovery depois de sobrecarga e
comparação com pares. **Três experimentos entregaram parte disso:**

| Pergunta do envelope | Estado |
|---|---|
| knee / goodput | **medido**: não há knee até **10.000 req/s**; goodput ≥ 99,99% em oito pontos |
| latência sob carga | **medido**: p99 de 1,25 ms a 960/s até 1,79 ms a 10.000/s |
| efeito de `max_handlers` | **medido**: 1, 2, 4 e 8 lanes em três pontos de stress |
| recusa: mecanismo | **medido**: função da rajada de reconexão **e** da taxa |
| **recovery depois de sobrecarga** | ❌ não medido — **a lacuna mais importante**, e a própria região segura a nomeia |
| **matriz fatorial com `max_connections` e pool upstream** | ❌ não medido |
| **comparação com pares** | ❌ não medida, e o §8 do pré-registro do soak proíbe fazê-la sem harness que prove trabalho equivalente |
| **safe operating region publicada** | ✅ **escrita** em 2026-08-05 — `docs/safe-operating-region.md` |

**A decisão precisa saber disto:** o envelope está **incompleto**, e a §4 tem de
dizer se decide assim mesmo (com a região segura derivada do que existe) ou se
segura em R1 até completá-lo. **Não decidir isso é decidir por omissão.**

## 3. A auditoria do instrumento — três defeitos que esta campanha encontrou

Todos em harnesses de campanha, nenhum em produto. Estão aqui porque o item 3 do
pacote pede auditoria do instrumento, e um instrumento com três defeitos
corrigidos é mais confiável que um sem defeito conhecido.

| Defeito | O que produzia | Corrigido em |
|---|---|---|
| harness lia o servidor **de outro processo** | 200 no `/health` vindo de um órfão na porta; mediria contadores errados com confiança | `trap EXIT` + recusa de porta ocupada + checagem do próprio PID |
| harness reportava a **configuração de outro run** | "64,13% de goodput" que era o gerador nunca saindo da primeira taxa | taxas por ambiente + comparação `manifest ↔ plano` |
| piso de disco **constante fingindo derivação** | recusava hosts que cabiam e admitiria hosts que não | derivado da taxa, nas duas escalas (run e escada) |

**O padrão comum:** os três produzem **números confiantes**. Nenhum falha
ruidosamente. É a classe de defeito que o G2 existe para pegar, e foi pega
porque cada controle tem mutante.

## 4. A decisão

**Em branco até os dois finais fecharem.**

| Campo | Valor |
|---|---|
| Final 1 | ⏳ em curso desde `2026-08-05T10:28:37Z` |
| Final 2 | ⏳ não iniciado — **outro dia** (§9 do pré-registro) |
| veredito | — |
| decisão | **PROMOVER PARA R2 / SEGURAR EM R1 / REVOGAR** |

### 4.1 As três leituras possíveis, escritas ANTES dos resultados

Isto é G3 aplicado à própria decisão: se eu escrever os critérios de leitura
depois de ver os finais, a decisão vira racionalização.

**Ambos PASS, zero recusa de carga:**
> A alegação de estabilidade vale **para este candidato, neste envelope**. Mas o
> item 5 continua parcial: **sem recovery depois de sobrecarga**, sem matriz
> fatorial, e com **15 das 18 células de latência do SLO ainda `open`**.
>
> *(Corrigido em 2026-08-05: esta leitura dizia "sem região segura publicada", e
> ela foi publicada horas depois — `docs/safe-operating-region.md`. O resto da
> objeção sobrevive intacto, e é por isso que a correção não muda a recomendação.
> Deixo a nota porque um critério de leitura editado em silêncio depois de o
> mundo mudar é o que o G3 existe para impedir.)*
>
> A leitura honesta é **PROMOVER com o envelope declarado incompleto**, ou
> **SEGURAR** até completá-lo. Eu recomendo a segunda: promover com um critério
> de saída parcialmente aberto é o que o programa recusa em toda outra parte.
>
> **E o item que mais pesa nessa recomendação é o recovery.** Uma região segura
> que não sabe o que acontece quando a carga passa do topo e volta é uma região
> segura sobre o caminho de ida.

**Um PASS e um FAIL:**
> **Vermelho.** §9 do pré-registro: não é melhor-de-dois. O próximo passo é
> atribuir a causa, não uma terceira corrida.

**Recusa de carga em qualquer final:**
> O C22 vale como escrito. E o significado é maior que antes: **nem o default do
> produto bastou**, o que transforma o **B3** — tirar a `/health` das lanes de
> aplicação — de melhoria estrutural em caminho necessário, com o argumento mais
> forte que a campanha já produziu.

## 5. Os critérios de saída, conferidos um a um

| Critério | Estado |
|---|---|
| zero P0/P1 aberto sem aceite formal | ✅ — os abertos (`wp123`, `ingest-leak`, hosts caindo) são de instrumento e estão registrados |
| **soak ≥12 h PASS pelos critérios pré-registrados** | ⏳ **os finais** |
| toda falha classificada | ✅ nos degraus rodados; a confirmar nos finais |
| **SLO e safe operating region publicados** | ⚠️ **região segura escrita**; o SLO por workload **não pode ser fechado pelo caminho prescrito** — ver `R2-SLO-derivation-preregistration.md` |
| observabilidade mantém diagnóstico sob saturação | ✅ — R2-WP03; o snapshot da ADR-050 funcionou em todos os runs |
| proxy real, segurança e rebuild aprovados | ✅ — R2-WP06 e `evidence/2026-08-03-r2-proxy-framing/` |
| canário e rollback concluídos | ✅ com risco aceito assinado nos degraus 2–6 |
| **hash do artefato implantado = hash aprovado** | ✅ — provado na v0.11.0, com mutante |

**A região segura foi escrita** (`docs/safe-operating-region.md`) e o critério
deixou de estar totalmente em aberto. **O que sobra dele é o SLO por perfil**: 15
das 18 células de latência continuam `open` no §6.2 do pré-registro do soak, e
uma região segura não é um SLO — ela diz onde operar, não o que prometemos.

### 5.1 O SLO por workload: o prazo venceu e a fonte não serve

Duas coisas apareceram em 2026-08-06 e mudam o que a §4 pode afirmar:

1. **O prazo do §6.2 já foi perdido.** Ele exige o SLO commitado "before the
   final run", e **os dois finais rodaram sem ele**. Um SLO escrito agora não
   pode graduar nenhum dos dois sem ser "G3 read backwards" — o que o próprio
   §6.2 proíbe.
2. **A fonte prescrita não produz o dado.** O §6.2 manda derivar do knee do
   WP05, mas o harness do knee agrega os seis workloads numa distribuição só
   (`glob(raw/*.csv)`), descartando a dimensão que o SLO precisa. E o agregado
   mistura um workload com piso de 40 ms por projeto: o `p999=40.249 µs` do K1 é
   o `/wait/40ms`, não degradação.

**O que existe agora:** a regra de derivação está **congelada em commit próprio,
antes de qualquer número por workload existir** —
`R2-SLO-derivation-preregistration.md`. É a única proteção do G3 que sobrou, e
ela é auditável: um revisor aplica a regra aos números e tem de chegar às mesmas
células.

**A saída recomendada:** rodar a medição por workload (§2 daquele documento)
antes de decidir. ~30 min por ponto, não toca o produto, não cria candidato novo
sob o G1. **Não é saída** preencher as células com os agregados: seria publicar
como SLO um número que soma um `sleep` de 40 ms a um `/tiny`.

**Então continuam dois em aberto: o soak (tempo) e o SLO por workload (trabalho,
agora com causa nomeada).**
A §4.1 continua valendo: promover com um critério de saída parcialmente aberto é
o que o programa recusa em toda outra parte.

## 6. O que este pacote deliberadamente não faz

- **Não antecipa o veredito.** A §4 está em branco de propósito.
- **Não trata o envelope parcial como completo.** A §2 lista o que falta com
  nome, para que a decisão seja tomada sabendo.
- **Não esconde que o R2-WP04 rodou antes numa configuração errada.** O veredito
  daquela escada continua válido para aquela configuração, e a história está em
  `evidence/2026-08-05-r2-wp04-default-ladder/` §2.
