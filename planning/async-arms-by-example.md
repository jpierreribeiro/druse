# Os quatro braços, no mesmo handler

**2026-08-08.** Escrito a pedido do dono, que considera aceitar o custo de perder
*"simples por padrão"* e quer ver **em código** o que isso significa.

> **ISTO NÃO PROPÕE API.** Sob o **G5**, um plano nomeia uma necessidade e não
> inventa assinatura. As assinaturas abaixo são **ilustrativas** — existem para
> tornar o custo visível, e nenhuma delas deve ser lida como proposta de
> `web`. O R3-WP04 é quem escolhe, com o shootout do
> `sync-async-evaluation.md`.

**O handler é o mesmo nos quatro:** buscar um usuário no Postgres e devolver
JSON. É o caso mais comum de uma API real, e é onde o custo aparece.

---

## Braço A — hoje (lanes síncronas limitadas)

```odin
get_user :: proc(ctx: ^web.Context) {
    id := web.path_int(ctx, "id") or_return          // extractor falha em 400 tipado
    user, err := pg.query_one(db, User, "SELECT * FROM users WHERE id = $1", id)
    if err != nil {
        web.problem(ctx, .Internal_Server_Error, "consulta falhou")
        return
    }
    web.ok(ctx, user)
}
```

**Onze linhas, lê de cima para baixo.** O `defer` funciona. A arena da requisição
morre quando o procedimento retorna. Um erro é um `if`. Um `return` encerra.

**O custo:** enquanto `pg.query_one` espera, **a lane inteira para** — e as outras
conexões atribuídas a ela esperam junto, **sem que contador nenhum se mova**.

---

## Braço B — event lanes + job pool limitado

```odin
get_user :: proc(ctx: ^web.Context) {
    id := web.path_int(ctx, "id") or_return

    // A ÚNICA mudança: declarar que este trecho bloqueia.
    web.blocking(ctx, proc(ctx: ^web.Context, id: int) {
        user, err := pg.query_one(db, User, "SELECT * FROM users WHERE id = $1", id)
        if err != nil {
            web.problem(ctx, .Internal_Server_Error, "consulta falhou")
            return
        }
        web.ok(ctx, user)
    }, id)
}
```

**O corpo continua direto.** `defer` continua funcionando dentro do bloco. Erro
continua sendo `if`. O que muda é **uma anotação**: o trecho bloqueante sai da
lane e vai para um pool limitado, e a lane volta a girar o event loop.

**O que isto custa de verdade:**

- uma fila nova, que precisa de **limite** e de política quando enche;
- a arena da requisição passa a atravessar a fronteira do pool — **quem é dono
  do quê** vira pergunta explícita;
- cancelamento e `shutdown` precisam saber esperar (ou não) por jobs em voo;
- **duas** formas de escrever handler no mesmo framework, e um jeito errado de
  escolher entre elas.

**Não custa:** uma segunda API de Handler, reescrever handlers que não bloqueiam,
nem abrir mão do estilo direto.

---

## Braço C — assíncrono de verdade (continuações)

```odin
Get_User_State :: struct {
    ctx:  ^web.Context,
    id:   int,
    // Tudo que o handler "lembrava" na pilha agora mora aqui, à mão,
    // e alguém tem de ser dono desta memória até a última continuação.
}

get_user :: proc(ctx: ^web.Context) {
    id := web.path_int(ctx, "id") or_return

    state := web.state_alloc(ctx, Get_User_State)     // vive além deste frame
    state.ctx = ctx
    state.id  = id

    pg.query_one_async(db, "SELECT * FROM users WHERE id = $1", id,
        on_row, on_error, state)
    // `get_user` RETORNA AQUI, sem resposta. A requisição continua viva.
}

on_row :: proc(user: User, opaque: rawptr) {
    state := (^Get_User_State)(opaque)
    web.ok(state.ctx, user)
    web.state_free(state)
}

on_error :: proc(err: pg.Error, opaque: rawptr) {
    state := (^Get_User_State)(opaque)
    web.problem(state.ctx, .Internal_Server_Error, "consulta falhou")
    web.state_free(state)
}
```

**Onze linhas viraram trinta, e três procedimentos.** Mas a contagem de linhas é
a parte barata. O que quebra:

| some | por quê |
|---|---|
| **`defer`** | o frame retorna antes do trabalho terminar |
| **`or_return`** | não há para onde retornar |
| **erro como `if`** | vira um callback separado, longe do lugar que causou |
| **a pilha como memória** | tudo vira `struct` de estado, alocada à mão |
| **"a arena morre no retorno"** | a arena tem de sobreviver ao frame, e **alguém** decide quando morre |

