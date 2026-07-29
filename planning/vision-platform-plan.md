# Plataforma de visão computacional (EPI) — plano e idealização

**Status: IDEALIZAÇÃO, 2026-07-29. Não autoriza uma linha de código, nem no
Uruquim nem nos Crystals.** Este documento responde a uma proposta de
arquitetura trazida pelo dono. Ele concorda com a maior parte dela, corrige
sete pontos, e reordena o programa em função do que pode matar o produto.

**Por que ele mora aqui.** O produto não é o Uruquim e não é um Crystal — é uma
aplicação que os consome, e no fim terá repositório próprio. Até existir esse
repositório, o plano fica em `planning/` do core porque é aqui que vive o
registro de decisão do dono, e porque o produto é candidato natural ao item
ainda aberto de *proof by use* (Fase 8 / ID-9). **Recomendação: criar o
repositório do produto antes do primeiro commit de código**, e mover este
arquivo para lá.

---

## 1. O que foi proposto, e o que está certo

A proposta é boa e a maior parte dela sobrevive à revisão. Em particular,
estão corretos e ficam registrados como aceitos:

- **Control plane e data plane separados.** O Uruquim administra o produto; ele
  não transporta frames nem executa inferência dentro de um handler HTTP.
- **Agente local obrigatório.** Câmeras vivem em `192.168.x.x`; um host público
  não alcança rede privada de terceiro (RFC 1918). Port-forward por câmera é
  operacionalmente ruim e amplia demais a superfície de ataque; integração de
  nuvem por fabricante cria dependência. O agente é a opção controlável.
- **Não reimplementar RTSP, H.264, runtime de rede neural ou OpenCV.**
  GStreamer para ingestão, ONNX Runtime para inferência portátil, PyTorch só
  para treino.
- **Amostragem agressiva e fila limitada com descarte do frame velho.** Para
  monitoramento ao vivo, um frame novo vale mais que uma fila de frames
  antigos.
- **Regra temporal, nunca um frame só.** Confirmação por N observações em uma
  janela, mais cooldown.
- **`tenant_id` em tudo**, inclusive frames, filas, métricas, chaves de objeto
  e tópicos de evento.
- **Três backends de inferência (Fake, ONNX CPU, Remote)** para desenvolver a
  arquitetura inteira sem GPU.

O que segue são as correções.

---

## 2. C1 — O gargalo é a banda de subida do cliente, não a GPU

A proposta trata a decisão "sem inferência local" como resolvida e passa
direto para batching e escalonamento. Mas se o agente só faz "conectividade e
transporte", ele precisa **subir vídeo contínuo de todas as câmeras**, e essa
conta não fecha:

```text
Stream principal típico (1080p H.264):   3–6 Mbit/s por câmera
50 câmeras                              150–300 Mbit/s sustentados
                                        ~1,5 TB por câmera por mês
```

Galpão industrial no Brasil raramente tem 200 Mbit/s **de upload** estável. O
produto morre na instalação, antes de qualquer discussão sobre modelo.

**A saída é o substream.** Praticamente toda câmera IP publica um segundo
profile — na linguagem ONVIF, um perfil secundário — pensado exatamente para
análise e para grades de visualização:

```text
Substream típico:  640×360 a 704×576, 6–15 fps, 256–512 kbit/s
50 câmeras                              13–25 Mbit/s
```

Isso é 5–10× menos banda, **a custo zero de CPU na borda** (nada é decodificado
nem recodificado — o agente relaia os pacotes já comprimidos), e ainda reduz o
custo de decode na nuvem, que a própria proposta identifica como possível
gargalo junto do modelo.

**O que não vale a pena:** decodificar na borda, amostrar a 2 fps e reenviar
JPEG. A conta dá empate — JPEG 640×360 a 2 fps fica em 300–550 kbit/s, a mesma
ordem do substream H.264 a 10 fps — e o empate é pago com decode e encode na
máquina do cliente. Só passa a valer se o link do cliente exigir outro degrau,
e nesse caso a resposta é reencodar em H.264 com GOP longo a 2 fps
(~100 kbit/s), não JPEG.

> **Regra:** relaiar o substream primeiro. Medir. Transcodificar na borda só
> quando um link real recusar 400 kbit/s por câmera.

**Consequência de projeto:** a descoberta ONVIF do agente não é "achar a
câmera". É **achar os dois profiles e verificar que o secundário existe, está
habilitado e tem resolução utilizável**. Câmera sem substream utilizável é uma
categoria de incompatibilidade que o produto precisa saber reportar no
cadastro, não descobrir em produção.

