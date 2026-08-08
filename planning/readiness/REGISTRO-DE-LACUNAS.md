# Registro de lacunas — tudo que falta, com dono, portão e custo

**2026-08-08.** Criado porque sete das dez limitações do framework **não estavam
em plano nenhum**: nem critério de saída do R2, nem trilha do R3. Ficavam num
limbo em que ninguém as agendava.

**Decisão do dono (2026-08-08):** *"temos que corrigir tudo isso, mesmo numa
eventual pós-R3"*. Portanto **nada aqui é descartável.** Um item pode ser adiado,
não abandonado.

**Este documento é anexo do `R2-WP08-decision-package.md`.** A decisão de
promover ou segurar deve ser tomada sabendo o que fica em aberto.

---

## 0. Como ler

**Verificação** diz o que sustenta o item, e é a coluna que impede este registro
de virar lista de medos:

| marca | significa |
|---|---|
| **medido** | há artefato com número |
| **lido** | confirmado por leitura direta do código, com arquivo e linha |
| **relatado** | veio de auditoria e ainda não reverifiquei |

**Portão** é onde o item *deveria* ser resolvido, não onde está hoje.

---

## 1. Limitações do envelope — as dez

| ID | lacuna | verificação | portão | custo |
|---|---|---|---|---|
| **L1** | **nunca viu tráfego real** | medido (risco aceito assinado, R2-WP07 §8.1) | **R2 canário, degrau 2** | pôr em produção como canário |
| **L2** | **falha de handler custa o processo inteiro** | medido (`R3-WP10`: "hoje um fault custa 100% da capacidade e toda conexão em voo") | **R3-WP10** ✅ *já é trilha* | médio-alto |
| **L3** | **recuperação depois de sobrecarga não medida** | medido (ausência; `safe-operating-region.md` §5) | **R2** (barato) | ~2 h de host |
| **L4** | **uma classe de máquina, um mix** | medido | **R3, sem WP** ⚠️ | alto |
| **L5** | **três hosts mortos sob carga** | medido | **R2, bloqueante** | em investigação |
| **L6** | **SLO por workload: 15 de 18 células** | medido | **R2** | ~1 h de host |
| **L7** | **parada de 30 ms no ciclo 225** | medido (`FINDING-cycle-225.md`) | **R2, não bloqueante** | horas |
| **L8** | **contenção: `serve` não aceita endereço** | lido (`web/serve.odin:30`) | **pós-freeze** | pequeno |
| **L9** | **API pode quebrar (pré-1.0)** | medido (política publicada) | **R3-WP06** ✅ *já é trilha* | processo |
| **L10** | **custo de TLS não isolado; sem comparação com pares** | medido (ausência) | **R3, sem WP** ⚠️ | ~2 h de host + harness |

**Só L2 e L9 já têm trilha no R3.** L4 e L10 pertencem ao R3 e **não têm WP** —
precisam ser criados. L1, L3, L5, L6 e L7 são do R2.

---

## 2. Defeitos de produto — auditoria de 2026-08-08

**Nenhum foi corrigido.** Sob o G1, tocar `web/` cria candidato novo e descarta
as horas dos finais. **Todos são pós-freeze do WP08.**

| ID | defeito | verificação | consequência | custo |
|---|---|---|---|---|
| **P1** | `upload_max_conc` sai **1** em vez de `lanes−1` | **lido** — `serve.odin:94-97` lê `max_handlers` **cru** (0 por default), então `max(1, 0−1) = 1` | contrato publicado promete 3 num host de 4 lanes; **entrega 1/3 da capacidade documentada**, em silêncio | pequeno |
| **P3** | diagnóstico de boot é **mudo** no contexto default | **lido e confirmado contra o toolchain fixado** — `limits_poison` guarda por `procedure == nil`, mas `core.odin:911` instala `default_logger_proc`, cujo corpo é `// Nothing` | limites inválidos → app envenenado → `serve` retorna void → **processo sai 0 sem imprimir nada e sem escutar** | pequeno |
| **P6** | `reserved_conns` ignorado quando `max_connections = 0` | **lido** — `limits.odin:460` só valida com `max_connections > 0` | operador pede pool ilimitado **e** reserva de drenagem, recebe nada, sem aviso | pequeno |
| **P2** | `web.stats()` lê `server.threads` **depois do free** | relatado — `vendor/odin-http/server.odin:453` deleta sem zerar; o `retire` do adapter é posterior | use-after-free numa janela de poucas instruções; `web.stats` é documentada como segura de qualquer thread | pequeno (`s.threads = nil`) |
| **P4** | mensagem de limite inválido **diagnostica o caso errado** | relatado — `errors.odin:1045` fala em "zero or negative" também para `max_handlers = 257` | mesma classe do `wp123`: **manda a investigação para o lugar errado com confiança** | pequeno |
| **P5** | o clamp `[4,32]` protege **só** o caminho automático | **lido** — `odin_http_adapter.odin:34` só clampa quando `requested == 0` | `max_handlers = 1` é aceito **e anunciado**, e custa **34.174 µs de p99** (27× o default). Foi essa classe de raciocínio que travou o WP04 por dois dias | pequeno (aviso) |
| **P7** | XFF: **linhas de cabeçalho separadas** podem inverter a caminhada | relatado — o backend funde repetições em ordem de chegada; um proxy que **prepende** põe o valor do cliente à direita, que é onde a caminhada procura | `client_ip` escolhido pelo atacante. **Contido** sob o perfil suportado (o Caddy fixado acrescenta, não prepende) — **mas não medido**, e o framework **não consegue nem saber** que chegaram duas linhas | médio |
| **P8** | `trust_proxies({"10."})` faz de **qualquer vizinho** um forjador | relatado — o mesmo conjunto responde "pode falar pelos clientes?" e "é hop interno?" | é a configuração **documentada** no próprio arquivo. Conserto de fundo = separar os dois conjuntos ou aceitar CIDR — **mudança de API pública** | médio-alto |
| **P9** | `client_ip` devolve bytes **não validados e sem limite** | relatado — `X-Forwarded-For: unknown` devolve `"unknown"` | o cookbook manda usar como chave de rate-limit: **cardinalidade escolhida pelo cliente** | pequeno |

