#!/usr/bin/env bash
# post-clone-openwebui-gpu-fixup.sh
# Proxmox host-side script om gekloonde LXC's klaar te maken voor AMD ROCm + Ollama + OpenWebUI
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <CTID> [<CTID2> ...]"
  exit 2
fi

need_host_gpu(){
  [[ -e /dev/kfd ]] || { echo "ERROR: /dev/kfd ontbreekt op de host. Zorg dat amdgpu geladen is en reboot desnoods."; exit 1; }
  ls -l /dev/dri/renderD* >/dev/null 2>&1 || { echo "ERROR: /dev/dri/renderD* ontbreekt op de host."; exit 1; }
}
need_host_gpu

for CTID in "$@"; do
  echo "================ CT $CTID ================"

  if ! pct status "$CTID" &>/dev/null; then
    echo "ERROR: CTID $CTID bestaat niet"; continue
  fi

  # Mounts toevoegen indien niet aanwezig
  CFG="$(pct config "$CTID")"
  if ! grep -qE '^mp0: /dev/dri,' <<<"$CFG"; then
    echo "[*] Voeg mp0 /dev/dri toe aan CT $CTID"
    pct set "$CTID" -mp0 /dev/dri,mp=/dev/dri
  else
    echo "[-] mp0 /dev/dri al aanwezig"
  fi
  if ! grep -qE '^mp1: /dev/kfd,' <<<"$CFG"; then
    echo "[*] Voeg mp1 /dev/kfd toe aan CT $CTID"
    pct set "$CTID" -mp1 /dev/kfd,mp=/dev/kfd
  else
    echo "[-] mp1 /dev/kfd al aanwezig"
  fi

  RUNNING="$(pct status "$CTID" | awk '{print $2}')"
  if [[ "$RUNNING" != "running" ]]; then
    echo "[*] Start CT $CTID"
    pct start "$CTID"
    sleep 3
  fi

  run(){ pct exec "$CTID" -- bash -lc "$*"; }

  echo "[*] Basis tooling in CT (curl, ss, etc.)"
  run "apt-get update -y && apt-get install -y curl iproute2 procps"

  echo "[*] Controleer GPU devices in CT"
  run "ls -l /dev/kfd /dev/dri/renderD* || true"

  echo "[*] Zet Ollama ROCm-omgeving + RDNA3 override (gfx1150)"
  run "mkdir -p /etc/systemd/system/ollama.service.d"
  run "cat >/etc/systemd/system/ollama.service.d/rocm.conf <<'EOF'
[Service]
Environment=OLLAMA_USE_ROCM=1
Environment=HSA_OVERRIDE_GFX_VERSION=11.0.0
Environment=HSA_ENABLE_SDMA=0
Environment=HIP_VISIBLE_DEVICES=0
Environment=ROCR_VISIBLE_DEVICES=0
EOF"

  echo "[*] Zet OpenWebUI service (HOME, secret, endpoint)"
  # Zorg voor user en dirs (indien template dat nog niet had)
  run "id openwebui >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin openwebui"
  run "install -d -o openwebui -g openwebui /opt/openwebui"
  # Secret key in HOME van openwebui, niet in /root
  run "[[ -f /home/openwebui/.webui_secret_key ]] || (head -c 32 /dev/urandom | base64 > /home/openwebui/.webui_secret_key && chown openwebui:openwebui /home/openwebui/.webui_secret_key && chmod 600 /home/openwebui/.webui_secret_key)"

  # Als unit nog niet bestond, maak 'm aan (bind op 0.0.0.0:8080)
  run "test -f /etc/systemd/system/open-webui.service || cat >/etc/systemd/system/open-webui.service <<'EOF'
[Unit]
Description=Open WebUI
After=network.target ollama.service

[Service]
User=openwebui
Group=openwebui
Environment=HOME=/home/openwebui
Environment=GLOBAL_LOG_LEVEL=INFO
Environment=OLLAMA_BASE_URL=http://127.0.0.1:11434
WorkingDirectory=/opt/openwebui
ExecStart=/opt/openwebui/venv/bin/open-webui serve --host 0.0.0.0 --port 8080
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF"

  echo "[*] Groepen en rechten"
  run "groupadd -f render; groupadd -f video || true"
  run "usermod -aG render,video ollama 2>/dev/null || true"
  run "usermod -aG render,video openwebui 2>/dev/null || true"
  run "id ollama || true; id openwebui || true"
  run "ls -l /dev/kfd /dev/dri/renderD* || true"

  echo "[*] Services herladen en starten"
  run "systemctl daemon-reload"
  run "systemctl enable --now ollama || true"
  run "systemctl enable --now open-webui || true"
  run "systemctl restart ollama || true"
  run "systemctl restart open-webui || true"
  sleep 2

  echo "[*] Snelle healthchecks"
  run "ss -ltnp | egrep ':(11434|8080)' || true"
  run "curl -sS http://127.0.0.1:11434/api/version || true"
  run "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/health || true"

  echo "[*] ROCm detectie"
  run "/opt/rocm/bin/rocminfo | egrep -i 'Agent|gfx|AMD Radeon' -n || true"
  run "/opt/rocm/bin/rocm-smi || true"

  echo "[*] Model self-test (klein model) — pull en 1 prompt"
  run "timeout 300 ollama pull llama3.2:1b || true"
  run "printf 'Zeg heel kort: GPU test?\\n' | timeout 120 ollama run llama3.2:1b || true"

  echo "[*] Samenvatting:"
  IPLINE="$(pct exec "$CTID" -- bash -lc "ip -4 -brief addr show dev eth0 | awk '{print \$3}'")" || true
  echo "    CTID: $CTID | IP: ${IPLINE:-unknown}"
  echo "    OpenWebUI: http://<IP>:8080  |  Ollama API: http://<IP>:11434"
  echo
done
