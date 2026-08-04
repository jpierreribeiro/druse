# Onde estamos — mapa do programa de prontidão

**Última atualização: 2026-08-04** — o R2-WP04 fechou (parado, §6.2).

Este arquivo existe para uma pessoa que volta ao projeto depois de um tempo e
precisa saber onde está antes de saber os detalhes. Os outros documentos deste
diretório são precisos e densos; este é o mapa.

**Regra deste arquivo:** ele é atualizado no mesmo commit que move um portão ou
fecha um work package. **Não há gate que force isso** — está dito aqui porque um
documento de orientação desatualizado é pior que nenhum, e essa é a falha que
este repositório costuma punir com um teste. Se você o encontrar contradizendo
`R2-restricted-production.md`, **aquele arquivo é a verdade** e este está velho.

---

## 1. O quadro em três frases

O Druse tem um programa de prontidão com três portões: **R1** (piloto
controlado), **R2** (produção restrita), **R3** (maturidade geral). O portão está
em **R1** desde 2026-08-02 e continua lá. O R2 exige evidência *medida*, e a
evidência que promove ainda não existe.

**A confusão mais comum é essa:** muito trabalho acontece e o portão não anda. É
o desenho funcionando. O programa recusa explicitamente "existe um teste",
"funcionou na máquina do autor" e "o resultado histórico é parecido" como estados
de encerramento.

## 2. Por que R2 é lento

"Produção restrita" não significa que o framework melhorou — significa que
alguém **mediu** que ele aguenta um envelope declarado, e preservou a medição
com hashes para que ela possa ser contestada depois.

O custo alto é deliberado. As seis regras globais estão no
[`README.md`](README.md); as duas que mais aparecem no dia a dia:

- **G2** — todo instrumento prova a si mesmo antes de medir o produto: um
  controle positivo que fica verde e um mutante que fica vermelho **pela razão
  esperada**. Um controle que só sabe recusar é indistinguível de um quebrado.
- **G3** — critérios são congelados **antes** do run. Mudar critério depois de
  ver o resultado invalida o run para promoção.

## 3. O R2 em oito peças

| | O que prova | Estado |
|---|---|---|
| WP01 | o instrumento consegue explicar uma falha | **fechado** |
| WP02 | o host e o candidato estão congelados | **fechado** |
| WP03 | o servidor é observável enquanto falha | **fechado** |
| **WP04** | **o candidato aguenta 12 h sem degradar** | **PAROU em 2026-08-04** por regra C22 — achado de capacidade, ver §6.2 |
| WP05 | qual é o teto de capacidade e como degrada | **é o próximo** — herda o achado do WP04 |
| WP06 | segurança e cadeia de suprimentos | **fechado em 2026-08-04** — os 2 itens decididos, ver §5 |
| WP07 | composição sob tráfego real | degrau 1 entregue; degraus 2–6 = risco aceito |
| WP08 | o freeze e a decisão PROMOVER / SEGURAR | depende de tudo acima |

**O WP04 era o gargalo e deixou de ser — não porque foi resolvido, mas porque
foi respondido.** Ele parou em 2026-08-04 com um achado (§6.2): descer a taxa
não faz a recusa chegar a zero, então não existe corrida de 12 h a rodar neste
candidato. **O gargalo passou a ser uma decisão de produto sobre
`max_handlers = lanes`**, e essa é sua (§6).

## 4. O que 2026-08-03 produziu — e o que não produziu

**Esta seção é sobre o dia anterior**, e vale mantê-la porque os instrumentos que
ela descreve são o que tornou 2026-08-04 possível. O que aconteceu em 08-04 está
no §6.2.

**Produziu duas coisas, e vale separá-las.**

**O ponto de operação.** A campanha tentava ~15.700 req/s e quebrava. Está
medido onde o servidor **para de recusar conexões**: ~2.350 req/s agregados com
2 lanes. Isso é 15% do que se tentava. Não é o Druse piorando — é a campanha
sendo honesta pela primeira vez sobre um host com dois núcleos físicos para o
servidor. A escada completa está em
[`../../ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md`](../../ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md) §4.1.

**Os instrumentos.** Fuzzer de wire, comparação de framing pelo proxy real,
harness de shadow com contabilidade fechada, e verificação de que o artefato
implantado é o aprovado. Nada disso é evidência sobre o produto; é o que torna a
evidência possível.

