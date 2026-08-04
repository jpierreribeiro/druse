# Política de release

**Decidida em 2026-08-04.** Primeiro entregável do R3-WP06, e o instrumento que
remove a limitação **L6** — *pre-1.0, sem backports nem LTS* — classificada como
**bloqueante para adoção** em `planning/readiness/R3-programa-sem-limitacoes-bloqueantes.md` §1.1.

L6 é a mais barata das três limitações bloqueantes: não precisa de host, não
precisa do R2 fechado, e é documentação mais um release ensaiado. É por isso que
ela vem primeiro.

---

## 1. Onde este projeto está, sem eufemismo

**Pré-1.0.** A versão corrente é `v0.10.0`, e o número não é modéstia — é a
descrição correta do estado:

| | |
|---|---|
| portão de prontidão | **R1 — piloto interno não crítico** |
| produção geral | **não autorizada** |
| origem do código | **inteiramente gerado por IA, sem revisão humana linha a linha** (ver `release-integrity-policy.md` §6) |
| plataforma | Linux x86-64 apenas |
| TLS/HTTP2/WebSocket | por proxy revisado, não nativos |

**Se você está avaliando adoção, leia a linha do portão primeiro.** As políticas
abaixo dizem o que prometemos *sobre releases*; elas não promovem o produto.

## 2. Versionamento pré-1.0

**`0.MINOR.PATCH`, com a regra explícita porque semver deixa 0.x indefinido:**

- **MINOR** sobe quando o contrato público muda de forma que exige ação de quem
  atualiza — símbolo removido, assinatura alterada, comportamento observável
  diferente com a mesma chamada;
- **PATCH** sobe para correção, endurecimento e adição de símbolo novo que não
  quebra chamada existente.

**Em 0.x, um MINOR pode quebrar.** É o que 0.x significa, e está dito aqui em vez
de deixado para o leitor descobrir num upgrade.

**O contrato público é enumerado, não descrito.** `build/check_public_api.sh` e
`tests/wp2-public-surface` reprovam se um símbolo aparecer ou sumir sem que a
enumeração mude no mesmo commit. Isso é o que torna a regra acima verificável em
vez de uma intenção.

## 3. Janela de suporte

**Só a linha corrente é suportada.** Não há backport para MINOR anterior.

| | |
|---|---|
| suportado | o último `0.MINOR` publicado |
| correção de segurança | vai para o próximo release da linha corrente |
| backport | **nenhum** |
| LTS | **nenhum**, e não haverá antes do 1.0 |

**Por que zero backport, dito em vez de escondido:** backport exige manter duas
árvores verdes contra o mesmo gate, e o gate leva ~30 min por árvore. Prometer
backport com um responsável só produziria uma promessa que a primeira urgência
quebraria. **Uma janela de suporte curta e verdadeira vale mais que uma longa e
condicional.**

Quem precisa de estabilidade maior que isso: fixe um commit, vendorize, e
atualize deliberadamente. A §6 descreve o modo de consumo que este projeto
suporta e que torna isso natural.

## 4. Checklist de release

Todo release executa isto na ordem, e cada passo é verificável por comando:

1. **árvore limpa** e no `main` sincronizado;
2. **`bash build/check.sh` verde por inteiro** — ~250 controles, ~30 min. Um
   release nunca sai de uma árvore com gate vermelho, mesmo que a falha "não
   tenha relação";
3. **contrato público conferido** — o gate já o faz; se a enumeração mudou, a
   §2 diz se é MINOR ou PATCH;
4. **CHANGELOG.md atualizado** com as entradas do §5;
5. **construir uma vez** e aprovar o artefato: `ops/release/approve-artefact.sh`
   grava sha256, tamanho, commit, tree e toolchain, e **recusa árvore suja**;
6. **BOM gerada** — `ops/release/generate-bom.sh`;
7. **tag anotada** com o corpo da nota de release;
8. **implantar aquele arquivo** e provar com `ops/release/verify-deployed.sh`
   que os bytes no alvo hasheiam para o valor aprovado;
