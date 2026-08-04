# L6 — o release ensaiado, passo a passo

**2026-08-04.** Executa o checklist de
[`docs/release-policy.md`](../../docs/release-policy.md) §4 de ponta a ponta.

**Por que isto existe:** uma política de release só vale depois de ter sido
seguida uma vez. Escrever nove passos e nunca executá-los produz um documento
que descreve um processo hipotético — e o R3 exige, para fechar a limitação
**L6**, *"os arquivos … + um release executado pelo checklist"*.

**O que este pacote NÃO é:** um release publicado. Ver §3.

---

## 1. Os passos, e o que cada um produziu

| # | Passo | Resultado |
|---|---|---|
| 1 | árvore limpa e sincronizada | 0 arquivos modificados, `main` = `origin/main` |
| 2 | `build/check.sh` verde por inteiro | **exit 0, 249 controles** |
| 3 | contrato público conferido | dentro do gate |
| 4 | `CHANGELOG.md` atualizado | seção `Unreleased` com o **Breaking** do TRUST-001 |
| 5 | construir uma vez e aprovar | `approval=pass`, `raw/approval.txt` |
| 6 | BOM gerada | `raw/bom.txt` |
| 7 | tag anotada | **não executado — ver §3** |
| 8 | implantar aquele arquivo e provar | **`deployed_identity=match`**, `raw/verify.txt` |
| 9 | nota publicada | **não executado — ver §3** |

Identidade do artefato ensaiado:

```
artefact_sha256 = 548001674bf505cc14be18ae1278ed08ee8dcaee6345d47cdb28c9d1f2f284c3
artefact_bytes  = 918672
commit          = 3ed117d168884af8839f3f6163c84005d7ac5ba6
odin            = dev-2026-07a / 819fdc7
```

## 2. O ensaio provou o verificador, não só o executou

Um passo 8 que só roda o caminho feliz não prova nada: um verificador quebrado
diz `match` para tudo. Três mutantes, cada um com o exit code:

| | Mutante | `verify` | exit |
|---|---|---|---|
| **M1** | um byte trocado, **tamanho idêntico** | `fail` | **1** |
| **M2** | arquivo ausente no alvo | `fail` | **1** |
| **M3** | argumentos na ordem errada | `fail` | **1** |

**O M1 é o que importa**, e a mensagem que ele produz é a razão:

> *the deployed file is 918672 bytes, exactly as approved, and hashes
> differently: identical size is not identity, and this is the case the rebuild
> measurement produced*

É exatamente a forma que a medição de 2026-08-03 encontrou — dois builds do mesmo
commit com **tamanho igual e bytes diferentes**. Um verificador que comparasse
comprimento passaria nele.

**O M3 é meu erro, promovido a controle.** Invoquei o script com os argumentos
trocados por engano; ele recusou nomeando a causa (*"a comparison against an
empty expectation passes for every file"*) em vez de comparar contra nada e dizer
`pass`. Ficou no pacote porque é o modo de falha mais provável de um operador
apressado.

### 2.1 E um mutante meu que não mutou

O primeiro M1 escreveu `0x00` no byte 1000 — que **já era** `0x00`. O arquivo
saiu idêntico, o verificador disse `pass`, e por um instante isso pareceu um
defeito grave no verificador.

Conferir `cmp` antes de acusar mostrou que o defeito era do teste. **Um mutante
que não muta é um controle que aprova qualquer coisa**, e a única defesa é
verificar a mutação em vez de assumi-la. Está registrado aqui porque é o erro
mais fácil de cometer em silêncio neste tipo de controle.

## 3. O que ficou de fora, e por quê

**Os passos 7 e 9 — a tag anotada e a nota publicada — não foram executados.**

Não é limitação técnica: é que os dois são **atos de publicação**. Publicar
`v0.11.0` coloca no mundo um release que carrega uma **quebra de compatibilidade**
(o TRUST-001, que pela §2 da política de release move o MINOR), num projeto cujo
portão de prontidão está em **R1** e cujo R2-WP04 está parado.

Isso é decisão do dono, e é de uma classe diferente das que foram delegadas hoje:
as outras eram escolhas de engenharia com efeito interno; esta é uma afirmação
para fora.

**O que falta é uma linha**, e o restante do checklist já foi provado executável:

```bash
git tag -a v0.11.0 -F <nota-de-release>
git push origin v0.11.0
```

**Enquanto ela não rodar, a L6 não fecha** — e a L6 é uma das três limitações
bloqueantes do R3. As outras duas metades (as três políticas) estão commitadas.

## 4. Conteúdo

```
raw/approval.txt     o registro de aprovação: hash, tamanho, commit, tree, toolchain
raw/bom.txt          a BOM (deliberadamente não chamada de SBOM)
raw/verify.txt       o passo 8 no caminho feliz: deployed_identity=match
raw/verify-m1.txt    byte trocado com tamanho idêntico -> fail
raw/verify-m2.txt    arquivo ausente -> fail
raw/verify-m3.txt    argumentos trocados -> fail
SHA256SUMS           de tudo acima
```