**O que NÃO produziu: nenhuma prova de que o Druse é estável em produção.** Isso
viria das duas corridas de 12 h — e em 2026-08-04 ficou medido que elas **não são
rodáveis** neste candidato, o que é uma resposta diferente de "ainda não
rodaram". Ver §6.2.

### 4.1 Achados abertos, que não bloqueiam nada mas não somem

| ID | O quê | Onde |
|---|---|---|
| **TRUST-001** | `trust_proxies` casa prefixos de texto sem âncora: escrever `10.0.0.1` para nomear um proxy também confia em ~110 outros endereços, e não há forma de dizer "exatamente este". Não alcançável por um cliente do outro lado do proxy | `planning/r2-wp06-endpoint-review.md` |
| **SHADOW-001** | `web.serve` recebe porta e **nenhum endereço** — não dá para pedir a uma aplicação Druse que escute só em loopback. Conter é trabalho do firewall do host | `R2-restricted-production.md` §8.1 |
| **F8** | limite de memória sob corpo hostil continua pinado por argumento, não por teste. A asserção pertence ao run de 12 h | `planning/security-backlog-reconciliation.md` |

## 5. O que está esperando por você

**Duas das três foram decididas por mim em 2026-08-04**, sob autorização
explícita — ver [`DECISOES-2026-08-04.md`](DECISOES-2026-08-04.md). Resta o risco
aceito do canário (já assinado) e a decisão de produto do §6 item 2, que é a que
destrava o R2.

### 5.1 Canário, degraus 2–6 — risco aceito (ASSINADO em 2026-08-03)

O plano prevê rampa de tráfego real: 1%, 5%, 25%, 50%, 100%. Não existe tráfego
real neste projeto. "Bloqueado" não é um estado de encerramento — os três
permitidos são concluído, **risco aceito** e fora do perfil.

**O que fica descoberto:** qualquer falha que só apareça sob distribuição real —
cabeçalhos de clientes que ninguém previu, padrões de conexão de CDN, picos
correlacionados, e o comportamento do rollback com usuários em voo.

**Mitigação em vigor:** o degrau 1 (shadow) roda antes de qualquer promoção;
alertas e runbooks do R1 ativos; rollback ensaiado e medido em 3 s; o primeiro
serviço real **é** o degrau 2 e será tratado como canário, com abort automático.

O texto formal está em `R2-restricted-production.md` §8.1.

### 5.2 Assinatura de release — DECIDIDA em 2026-08-04

A política existe: [`../../docs/release-integrity-policy.md`](../../docs/release-integrity-policy.md).

**Releases são verificados por hash e não assinados, e a nota de release diz
literalmente isso** — a palavra "assinado" fica proibida enquanto a política
valer.

A razão: assinatura prova **custódia**, não integridade, e a integridade já está
provada por hash num registro versionado. Hoje não há um "quem" separado — a
chave estaria na mesma máquina do build, usada por quem commita o hash. Isso
adicionaria uma alegação de garantia que a custódia não sustenta.

**Três gatilhos nomeados** tornam a assinatura obrigatória: um segundo
mantenedor, distribuição fora do repositório, ou um adotante pedindo. A decisão
não é permanente por inércia.

### 5.3 TRUST-001 — CORRIGIDO em 2026-08-04

Uma entrada terminada em `.` ou `:` é prefixo; qualquer outra casa o endereço
inteiro. `tests/trust001-anchoring`, seis casos sobre socket real, com mutante.

**O defeito era pior do que o catálogo dizia.** A documentação justificava
casamento textual em vez de CIDR com a frase *"a wrong prefix can only fail to
trust one you did"* — e essa afirmação era **falsa**: `"127.0.0.1"` confiava em
~110 endereços vizinhos. Uma justificativa de desenho que a implementação não
satisfaz é pior que nenhuma, porque quem lê orça risco contra ela.

Mantive textual **contra** CIDR de propósito: parsing de IPv4/IPv6 e aritmética
de máscara são três lugares para estar sutilmente errado numa fronteira de
segurança, e aqui não há revisão humana para pegar. O custo está dito — `/25` não
tem grafia, o que já era verdade antes.

É quebra de compatibilidade, registrada no `CHANGELOG.md` com a ação necessária.

## 6. O que falta, em ordem

