#!/usr/bin/env bash
# O experimento A/B da morte de host: Druse × não-Druse, sob a MESMA carga.
#
#   uso: host-death-ab.sh --arm druse|control --minutes N --out DIR
#
# CONTRATO: planning/readiness/HOST-DEATH-preregistration.md
#
# A ÚNICA VARIÁVEL É O SERVIDOR. Gerador, taxas, conexões, taskset, estrutura de
# ciclo e as duas injeções são idênticos aos do run-soak.sh, porque a hipótese
# H-C diz que a causa pode estar na campanha e não no servidor — e uma campanha
# diferente entre os braços não distinguiria H-B de H-C.
#
# O QUE É FIEL AO run-soak.sh (conferido linha a linha em 2026-08-06):
#   fase de 120 s, escalonamento de lançamento, 5 s entre ciclos
#   health 20/16, tiny 702/128, json-encode 105/128, json-decode 280/256 POST,
#   bytes-64k 10/64, wait-40ms 1/32
#   a cada 5º ciclo: rst (128 × 20 ms, 16 conexões) E slow_readers (24 × /bytes/1m, 8 s)
#
# O QUE NÃO É, DE PROPÓSITO:
#   sem análise, sem graduação, sem verdict.json. Este roteiro não julga o
#   produto; ele responde "o host sobreviveu?". A variável de saída é medida
#   DE FORA, por ops/soak/watch-remote.sh, porque um host morto não registra a
#   própria morte.
#   sem -raw por requisição. O forense de falha não é a pergunta aqui, e 4,25 GiB
#   de escrita por 12 h seriam uma diferença gratuita entre este roteiro e o
#   que se quer isolar.
#
# ISTO NÃO É COMPARAÇÃO DE PERFORMANCE e não pode ser reportado como uma. Ele
# iguala carga OFERECIDA, não trabalho realizado — o §8 do pré-registro do soak
# proíbe o resto.
set -u

ARM=""; MINUTES=120; OUT=""; PORT="${DRUSE_AB_PORT:-8080}"
SERVER_CPUS="${DRUSE_SOAK_SERVER_CPUS:-0,1,4,5}"
GEN_CPUS="${DRUSE_SOAK_GENERATOR_CPUS:-2,3,6,7}"
PHASE_SECONDS=120
STAGGER=1

while (( $# )); do
  case "$1" in
    --arm)     ARM="$2"; shift 2 ;;
    --minutes) MINUTES="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    *) echo "argumento desconhecido: $1" >&2; exit 2 ;;
  esac
done

die() { echo "host-death-ab: $*" >&2; exit 1; }
[[ "$ARM" == druse || "$ARM" == control ]] || die "--arm tem de ser druse ou control"
[[ -n "$OUT" ]] || die "faltou --out"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$OUT/cycles" "$OUT/control"