**E o pior:** um `return` esquecido em qualquer ramo **vaza a requisição** — ela
fica viva, sem resposta, até o deadline. No braço A isso é impossível por
construção.

**Duas continuações por dependência.** Um handler que consulta banco, chama um
upstream e escreve num cache tem **seis**.

---

## Braço D — fachada síncrona sobre fibras

```odin
get_user :: proc(ctx: ^web.Context) {
    id := web.path_int(ctx, "id") or_return
    user, err := pg.query_one(db, User, "SELECT ...", id)   // suspende a fibra
    if err != nil { web.problem(ctx, .Internal_Server_Error, "falhou"); return }
    web.ok(ctx, user)
}
```

**Idêntico ao braço A.** É essa a promessa: parece síncrono, não retém thread.

**E é exatamente por isso que o `sync-async-evaluation.md` avisa:**

> *"'parece síncrono' **não é evidência** de que o runtime é simples."*

O custo saiu do handler e foi para **debaixo dele**:

- **memória de pilha por fibra.** 10.000 requisições em voo = 10.000 pilhas. A 64
  KiB cada, são 640 MiB só de pilha — e pilha que cresce não pode ser movida sem
  cuidado com ponteiros;
- **`defer` e contexto por thread** precisam seguir a fibra, não a thread;
- **FFI bloqueante prende a thread da fibra assim mesmo** — nenhum runtime
  resolve uma chamada nativa que não cede;
- **fairness e starvation** viram problema seu: um handler em laço apertado
  segura o escalonador;
- **escalonador próprio** é a peça que o R3-WP04 marca como
  *"presumido recusado até evidência extraordinária"*.

**Odin não tem fibras.** Este braço é *escrever um runtime*, não usá-lo.

---

## O que eu concluo dos quatro

**O braço B entrega a maior parte do ganho pelo menor custo**, e é por isso que a
regra de decisão congelada diz, textualmente:

> *"Se um job pool vencer dependências bloqueantes **sem uma segunda API de
> Handler**, prefira-o a um runtime async geral."*

**O braço C é honesto e é caro.** Ele não perde só "simplicidade": perde `defer`,
`or_return`, erro-como-`if` e a arena que morre sozinha. Num framework cujo
compromisso número um é *"simples por padrão"* e cujas regras de API exigem que
o código seja legível por quem nunca o viu, isso é **mudar o produto**, não
otimizá-lo.

**O braço D parece o A e é o mais arriscado dos quatro** — o custo fica invisível
até a produção.

---

## O que decidiria isto, e já está especificado

O §5 do `sync-async-evaluation.md` fixa **oito workloads**, e dois deles existem
precisamente para esta pergunta:

- **espera sintética** de 1, 10, 100 e 500 ms **sem CPU de servidor** — *"para
  expor o melhor caso do async"*;
- **PostgreSQL** com `pg_sleep`, espera de lock, cancelamento e **exaustão de
  pool**.

E o §7 impõe uma pré-checagem **aritmética, antes de qualquer implementação**:
async só vence onde **espera ≫ serviço**, **a demanda excede o teto de lanes**, e
**o pool do banco não é a restrição**. As três, juntas.

**A terceira é a que eu duvido que se sustente numa API com banco.** Com um pool
de 20 conexões, 5.000 requisições em voo esperam nas mesmas 20 — o async move a
fila da lane para o pool e cobra a reescrita de todos os handlers pelo transporte.

**Onde a conjunção fecha de verdade é sem recurso compartilhado limitado:**
long-polling, SSE, WebSocket, fan-out para muitos upstreams distintos. E para
esse caso a regra já manda entregar o caminho especializado em vez de trocar os
Handlers — **o que a Fase 7 já fez**, com `web.stream`.

---

## Recomendação

**Não decida por intuição nem por syntax.** Rode o shootout do R3-WP04 com os
oito workloads. Ele foi escrito para responder exatamente isto, tem regra de
decisão congelada, e o braço A é o **empate por padrão** — *"porque está
entregue, é entendido, e é reversível por `max_handlers = 1`"*.

**E antes de qualquer braço:** o head-of-line blocking silencioso é defeito hoje,
no braço A, e conserta-se **sem mudar API nenhuma** — basta a fila deixar de ser
invisível. É o item **P11** do `REGISTRO-DE-LACUNAS.md`, e é a coisa mais barata
de alto retorno nesta lista.
