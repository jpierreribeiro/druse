# Três hosts mortos sob carga de campanha — e a hipótese que agora precisa ser testada

**2026-08-06.** O terceiro host morreu durante o R2-WP04 Final 2. Este documento
existe porque **três não é coincidência**, e porque a explicação confortável
("ambiente") ficou mais fraca que a desconfortável.

---

## 1. Os três

| # | data | host | quando morreu | sintoma |
|---|---|---|---|---|
| 1 | 2026-08-04 | `184.72.201.140` | sob carga | `sshd` travado; kernel trocado sozinho por auto-upgrade |
| 2 | 2026-08-04 | `3.208.73.168` | sob carga | sumiu da rede |
| 3 | **2026-08-06** | **`98.92.141.100`** (`i-0dc43a340e9ab0388`) | **~03:06–03:14Z**, **1h15 dentro do Final 2** | SSH, ICMP e 8080 sem resposta |

O terceiro tinha o auto-upgrade **desligado** — a causa do primeiro estava
eliminada por construção.

**Nenhum morreu ocioso. Os três morreram sob carga de campanha.**

## 2. O que já foi eliminado por medição

`conntrack` (1M de capacidade, 34 em uso), `tcp_max_tw_buckets` (65.536 contra
~1.900 de pico) e portas efêmeras. Nenhum dos três chegou perto de um limite.

## 3. A hipótese que eu vinha tratando como ruído

Eu vinha escrevendo "sem mecanismo conhecido" e classificando como achado de
**instrumento**. Com três, isso não se sustenta mais. A hipótese que precisa ser
testada é desconfortável:

> **O candidato pode estar derrubando o host.**

O que a torna plausível:

- os três morreram **sob carga**, nenhum ocioso;
- o servidor usa **io_uring**, e este projeto já tem um achado de io_uring com
  `RLIMIT_MEMLOCK` (F-C03-2) — memória fixada por anéis é memória do **kernel**,
  não do processo, e **não aparece no RSS** que o soak monitora;
- o Final 1 rodou 12 h no mesmo host sem matá-lo, então, se for isso, é
  **acumulativo entre runs** ou depende de uma condição que o Final 1 não teve.

**O que a enfraquece:** os sintomas dos três diferem, o RSS do Final 1 ficou em
0,99 KiB/h, e a instância pode ter morrido por razão de infraestrutura que não
temos como ver sem os logs da AWS.

## 4. Por que isto muda de categoria

Enquanto era "instrumento", o custo era perder corridas. Se for o produto, é
**P0 de produção**: um framework que derruba a máquina depois de horas de carga
não é promovível a R2 sob nenhuma leitura.

**Isto entra no R2-WP08 como item aberto de severidade máxima**, e a §4.1 do
pacote de decisão precisa lê-lo antes de qualquer promoção.

## 5. O que fazer, em ordem

1. **Antes de relançar: o diagnóstico.** Console da AWS (system log e screenshot
   da instância), `dmesg` pós-boot, `journalctl -k -b -1`. **Relançar sem olhar
   perde a terceira amostra**, e já perdemos as duas primeiras assim.
2. **Instrumentar memória de kernel**, que é o ponto cego apontado na §3:
   `/proc/meminfo` (`Unevictable`, `Mlocked`), `slabtop`, contadores de io_uring.
   O soak monitora RSS e RSS não veria isso.
3. **Separar produto de campanha:** rodar carga equivalente contra um servidor
   que **não** seja o Druse (ou o Druse sem io_uring, se houver caminho) no mesmo
   tipo de host. Se o host morrer também, é ambiente. **Se só morrer com o
   Druse, o achado é nosso.** É o mutante que falta.
4. Só então relançar o Final 2.

## 6. O que este episódio custou, e o erro que foi meu

O Final 2 morreu **1h15 dentro de 12 h**, às ~03:06Z. **Eu só descobri às
11:53Z** — quase nove horas depois.

O monitor que eu deixei rodando fazia isto:

```bash
out=$(ssh ... 'echo "n=$(find ... | wc -l)"' 2>/dev/null | tail -1)
case "$out" in
  DONE) ... ;;
  *)    echo "$(date -u +%H:%MZ) $out" ;;     # <- ssh falhou: $out vazio
esac
```

Quando o SSH morre, `$out` fica **vazio** e o monitor imprime uma linha com hora
e nada mais. **Setenta e duas linhas em branco**, uma a cada sete minutos, todas
parecendo atividade normal.

**Eu tinha documentado exatamente este defeito no dia anterior**, na §10.2 das
notas da escada: *"um instrumento que reporta zero quando quebra é
indistinguível de um run morto"*. Escrevi isso sobre três comandos meus, e então
construí um monitor com a mesma falha e não olhei a saída dele por nove horas.

**A correção:** um monitor tem de distinguir **três** estados — progrediu, não
progrediu, **não consegui perguntar** — e o terceiro tem de ser barulhento.
Silêncio não pode ser indistinguível de saúde.
