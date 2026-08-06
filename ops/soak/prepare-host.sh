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
  estado=$(systemctl is-enabled "$unidade" 2>/dev/null || echo "unknown")
  ativo=$(systemctl is-active "$unidade" 2>/dev/null || echo "unknown")
  if [[ "$estado" == "enabled" || "$ativo" == "active" ]]; then
    falha "$unidade continua $estado/$ativo — a campanha NÃO pode rodar assim"
  else
    ok "$unidade: $estado/$ativo"
  fi
done

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
echo "  núcleos físicos: $(lscpu -p=CORE 2>/dev/null | grep -vc '^#' | xargs -I{} echo {} 2>/dev/null || echo '?')"
echo "  memória: $(free -g 2>/dev/null | awk '/^Mem:/{print $2" GiB"}')"
echo "  disco livre em \$HOME: $(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -d ' ')"
echo "  volume raiz: $(findmnt -no SOURCE / 2>/dev/null)"
echo "  kernel: $(uname -r)"

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
