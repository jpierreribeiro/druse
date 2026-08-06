# "The same candidate" — provado, e não por hash de binário

**2026-08-06.** A §9 do pré-registro exige *"two independent final runs of **the
same candidate**"*. Ninguém tinha verificado se os degraus da escada satisfazem
isso. Verifiquei. **Satisfazem — mas não pelo caminho que se esperaria.**

## O problema

| degrau | `server_sha256` | `openload_sha256` | `git_tree` |
|---|---|---|---|
| smoke | `5a5f39b7ce26fb54` | `bc61a8e6df38e852` | `8bcfe75dabb8` |
| burn-in | `ad0366622d7f07bb` | `bc61a8e6df38e852` | `8bcfe75dabb8` |
| rehearsal | `2d138c9959274979` | `bc61a8e6df38e852` | `8bcfe75dabb8` |
| Final 1 | `0d1693af47fb5953` | `bc61a8e6df38e852` | `8bcfe75dabb8` |

**A árvore é a mesma nos quatro. O binário do servidor é diferente nos quatro.**
O toolchain não é reprodutível — isto já era sabido, mas nunca tinha sido posto
contra a exigência da §9, onde ele deixa de ser curiosidade e vira um buraco:
*se o binário muda a cada build, em que sentido os dois finais testam a mesma
coisa?*

## A investigação

**Não é só metadado de build.** As quatro seções diferem assim:

| seção | veredito |
|---|---|
| `.text` | **4 variantes** |
| `.rodata` | 4 variantes |
| `.data.rel.ro` | 4 variantes |
| `.eh_frame` | 4 variantes |
| `.note.gnu.build-id` | 4 variantes |
| `.data`, `.init_array`, `.comment`, `.dynsym` | **idênticas** |

`.text` diferente é código diferente — não dava para descartar como carimbo de
build. Mas os quatro têm **exatamente 918.656 bytes**, o que aponta para
reordenação, não para código distinto.

## A prova

`nm --defined-only -S` nos quatro: **559 símbolos em todos**. Os ~20 nomes que
diferiam eram estáticos anônimos gerados pelo compilador, com sufixo de um
contador interno:

```
os::[file_linux.odin]::_standard_stream_init-.files-54157      (smoke)
os::[file_linux.odin]::_standard_stream_init-.files-53753      (final1)
                                             ^^^^^ mesmo símbolo, mesmo tamanho
```

Removido o contador, o inventário `(nome-base, tamanho)` dos quatro binários tem
**o mesmo sha256**:

```
7f018796871bc73d   smoke   burn-in   rehearsal   Final 1
```

Zero pares diferentes em qualquer par de degraus.

## O que isto autoriza dizer, e o que não

**Autoriza:** os quatro degraus rodaram o **mesmo programa** — mesma árvore
fonte, mesmo toolchain fixado, mesmo inventário de 559 símbolos com tamanhos
idênticos. A diferença de `.text` é de **ordenação**, e o contador do compilador
é a assinatura dela.

**Não autoriza:** dizer que os binários são intercambiáveis byte a byte, nem que
uma reordenação não pode ter efeito de performance — layout muda cache de
instrução. Não medi isso, e o efeito, se existir, está dentro da variação que os
quatro degraus já mostraram.

**E não autoriza generalizar para `nm`:** ele é cego a procedimentos inlined.
O que está provado é o inventário de símbolos, não cada instrução emitida.

## Por que isto importa para o WP08

A §9 trata "mesmo candidato" como dado. **Não era.** Com o toolchain
irreprodutível, a única leitura que sobreviveria a um revisor seria "os dois
finais rodaram binários diferentes e a comparação não é válida".

Agora há uma resposta com evidência: **mesma árvore, mesmo inventário, mesmo
toolchain fixado** — e a diferença de hash nomeada e explicada, em vez de
silenciada.

## Reproduzir

```bash
for f in smoke burnin rehearsal final1; do
  nm --defined-only -S server-$f | awk '{print $NF, $2}' | sed -E 's/-[0-9]+ / /' | sort
done | ...   # os quatro dão o mesmo sha256
```
