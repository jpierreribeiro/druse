# Política de compatibilidade

**Decidida em 2026-08-04.** Segundo entregável do R3-WP06. A companheira de
[`release-policy.md`](release-policy.md): aquela diz *quando* publicamos, esta
diz *o que continua valendo* entre um release e o próximo.

---

## 1. As quatro superfícies, porque elas não têm a mesma promessa

Tratar "compatibilidade" como uma coisa só é como este tipo de política falha.
Aqui são quatro, com promessas diferentes e cada uma com o instrumento que a
verifica.

| Superfície | O que é | Promessa em 0.x | Verificado por |
|---|---|---|---|
| **API pública** | os símbolos exportados de `web` | enumerada; muda só em MINOR | `build/check_public_api.sh`, `tests/wp2-public-surface` |
| **Comportamento de wire** | o que sai no socket para uma dada requisição | **a mais forte das quatro** | corpus WP9, fuzz de wire, comparação de framing pelo proxy |
| **Configuração** | `Limits`, `trust_proxies`, argumentos de `serve` | muda só em MINOR, com diff **nos dois sentidos** | `CHANGELOG.md` + rollback (§9 da política de release) |
| **Perfil suportado** | plataforma, toolchain, proxy, topologia | muda com aviso; estreitar é quebra | `docs/supported-profile.md`, `build/check_supported_profile.sh` |

**A de wire é a mais forte de propósito.** Uma mudança de assinatura o
compilador pega; uma mudança de comportamento de wire chega ao cliente de alguém
em produção sem nada avisar. É por isso que ela tem corpus e fuzzer, e a API tem
uma lista.

## 2. O que é quebra, enumerado

**É quebra:**

- remover ou renomear símbolo público;
- mudar assinatura, ordem de parâmetros ou tipo de retorno;
- mudar **status, cabeçalho ou enquadramento** para uma requisição que antes
  recebia outro — inclusive trocar um fechamento silencioso por um status, que é
  melhoria e ainda assim é quebra;
- estreitar o perfil suportado (tirar uma plataforma, exigir proxy mais novo);
- mudar o significado de um valor de configuração mantendo o nome;
- mudar um default.

**Não é quebra:**

- adicionar símbolo, rota, campo de configuração com default preservado;
- corrigir um comportamento que a documentação **já descrevia de outro jeito** —
  aí o defeito era o código, e o contrato é o que estava escrito;
- mudar mensagem de log, texto de erro interno ou nome de métrica não exportada;
- mudar desempenho.

**A terceira linha da segunda lista é a que mais precisa de cuidado**, porque é a
brecha por onde qualquer mudança pode ser justificada. A regra que a limita:
**vale só quando a documentação anterior é citável.** Se a doc era omissa, o
comportamento observado é o contrato, e mudá-lo é quebra.

## 3. Quando uma correção de segurança quebra

**Segurança ganha, e a nota diz o que custou.**

O precedente é o **TRUST-001**, de hoje: `trust_proxies` casava prefixo sem
âncora, então `"127.0.0.1"` também confiava em ~110 endereços vizinhos. O
conserto **mudou o significado de uma entrada de configuração sem mudar o nome**
— quebra pela §2.

Foi aplicado sem janela de depreciação, e a razão vale como regra:

> **Uma janela de depreciação sobre uma API insegura prolonga a insegurança.**
> Quando a assinatura *é* o defeito, a remoção é imediata e a nota de release diz
> por que a janela não foi dada.

E a mesma nota tem de dizer **o que fazer**: aqui, que entradas como `"10."`
seguem funcionando e uma entrada sem separador passou a significar exatamente um
endereço.

## 4. O que 0.x não promete, dito antes de alguém descobrir

- **nenhum backport** — §3 da política de release;
- **nenhuma estabilidade de ABI**: o consumo é por fonte vendorizada, e não há
  binário compartilhado a manter;
- **nenhuma estabilidade de layout de struct** para tipos que a API pública
  devolve por valor, além do que o compilador exige;
- **nenhuma compatibilidade de artefato de evidência** entre esquemas — o schema
  do soak é versionado (`soak/1`) e o analisador recusa o que não conhece, o que
  é o comportamento certo e ainda assim uma quebra para quem guardou artefatos;
- **nenhuma promessa sobre o `vendor/`**: o fork do `odin-http` tem 43+
  divergências governadas por ledger, e reconciliá-lo é a Fase 3 do programa R3.
  Quem depende de detalhe interno do vendor depende de coisa que vai mudar.

## 5. Upgrade

**O caminho suportado é um MINOR por vez.** Pular versões é permitido e não
testado — e a diferença entre as duas coisas está aqui de propósito.

Para atualizar:

1. leia **"O que quebra"** no `CHANGELOG.md` de **cada** MINOR entre a sua e a
   nova;
2. atualize o submódulo para a tag nova;
3. compile — o contrato de API cai aqui;
4. rode seus testes contra as mudanças de wire e configuração, que **não** caem
   na compilação;
5. tenha o artefato anterior e a configuração anterior à mão antes de implantar
   (§9 da política de release).

O passo 4 é o que este projeto não pode fazer por você: só a sua suíte sabe quais
comportamentos de wire a sua aplicação assume.

## 6. Como esta política muda

Alterar este arquivo é mudar uma promessa, então segue a mesma regra que ele
impõe: **a mudança aparece no `CHANGELOG.md` do release em que passa a valer**,
com a data e a razão. Uma política de compatibilidade que muda em silêncio é uma
contradição em termos.

---

**Fecha:** o segundo entregável do R3-WP06.
**Falta para a L6:** um release executado pelo checklist da política de release —
uma política só vale depois de ter sido seguida uma vez.
