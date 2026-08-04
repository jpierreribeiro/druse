# R2-WP04 — os finais, do jeito que se executa

**Status: ESCADA EM EXECUÇÃO desde 2026-08-04.** Os finais continuam **não
iniciados** e dependem de um rehearsal verde a f = 0,06 (§2, linha 6).

Este arquivo existe para que retomar os finais seja apertar botões, e não
re-derivar decisões. Ele **não autoriza** nada: os runs começam quando o dono
manda (`ESTADO.md` §8).

Quem manda aqui é
[`ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md`](../../ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md).
Se este runbook o contradisser, **o pré-registro é a verdade e este arquivo está
velho**.

---

## 1. Onde a escada está, antes de qualquer comando

**Host de registro:** `44.212.50.252` (§3.7 do pré-registro). O anterior foi
perdido; não o use.

**Taxa vigente:** f = 0,06, agregado 960/s — a **sétima** emenda (§4.7).

Os degraus já rodados nesta escada estão em
[`../../evidence/2026-08-04-r2-wp04-ladder/`](../../evidence/2026-08-04-r2-wp04-ladder/),
com o veredito e a atribuição de recusas de cada um. Leia o README de lá antes de
rodar qualquer coisa: ele diz por que a taxa desceu e o que o rehearsal decide.

**A regra que governa tudo abaixo:** o C22 já usou a **única** descida permitida.
Não há f = 0,04. Se o rehearsal a f = 0,06 contar recusa **atribuível à carga**,
o R2-WP04 **para** e o resultado é um achado de capacidade sobre
`max_handlers = lanes` para o R2-WP05.

## 2. Pré-condições, verificáveis antes de gastar 12 h

| | O quê | Como confere |
|---|---|---|
| 1 | o checkout no host contém a emenda vigente | `git -C ~/soak-runs/repo log --oneline -1` bate com o do laptop |
| 2 | árvore limpa no host | `run-soak.sh` aborta com exit 4 se não for um checkout git limpo |
| 3 | qualificação do host válida | **vale 7 dias** (§10). A de `44.212.50.252` é de **2026-08-04 → expira 2026-08-11**. Depois disso, `preflight.sh` + `smoke.sh` de novo antes do primeiro degrau |
| 4 | disco | ~10,2 GiB por final, medidos. O `preflight.sh` **deriva** a exigência da taxa oferecida com piso de 25 GiB, e é ele quem recusa |
| 5 | artefatos preservados | `~/ladder3/` no host, e o pacote versionado em `evidence/2026-08-04-r2-wp04-ladder/`. Runs vermelhos não se apagam |
| 6 | **os finais estão liberados?** | **só depois de um rehearsal verde a f = 0,06.** O C22 já usou a única descida permitida (§4.7). Não rode um final sem esse degrau |

O host **não alcança o GitHub**. A transferência é `git bundle` ou
`git clone --depth 1` + `rsync` (o clone raso preserva o SHA real, ~20 MB).

## 3. O bloco de ambiente — as seis taxas são obrigatórias

**O `commands.txt` do pacote do smoke não lista as variáveis de taxa.** Ele foi
escrito antes da quarta emenda. Executá-lo como está roda nos defaults do
`run-soak.sh`, que são f = 1,00 — 15.685/s, dez vezes a taxa registrada — e o
artefato reprova no C21 depois de doze horas gastas. É a armadilha mais cara
deste degrau e ela não tem gate.

```bash
export DRUSE_ODIN_BIN=$HOME/odin-pinned/odin
export PATH=$HOME/odin-pinned:$PATH

# affinity de registro (§3.1) — NUNCA alterar por variável no prompt.
# Mudar isto é emenda ao pré-registro, commitada antes do run. C18 recusa.
export DRUSE_SOAK_SERVER_CPUS=0,1,4,5
export DRUSE_SOAK_GENERATOR_CPUS=2,3,6,7
export DRUSE_SOAK_LANES=2

# as taxas da emenda VIGENTE. C21 lê isto no manifesto e compara com a tabela
# em vigor -- não com uma cópia colada aqui.
export DRUSE_SOAK_HEALTH_RATE=20
export DRUSE_SOAK_TINY_RATE=600
export DRUSE_SOAK_JSON_ENCODE_RATE=90
export DRUSE_SOAK_JSON_DECODE_RATE=240
export DRUSE_SOAK_BYTES_64K_RATE=9
export DRUSE_SOAK_WAIT_40MS_RATE=1
```