---

## 3. C2 — A evidência é bufferizada na borda, não na nuvem

A proposta guarda um buffer circular na nuvem para montar o clipe de
`[t−5s, t+5s]`. Isso desfaz C1 inteiro: para ter o clipe em qualidade de
evidência, seria preciso subir o stream principal continuamente — justamente a
banda que acabamos de economizar. E o substream não serve como evidência: 360p
a 10 fps não sustenta uma conversa com auditor, com o SESMT, nem com um juiz do
trabalho.

**Inversão:** o buffer circular fica no agente, sobre o **stream principal**, e
só o recorte sobe.

```text
Agente (por câmera)
├── substream  ──> relay contínuo para a nuvem        (análise)
└── main stream ──> ring buffer de pacotes comprimidos (evidência)
                    ~20 s x 4 Mbit/s ≈ 10 MB de RAM

Incidente confirmado na nuvem
        │
        └──> "me dá [t−5s, t+5s] da câmera 12"
                    │
                    └──> agente remuxa para fMP4 e faz upload
```

Custo de banda da evidência passa a ser **por incidente**, não contínuo. Um
site com 50 câmeras e 30 incidentes por dia sobe ~150 MB/dia de evidência, não
1,5 TB/mês por câmera.

O ring buffer guarda **pacotes comprimidos**, não frames decodificados: nada é
decodificado na borda, e o recorte precisa apenas começar num keyframe (daí a
folga de 20 s para um GOP de 2 s). O snapshot que ilustra o incidente no painel
continua vindo do frame de análise, que a nuvem já tem.

**Isso muda o nome da coisa.** Não é um *thin agent*: é um **agente de borda
com buffer e muxer**. A decisão original do dono continua de pé — **nenhuma
inferência roda no cliente** — mas o agente não é um túnel burro, e o plano de
distribuição (binário único, serviço, container) precisa contar com RAM
proporcional ao número de câmeras.

---

## 4. C3 — O detector sozinho não resolve capacete

A proposta parte de um detector com três classes (`person`, `helmet`,
`safety_vest`) e depois associa capacete a pessoa por geometria. Isso funciona
em vídeo de demonstração e falha exatamente onde a própria proposta prevê
falha: câmera alta, trabalhador pequeno na imagem, contraluz.

O motivo é resolução. Numa cena 640×360 vinda de câmera de galpão, a pessoa
ocupa 40×90 px e o capacete ocupa **12×10 px**. Nenhum detector de propósito
geral é confiável nessa escala.

**Duas etapas, não uma:**

```text
Frame de análise (640×360, 2 fps)
        │
        ├── etapa 1: detector de PESSOA                   (1 inferência)
        │
        └── etapa 2: para cada pessoa, recorte do terço superior
                     redimensionado para 96×96
                     classificador binário capacete/sem capacete
                                                          (N inferências baratas)
```

Ganhos concretos:

1. **Resolução efetiva.** O recorte da cabeça vira 96×96 em vez de 12×10. É a
   diferença entre adivinhar e classificar.
2. **A associação some.** Não existe "de quem é este capacete": o recorte já é
   de uma pessoa. O problema geométrico mais frágil do pipeline deixa de
   existir.
3. **Calibração por cliente fica barata.** Retreinar um classificador binário
   de 96×96 com 2.000 recortes do site do cliente é trabalho de dias.
   Retreinar um detector multiclasse é trabalho de mês.
4. **Batching melhora.** Os recortes são todos do mesmo tamanho, de todas as
   câmeras e de todos os tenants — é o lote perfeito.

Custo: `1 + N` inferências por frame, com N tipicamente 0–5 e a etapa 2 uma a
duas ordens de grandeza mais barata que a etapa 1. Colete segue a mesma forma
com o recorte do tronco.

Continua valendo o recorte do MVP: **um EPI só, capacete.** Luvas, óculos,
botas, protetor auricular e postura ficam fora, e cada um deles é um projeto de
anotação próprio.

---

## 5. C4 — O experimento que decide o produto vem antes do código

Nada no plano — nem Odin, nem GStreamer, nem multi-tenancy — importa se a
hipótese de visão não se sustentar no ambiente real do cliente. Esse teste
custa uma semana e desarma um projeto de um ano:

```text
1. Gravar 2 horas de vídeo REAL do site alvo, no substream,
   incluindo o pior horário de luz.
2. Rotular à mão 200 frames: caixas de pessoa + capacete sim/não.
3. Rodar um detector de pessoa pronto (COCO) + um classificador
   de capacete pronto ou treinado em dataset público.
4. Medir precisão e recall POR PESSOA, não por frame.
```

