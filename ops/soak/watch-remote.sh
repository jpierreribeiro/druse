#!/usr/bin/env bash
# Observador REMOTO de uma corrida de soak. Roda na SUA máquina, não no host.
#
#   uso: watch-remote.sh --host IP --key CAMINHO.pem --timeline ARQUIVO [--interval S]
#        watch-remote.sh --self-test
#
# POR QUE ELE EXISTE, e por que roda de fora.
#
# No experimento de morte de host, a variável de saída é "o host morreu" — e um
# host morto não consegue registrar a própria morte. **O observador é o
# instrumento de medida do experimento**, não um acessório de conveniência.
#
# O DEFEITO QUE ELE CORRIGE, e que custou nove horas em 2026-08-06:
#
#   out=$(ssh ... 'echo "n=$(find ... | wc -l)"' 2>/dev/null | tail -1)
#   echo "$(date -u +%H:%MZ) $out"        # ssh morreu: $out vazio, linha em branco
#
# Setenta e duas linhas em branco, uma a cada sete minutos, todas parecendo
# atividade normal. O host tinha morrido na décima segunda.
#
# A REGRA: TRÊS estados, e o terceiro é o mais barulhento dos três.
#
#   OK           conseguiu perguntar E o progresso andou
#   STALL        conseguiu perguntar E o progresso NÃO andou
#   UNREACHABLE  NÃO CONSEGUIU PERGUNTAR   <-- nunca silencioso, nunca zero
set -u

HOST=""; KEY=""; TIMELINE=""; INTERVAL=60; SELF_TEST=0
PULL_DIR=""             # se definido, puxa os CSVs de vigia a cada sondagem
STALL_LIMIT=5          # ciclos parados até gritar
UNREACH_LIMIT=2        # ciclos sem resposta até declarar morte provável

while (( $# )); do
  case "$1" in
    --host)     HOST="$2"; shift 2 ;;
    --key)      KEY="$2"; shift 2 ;;
    --timeline) TIMELINE="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --pull)     PULL_DIR="$2"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    *) echo "argumento desconhecido: $1" >&2; exit 2 ;;
  esac
done

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Devolve o progresso, OU falha. Nunca devolve vazio como se fosse um número.
probe() {
  local out rc
  out=$(timeout 45 ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=20 "ubuntu@$HOST" \
        'if grep -qE "FINAL[0-9]*_DONE|AB_ARM_[a-z]*_DONE" ~/*.log 2>/dev/null; then echo DONE; else find ~/soak-runs/soak/telemetry -name "stats-*.json" 2>/dev/null | wc -l; fi' 2>/dev/null)
  rc=$?
  # A checagem que faltava: sucesso do ssh E saída não-vazia E numérica-ou-DONE.
  if (( rc != 0 )) || [[ -z "${out//[[:space:]]/}" ]]; then return 1; fi
  out="${out//[[:space:]]/}"
  if [[ "$out" != "DONE" && ! "$out" =~ ^[0-9]+$ ]]; then return 1; fi
  echo "$out"
}

if (( SELF_TEST )); then
  echo "== mutante: um host que não existe TEM de virar UNREACHABLE, não zero =="
  HOST="192.0.2.1"; KEY="${KEY:-/dev/null}"   # TEST-NET-1, garantidamente inalcançável
  if v=$(probe); then
    echo "  FALHOU: probe devolveu '$v' para um host inalcançável" >&2; exit 1
  fi
  echo "  PASS: probe falhou em vez de devolver vazio"
  echo
  echo "== controle positivo: uma sonda que responde tem de virar um número =="
  probe() { echo "1234"; }
  v=$(probe) && [[ "$v" == "1234" ]] && echo "  PASS: $v" || { echo "  FALHOU" >&2; exit 1; }
  echo
  echo "watch-remote: QUALIFICADO"
  exit 0
fi

[[ -n "$HOST"     ]] || { echo "faltou --host" >&2; exit 2; }
[[ -n "$KEY"      ]] || { echo "faltou --key" >&2; exit 2; }
[[ -n "$TIMELINE" ]] || { echo "faltou --timeline" >&2; exit 2; }

echo "utc,state,value,note" >"$TIMELINE"
last=-1; stalled=0; unreach=0

while :; do
  if value=$(probe); then
    unreach=0
    if [[ "$value" == "DONE" ]]; then
      echo "$(stamp),DONE,,corrida terminou" >>"$TIMELINE"
      echo "$(stamp)  DONE"
      exit 0
    fi
    # PUXAR ENQUANTO DÁ. Aprendido matando o quarto host em 2026-08-08: o
    # kernel-watch grava NO HOST, e o host é justamente o que morre. Eu tinha
    # 5h15 de contadores porque baixei uma vez à mão; as últimas 4h15 -- as que
    # levam à morte, as únicas que respondem a condição 2 do §4 -- ficaram na
    # máquina morta. Um vigia cujo dado morre junto com o sujeito não é vigia.
    if [[ -n "$PULL_DIR" ]]; then
      mkdir -p "$PULL_DIR"
      timeout 120 scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=20 \
        "ubuntu@$HOST:~/soak-runs/soak/kernel-watch.csv" "$PULL_DIR/kernel-watch.csv" 2>/dev/null \
        && echo "$(stamp),PULL,$(( $(wc -l < "$PULL_DIR/kernel-watch.csv" 2>/dev/null || echo 1) - 1 )),kernel-watch" >>"$TIMELINE"
      timeout 60 scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=20 \
        "ubuntu@$HOST:~/soak-runs/soak/cycles.csv" "$PULL_DIR/cycles.csv" 2>/dev/null || true
    fi
    if (( value > last )); then
      stalled=0
      echo "$(stamp),OK,$value," >>"$TIMELINE"
      echo "$(stamp)  OK          $value amostras"
    else
      stalled=$((stalled+1))
      echo "$(stamp),STALL,$value,ciclos parados=$stalled" >>"$TIMELINE"
      echo "$(stamp)  STALL       $value amostras, parado ha $stalled ciclos"
      if (( stalled >= STALL_LIMIT )); then
        echo "$(stamp)  !!! O HOST RESPONDE MAS NAO PROGRIDE HA $stalled CICLOS !!!"
      fi
    fi
    last=$value
  else
    unreach=$((unreach+1))
    echo "$(stamp),UNREACHABLE,,tentativas=$unreach" >>"$TIMELINE"
    echo "$(stamp)  !!! UNREACHABLE  nao consegui perguntar (tentativa $unreach) !!!"
    if (( unreach >= UNREACH_LIMIT )); then
      echo
      echo "======================================================================"
      echo "  HOST PROVAVELMENTE MORTO — $HOST"
      echo "  ultima leitura boa: $last amostras"
      echo "  $unreach sondagens seguidas sem resposta"
      echo "  NAO RELANCE. Pegue o console da AWS antes de qualquer reboot:"
      echo "  planning/readiness/HOST-DEATH-preregistration.md §6"
      echo "======================================================================"
      exit 1
    fi
  fi
  sleep "$INTERVAL"
done