1. **WP05** — e ele mudou de natureza. Não é mais só "o envelope de capacidade":
   herda a pergunta que parou o WP04 — **separar a variável taxa da variável
   concorrência de reconexão**. Precisa de instrumento novo, porque o
   `run-soak.sh` fixa as conexões por carga e reabre todas por ciclo.
2. **Decidir o que fazer com `max_handlers = lanes`.** Se a rajada for a
   variável, a saída é mais lanes ou tirar a `/health` das lanes de aplicação —
   o mesmo argumento que a ADR-050 já fez para métrica. **É decisão de produto,
   não de campanha.**
3. **WP08** — o pacote de decisão e o veredito.

**Os finais voltam à mesa quando existir uma configuração em que a recusa de
carga chegue a zero.** Não é calendário; é uma pergunta aberta.

### 6.1 Uma consequência do G1 que custou duas escadas, e vale saber antes

**Toda mudança de taxa reinicia a escada no smoke.** G1 conta configuração
load-bearing como identidade do candidato, e carga oferecida é load-bearing por
construção. O reinício é **smoke (10 min) + burn-in (30 min) + rehearsal (2 h)
≈ 2 h 40** — e o rehearsal não é opcional: é o único degrau com ciclos
suficientes para limitar uma probabilidade por ciclo.

Em 2026-08-04 isso foi pago **duas vezes**: uma pela troca de host (§3.7) e outra
pela descida de taxa do C22 (§4.7). **Foi dinheiro bem gasto:** o rehearsal
completo é justamente o degrau que produziu as 7 recusas de carga que
responderam a pergunta. Um atalho teria levado a doze horas desperdiçadas em vez
de duas.

### 6.2 A escada rodou inteira e o WP04 PAROU — com um achado, não com uma falha

**2026-08-04.** O host novo (§3.7) qualificou e a escada rodou até o fim:

| Degrau | Taxa | Analisador | Recusas: total / injetadas / **carga** |
|---|---|---|---|
| smoke, 5 ciclos | f = 0,10 | **PASS** | 56 / 56 / **0** |
| burn-in, 15 ciclos | f = 0,10 | **PASS** | 105 / 104 / **1** ← desce a taxa |
| smoke, 5 ciclos | f = 0,06 | **PASS** | 1 / 0 / **1** |
| burn-in, 15 ciclos | f = 0,06 | **PASS** | 72 / 72 / **0** |
| **rehearsal, 60 ciclos** | f = 0,06 | **PASS** | 461 / 454 / **7** ← **PARA** |

**Os finais de 12 h não rodaram e não vão rodar neste candidato.**

**Leia isto antes de concluir qualquer coisa: o produto passou em tudo.** Todo
degrau passou em todos os critérios pré-registrados. O rehearsal deu `/health`
com zero erros em 60 ciclos, p99 mediano 1.196 µs e inclinação de memória de
49,0 KiB/h **avaliada** contra teto de 1 MiB/h — vinte vezes de margem.

O que parou foi o **C22**, uma regra de campanha sobre qual taxa pode ser
certificada para um final. Um final de 12 h nesta taxa espera ~0,9 recusa em
`/health`, e o critério 1 permite zero.

**O achado, que é o que o WP04 entrega:** descer a taxa **não move o piso de
recusa** — f = 0,10 deu 1 em 20 ciclos, f = 0,06 deu 8 em 80. E todas as recusas
caem em **rajada de reconexão**, não em carga permanente. A hipótese para o WP05
é que a variável seja a rajada de ~624 conexões por ciclo contra
`max_handlers = lanes = 2`, e não a taxa. Se for, **nenhuma taxa converge**, e a
resposta é mais lanes ou uma admissão que não recuse a sonda de liveness.

O veredito completo está em
[`../../evidence/2026-08-04-r2-wp04-ladder/verdict.md`](../../evidence/2026-08-04-r2-wp04-ladder/verdict.md).

**Duas coisas que essa linha esconde e valem saber.**

A primeira é que o C22 **precisou ser emendado antes de poder disparar**. Ele
dizia "recusa do servidor > 0", e o smoke contou 56 recusas que a telemetria por
segundo mostrou terem acontecido *todas no mesmo segundo* em que 24 leitores
lentos foram injetados. A sexta emenda (§4.6) corrigiu o critério para ler
recusa **atribuível à carga**, e essa emenda favorecia continuar — está escrita
em vez de aplicada em silêncio por isso. No degrau seguinte o mesmo critério
reprovou o run.

