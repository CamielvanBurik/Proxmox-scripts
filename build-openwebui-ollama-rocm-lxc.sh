#!/usr/bin/env bash
set -euo pipefail

# ====== instellingen ======
CTID="${CTID:-250}"
HOSTNAME="${HOSTNAME:-openwebui}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-8}"
MEMORY_MB="${MEMORY_MB:-16384}"
SWAP_MB="${SWAP_MB:-0}"
STORAGE="${STORAGE:-local}"  # waar je template/CT rootfs staat
TEMPLATE="ubuntu-24.04-standard_24.04-1_amd64.tar.zst"
MAKE_TEMPLATE="${MAKE_TEMPLATE:-0}"   # 1 => na afloop pct template
# ==========================

echo "[*] Check host GPU devices"
[[ -e /dev/kfd ]] || { echo "ERROR: /dev/kfd ontbreekt op de host. Zorg dat amdgpu geladen is en reboot desnoods."; exit 1; }
ls -l /dev/dri/renderD* >/dev/null

echo "[*] Download Ubuntu LXC template (indien nodig)"
pveam update || true
if ! pveam list "$STORAGE" | awk '{print $2}' | grep -q "^${TEMPLATE}\$"; then
  pveam download "$STORAGE" "ubuntu-24.04-standard_24.04-1_amd64.tar.zst"
fi

if pct status "$CTID" &>/dev/null; then
  echo "[*] Container $CTID bestaat al; sla creatie over."
else
  echo "[*] Maak privileged LXC (CTID=$CTID)"
  pct create "$CTID" "${STORAGE}:vztmpl/${TEMPLATE}" \
    -hostname "$HOSTNAME" \
    -cores "$CORES" -memory "$MEMORY_MB" -swap "$SWAP_MB" \
    -rootfs "${STORAGE}:32" \
    -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    -unprivileged 0 \
    -features "keyctl=1,nesting=1"

  echo "[*] Bind GPU devices /dev/dri en /dev/kfd"
  pct set "$CTID" -mp0 /dev/dri,mp=/dev/dri
  pct set "$CTID" -mp1 /dev/kfd,mp=/dev/kfd
  pct set "$CTID" -onboot 1
fi

echo "[*] Start container"
pct start "$CTID"
sleep 3

run() { pct exec "$CTID" -- bash -lc "$*"; }

echo "[*] Basis packages + tooling"
run "apt-get update -y"
run "apt-get install -y curl wget ca-certificates gnupg software-properties-common python3-pip python3-venv"

echo "[*] ROCm userspace (Ubuntu 24.04, zonder DKMS)"
run "wget -q https://repo.radeon.com/amdgpu-install/6.4.1/ubuntu/noble/amdgpu-install_6.4.60301-1_all.deb -O /tmp/amdgpu-install.deb"
run "apt-get install -y /tmp/amdgpu-install.deb || true"
# Soms heeft amdgpu-install nog deps nodig:
run "apt-get -f install -y || true"
# Installeer alleen ROCm userspace (geen kernel/dkms in LXC)
run "amdgpu-install --usecase=rocm --no-dkms --accept-eula -y || true"
# Als packages al aanwezig zijn, faalt amdgpu-install niet hard; dat is oké.

echo "[*] Test ROCm detectie (rocminfo)"
run "/opt/rocm/bin/rocminfo | egrep -i 'Agent|gfx|AMD Radeon' -n || true"
run "/opt/rocm/bin/rocm-smi || true"

echo "[*] Installeer Ollama"
run "curl -fsSL https://ollama.com/install.sh | sh"
run "systemctl enable --now ollama"
run "systemctl status --no-pager ollama || true"

echo "[*] Forceer ROCm in Ollama + RDNA3 override voor gfx1150"
run "mkdir -p /etc/systemd/system/ollama.service.d"
run "cat >/etc/systemd/system/ollama.service.d/rocm.conf <<'EOF'
[Service]
Environment=OLLAMA_USE_ROCM=1
Environment=HSA_OVERRIDE_GFX_VERSION=11.0.0
Environment=HSA_ENABLE_SDMA=0
Environment=HIP_VISIBLE_DEVICES=0
Environment=ROCR_VISIBLE_DEVICES=0
EOF"
run "usermod -aG render,video ollama"
run "systemctl daemon-reload && systemctl restart ollama"
run "journalctl -u ollama -n 30 --no-pager || true"

echo "[*] Installeer OpenWebUI (venv + service)"
run "useradd -m -s /usr/sbin/nologin openwebui || true"
run "install -d -o openwebui -g openwebui /opt/openwebui"
run "python3 -m venv /opt/openwebui/venv"
run "/opt/openwebui/venv/bin/pip install -U pip"
run "/opt/openwebui/venv/bin/pip install open-webui"
run "usermod -aG render,video openwebui"

# Secret key file in home aanmaken om /root-permissie-fout te voorkomen
run "head -c 32 /dev/urandom | base64 > /home/openwebui/.webui_secret_key && chown openwebui:openwebui /home/openwebui/.webui_secret_key && chmod 600 /home/openwebui/.webui_secret_key"

# Systemd unit voor OpenWebUI
run "cat >/etc/systemd/system/open-webui.service <<'EOF'
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

run "systemctl daemon-reload && systemctl enable --now open-webui"
sleep 2

echo "[*] Healthchecks"
# Ollama API
run "curl -sS http://127.0.0.1:11434/api/version || true"
# OpenWebUI health (kan 200/302 of html zijn; we printen alleen code)
run "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/health || true"
# Poorten
run "ss -ltnp | egrep ':(8080|11434)' || true"

echo
echo "[OK] Klaar. OpenWebUI op http://<LXC-IP>:8080  |  Ollama API op http://<LXC-IP>:11434"
echo "     LXC IP kun je zien met: pct exec $CTID -- ip -4 addr show dev eth0 | grep inet"
echo

if [[ "$MAKE_TEMPLATE" == "1" ]]; then
  echo "[*] Schakel uit en maak template"
  pct shutdown "$CTID" --force-stop 1 || true
  sleep 3
  pct template "$CTID"
  echo "[OK] Template gemaakt: CTID=$CTID (nu te clonen via GUI of 'pct clone')"
fi
