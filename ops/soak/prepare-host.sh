#!/usr/bin/env bash
# Prepara um host de campanha do zero. Roda NO host, como `ubuntu`.
#
#   uso: prepare-host.sh [--repo CAMINHO]
#
# POR QUE ESTE ARQUIVO EXISTE. A receita estava só em prosa, no §7 do ESTADO.md,
# e um dos passos dela — desligar o auto-upgrade — não é higiene opcional: **foi
# um kernel trocado sozinho que matou o primeiro host de campanha** e criou a
# §3.7 do pré-registro. Um passo que mata a campanha quando esquecido não pode
# depender de alguém lembrar de uma linha num documento.
#
# A REGRA: cada passo é VERIFICADO depois de executado. Um preparo que executa e
# não confere é um preparo que reporta sucesso sobre um host que não está pronto
# — e o preflight só descobriria isso depois, ou pior, nunca.
#
# Idempotente: rodar duas vezes não estraga nada.
set -u

REPO="${HOME}/soak-runs/repo"
while (( $# )); do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    *) echo "argumento desconhecido: $1" >&2; exit 2 ;;
  esac
done

falhas=()
ok()    { echo "  [ok]   $*"; }
falha() { echo "  [FALHA] $*" >&2; falhas+=("$*"); }

echo "== 1. pacotes =="
sudo apt-get update -qq 2>/dev/null || falha "apt-get update falhou"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  clang docker.io golang-go python3 curl git sysstat >/dev/null 2>&1 \
  || falha "instalação de pacotes falhou"
for p in clang docker go python3 curl git; do
  command -v "$p" >/dev/null 2>&1 && ok "$p presente" || falha "$p ausente depois do apt"
done

echo "== 2. auto-upgrade DESLIGADO (foi isto que matou o primeiro host) =="
sudo systemctl disable --now unattended-upgrades.service apt-daily-upgrade.timer apt-daily.timer \
  >/dev/null 2>&1 || true
for unidade in unattended-upgrades.service apt-daily-upgrade.timer apt-daily.timer; do
  # head -1 NÃO é cosmético. `systemctl is-enabled` pode imprimir mais de uma
  # linha, e o `|| echo unknown` acrescenta outra quando o comando falha. Sem
  # isto, $estado vira "disabled\nunknown" — e a comparação `== "enabled"`
  # falha para QUALQUER string multilinha, inclusive "enabled\nunknown".
  # O controle passaria sobre uma unidade LIGADA. Achado na estreia em host
  # real, 2026-08-06.
  estado=$( { systemctl is-enabled "$unidade" 2>/dev/null || echo "unknown"; } | head -1 )
  ativo=$(  { systemctl is-active  "$unidade" 2>/dev/null || echo "unknown"; } | head -1 )
  if [[ "$estado" == "enabled" || "$ativo" == "active" ]]; then
    falha "$unidade continua $estado/$ativo — a campanha NÃO pode rodar assim"
  else
    ok "$unidade: $estado/$ativo"
  fi
done

echo "== 2b. série do kernel (hipótese H-E) =="
# H-E, acrescentada depois da QUARTA morte de host: os quatro hosts que morreram
# rodavam kernel de PONTA sobre distro LTS -- 6.17.0-1017-aws em dois deles e
# 7.0.0-1009-aws no primeiro -- e a carga desta campanha é pesada em io_uring, o
# subsistema que mais muda entre versões. O Ubuntu 24.04 LTS tem a série 6.8.
# Isto NÃO recusa: H-E ainda não foi testada, e recusar por hipótese não medida
# seria o oposto do que este programa faz. Mas o kernel entra no relatório em
# voz alta, porque foi a única coisa comum às quatro mortes.
kernel_atual="$(uname -r)"
kernel_serie="${kernel_atual%%.*}.${kernel_atual#*.}"; kernel_serie="${kernel_serie%%.*}"
kernel_major_minor="$(echo "$kernel_atual" | cut -d. -f1,2)"
echo "  kernel: $kernel_atual  (série $kernel_major_minor)"
case "$kernel_major_minor" in
  6.8)
    ok "série 6.8 — a do Ubuntu 24.04 LTS. É o kernel que H-E prevê como sobrevivente." ;;
  *)
    echo "  [ATENÇÃO] série $kernel_major_minor NÃO é a 6.8 do 24.04 LTS."
    echo "            Os QUATRO hosts que morreram rodavam kernel de ponta."
    echo "            Ver planning/readiness/HOST-DEATH-preregistration.md §2.3."
    echo "            Para testar H-E, use um host na série 6.8."
    echo "            Para aceitar assim mesmo: DRUSE_SOAK_ALLOW_EDGE_KERNEL=1"
    if [[ "${DRUSE_SOAK_ALLOW_EDGE_KERNEL:-0}" != "1" ]]; then
      falha "kernel de ponta ($kernel_atual) sem DRUSE_SOAK_ALLOW_EDGE_KERNEL=1"
    else
      echo "  [ok]   risco de kernel de ponta ACEITO explicitamente — fica no relatório"
    fi ;;
esac