9. **nota de release publicada** com a frase literal da política de integridade:
   *verificado por hash, **não assinado***.

**O passo 8 é o critério de saída do R2-WP08**, emendado em 2026-08-03 porque
build reprodutível está *medido* como insatisfazível nesta toolchain — dois
builds do mesmo commit produzem bytes diferentes com tamanho idêntico. O critério
mudou de objeto, não de rigor: o artefato revisado é o artefato que roda.

## 5. Changelog e guia de upgrade

`CHANGELOG.md` carrega, por release:

- **O que quebra** — primeiro, sempre, mesmo que a lista seja vazia (escrever
  "nada quebra" é uma afirmação; omitir a seção é um silêncio);
- **O que foi corrigido**, com o identificador do achado quando existir
  (`TRUST-001`, `F-C03-2`, `STREAM-001`);
- **O que foi adicionado** ao contrato público;
- **O que mudou de comportamento sem mudar assinatura** — a categoria que mais
  machuca quem atualiza, porque compila e age diferente;
- **Ações necessárias**, com o diff de configuração quando houver.

## 6. Modo de consumo suportado

Odin não tem gerenciador de pacotes oficial, então o modo suportado é
**vendoring por commit fixado**:

```
git submodule add https://github.com/jpierreribeiro/druse vendor/druse
git -C vendor/druse checkout <tag>
odin build . -collection:druse=vendor/druse
```

**Só isso é suportado.** Não há registro de pacotes, e o `docs/supported-profile.md`
define o resto do envelope.

## 7. CVE, advisory e divulgação

`SECURITY.md` é o documento normativo. Em resumo operacional:

- um achado de segurança vira release da linha corrente, **sem backport** (§3);
- a nota nomeia o achado e a classe, e o teste que o pina entra no mesmo commit
  da correção — a regra local é que **um controle nunca visto vermelho é um
  controle não testado**, então toda correção de segurança traz seu mutante;
- não há embargo formal com terceiros porque não há terceiros; se houver, esta
  seção precisa ser reescrita antes e não depois.

## 8. Depreciação

**Em 0.x: uma MINOR de aviso antes da remoção**, quando for possível avisar.

Um símbolo a remover é marcado no `CHANGELOG.md` como *deprecated* num release, e
removido no MINOR seguinte no mínimo. **Quando não for possível** — uma assinatura
que é o próprio defeito, como o TRUST-001 foi — a remoção é imediata e a nota diz
por que a janela não foi dada. Uma janela de depreciação sobre uma API insegura
prolonga a insegurança.

## 9. Rollback

- o artefato anterior continua aprovado e seu hash continua no registro;
- rollback é implantar o arquivo anterior e rodar `verify-deployed.sh` contra o
  hash antigo — mesmo comando, valor diferente;
- **compatibilidade de configuração é uma promessa de release**: se um MINOR
  exige mudança de configuração, o `CHANGELOG.md` traz o diff nos dois sentidos,
  porque rollback sem a configuração antiga não é rollback.

O R1 mediu rollback em **3 s** e o ensaio está registrado.

## 10. O que falta para 1.0

Não é uma lista de features. É o que o `R3-general-maturity.md` §R3-WP06 já
exige, e nenhum item está fechado:

- janela real de produção sobre a API e o comportamento;
- upgrades executados por aplicações **externas ao core**;
- suporte, toolchain e vendor definidos;
- P0/P1 históricos fechados com postmortem incorporado;
- documentação para consumidor validada por alguém que não a escreveu;
- **e a aceitação explícita do custo de compatibilidade** — que é o item que
  transforma 1.0 de marketing em obrigação.

**Enquanto o portão estiver em R1, 1.0 não está em discussão.**

---

**Fecha:** o primeiro entregável do R3-WP06 e a metade documental da L6.
**Falta para L6:** `docs/compatibility-policy.md` e **um release executado por
este checklist** — a política só vale depois de ter sido seguida uma vez.