Critério: se, com confirmação temporal de 7 em 10 observações, o falso
positivo por câmera por turno não cair para a casa de unidades, o produto não é
vendável na forma proposta e o plano muda — não o dataset. Esse número é o
primeiro entregável do programa, e ele é obtido em Python, não em Odin.

---

## 6. C5 — Risco jurídico e trabalhista, que a proposta não cobre

A proposta trata privacidade como "evite reconhecimento facial". Isso é
necessário e insuficiente.

**LGPD.** Imagem de trabalhador é dado pessoal mesmo sem reconhecimento facial:
num turno de doze pessoas, "a pessoa da zona 3 às 10h35" é identificável por
contexto. O tratamento contínuo de imagem em ambiente de trabalho é operação de
alto risco; a orientação da ANPD sobre legítimo interesse pede necessidade,
transparência, expectativa do titular, registro das operações e balanceamento
de direitos, e um Relatório de Impacto (RIPD) é o instrumento adequado para
documentar isso. Base legal plausível: legítimo interesse ou cumprimento de
obrigação legal de gestão de riscos ocupacionais. **Nenhuma das duas dispensa
informar o trabalhador.**

**O risco comercial maior, e que não estava no documento.** O sistema produz
**prova datada, durável e auditável de que o empregador sabia** que havia
trabalho sem EPI. Em reclamação trabalhista, em ação regressiva do INSS ou em
investigação de acidente, esse acervo é material probatório — contra o cliente.
O departamento jurídico do cliente vai enxergar isso antes do gerente de
segurança. É a razão pela qual um produto assim é recusado, e não o preço.

Isso precisa moldar o modelo de dados desde o primeiro dia, não virar um
toggle depois:

- **Retenção curta por padrão** e configurável por tenant; expurgo automático
  provado por teste, não por política escrita.
- **O incidente carrega a remediação.** O registro canônico não é "violação
  em 12/03 às 10h35" — é "violação detectada, notificada ao supervisor às
  10h36, encerrada às 10h44". Um acervo que mostra o empregador **agindo** é
  defesa; um acervo que só acusa é passivo.
- **Painel agregado primeiro.** A tela inicial é taxa de conformidade por zona
  e por turno. O incidente individual é o detalhe, não o produto.
- **Identificação nominal nunca entra.** O evento é "pessoa sem capacete na
  zona 3". A track é efêmera e vive dentro da sessão da câmera.

**CIPA e sindicato.** Monitoramento por imagem em ambiente de trabalho é tema
de negociação coletiva. Um sistema percebido como punitivo é sabotado — câmera
desviada, lente suja, alerta ignorado. O posicionamento tem que ser prevenção,
com o alerta indo para o supervisor de área, e não para o RH.

---

## 7. C6 — O que o Uruquim hoje pode e o que ele não pode

Auditado no commit deste branch, não presumido.

**Já existe e serve** (Crystals): `config`, `db/postgres` + `db/migrate`,
`validate`, `auth/session` (+ `_postgres`), `auth/password`, `auth/api_key`
(+ `_postgres`), `authorization`, `csrf`, `rate_limit`, `web/cookie`,
`web/form`, `web/html`, `web/template`, `idempotency`, `jobs` + `jobs_postgres`
+ `cmd/worker`, `mail`, `storage` + `storage_s3` (com `put_stream`, ou seja o
upload de clipe é streaming e não carrega o arquivo em RAM), `http_client`,
`web/sse` (feed ao vivo de incidentes, com heartbeat e `Last-Event-ID`),
`web/metrics` (Prometheus). O core traz multipart, upload, streaming, deadlines,
proxies confiáveis, shedding observável e drain.

Ou seja: **o control plane é majoritariamente montagem, não construção.** A
proposta subestimou o quanto já está pronto.

**Restrições duras, que mudam o desenho:**

| Restrição | Consequência |
|---|---|
| HTTP/1.1 apenas — **sem HTTP/2, sem gRPC, sem WebSocket** | O canal agente↔nuvem não pode ser gRPC. Comandos vão por SSE ou long-poll; mídia **não passa pelo Uruquim**. |
| Sem `LISTEN`/`NOTIFY` no `db/postgres` | Sem barramento de eventos pronto. Ou `jobs_postgres` + polling, ou um Crystal novo. |
| `storage_s3` não emite URL pré-assinada, por recusa explícita | Evidência é servida pelo control plane com token curto próprio, ou nasce um `storage_s3.presign`. |
| Uruquim **sem release**; Crystals experimentais, ID-9 (*proof by use*) em aberto | Este produto **é** a prova por uso. Isso é argumento a favor — e obriga a orçar explicitamente tempo de conserto de framework dentro do cronograma do produto. |

