# A janela de 600 ms: hipótese refutada por medição

**2026-08-04.** Fecha o item devido dos achados §7 e §8 de
[`../../planning/r2-wp04-ladder-notes-2026-08-04.md`](../../planning/r2-wp04-ladder-notes-2026-08-04.md):
*"medir o tempo de inicialização sob carga em vez de supor"*.

---

## 1. A hipótese que eu tinha escrito

O `ingest-leak` reprovou com `server did not start`, e eu registrei:

> A janela de prontidão do fixture é **600 ms** … O servidor sobe rings de
> io_uring antes de aceitar, e numa máquina carregada 600 ms é apertado.

E recusei alargar a janela justamente para não enterrar a pergunta.

## 2. A medição

Tempo do `exec` até o primeiro `accept`, 12 medições em cada condição:

| condição | n | mín | mediana | máx |
|---|---:|---:|---:|---:|
| sem carga | 12 | 20 ms | **42 ms** | 127 ms |
| sob 8 processos de CPU (máquina de 4 núcleos) | 12 | 45 ms | **78 ms** | **174 ms** |

**Nenhuma das 24 medições passou de 600 ms.** A margem contra o pior caso
observado é de **3,4×**, e a carga aplicada é o dobro de processos ocupados por
núcleo disponível.

## 3. O que isto refuta

**A hipótese de que 600 ms é apertado para a inicialização está refutada.** A
falha do `ingest-leak` **não** foi lentidão de startup. O servidor não demorou —
ele não subiu.

Isso é mais interessante que a hipótese original, porque um servidor que não sobe
tem uma causa e não uma distribuição.

## 4. O LIMITE desta medição, que é o que ela não cobre

**Medi o `soak-server`, que NÃO habilita upload.** O fixture do `ingest-leak`
chama `web.enable_upload(...)` com um diretório de spool antes de servir.

Então esta medição diz: *a inicialização genérica é rápida sob carga*. Ela **não
diz nada** sobre a inicialização **com upload habilitado**, que é exatamente o
caminho do teste que falhou.

Registro isso como limite em vez de deixar a conclusão parecer maior do que é —
foi o erro que a documentação do `trust_proxies` cometeu e que custou o
TRUST-001.

## 5. Para onde a refutação aponta

Se `serve` não vinculou a porta e não foi por lentidão, a suspeita passa a ser a
**inicialização do ingest**: um `enable_upload` que falha deixa a App inutilizável
e o `serve` retorna sem aceitar — o que se parece exatamente com
`server did not start`.

**E isso liga o §8 ao §7.** O `wp123` falhou com **507**, que é
`ingest.begin` não conseguindo abrir o spool. Dois fixtures, dois sintomas
diferentes, o mesmo subsistema — e agora uma hipótese comum que não é sobre
tempo.

**O próximo passo é medir a mesma janela com `enable_upload` habilitado.**
Precisa de um binário de teste que ainda não existe; está nomeado e não feito.

## 6. Conteúdo

```
measure.sh        o harness: exec -> primeiro accept, por PID, sem pkill
raw-idle-ms.txt   12 medições sem carga
raw-load-ms.txt   12 medições sob 8 processos de CPU
```
