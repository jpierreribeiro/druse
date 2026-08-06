#!/usr/bin/env bash
# Vigia de memória de KERNEL, ao lado de um run de soak.
#
#   uso: kernel-watch.sh --pid PID --out ARQUIVO.csv [--interval SEGUNDOS]
#        kernel-watch.sh --self-test          # G2: controle positivo + mutante
#
# POR QUÊ. O soak vigia RSS. Memória fixada por anéis de io_uring é memória de
# kernel: ela NÃO entra no RSS, e aparece em VmPin do processo e em
# Mlocked/Unevictable do /proc/meminfo. O indicador que mais nos tranquilizou no
# Final 1 (0,99 KiB/h de RSS) é cego exatamente onde a hipótese H-B moraria —
# ver planning/readiness/HOST-DEATH-preregistration.md §3.
#
# POR QUE FORA DO run-soak.sh. Mudar o runner alteraria runner_sha256 e quebraria
# a comparabilidade com o Final 1, que ainda vale. Este vigia é aditivo: não toca
# o instrumento pinado por hash.
#
# A REGRA DESTE ARQUIVO: ele tem TRÊS estados, e o terceiro é barulhento.
# Progrediu, não progrediu, e NÃO CONSEGUI PERGUNTAR. Um vigia que grava zero
# quando não consegue ler é indistinguível de um sistema saudável — foi esse
# defeito que custou nove horas em 2026-08-06, e ele não entra aqui.
set -u

INTERVAL=5
PID=""
OUT=""
SELF_TEST=0

while (( $# )); do
  case "$1" in
    --pid)      PID="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    *) echo "argumento desconhecido: $1" >&2; exit 2 ;;
  esac
done

die() { echo "kernel-watch: $*" >&2; exit 1; }

# --- leitura, com falha ruidosa -----------------------------------------------
# Cada uma destas devolve o valor OU grita. Nenhuma devolve 0 por não saber.

meminfo_kib() {  # $1 = campo
  local v
  v=$(awk -v k="$1:" '$1==k{print $2; found=1} END{if(!found) exit 3}' /proc/meminfo) \
    || die "campo '$1' ausente em /proc/meminfo — este kernel não expõe o que o vigia mede"
  echo "$v"
}

procstatus_kib() {  # $1 = pid, $2 = campo
  local v
  [[ -r "/proc/$1/status" ]] || die "não consigo ler /proc/$1/status — o processo morreu ou não é meu"
  v=$(awk -v k="$2:" '$1==k{print $2; found=1} END{if(!found) print "NA"}' "/proc/$1/status")
  echo "$v"   # NA é honesto: o campo pode não existir neste kernel. Zero não seria.
}

count_fds() {
  [[ -d "/proc/$1/fd" ]] || die "não consigo listar /proc/$1/fd"
  ls -1 "/proc/$1/fd" 2>/dev/null | wc -l
}

count_iouring_fds() {
  local n=0 t
  [[ -d "/proc/$1/fd" ]] || die "não consigo listar /proc/$1/fd"
  for f in "/proc/$1/fd"/*; do
    t=$(readlink "$f" 2>/dev/null) || continue
    [[ "$t" == "anon_inode:[io_uring]" ]] && n=$((n+1))
  done
  echo "$n"
}

# --- self-test (G2) -----------------------------------------------------------
if (( SELF_TEST )); then
  echo "== controle positivo: fixar 4 MiB e ver Mlocked subir =="
  before=$(meminfo_kib Mlocked)
  python3 - <<'PY' &
import ctypes, mmap, os, time
n = 4 * 1024 * 1024
buf = mmap.mmap(-1, n)
buf.write(b"\0" * n)
libc = ctypes.CDLL("libc.so.6", use_errno=True)
addr = ctypes.addressof(ctypes.c_char.from_buffer(buf))
rc = libc.mlock(ctypes.c_void_p(addr), ctypes.c_size_t(n))
if rc != 0:
    err = ctypes.get_errno()
    print(f"MLOCK_FALHOU errno={err}", flush=True)
    os._exit(9)
print("MLOCK_OK", flush=True)
time.sleep(6)
PY
  helper=$!
  sleep 2
  after=$(meminfo_kib Mlocked)
  delta=$(( after - before ))
  wait "$helper" 2>/dev/null; rc=$?
  if (( rc == 9 )); then
    echo "  INDETERMINADO: mlock recusado (RLIMIT_MEMLOCK=$(ulimit -l) KiB)." >&2
    echo "  Isto NÃO é um vigia aprovado. Aumente o limite e repita." >&2
    exit 3
  fi
  echo "  Mlocked: ${before} -> ${after} KiB (delta ${delta})"
  if (( delta < 3072 )); then
    die "controle positivo FALHOU: esperava >= 3072 KiB de subida, vi ${delta}"
  fi
  echo "  controle positivo: PASS"

  echo "== mutante: apontar para um PID inexistente e exigir GRITO =="
  if bash "$0" --pid 999999 --out /dev/null --interval 1 >/dev/null 2>&1; then
    die "mutante FALHOU: o vigia aceitou um PID inexistente. Ele gravaria zeros."
  fi
  echo "  mutante: PASS (recusou, como tem de recusar)"
  echo
  echo "kernel-watch: QUALIFICADO"
  exit 0
fi

# --- operação normal ----------------------------------------------------------
[[ -n "$PID" ]] || die "faltou --pid"
[[ -n "$OUT" ]] || die "faltou --out"
[[ -d "/proc/$PID" ]] || die "PID $PID não existe — recuso medir e gravar zeros"

echo "unix_s,mem_free_kib,mem_avail_kib,unevictable_kib,mlocked_kib,slab_kib,sunreclaim_kib,kernel_stack_kib,page_tables_kib,vmalloc_used_kib,file_nr,proc_vmpin_kib,proc_vmlck_kib,proc_vmrss_kib,proc_threads,proc_fds,proc_iouring_fds" >"$OUT"

while :; do
  if [[ ! -d "/proc/$PID" ]]; then
    echo "kernel-watch: PID $PID desapareceu em $(date -u +%Y-%m-%dT%H:%M:%SZ) — parando" >&2
    exit 0   # o processo acabar é normal; sumir SEM aviso é que não seria
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -u +%s)" \
    "$(meminfo_kib MemFree)" "$(meminfo_kib MemAvailable)" \
    "$(meminfo_kib Unevictable)" "$(meminfo_kib Mlocked)" \
    "$(meminfo_kib Slab)" "$(meminfo_kib SUnreclaim)" \
    "$(meminfo_kib KernelStack)" "$(meminfo_kib PageTables)" \
    "$(meminfo_kib VmallocUsed)" \
    "$(awk '{print $1}' /proc/sys/fs/file-nr)" \
    "$(procstatus_kib "$PID" VmPin)" "$(procstatus_kib "$PID" VmLck)" \
    "$(procstatus_kib "$PID" VmRSS)" "$(procstatus_kib "$PID" Threads)" \
    "$(count_fds "$PID")" "$(count_iouring_fds "$PID")" \
    >>"$OUT"
  sleep "$INTERVAL"
done