> **Os números acima são a SÉTIMA emenda (§4.7), f = 0,06, agregado 960/s.**
> Eles substituíram os da quinta (f = 0,10) em 2026-08-04, quando o C22 disparou
> no burn-in.
>
> **Não confie nesta cópia.** Ela já esteve errada uma vez — este runbook nasceu
> em 2026-08-03 com as taxas da quinta emenda, e no dia seguinte elas eram
> outras. **A fonte é a tabela de registro vigente no pré-registro**, hoje o
> §4.7; o C21 compara o manifesto com *ela*, não com este arquivo. Se as duas
> discordarem, este está velho.
>
> Isto é a mesma armadilha que o `commands.txt` do pacote antigo tem e que a §8.5
> abaixo descreve — só que aqui ela é minha.

Confira o manifesto **antes** de deixar um run de 12 h correr sozinho, contra o
pré-registro e não contra o bloco acima:

```bash
grep '_rate=' ~/soak-runs/soak/manifest.txt
# health_rate=20 tiny_rate=600 json_encode_rate=90
# json_decode_rate=240 bytes_64k_rate=9 wait_40ms_rate=1
```

## 4. A sequência

Ciclo = 120 s (`DRUSE_SOAK_PHASE_SECONDS`), então ciclos e minutos convertem
direto.

| # | Degrau | Comando | Duração |
|---|---|---|---:|
| 0 | qualificação | `bash ops/soak/preflight.sh` e `bash ops/soak/smoke.sh` | ~15 min |
| 1 | smoke | `DRUSE_SOAK_MAX_CYCLES=5 bash ops/soak/run-soak.sh ~/soak-runs 1` | 10 min |
| 2 | burn-in | `DRUSE_SOAK_MAX_CYCLES=15 bash ops/soak/run-soak.sh ~/soak-runs 2` | 30 min |
| 3 | rehearsal | `DRUSE_SOAK_MAX_CYCLES=60 bash ops/soak/run-soak.sh ~/soak-runs 3` | 2 h |
| 4 | **Final 1** | `bash ops/soak/run-soak.sh ~/soak-runs 12` | ≥12 h |
| 5 | re-qualificação | `preflight.sh` + `smoke.sh` outra vez (§9) | ~15 min |
| 6 | **Final 2** | idem, **em outro dia** | ≥12 h |

Cada degrau é graduado antes do próximo:

```bash
python3 ops/soak/analyze-soak.py ~/soak-runs/soak
```

O analisador **sempre sai 0 e sempre imprime um veredito** — o exit code não é o
resultado, o `verdict.json` é. Mova o diretório do run para `~/ladder3/<degrau>-<timestamp>/`
antes do próximo (`mv` para diretório existente **aninha**, não substitui).

**Forma do calendário:** Dia A = 2 h 40 de escada + 12 h de Final 1 ≈ 15 h.
Dia B = 15 min de re-qualificação + 12 h de Final 2. Os dois finais em dias
diferentes não é burocracia (§9): uma corrida boa sozinha não distingue "estável"
de "teve uma boa noite".

## 5. Um run de 12 h sobrevive à queda do ssh

`nohup` sozinho não basta se o shell remoto morrer no meio de um pipeline. Use
`setsid`, grave o PID, e **nunca** `pkill -f`:

```bash
ssh -i ~/Downloads/colossus.pem ubuntu@44.212.50.252 \
  'cd ~/soak-runs/repo && setsid nohup bash ops/soak/run-soak.sh ~/soak-runs 12 \
     >~/soak-runs/final1.log 2>&1 < /dev/null & echo $! > ~/soak-runs/final1.pid'

# acompanhar
ssh ... 'tail -5 ~/soak-runs/final1.log; ls ~/soak-runs/soak/cycles | wc -l'

# abortar, se for preciso — por PID, jamais por padrão
ssh ... 'kill $(cat ~/soak-runs/final1.pid)'
```

**Por que jamais `pkill -f`:** a linha de comando do próprio `ssh` contém o
padrão, e o `pkill` mata a sessão que o executou. Custou duas sessões nesta
campanha.

O `run-soak.sh` escreve `control/final-state.txt` em todo caminho de saída,
inclusive no abortado — um run morto antes disso produz FAIL explicável, e é
assim que deve ser.

## 6. As decisões, congeladas antes de ver qualquer número

**Degraus pré-finais, na taxa vigente:**

| Observado | O que acontece |
|---|---|
| analisador PASS e **zero** recusas de carga no rehearsal | segue para o Final 1 |
| recusa de carga em smoke ou burn-in | **não para a escada** — o C22 julga no rehearsal, porque 5 ou 15 ciclos não limitam uma probabilidade por ciclo (§4.2). Relate e siga |
| **recusa de carga no rehearsal** | **o R2-WP04 PARA.** A única descida permitida já foi usada em 2026-08-04 (§4.7); não existe f = 0,04. Vira achado de capacidade sobre `max_handlers = lanes` para o R2-WP05 |
| recusa dentro de janela de injeção declarada | contada e **relatada**, nunca abatida, e **não move a taxa** (§4.6): baixar a carga de fundo não remove 24 leitores lentos estacionados em duas lanes |
| vermelho por instrumento | conserta o instrumento; sob G1 isso é candidato novo e a escada recomeça no smoke |