**Decorrência de arquitetura:** dois canais, não um.

```text
Agente ──HTTPS──> Uruquim Control Plane
        registro, saúde, comandos (SSE), upload de evidência
        autenticado com auth/api_key, que já existe

Agente ──TLS/TCP──> Stream Plane (Odin nativo, fora do Uruquim)
        relay do substream
```

Empurrar RTP por dentro de um framework web é o erro que este desenho evita.

---

## 8. O data plane em Odin — o que decidir antes de escrever

**Concorrência.** Odin não tem runtime assíncrono, e o item 18 do
`future-research.md` (sync/async) está aberto justamente aqui. Este produto
**não** deve esperar por essa resposta: ele é thread-por-papel com filas
limitadas, que é o modelo que o Odin faz bem.

```text
GStreamer  — N threads, geridas pela própria biblioteca
Scheduler  — 1 thread
Inference  — M workers (M = dispositivos, não câmeras)
Tracking   — 1 thread por grupo de câmeras
```

**Backpressure de graça, antes de escrever fila.** `appsink` do GStreamer com
`max-buffers=1 drop=true` já implementa "o frame novo vence" no ponto certo do
pipeline. Escrever uma fila em Odin antes de usar isso é reimplementar o que a
dependência entrega.

**Slot, não fila.** Depois do appsink, o que existe por câmera é um slot de
profundidade 1–2 com troca atômica e reciclagem, não uma fila. Fila de frames é
latência disfarçada de robustez.

**Sem `malloc` por frame.** Pool de slabs de tamanho fixo por câmera, alocado
na abertura da sessão. `pixels: []u8` dentro do envelope, como na proposta,
convida a cópia: o envelope carrega **handle do pool + refcount**, e a cópia,
quando existir, é explícita.

**`generation` está certo** e é a peça que evita processar frame de conexão
morta depois de uma reconexão. Vale para track e para incidente também.

**Deadline atravessa tudo.** `deadline_at` no envelope, descarte em toda etapa,
contador de descarte por etapa exportado como métrica. Frame que perdeu o
deadline não é erro — é operação normal, e precisa ser visível.

**Escalonamento.** Não inventar "Inference Cost Unit" antes de medir. Começar
com admissão por *frames em voo por dispositivo* e uma tabela medida de
latência por `(modelo, resolução, tamanho de lote)`. Justiça entre tenants por
**deficit round robin** — O(1), uma linha de estado por tenant — e não WFQ.
WFQ entra se e quando o DRR for provado insuficiente.

**Sessão de câmera é máquina de estados.** A proposta acerta em cheio. Os
estados mínimos: `configured → probing → connected → streaming → degraded →
backoff → retired`, com transição observável e exportada. Câmera que troca de
codec, muda de resolução, reinicia ou tem a senha alterada é o caso normal, não
a exceção.

**Bindings.** Seguir o precedente já existente nos Crystals — o `db/postgres`
usa declarações C vendorizadas (`vendor/odin-postgresql`) sob a
`vendor-policy.md`, com verificação por comportamento. GStreamer e ONNX Runtime
entram do mesmo jeito, com a superfície mínima que o produto usa, e não com um
binding completo da biblioteca.

**Isolamento entre tenants.** `tenant_id` em toda tabela com RLS no PostgreSQL,
prefixo de tenant em toda chave de objeto, e no data plane um pool por tenant —
para que um frame não tenha caminho físico até o processamento de outro. Um
vazamento de evidência entre clientes encerra o produto; isolamento nasce no
projeto.

---

## 9. Programa, reordenado pelo que pode matar o produto

A proposta ordena por camada. Isto ordena por risco: os dois riscos que matam o
produto são **a hipótese de visão** e **a realidade das câmeras**. Nenhum dos
dois é resolvido pela máquina de nuvem, e os dois podem ser atacados no
Latitude.

