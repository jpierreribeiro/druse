# Política de integridade de release

**Decidida em 2026-08-04.** Fecha o primeiro dos dois itens abertos do R2-WP06.

O WP06 pedia *"assinar checksums/release conforme política do projeto"* e
travava numa verdade simples: **não existia política**. Nenhum arquivo definia
chave, formato, custódia ou verificação. Este documento é a política.

---

## 1. A decisão

**Releases são verificados por hash, não assinados — e a nota de release diz
exatamente isso.**

Um artefato é aprovado gravando seu sha256 num registro commitado
(`ops/release/approve-artefact.sh`), e o que roda em produção é verificado
contra aquele registro (`ops/release/verify-deployed.sh`). A cadeia é:
**compilar uma vez → hashear aquele arquivo → implantar aquele arquivo → provar
que os bytes no alvo hasheiam para o valor aprovado.**

## 2. Por que não assinar agora

**Uma assinatura prova custódia, não integridade.** A integridade já está
provada: o hash está num arquivo versionado, e o `verify-deployed.sh` a confere.
O que uma assinatura acrescentaria é *quem aprovou*.

**E hoje não há um "quem" separado.** O projeto tem um único responsável. Uma
chave guardada na mesma máquina que faz o build, usada pela mesma pessoa que
commita o hash, protege contra um atacante que já teria as duas coisas. Ela
adiciona cerimônia, um segredo novo para vazar, e — o pior — **uma alegação de
garantia que a custódia não sustenta**.

Assinar cedo demais é pior que não assinar, porque um leitor orça risco contra a
assinatura. Este repositório já pagou por isso uma vez: o `trust_proxies` trazia
um argumento de segurança que a implementação não satisfazia (TRUST-001), e o
problema não era o código — era o leitor confiar na justificativa.

## 3. O gatilho, nomeado para que a decisão não seja permanente por inércia

**Assinar passa a ser exigido quando qualquer um destes for verdade:**

1. **um segundo mantenedor** puder aprovar releases — aí a assinatura passa a
   dizer *qual dos dois*, que é informação que não existe hoje;
2. **um canal de distribuição** entregar o artefato fora do repositório (registro
   de pacotes, imagem publicada, binário em CDN) — aí o hash deixa de estar
   ao lado do artefato e a assinatura passa a ser o vínculo;
3. **um adotante externo** pedir, o que é evidência direta de que a garantia
   atual não basta para o uso dele.

Quando o gatilho disparar, a política a escrever tem de nomear: algoritmo,
custódia da chave privada, rotação, revogação, e **como um terceiro verifica sem
confiar em nós**. Nada disso é decidível hoje sem inventar as respostas.

## 4. O que a nota de release tem de dizer, literalmente

> Verificado por hash. **Não assinado.** O sha256 do artefato implantado consta
> em `<registro>` e foi conferido contra os bytes no alvo.

**A palavra "assinado" não pode aparecer numa nota de release deste projeto
enquanto esta política estiver em vigor.** `approve-artefact.sh` grava a
distinção dentro do próprio registro (`not_claimed=`), para que um leitor do
artefato não precise achar este documento.

## 5. O que esta política NÃO promete

- **Não promete build reprodutível.** Está medido que não é: dois builds do mesmo
  commit, mesmo compilador, mesma máquina, produzem bytes diferentes com tamanho
  idêntico (`evidence/2026-08-03-r2-wp06-assurance/`). A causa é a toolchain e
  está fora do alcance deste repositório. O critério do R2-WP08 foi emendado por
  isso (§9.1): ele exige que o *artefato* seja o mesmo arquivo, não que o *build*
  seja reproduzível — o que é mais forte para o alvo e mais fraco para um
  terceiro que queira reconstruir.
- **Não promete revisão humana de código.** Ver §6.
- **Não promete janela de suporte.** Isso é `docs/release-policy.md` (L6), e é
  outro documento.

## 6. A declaração que um adotante precisa ler antes de confiar nisto

**Este framework foi construído inteiramente por IA. Não há código escrito por
humanos e não houve revisão humana linha a linha.**

Isso está aqui, numa política de integridade, porque é exatamente o tipo de fato
que um adotante usa para decidir quanto confiar — e omiti-lo enquanto se publica
uma cadeia de verificação seria deixar a cadeia sugerir uma garantia que ela não
dá.

**O que existe no lugar da revisão humana**, e é verificável em vez de
declarado:

- um gate de ~250 controles que roda inteiro antes de todo push;
- controle positivo **e mutante** para cada controle de segurança — a regra local
  é que um controle nunca visto vermelho é um controle não testado;
- corpus de comportamento de wire com casos derivados de defeitos reais;
- auditorias adversariais registradas, incluindo as que refutaram conclusões
  anteriores do próprio projeto;
- um programa de prontidão que recusa "existe um teste" e "funcionou na máquina
  do autor" como estados de encerramento.

**O que isso não substitui:** julgamento de um mantenedor experiente sobre o que
*não* foi testado. Um gate cobre o que alguém pensou em cobrir. É a razão pela
qual o portão deste projeto está em **R1 — piloto controlado** — e não em
produção geral, e a razão pela qual o item 1 do §3 (um segundo mantenedor) é o
primeiro gatilho da lista.

---

**Fecha:** R2-WP06, item "assinar checksums/release".
**Resultado:** política definida; assinatura **adiada com gatilho nomeado**, não
omitida.