A segunda é o que o número diz: **o limiar de recusa é propriedade do framework
num ambiente, não do framework sozinho.** Três hosts, três taxas de registro. É a
entrada mais útil que esta escada produziu para o WP05, e não é o Druse piorando.

O pacote vive em
[`../../evidence/2026-08-04-r2-wp04-ladder/`](../../evidence/2026-08-04-r2-wp04-ladder/)
e cresce a cada degrau — desta vez desde o primeiro, porque quando o host
anterior morreu as conclusões sobreviveram e os dados brutos não.

### 6.3 As sete emendas, para quem quiser auditar a cadeia de decisões

O pré-registro foi emendado sete vezes, **sempre antes do run que a emenda
governa**, e a cadeia inteira é auditável:

| | O quê |
|---|---|
| §3.1 (1ª, 2ª) | host, duas vezes em 2026-08-02 |
| §3.6, §3.4, §3.3 | canal de métrica, custo declarado, limitação das medições antigas |
| §4.1 (4ª) | as taxas re-derivadas por medição — a escada de 10 pontos |
| §4.5 (5ª) | f = 0,10 + **C21** (a taxa do run é a da emenda vigente) + **C22** (piso da descida) |
| §3.7 (3ª de host) | o host novo, depois que o anterior morreu |
| §4.6 (6ª) | **C22 corrigido**: recusa *atribuível à carga* + **C23** (a atribuição é obrigatória) |
| §4.7 (7ª) | a descida para f = 0,06, disparada pelo próprio C22 |

**A §4.6 é a que merece escrutínio, porque me beneficiou** — ela impediu uma
descida que teria custado 2h40. As duas defesas estão lá e ambas são mais velhas
que o run. E no degrau seguinte o mesmo critério corrigido reprovou o run e
cobrou as 2h40 mesmo assim.

O passo a passo executável está em
[`R2-WP04-finals-runbook.md`](R2-WP04-finals-runbook.md) — **e os finais que ele
descreve não estão liberados** (§6.2).

## 7. Como retomar