### 2.1 Contabilidade de recusas — o denominador que ninguém vê

| ID | lacuna | verificação | portão |
|---|---|---|---|
| **P10** | **sete caminhos fecham conexão sem resposta e não contam em lugar nenhum** — incluindo **EMFILE** e a pendente órfã por exaustão de lane | relatado, com linhas | **R2 se possível** |
| **P11** | **saturação em keep-alive não é contada de forma alguma** — o ramo `handler_lane_enter` é inalcançável | relatado | R3 |

**Por que P10 importa agora:** um processo sem descritores e um processo saturado
**têm o mesmo aspecto em `web.stats`** — tudo parado, nada contado. Se a hipótese
H-B da morte de host for real, essa é exatamente a assinatura que o A/B pode
observar. `accept_failures` é um `int` privado, exposto por nenhum campo.

**Consequência para a região segura:** `saturation_refusals` mede pressão de
**conexão nova**, não saturação. A frase "a recusa é função da rajada e da taxa"
continua certa — e agora se sabe **por que a rajada domina**: é a única metade
que o contador enxerga.

---

## 3. Achados abertos sem causa

| ID | o quê | estado |
|---|---|---|
| **A1** | **wp123** — `507` numa reprovação única; não reproduziu em 41 tentativas. A mensagem **nomeia um defeito que o código não tem mais** | aberto |
| **A2** | **ingest-leak** — `server did not start`; **não é lentidão** (48 medições, pior caso 174 ms contra janela de 600) | aberto |
| **A3** | **três mortes de host** | em investigação (L5) |
| **A4** | **ciclo 225** | aberto (L7) |
| **A5** | **F8** — limite de memória sob corpo hostil pinado por argumento, não por teste | aberto |

**A1 e A2 envolvem `web/internal/ingest/` e podem ser o mesmo defeito.** O `507`
**colapsa duas causas** que o adapter não distingue — separá-las é trabalho
concreto e é o próximo passo útil.

---

## 4. O que este registro muda no WP08

**A §4 do pacote de decisão passa a ter uma pergunta a mais:** promover para R2
com **quantos** destes em aberto, e quais são aceitáveis por escrito?

**Sugestão de classificação para a decisão:**

| classe | itens | leitura |
|---|---|---|
| **bloqueiam promoção** | L5 (se a causa for o framework) | um framework que derruba a máquina não é promovível |
| **deveriam fechar antes** | L3, L6, P1, P3 | medições baratas e defeitos pequenos de contrato publicado |
| **risco aceito, por escrito** | L1, L7, P2, P4, P5, P6, P9, A1, A2, A5 | conhecidos, nomeados, com custo estimado |
| **explicitamente R3** | L2, L4, L9, L10, P7, P8, P11 | trabalho de fôlego ou mudança de API |

**Nada nesta tabela é "ignorar".** A classe "risco aceito" exige assinatura e
validade, como o R2-WP07 já faz com os degraus 2–6 do canário.

---

## 5. Os dois WPs de R3 que faltam criar

O R3 é **cardápio, não programa de fechar lacunas** — seus resultados permitidos
incluem *"R2 REMAINS THE PRODUCT"* e *"TRAIL REJECTED"*. Então um item só é
tratado se virar trilha, e **duas lacunas do R3 não têm trilha**:

1. **Matriz de plataformas (L4)** — outras topologias de CPU, outros mixes, mais
   I/O bloqueante por requisição. Hoje toda a evidência é `c5.2xlarge` com **um**
   handler bloqueante a 1–2 req/s.
2. **Custo de TLS e comparação com pares (L10)** — a comparação exige, pelo §8 do
   pré-registro do soak, um harness que **prove trabalho equivalente**. Esse
   harness não existe.

**Recomendação:** criá-los como `R3-WP11` e `R3-WP12` antes do freeze do WP08,
para que o registro tenha destino e não só nome.
