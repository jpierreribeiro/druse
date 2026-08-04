#!/usr/bin/env bash
# R2-WP05 experimento 1 — retomada dos três braços que faltam.
#
#   usage: resume-sweep.sh   (no host de campanha, dentro de ~/soak-runs/repo)
#
# O sweep de 2026-08-04 parou em cinco de oito braços quando o host ficou
# inacessível pela segunda vez no mesmo dia. Faltam rep2-C, rep2-B e rep2-A.
#
# ESTE SCRIPT NÃO COMEÇA MEDINDO. Ele diagnostica primeiro, e recusa continuar se
# o ambiente mudou — porque duas coisas podem invalidar os cinco braços já
# medidos, e descobrir qualquer uma delas depois de rodar mais três seria pior do
# que não rodar.
set -uo pipefail

BASE="${DRUSE_WP05_BASE:-$HOME/soak-runs}"
OUT="$HOME/wp05-results"
DIAG="$HOME/wp05-resume-diagnostics.txt"

echo "=== 1. DIAGNÓSTICO, antes de qualquer carga ==="
{
  echo "resume_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "## por que este bloco existe: dois hosts caíram sob a carga desta"
  echo "## campanha em 2026-08-04, e não há mecanismo — só correlação."
  echo "uptime=$(uptime)"
  echo "kernel=$(uname -r)"
  echo "cpu_model=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)"
  echo "siblings=$(lscpu -e=CPU,CORE 2>/dev/null | tail -n +2 | tr '\n' ';')"
  echo "mem_available_kib=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)"
  echo "conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo absent)"
  echo "conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo absent)"
  echo "tw_sockets=$(ss -tan state time-wait 2>/dev/null | wc -l)"
  echo "ephemeral_range=$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)"
  echo "somaxconn=$(cat /proc/sys/net/core/somaxconn 2>/dev/null)"
  echo "## os contadores que uma rajada de reconexão estressa:"
  nstat -az 2>/dev/null | grep -E "TcpExtListenOverflows|TcpExtListenDrops|TcpExtTCPReqQFullDrop|TcpAttemptFails|TcpOutRsts" || echo "nstat indisponível"
  echo "## últimas linhas do kernel — OOM, drops, ENA resets:"
  dmesg -T 2>/dev/null | tail -40 || echo "dmesg indisponível sem privilégio"
} | tee "$DIAG"

echo
echo "=== 2. O AMBIENTE AINDA É O MESMO? (G1) ==="
# Os cinco braços medidos rodaram num Xeon Platinum 8275CL, kernel
# 6.17.0-1017-aws. Um stop/start pode ter caído em hardware diferente, e sob G1
# isso é ambiente novo: os braços antigos NÃO se juntam aos novos.
WANT_CPU="Intel(R) Xeon(R) Platinum 8275CL CPU @ 3.00GHz"
WANT_KERNEL="6.17.0-1017-aws"
GOT_CPU="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)"
GOT_KERNEL="$(uname -r)"
DRIFT=0
[[ "$GOT_CPU" == "$WANT_CPU" ]] || { echo "  CPU MUDOU: '$GOT_CPU' != '$WANT_CPU'"; DRIFT=1; }
[[ "$GOT_KERNEL" == "$WANT_KERNEL" ]] || { echo "  KERNEL MUDOU: '$GOT_KERNEL' != '$WANT_KERNEL'"; DRIFT=1; }
if (( DRIFT )); then
  cat >&2 <<'MSG'

PARADA: o ambiente mudou.

Os cinco braços de 2026-08-04 pertencem ao ambiente anterior. Sob G1 os novos
não se juntam a eles, e rodar rep2-C/B/A aqui produziria um experimento cujas
duas metades vêm de máquinas diferentes — que é exatamente o que a regra existe
para impedir.

O que fazer: emendar o pré-registro do WP05 nomeando o ambiente novo, e REINICIAR
o experimento pelos oito braços. Não retomar pelos três.
MSG
  exit 2
fi
echo "  CPU e kernel conferem com o ambiente dos cinco braços."

echo
echo "=== 3. OS CINCO BRAÇOS SOBREVIVERAM? ==="
FOUND=0
for arm in rep1-A rep1-B rep1-C rep1-D rep2-D; do
  if [[ -f "$OUT/$arm.manifest" ]]; then
    printf "  %-8s %s\n" "$arm" "$(awk -F= '/^saturation_refusals=/{print "recusas="$2}' "$OUT/$arm.manifest")"
    FOUND=$((FOUND + 1))
  else
    echo "  $arm  AUSENTE"
  fi
done
if (( FOUND < 5 )); then
  cat >&2 <<MSG

PARADA: só $FOUND dos 5 manifestos sobreviveram.

Sem os manifestos, os números observados são registro de conversa e não
evidência — a regra do programa é que medição sem artefato não promove nada.
Rodar três braços para juntar a cinco que não existem produz um experimento com
cinco buracos.

O que fazer: reiniciar o experimento pelos oito braços.
MSG
  exit 3
fi

echo
echo "=== 4. QUALIFICAÇÃO (o host mudou de IP; a anterior era da outra máquina) ==="
cd "$BASE/repo" || { echo "sem checkout em $BASE/repo" >&2; exit 4; }
export DRUSE_ODIN_BIN="${DRUSE_ODIN_BIN:-$HOME/odin-pinned/odin}"
export PATH="$HOME/odin-pinned:$PATH"
export DRUSE_SOAK_BASE="$BASE"
export DRUSE_SOAK_SERVER_CPUS=0,1,4,5
export DRUSE_SOAK_GENERATOR_CPUS=2,3,6,7
export DRUSE_SOAK_LANES=2
export DRUSE_SOAK_HEALTH_RATE=20 DRUSE_SOAK_TINY_RATE=600 DRUSE_SOAK_JSON_ENCODE_RATE=90
export DRUSE_SOAK_JSON_DECODE_RATE=240 DRUSE_SOAK_BYTES_64K_RATE=9 DRUSE_SOAK_WAIT_40MS_RATE=1
bash ops/soak/preflight.sh "$HOME/preflight-resume.txt" || {
  echo "PARADA: o host não qualifica. O relatório diz por quê." >&2; exit 5; }
echo "  preflight=pass"

echo
echo "=== 5. OS TRÊS BRAÇOS QUE FALTAM ==="
# Ordem preservada do desenho: a repetição 2 roda D, C, B, A. O D já rodou.
run() {
  local tag="$1" lanes="$2" period="$3"
  echo "### $tag lanes=$lanes period=$period $(date -u +%H:%M:%SZ)"
  bash ops/wp05/burst-sweep.sh "$BASE" "$tag" "$lanes" "$period" 1200 \
    >"$OUT/$tag.log" 2>&1
  local rc=$?
  if (( rc != 0 )); then echo "### $tag INVALIDO exit=$rc (W4)"; return 1; fi
  cp "$BASE/wp05/$tag/manifest.txt" "$OUT/$tag.manifest"
  echo "### $tag recusas=$(awk -F= '/^saturation_refusals=/{print $2}' "$OUT/$tag.manifest") bursts=$(awk -F= '/^bursts=/{print $2}' "$OUT/$tag.manifest")"
  # Folga entre braços. Não é superstição: dois hosts caíram sob esta carga e o
  # mecanismo é desconhecido. Sessenta segundos deixam o TIME_WAIT drenar e dão
  # ao kernel uma janela sem rajada. Se o host cair mesmo assim, a folga não era
  # a variável — e isso também é informação.
  sleep 60
}

run rep2-C 2 20 && run rep2-B 2 60 && run rep2-A 2 0
echo "RESUME_DONE"