# --- a porta tem de estar livre, e o dono dela tem de ser NOSSO --------------
# Aprendido em 2026-08-04: um braço morreu deixando o servidor vivo, e os sete
# seguintes mediram o processo órfão sem perceber.
if (cat < /dev/null > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  die "a porta $PORT já está ocupada — recuso medir o servidor de outro processo"
fi

# --- construir o braço --------------------------------------------------------
if [[ "$ARM" == druse ]]; then
  command -v "${DRUSE_ODIN_BIN:-odin}" >/dev/null 2>&1 || die "odin não encontrado"
  # -collection:druse é obrigatório: o soak-server faz `import web "druse:web"`.
  # Sem ele o build morre com "Unknown library collection", e sem esta linha o
  # roteiro morreria na hora zero do host. Achado ensaiando o braço localmente.
  ( cd "$REPO" && "${DRUSE_ODIN_BIN:-odin}" build ops/soak/soak-server \
      -collection:druse="$REPO" -o:speed -out:"$OUT/bin-server" ) \
    || die "build do soak-server falhou"
  SERVER_CMD=("$OUT/bin-server" 0 "$PORT" "$OUT/control/snapshot.txt")
else
  command -v go >/dev/null 2>&1 || die "go não encontrado"
  ( cd "$REPO/ops/soak/control-server" && go build -buildvcs=false -trimpath -o "$OUT/bin-server" main.go ) \
    || die "build do control-server falhou"
  SERVER_CMD=("$OUT/bin-server" "$PORT")
fi

OPENLOAD="$OUT/bin-openload"
( cd "$REPO/ops/soak/openload" && go build -buildvcs=false -trimpath -o "$OPENLOAD" main.go ) \
  || die "build do openload falhou"

# --- identidade ---------------------------------------------------------------
{
  echo "schema=host-death-ab/1"
  echo "arm=$ARM"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "minutes=$MINUTES"
  echo "phase_seconds=$PHASE_SECONDS"
  echo "server_cpus=$SERVER_CPUS"
  echo "generator_cpus=$GEN_CPUS"
  echo "kernel=$(uname -srmo)"
  echo "hostname=$(hostname 2>/dev/null || echo unknown)"
  echo "git_tree=$(cd "$REPO" && git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "server_sha256=$(sha256sum "$OUT/bin-server" | awk '{print $1}')"
  echo "openload_sha256=$(sha256sum "$OPENLOAD" | awk '{print $1}')"
  echo "root_device=$(findmnt -no SOURCE / 2>/dev/null || echo unknown)"
} >"$OUT/manifest.txt"

# --- subir o servidor e o vigia ----------------------------------------------
taskset -c "$SERVER_CPUS" "${SERVER_CMD[@]}" >"$OUT/control/server.log" 2>&1 &
server_pid=$!
sleep 2
kill -0 "$server_pid" 2>/dev/null || die "o servidor não subiu; ver control/server.log"
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$PORT/health" || true)
  [[ "$code" == 200 ]] && break
  sleep 1
done
[[ "${code:-}" == 200 ]] || die "o servidor subiu mas /health não respondeu 200"
echo "server_pid=$server_pid" >"$OUT/control/server.pid"

bash "$REPO/ops/soak/kernel-watch.sh" --pid "$server_pid" \
  --out "$OUT/kernel-watch.csv" --interval 5 >"$OUT/control/kernel-watch.log" 2>&1 &
watch_pid=$!
sleep 6
kill -0 "$watch_pid" 2>/dev/null || die "o kernel-watch não ficou de pé; ver control/kernel-watch.log"

cleanup() {
  kill "$watch_pid" 2>/dev/null || true
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

# --- a carga ------------------------------------------------------------------
run_load() {
  local cycle="$1" name="$2" path="$3" rate="$4" conns="$5" method="${6:-GET}" payload="${7:-}"
  local args=(-url "http://127.0.0.1:$PORT$path" -method "$method" -rate "$rate"
              -duration "${PHASE_SECONDS}s" -connections "$conns" -timeout 5s)
  [[ -n "$payload" ]] && args+=(-payload "$payload")
  taskset -c "$GEN_CPUS" "$OPENLOAD" "${args[@]}" \
    >"$OUT/cycles/c$(printf '%04d' "$cycle")-$name.json" \
    2>"$OUT/cycles/c$(printf '%04d' "$cycle")-$name.err" &
  LAST_PID=$!
}

run_rst() {
  taskset -c "$GEN_CPUS" "$OPENLOAD" -url "http://127.0.0.1:$PORT/tiny" \
    -rst-count 128 -rst-delay 20ms -connections 16 \
    >"$OUT/cycles/c$(printf '%04d' "$1")-rst.json" \
    2>"$OUT/cycles/c$(printf '%04d' "$1")-rst.err" &
  LAST_PID=$!
}

run_slow_readers() {
  python3 - "$PORT" >"$OUT/cycles/c$(printf '%04d' "$1")-slow-readers.txt" 2>&1 <<'PY' &
import socket, sys, time
port = int(sys.argv[1])
sockets = []
for _ in range(24):
    sock = socket.create_connection(("127.0.0.1", port), timeout=2)
    sock.sendall(b"GET /bytes/1m HTTP/1.1\r\nHost: soak\r\nConnection: close\r\n\r\n")
    sockets.append(sock)
time.sleep(8)
for sock in sockets:
    sock.close()
print(f"opened_and_closed={len(sockets)}")
PY
  LAST_PID=$!
}

END_EPOCH=$(( $(date +%s) + MINUTES * 60 ))
cycle=0
echo "cycle,started_utc,ended_utc,health_status" >"$OUT/cycles.csv"

while [[ "$(date +%s)" -lt "$END_EPOCH" ]]; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "server_died_cycle=$cycle" >"$OUT/control/server-died.txt"
    break
  fi
  cycle=$((cycle + 1))
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  pids=()
  run_load "$cycle" health       /health              20  16;       pids+=("$LAST_PID"); sleep "$STAGGER"
  run_load "$cycle" tiny         /tiny                702 128;      pids+=("$LAST_PID"); sleep "$STAGGER"
  run_load "$cycle" json-encode  /json/medium         105 128;      pids+=("$LAST_PID"); sleep "$STAGGER"
  run_load "$cycle" json-decode  /json/medium/decode  280 256 POST medium-json; pids+=("$LAST_PID"); sleep "$STAGGER"
  run_load "$cycle" bytes-64k    /bytes/64k           10  64;       pids+=("$LAST_PID"); sleep "$STAGGER"
  run_load "$cycle" wait-40ms    /wait/40ms           1   32;       pids+=("$LAST_PID")
  if (( cycle % 5 == 0 )); then
    run_rst "$cycle";          pids+=("$LAST_PID")
    run_slow_readers "$cycle"; pids+=("$LAST_PID")
  fi
  for pid in "${pids[@]}"; do [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true; done
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/health" || echo "000")
  echo "$cycle,$started,$(date -u +%Y-%m-%dT%H:%M:%SZ),$code" >>"$OUT/cycles.csv"
  sleep 5
done

{
  echo "ended_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "cycles=$cycle"
  echo "server_alive_at_end=$(kill -0 "$server_pid" 2>/dev/null && echo yes || echo no)"
  echo "kernel_watch_samples=$(( $(wc -l <"$OUT/kernel-watch.csv" 2>/dev/null || echo 1) - 1 ))"
} >"$OUT/control/final-state.txt"

echo "AB_ARM_${ARM}_DONE"