| Etapa | O que é | O que prova | Mata o quê |
|---|---|---|---|
| **E0** | Sem código: inventário ONVIF de um site real, medição do link, conta de banda e de custo por câmera/mês, postura jurídica | Que existe um site instalável e um preço | Viabilidade comercial |
| **E1** | O experimento de C4, em Python, sobre vídeo real | Precisão e recall por pessoa | **A hipótese de visão** |
| **E2** | Data plane offline em Odin: arquivo → GStreamer → decode → amostragem → backend Fake → tracking → regra → incidente em JSON. Sem rede, sem câmera, sem nuvem | O laço central e o modelo de memória | Erro de arquitetura barato |
| **E3** | Uma câmera real, local: sessão RTSP como máquina de estados, reconexão, `generation`, ring buffer, remux do clipe | A superfície operacional mais hostil | **A realidade das câmeras** |
| **E4** | Backend ONNX CPU: detector de pessoa + classificador de capacete, sobre gravação do site alvo | Que E1 sobrevive fora do Python | Regressão na tradução |
| **E5** | Control plane no Uruquim: tenant, site, câmera, zona, política, incidente, evidência, revisão humana | Composição dos Crystals — e ID-9 | Risco de framework |
| **E6** | Split agente↔nuvem: transporte, frota, 100 câmeras virtuais contra o backend Fake, backpressure, DRR | Escala, sem GPU e sem 100 câmeras reais | Erro de escalonamento |
| **E7** | Piloto pago, um cliente, um site, capacete, uma zona por câmera | Tudo | — |

MVP recortado, mantido como na proposta e reafirmado: **1 tenant, 1 site, 1–4
câmeras, só capacete, 1 zona por câmera, 2–3 inferências por segundo, 1 modelo,
1 tipo de alerta, snapshot + clipe curto, revisão humana.**

---

## 10. O que fica explicitamente de fora

Do MVP e das etapas E0–E7:

- Decoder H.264 próprio, RTSP próprio, runtime de rede neural próprio, driver
  de GPU, biblioteca equivalente ao OpenCV, framework de treino.
- DeepStream e TensorRT. Entram como *worker remoto* atrás da mesma interface
  `Inference_Backend`, quando houver GPU e volume que justifiquem — nunca como
  binding grande dentro do núcleo.
- Reconhecimento facial e identificação nominal. Não é "depois": é fora do
  produto.
- Qualquer EPI além de capacete.
- Gravação contínua de vídeo na nuvem. O produto guarda evidência de incidente,
  não é um VMS.
- Microserviços. O primeiro deploy são quatro processos: control plane, data
  plane, inference worker, agente. A separação conceitual é obrigatória desde
  já; a separação física é consequência medida.

---

## 11. Questões abertas — cada uma com dono e critério

| # | Questão | Dono | O que a fecha |
|---|---|---|---|
| **VQ-1** | O substream das câmeras do site alvo é utilizável? Resolução, fps, disponibilidade via ONVIF Profile T | dono, em E0 | Inventário de um site real, câmera por câmera |
| **VQ-2** | Qual precisão por pessoa um detector pronto + classificador de capacete atinge no ambiente do cliente? | dono, em E1 | 200 frames rotulados, precisão/recall medidos |
| **VQ-3** | Falso positivo por câmera por turno, com confirmação temporal — qual número o cliente tolera? | dono, com um cliente real | Uma conversa, antes do código |
| **VQ-4** | Quanto de RAM o ring buffer de evidência custa por câmera, com GOP real? | E3 | Medição, não estimativa |
| **VQ-5** | O canal de mídia agente↔nuvem: TLS/TCP próprio, ou relay RTSP sobre TLS? | E6 | Protótipo dos dois sob perda de pacote |
| **VQ-6** | Barramento de eventos: `jobs_postgres` com polling basta, ou nasce um Crystal? | E5 | Latência medida de incidente até painel |
| **VQ-7** | Evidência servida: proxy pelo control plane, ou `storage_s3.presign`? | E5 | Custo de banda no control plane sob carga de revisão |
| **VQ-8** | Base legal e RIPD: legítimo interesse ou obrigação legal? | dono, com assessoria jurídica | Parecer, antes do piloto |
| **VQ-9** | Sem inferência local sobrevive ao preço? Qual o ponto de virada em número de câmeras por site? | depois de E4 | Custo medido de GPU por câmera contra preço de um mini-PC no site |

---

## 12. A frase que resume a divisão

> **O Uruquim administra o produto. O Odin nativo administra o fluxo de dados.
> Bibliotecas maduras cuidam de codec e inferência. Python fica restrito ao
> treino.**

Ela veio da proposta, está certa, e fica. As correções deste documento não
mudam a divisão — mudam **o que roda de cada lado da borda**: o substream sobe,
o stream principal fica, a evidência é recortada onde ela nasce, e a decisão do
produto é tomada em E1, com vídeo real, antes do primeiro `package` em Odin.
