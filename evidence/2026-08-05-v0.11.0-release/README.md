# v0.11.0 — o release que fecha a L6

**2026-08-05.** O checklist de [`docs/release-policy.md`](../../docs/release-policy.md)
§4 executado **inteiro**, nove passos de nove.

Este é o release que a política existia para descrever. Uma política de release
só vale depois de ter sido seguida uma vez — e o R3 exige, para fechar a
limitação **L6** (*pre-1.0, sem backports nem LTS*), *"os arquivos … + um release
executado pelo checklist"*.

---

## 1. Os nove passos

| # | Passo | Resultado |
|---|---|---|
| 1 | árvore limpa e sincronizada | 0 modificados, `main` = `origin/main` |
| 2 | `build/check.sh` verde por inteiro | **exit 0, 249 controles**, zero falhas |
| 3 | contrato público conferido | dentro do gate |
| 4 | `CHANGELOG.md` | `Unreleased` promovido a `[0.11.0]` |
| 5 | construir **uma** vez e aprovar | `approval=pass` |
| 6 | BOM gerada | `raw/bom.txt` |
| 7 | tag anotada | `v0.11.0`, com a nota em `raw/nota.txt` |
| 8 | implantar aquele arquivo e provar | **`deployed_identity=match`** |
| 9 | publicar | `main` e `v0.11.0` em `origin` |

```
artefact_sha256 = d9d4bda67d0cba476e0db6a9b6efe87993a97359c771700ea292e32709276bf8
artefact_bytes  = 918672
commit          = 3c370b20c8bdb05f61ac2840981140e826484f7c
odin            = dev-2026-07a / 819fdc7
```

## 2. O passo 8 foi provado, não só executado

Um verificador quebrado diz `match` para tudo. O mutante rodou junto:

| | mutante | `verify` | exit |
|---|---|---|---|
| M1 | um byte trocado, **tamanho idêntico** | `fail` | **1** |

O M1 é a forma exata que a medição de 2026-08-03 encontrou — dois builds do
mesmo commit com tamanho igual e bytes diferentes. Um verificador que comparasse
comprimento passaria nele.

**A mutação foi conferida com `cmp` antes de ser usada**, porque no ensaio de
2026-08-04 o primeiro mutante escreveu `0x00` num byte que já era `0x00` e o
`pass` correto pareceu, por um instante, defeito grave do verificador.

## 3. O que a nota de release diz, e por quê

**"Verificado por hash. NÃO ASSINADO."** É a política de integridade, e a palavra
"assinado" fica proibida enquanto ela valer: assinatura prova *custódia*, e hoje
não há um "quem" separado — a chave estaria na mesma máquina do build, usada por
quem commita o hash.

**"Este framework foi construído inteiramente por IA."** Está na nota porque um
adotante usa isso para decidir quanto confiar, e publicar uma cadeia de
verificação omitindo o fato deixaria a cadeia sugerir uma garantia que ela não
dá. Junto vem o que existe no lugar (o gate, os mutantes, o corpus) e o que isso
**não** substitui: julgamento sobre o que ninguém pensou em testar.

**A quebra de compatibilidade vem primeiro, com a ação necessária.** É o TRUST-001,
correção de segurança, sem janela de depreciação — e a política de
compatibilidade §3 explica por que: uma janela sobre uma API insegura prolonga a
insegurança.

## 4. O que este release NÃO significa

- **Não move o portão.** Continua em **R1** — piloto interno não crítico.
- **Não é 1.0**, e a política lista os seis itens que faltariam.
- **Não promete backport.** Só a linha corrente, e isso é escolha declarada.

## 5. Conteúdo

```
raw/approval.txt   o registro de aprovação: hash, tamanho, commit, tree, toolchain
raw/bom.txt        a BOM (deliberadamente não chamada de SBOM)
raw/verify.txt     o passo 8: deployed_identity=match
raw/verify-m1.txt  o mutante de byte trocado -> fail, exit 1
raw/nota.txt       a nota de release publicada na tag
```