- **Host de campanha:** `44.212.50.252`, usuário `ubuntu`, chave
  `~/Downloads/colossus.pem`. c5.2xlarge `i-08c31e483e890fd16`, us-east-1a,
  Ubuntu 24.04.4, kernel `6.17.0-1017-aws`, Xeon 8275CL, 4 núcleos físicos com
  irmãos SMT. **Qualificado em 2026-08-04** — `preflight=pass`, `smoke=pass`,
  sem override. Validade 7 dias, expira **2026-08-11**. A troca de host está
  registrada na **§3.7** do pré-registro; o host anterior
  (`184.72.201.140`) foi perdido e **não** deve ser usado.

  > **Preparação do host, para reproduzir:** `clang`, `docker.io`, `golang-go`;
  > Odin fixado via `ops/ci/install-odin.sh` em `~/odin-pinned` (hash conferido,
  > `819fdc7`); `memlock unlimited` em `/etc/security/limits.d/99-druse-campaign.conf`
  > **e** `/etc/systemd/system/user@.service.d/99-druse.conf`; `ubuntu` no grupo
  > `docker`; e **auto-upgrade desligado** — `systemctl disable --now
  > unattended-upgrades.service apt-daily-upgrade.timer apt-daily.timer`. Esta
  > última não é higiene opcional: foi um kernel trocado sozinho que criou a §3.7.

  > **Histórico da máquina anterior, se alguém a encontrar:**
  > `184.72.201.140` / `i-05c3c8168b18776a5` travou o `sshd` — TCP aceita, banner
  > nunca chega, sobrevive a reboot — e tinha derivado para o kernel
  > `7.0.0-1009-aws` sozinha. Os artefatos de `~/ladder2/` e `~/rate-derivation/`
  > estão só nela; se for recuperada, **tire um snapshot do EBS antes de
  > qualquer coisa**.

  > **INACESSÍVEL desde 2026-08-03, ~23h (BRT).** O WP04 foi autorizado a
  > começar e não começou por isto. O sintoma é específico e vale registrar
  > porque descarta as causas fáceis: **a porta 22 aceita a conexão TCP e o
  > banner do SSH nunca chega** (`Connection timed out during banner exchange`),
  > cinco tentativas. As portas 80 e 12345 recusam corretamente no mesmo
  > instante, então "aberto" ali é significativo e a instância não está parada
  > nem sem rota — alguma coisa escuta em 22 e não completa handshake.
  >
  > Isso é sshd travado ou host em thrashing/disco cheio, não rede. **Não há
  > CLI nem credencial AWS nesta máquina** (`aws` não instalado, `~/.aws`
  > inexistente), então diagnosticar pelo console ou reiniciar a instância é
  > ação do dono. O caminho mais curto é o console da EC2: *system log* e
  > *instance status checks* dizem qual dos dois é em um minuto.
  >
  > **A qualificação do host expira em 2026-08-10** (vale 7 dias, §10 do
  > pré-registro). Se ele voltar depois disso, `preflight.sh` e `smoke.sh`
  > rodam de novo antes do primeiro degrau — 15 min, não um problema.
  >
  > **Atualização 2026-08-04, 02:58 UTC — o reboot não resolveu, e o log de
  > sistema trouxe um achado maior que a queda.** A instância reiniciou às
  > 02:40:04 UTC, o `ssh.service` subiu verde no boot, e dezoito minutos depois
  > o banner continuava não chegando. O `ssh.socket` do Ubuntu 26.04 é
  > socket-activated, o que explica o sintoma exatamente: o systemd aceita o TCP
  > e o `sshd` nunca é gerado.
  >
  > **O kernel mudou: `7.0.0-1006-aws` → `7.0.0-1009-aws`.** O §3.1 do
  > pré-registro pina o 1006. Sob G1 isso é ambiente diferente, e vale mesmo que
  > o SSH volte: **o host precisa de emenda commitada antes de qualquer run**,
  > não só de re-qualificação. Um unattended-upgrade instalou kernel novo entre
  > a qualificação e agora — e é também a explicação mais provável da queda.
  >
  > O buraco de controle que isso expôs está fechado (`3901514`): o
  > `preflight.sh` agora **recusa** um host que se atualiza sozinho, nomeando os
  > units, com override carimbado e mutante. O §3 já exigia "o host não roda mais
  > nada na janela"; faltava enumerar o auto-atualizador.
  >
  > **O que está só naquele disco:** os artefatos de `~/ladder2/` e
  > `~/rate-derivation/`. **Nenhum pacote de burn-in ou rehearsal foi commitado
  > em `evidence/`** — as conclusões estão no pré-registro §4.2/§4.3, os dados
  > brutos não. Antes de qualquer stop/start/terminate, **tire um snapshot do
  > volume EBS**: é barato, não destrutivo, e é o que impede perder isso.
  >
  > O bundle do candidato já está montado e verificado
  > (`git bundle`, 7,2 MB, história completa até `c8096b5`). Quando houver host,
  > a transferência é um `scp` e o resto é o runbook.
- **Affinity de registro:** servidor `0,1,4,5`, gerador `2,3,6,7`,
  `DRUSE_SOAK_LANES=2`. **Nunca alterar isso por variável de ambiente** — é uma
  emenda ao pré-registro, commitada antes do run.
- **Repositório no host:** `~/soak-runs/repo`, checkout git limpo. O host não
  alcança o GitHub; a transferência é por `git bundle`.
- **Artefatos preservados:** `~/ladder2/` (smoke, burn-in e rehearsal, cada um em
  diretório com timestamp) e `~/rate-derivation/` (os dez pontos da escada de
  taxa). Runs vermelhos são preservados, nunca apagados — são evidência sobre o
  instrumento.
- **Evidência versionada:** `evidence/2026-08-03-*` neste repositório.

Três armadilhas já pagas, para não redescobrir:

1. **`pkill -f` por padrão sobre ssh mata a própria sessão** — a linha de comando
   do ssh contém o padrão. Use PID ou script em arquivo.
2. **`mv` para diretório existente aninha em vez de substituir** — o modo de
   falha é ler o artefato errado em silêncio.
3. **`git push` trava** no hook de pre-push, que roda o gate inteiro. Rode o gate
   você mesmo e use `--no-verify`.

## 8. O que este arquivo não é

- **Não é uma promessa de prontidão.** O portão está em R1 e nada aqui o move.
- **Não é substituto de nenhum plano.** `R2-restricted-production.md` é o plano;
  o pré-registro da campanha é o contrato do run; os `verdict.md` em `evidence/`
  são os resultados. Este arquivo aponta para eles.
- **Não é gatilho para nada.** Nenhuma decisão registrada aqui autoriza começar
  um run — os runs começam quando o dono manda.
