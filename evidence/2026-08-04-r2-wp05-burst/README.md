# R2-WP05, experimento 1 — **INTERROMPIDO**, cinco de oito braços

**2026-08-04.** Este pacote **não conclui o experimento** e **não sustenta
nenhuma conclusão sobre H1 ou H2**. Ele existe para que o trabalho seja
retomável e para que os números observados não virem lenda.

O contrato é
[`../../planning/readiness/R2-WP05-burst-preregistration.md`](../../planning/readiness/R2-WP05-burst-preregistration.md).

---

## 1. Por que está interrompido

O host de campanha `44.212.50.252` ficou inacessível durante a segunda
repetição — sem ICMP e sem TCP em porta nenhuma, com a instância marcada
*Running* no console. Um reboot não restaurou; um stop/start moveu o IP para
`3.208.73.168` e, até o fim desta sessão, também não respondeu.

**É o segundo host perdido no mesmo dia, ambos sob carga desta campanha.** O
primeiro (`184.72.201.140`) travou o `sshd` de outro jeito — aceitava TCP e nunca
mandava banner. Sintomas diferentes enfraquecem uma causa única, mas o padrão
está registrado como achado aberto em vez de acidente (§4).

## 2. O que foi observado

**Estes números vêm do log do sweep lido por ssh. Os manifestos que os
sustentam estão em `~/wp05-results/` no host e NÃO foram recuperados.** Sob as
regras do programa, uma medição sem artefato não é evidência — então a tabela
abaixo é um **registro de observação**, não um resultado.

| braço | lanes | rajadas | recusas de carga | status |
|---|---:|---:|---:|---|
| rep1-A | 2 | 1 | **0** | observado |
| rep1-B | 2 | 20 | **4** | observado |
| rep1-C | 2 | 60 | **13** | observado |
| rep1-D | **4** | 20 | **0** | observado |
| rep2-D | **4** | 20 | **0** | observado |
| rep2-C | 2 | 60 | — | interrompido |
| rep2-B | 2 | 20 | — | não rodou |
| rep2-A | 2 | 1 | — | não rodou |

Todos os braços rodaram **a mesma taxa agregada (960/s) e a mesma duração
(1200 s)**. Só a estrutura de reconexão e o número de lanes mudaram.

## 3. Por que isto NÃO declara H1 nem H2

Os critérios foram congelados antes da medição, e nenhum dos dois está
satisfeito:

- **W1** exige crescimento monotônico de A para B para C **nas duas
  repetições**. A segunda não tem A, B nem C completos.
- **W3** exige `D < B` **nas duas repetições**. A segunda não tem B.

**A primeira repetição é coerente** — uma taxa constante de ~0,21 recusa por
rajada reproduz A, B e C, e D zerou com o dobro de lanes. Mas coerência em uma
repetição é exatamente o que o desenho de duas repetições existe para não
aceitar, e o W1 foi escrito **antes** de eu ver qualquer número, para este
momento.

**Declarar aqui seria usar o critério enquanto ele é conveniente.** O mesmo
critério me custou 2h40 no R2-WP04 hoje quando disparou contra mim; ele não vale
menos agora que atrapalha.

## 4. O achado que a interrupção produziu, e que não estava previsto

**Dois hosts perdidos em um dia, ambos sob carga desta campanha.**

O que distingue este experimento do soak do WP04 é a **densidade de
reconexão**: ~624 conexões novas a cada 20 segundos no braço C, contra uma a
cada 120 segundos no soak. É a variável que o experimento existe para explorar, e
é plausível que também seja a que derruba o host.

**Não tenho mecanismo, só correlação.** A conta de sockets em `TIME_WAIT` não
fecha como explicação: ~1.900 simultâneos contra ~28 mil portas efêmeras. Então
isto fica como pergunta, não como conclusão.

**O que isso muda no plano:** retomar o experimento sem diagnóstico arrisca
derrubar um terceiro host e gastar mais três horas para chegar ao mesmo lugar. O
próximo passo **não** é relançar os três braços — é olhar `dmesg`, contadores do
kernel e `netstat -s` num host vivo, antes de qualquer carga.

## 5. Como retomar

1. **host vivo, e diagnóstico ANTES de qualquer braço** (§4);
2. **conferir se `~/wp05-results/` sobreviveu** — se sim, os cinco braços viram
   evidência de verdade e faltam três; se não, o experimento reinicia;
3. **conferir CPU e kernel** — um stop/start pode cair em hardware diferente, e
   sob G1 isso é ambiente novo: os braços antigos não se juntam aos novos sem
   emenda;
4. `preflight.sh` + `smoke.sh` no host novo — a qualificação era da máquina
   antiga;
5. rodar `rep2-C`, `rep2-B`, `rep2-A` com `ops/wp05/burst-sweep.sh`, que já está
   commitado e endurecido.

**O instrumento e o pré-registro estão prontos e commitados.** O que falta é
máquina e três braços.