echo "== 2c. detector de travamento armado? (§2.4) =="
# Quatro hosts morreram e DOIS consoles capturados vieram VAZIOS. Panic, OOM,
# reset de driver e soft lockup TODOS imprimiriam; nenhum imprimiu. O NMI
# watchdog não dá para ligar aqui (sem PMU). O detector de tarefa travada é por
# software, funciona sem PMU, e hoje só AVISA -- em pânico, ele imprime stack
# trace no console serial antes de reiniciar.
# Conferir o VALOR EFETIVO em /proc/sys, não o /proc/cmdline. A AMI fixa
# panic=-1 no cmdline e um sysctl posterior sobrescreve; ler o cmdline reporta
# "não armado" para um host armado. Achado em 2026-08-08, no host 5: mesma
# classe dos outros — conferir a fonte errada com confiança.
armado=1
leia() { cat "/proc/sys/kernel/$1" 2>/dev/null || echo "?"; }
p_panic=$(leia panic); p_hung=$(leia hung_task_panic); p_soft=$(leia softlockup_panic)
[[ "$p_hung" == "1" ]] && ok "hung_task_panic = 1" || { echo "  [ATENÇÃO] hung_task_panic = $p_hung — travamento será MUDO"; armado=0; }
[[ "$p_soft" == "1" ]] && ok "softlockup_panic = 1" || { echo "  [ATENÇÃO] softlockup_panic = $p_soft"; armado=0; }
if [[ "$p_panic" =~ ^[0-9]+$ ]] && (( p_panic > 0 )); then
  ok "kernel.panic = ${p_panic}s — há janela para o serial capturar"
else
  echo "  [ATENÇÃO] kernel.panic = $p_panic — com -1 ou 0 o texto do pânico mal sai pelo serial."
  armado=0
fi
if (( armado )); then ok "detector de travamento armado"; else
  echo "  Para armar SEM reboot (sysctl ganha do cmdline da AMI):"
  echo "    printf 'kernel.panic=30\\nkernel.hung_task_panic=1\\nkernel.softlockup_panic=1\\n' \\"
  echo "      | sudo tee /etc/sysctl.d/99-druse-hang-detector.conf && sudo sysctl --system"
  echo "  NÃO recuso por isto: é instrumentação, não requisito de validade."
fi

echo "== 3. memlock unlimited (io_uring registra memória fixada) =="
sudo mkdir -p /etc/security/limits.d /etc/systemd/system/user@.service.d
printf '* soft memlock unlimited\n* hard memlock unlimited\n' \
  | sudo tee /etc/security/limits.d/99-druse-campaign.conf >/dev/null
printf '[Service]\nLimitMEMLOCK=infinity\n' \
  | sudo tee /etc/systemd/system/user@.service.d/99-druse.conf >/dev/null
sudo systemctl daemon-reload 2>/dev/null || true
# A verificação real só vale numa sessão NOVA; esta diz o que a sessão atual vê.
atual=$(ulimit -l)
if [[ "$atual" == "unlimited" ]] || (( atual > 1048576 )); then
  ok "memlock nesta sessão: $atual"
else
  echo "  [aviso] memlock nesta sessão: $atual — RECONECTE o ssh e rode de novo para conferir"
fi

echo "== 4. docker para o usuário =="
sudo usermod -aG docker ubuntu 2>/dev/null || falha "usermod docker falhou"
id -nG ubuntu | tr ' ' '\n' | grep -qx docker && ok "ubuntu no grupo docker" \
  || echo "  [aviso] grupo docker só vale na próxima sessão"

echo "== 5. Odin fixado =="
if [[ -x "$HOME/odin-pinned/odin" ]]; then
  ok "odin já instalado: $("$HOME/odin-pinned/odin" version 2>&1 | head -1)"
elif [[ -x "$REPO/ops/ci/install-odin.sh" ]]; then
  # O destino vem por AMBIENTE, não por argumento posicional. Passar posicional
  # seria silenciosamente ignorado e instalaria em /opt/druse — o preparo diria
  # "ok" e o odin estaria noutro lugar. Conferido em 2026-08-06.
  DRUSE_ODIN_PREFIX="$HOME/odin-pinned" bash "$REPO/ops/ci/install-odin.sh" >/dev/null 2>&1 \
    && [[ -x "$HOME/odin-pinned/odin" ]] \
    && ok "odin instalado: $("$HOME/odin-pinned/odin" version 2>&1 | head -1)" \
    || falha "install-odin.sh falhou ou não deixou binário em ~/odin-pinned"
else
  falha "sem odin e sem $REPO/ops/ci/install-odin.sh — clone o repositório primeiro"
fi

echo "== 6. o repositório =="
if [[ -d "$REPO/.git" ]]; then
  ok "repositório em $REPO ($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?'))"
else
  falha "não há repositório em $REPO"
fi

echo "== 7. topologia e disco, só para registro =="
echo "  núcleos online: $(nproc)"
# `grep -vc '^#'` conta LINHAS — uma por thread — e devolve 8 num host de 4
# núcleos com SMT. O default de lanes resolve por núcleo FÍSICO, então esse
# número errado desmente a configuração que ele deveria explicar. `sort -u`
# é o conserto.
echo "  núcleos físicos: $(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
echo "  threads online:  $(nproc)"
echo "  memória: $(free -g 2>/dev/null | awk '/^Mem:/{print $2" GiB"}')"
echo "  disco livre em \$HOME: $(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -d ' ')"
echo "  volume raiz: $(findmnt -no SOURCE / 2>/dev/null)"
echo "  kernel: $(uname -r)  (série do 24.04 LTS = 6.8)"

echo
if (( ${#falhas[@]} )); then
  echo "PREPARO INCOMPLETO — ${#falhas[@]} problema(s):" >&2
  for f in "${falhas[@]}"; do echo "  - $f" >&2; done
  echo >&2
  echo "NÃO rode a campanha até resolver. O preflight pode até passar, e o host" >&2
  echo "ainda estar preparado errado — foi assim que o primeiro morreu." >&2
  exit 1
fi
echo "PREPARO COMPLETO."
echo
echo "Próximo passo NÃO é o Final 2. É o par A/B — ver o §0 de"
echo "planning/readiness/HANDOFF-2026-08-05.md."
