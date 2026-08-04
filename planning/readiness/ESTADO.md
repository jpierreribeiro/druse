# Onde estamos — mapa do programa de prontidão

**Última atualização: 2026-08-03.**

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
| **WP04** | **o candidato aguenta 12 h sem degradar** | **falta a evidência que promove** |
| WP05 | qual é o teto de capacidade e como degrada | depende do WP04 |
| WP06 | segurança e cadeia de suprimentos | executado; 2 itens são decisão do dono |
| WP07 | composição sob tráfego real | degrau 1 entregue; degraus 2–6 = risco aceito |
| WP08 | o freeze e a decisão PROMOVER / SEGURAR | depende de tudo acima |

**O WP04 é o gargalo, e é gargalo de calendário, não de trabalho.** O
pré-registro exige **duas corridas de ≥12 h em dias diferentes**. Não é
burocracia: uma corrida boa sozinha não distingue "estável" de "teve uma boa
noite". Rodar as duas no mesmo dia produz um artefato que o próprio plano recusa
para promoção.

## 4. O que 2026-08-03 produziu — e o que não produziu

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
vem das duas corridas de 12 h, que não aconteceram.

### 4.1 Achados abertos, que não bloqueiam nada mas não somem

| ID | O quê | Onde |
|---|---|---|
| **TRUST-001** | `trust_proxies` casa prefixos de texto sem âncora: escrever `10.0.0.1` para nomear um proxy também confia em ~110 outros endereços, e não há forma de dizer "exatamente este". Não alcançável por um cliente do outro lado do proxy | `planning/r2-wp06-endpoint-review.md` |
| **SHADOW-001** | `web.serve` recebe porta e **nenhum endereço** — não dá para pedir a uma aplicação Druse que escute só em loopback. Conter é trabalho do firewall do host | `R2-restricted-production.md` §8.1 |
| **F8** | limite de memória sob corpo hostil continua pinado por argumento, não por teste. A asserção pertence ao run de 12 h | `planning/security-backlog-reconciliation.md` |

## 5. O que está esperando por você

Três coisas, de naturezas diferentes. **Nenhuma é urgente e nenhuma bloqueia o
WP04.**

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

### 5.2 Assinatura de release — falta uma política, não uma assinatura

O R2-WP06 pede "assinar checksums/release conforme política do projeto". **Não
existe política**: nenhum arquivo define chave, formato, custódia ou verificação.

Assinar com uma chave inventada durante um work package seria pior que não
assinar — uma assinatura cuja custódia ninguém decidiu não prova nada e convida a
ser confiada.

O WP08 já entrega a metade verificável: o hash do artefato implantado confere com
o aprovado. A assinatura acrescentaria *quem* aprovou. **Enquanto não houver
política, a nota de release diz "verificado por hash", não "assinado".**

### 5.3 TRUST-001 — é uma decisão de API pública

Consertar o casamento de prefixos muda o significado de uma API pública. A regra
G5 diz que um plano pode **nomear** a necessidade e não pode **inventar** a
assinatura. A necessidade nomeada: *uma entrada que signifique um endereço e
somente ele*.

## 6. O que falta, em ordem

1. **Final 1** — ≥12 h no host de campanha, a f = 0.10.
2. **Final 2** — outro dia, mesmo candidato, host re-qualificado antes.
   - ambos PASS → a alegação de estabilidade vale para o candidato;
   - um PASS e um FAIL → **vermelho**, e o próximo passo é atribuir a causa, não
     uma terceira corrida;
   - ambos FAIL → vermelho, e o WP04 para.
3. **WP05** — o envelope de capacidade, o knee e a curva de degradação.
4. **WP08** — o pacote de decisão e o veredito.

**Dois dias de calendário para a evidência que decide o R2.** Nada disso precisa
de você além de dizer para começar.

### 6.1 Uma consequência do G1 que vale saber antes

A taxa dos finais (f = 0.10) é diferente da que o rehearsal rodou (f = 0.15).
**G1 conta configuração load-bearing como parte da identidade do candidato**, e
carga oferecida é load-bearing por construção. Então a escada reinicia no smoke
antes dos finais.

**Correção de 2026-08-03 (tarde):** uma versão anterior deste parágrafo dizia
"smoke (10 min) e burn-in (30 min), ~40 min a mais". **Faltava o rehearsal**, e
ele não é opcional: no f = 0.15, quinze ciclos contaram 3 recusas e sessenta
contaram 345. Um burn-in verde não limita 360 ciclos — é exatamente o erro que a
§4.2 do pré-registro já nomeou quando seis minutos não previram trinta.

O reinício é **smoke (10 min) + burn-in (30 min) + rehearsal (2 h) ≈ 2 h 40**.
Continua não sendo um dia, e continua cabendo antes do Final 1 no mesmo dia.

Carregar os degraus antigos para a frente significaria citar verdes tomados a uma
taxa que a campanha não usa mais.

### 6.2 A quinta emenda está commitada; os finais não dependem de mais nenhum papel

A regra da §4.1 obrigava a taxa a descer "em seu próprio commit, antes do final".
Foi feito: **§4.5 do pré-registro** registra a tabela de f = 0.10 (agregado
1.586/s, 33% abaixo do teto livre de recusa), o C21 passou a nomear a emenda
vigente em vez de "a tabela acima", e o **C22** congelou o piso da descida —
f = 0.06 uma vez, e uma recusa lá **para o WP04** para atribuição em vez de uma
quarta descida.

O passo a passo executável — bloco de ambiente com as seis taxas, sequência,
como um run de 12 h sobrevive à queda do ssh, e as decisões congeladas — está em
[`R2-WP04-finals-runbook.md`](R2-WP04-finals-runbook.md).

## 7. Como retomar

- **Host de campanha:** `184.72.201.140`, usuário `ubuntu`, chave
  `~/Downloads/colossus.pem`. c5.2xlarge, 4 núcleos físicos com irmãos SMT.

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