Onde ler as recusas: **a saída de `ops/soak/attribute-refusals.py`**, não o total
cru do `final-stats.json` e muito menos os erros do `/health`. O C22 lê a linha
`attributable to load`; o total inclui as falhas injetadas, que descer a taxa não
remove. O C23 exige que essa divisão exista em todo degrau que relate recusa. Foi a lição do §4.1 — se o `/health` come a recusa é
sorte, se o servidor recusa alguma coisa é mecanismo.

**Finais (§9), sem exceção:**

| Resultado | O que vale |
|---|---|
| PASS + PASS | a alegação de estabilidade vale para o candidato; segue WP05 e WP08 |
| PASS + FAIL | **vermelho.** Não é melhor-de-dois. O próximo passo é atribuir a causa, não uma terceira corrida |
| FAIL + FAIL | vermelho, e o R2-WP04 para |

Uma terceira corrida só é licenciada depois que a discordância tem causa nomeada,
e essa causa ou é corrigida — **candidato novo, escada do zero** — ou é registrada
como limitação.

**G3, o que ele proíbe aqui:** mudar qualquer critério ou taxa depois de ver o
resultado de um final invalida aquele final para promoção. Se um número precisar
mudar, ele muda antes, em commit próprio, e a escada recomeça.

## 7. O pacote de evidência

Um diretório por final, `evidence/YYYY-MM-DD-r2-wp04-final-{1,2}/`, no formato
que `evidence/2026-08-03-r2-soak-smoke/` já estabeleceu:

```
verdict.md                  o veredito em prosa, citando o analisador
analysis/verdict.json       a graduação
raw/manifest.txt            identidade: commit, tree, binários, AS SEIS TAXAS
raw/cycles.csv              status e p99 por ciclo
raw/final-state.txt         como o run terminou
raw/final-stats.json        contadores do servidor, com saturation_refusals
raw/preflight.txt           a qualificação em que este run se apoiou
raw/injected.txt            as falhas deliberadas, declaradas
config/pre-registration.md  o pré-registro COM a §4.5
commands.txt                o bloco da §3 deste runbook, taxas incluídas
environment.txt             o host qualificado
SHA256SUMS                  de tudo acima
```

Runs vermelhos **entram no pacote**, não são apagados: são evidência sobre o
instrumento e sobre o produto. Foi assim que os quatro vermelhos de instrumento
do WP04 viraram o §6 das notas de execução.

## 8. Armadilhas, todas já pagas uma vez

1. **`pkill -f` mata a própria sessão ssh** — use PID (§5).
2. **`mv` para diretório existente aninha** em vez de substituir; o modo de falha
   é ler o artefato errado em silêncio.
3. **`git push` trava** no hook de pre-push, que roda o gate inteiro. Rode
   `bash build/check.sh` você mesmo (~30 min, como usuário não-privilegiado) e
   depois `git push --no-verify`.
4. **Nada pesado em paralelo com o gate** — `tests/wp98-interop` reprova por
   contenção. Confirme contra a `main` limpa antes de culpar sua mudança.
5. **As taxas não estão no `commands.txt` do pacote antigo** (§3). Confira o
   manifesto.
6. **`ops/soak/fixtures/` é gerado** por `build.py`; edite o gerador.
7. **Seis hashes de instrumento estão pinados** no §2.1 e o
   `check_soak_controls.sh` reprova na deriva. É intencional (G1) e disparou
   quatro vezes corretamente nesta campanha.

## 9. Depois dos finais

| | O quê |
|---|---|
| **WP05** | o envelope de capacidade: o knee e a curva de degradação. Entra com duas dívidas já nomeadas — a recomendação sobre `max_handlers = lanes` e o `/health` fora das lanes (§4.1), e o C22 se ele disparar |
| **WP08** | o pacote de decisão: PROMOVER PARA R2 / SEGURAR EM R1 / REVOGAR |
| **F8** | o limite de memória sob corpo hostil continua pinado por argumento; a asserção pertence a um run de 12 h |

Três coisas continuam esperando pelo dono e **nenhuma bloqueia os finais**:
o risco aceito dos degraus 2–6 do canário (assinado, revogável), a política de
assinatura de release que não existe, e o TRUST-001 como decisão de API pública.
Estão descritas no [`ESTADO.md`](ESTADO.md) §5.
