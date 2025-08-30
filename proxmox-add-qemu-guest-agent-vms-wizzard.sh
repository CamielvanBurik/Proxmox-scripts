#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Proxmox VM Guest Agent Setup (SSH) — GEEN MOUNTS
# - Selecteer VMs (fzf of numeriek menu)
# - Installeer qemu-guest-agent via SSH in de VM
# - Enable agent in Proxmox (qm set -agent enabled=1)
# ============================================

LOG_FILE="${LOG_FILE:-/var/log/proxmox-vm-agent-setup.log}"
NO_FZF="${NO_FZF:-false}"

# SSH defaults (kun je via env overschrijven)
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"                  # leeg = default keys/agent
SSH_STRICT="${SSH_STRICT:-accept-new}"  # yes|no|accept-new
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
fail(){ log "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

usage(){
  cat <<EOF
Gebruik: $(basename "$0") [opties]

Opties:
  --no-fzf           Forceer numeriek menu (geen fzf)
  -h, --help         Toon deze hulp en stop

Env (SSH):
  SSH_USER=root      SSH gebruiker
  SSH_PORT=22        SSH poort
  SSH_KEY=           Pad naar private key (leeg = default keys/agent)
  SSH_STRICT=accept-new|no|yes
  SSH_CONNECT_TIMEOUT=5   SSH timeout in seconden

Werking:
  - Toont lijst VMs
  - Per VM: installeert qemu-guest-agent via SSH, start/enabled service
  - Zet ook 'qm set <vmid> -agent enabled=1'
  - Maakt GEEN mounts, wijzigt GEEN fstab, installeert GEEN NFS packages
EOF
}

# Args
while (("$#")); do
  case "$1" in
    --no-fzf) NO_FZF=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Onbekende optie: $1"; usage; exit 1 ;;
  endcase
  shift
done

# ----- fzf (optioneel) -----
ensure_fzf() {
  [[ -t 1 ]] || return 1
  [[ "$NO_FZF" == "true" ]] && return 1
  if have fzf; then return 0; fi
  log "fzf niet gevonden; probeer te installeren…"
  local SUDO=""; (( EUID != 0 )) && have sudo && SUDO="sudo"
  if have apt-get; then
    env DEBIAN_FRONTEND=noninteractive $SUDO apt-get -y update || true
    env DEBIAN_FRONTEND=noninteractive $SUDO apt-get -y install fzf || true
  elif have dnf; then
    $SUDO dnf -y install fzf || true
  elif have yum; then
    $SUDO yum -y install fzf || true
  elif have zypper; then
    $SUDO zypper --non-interactive install fzf || true
  elif have pacman; then
    $SUDO pacman -Sy --noconfirm fzf || true
  fi
  have fzf && { log "fzf geïnstalleerd."; return 0; } || { log "Kon fzf niet installeren; numeriek menu fallback."; return 1; }
}

# ----- Proxmox VM helpers -----
qm_list_vm_raw(){ qm list 2>/dev/null || true; }
qm_list_vmids(){ qm_list_vm_raw | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }
vm_status(){ qm status "$1" 2>/dev/null | awk -F': ' '/status:/{print $2}'; }
vm_name_from_list(){ qm_list_vm_raw | awk -v id="$1" 'NR>1 && $1==id {print $2; exit}'; }
vm_is_running(){ [[ "$(vm_status "$1")" == "running" ]]; }
vm_agent_enabled(){
  local line; line="$(qm config "$1" 2>/dev/null | awk -F': ' '/^agent:/{print $2}')" || true
  [[ "$line" =~ (^1$|enabled=1) ]] && echo yes || echo no
}
vm_enable_agent(){
  local id="$1"
  if [[ "$(vm_agent_enabled "$id")" == "yes" ]]; then return 0; fi
  log "VM $id: enable QEMU Guest Agent (qm set -agent enabled=1)…"
  qm set "$id" -agent enabled=1 >/dev/null 2>&1 || log "VM $id: kon agent in config niet enablen."
}

# ----- IP-detectie (voor SSH) -----
vm_guess_ips(){
  local id="$1" name
  qm config "$id" 2>/dev/null \
    | awk -F'[=, ]' '/^ipconfig[0-9]+:/{for(i=1;i<=NF;i++) if($i ~ /^ip$/){print $(i+1)}}' \
    | sed 's|/.*||' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
  name="$(vm_name_from_list "$id" 2>/dev/null || true)"
  if [[ -n "$name" ]]; then
    getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u
  fi
}
vm_prompt_ip(){
  local id="$1"
  mapfile -t suggest < <(vm_guess_ips "$id" | head -n 3)
  local hint=""; ((${#suggest[@]})) && hint=" (suggesties: ${suggest[*]})"
  local ip=""
  while true; do
    read -r -p "IP-adres voor VM $id${hint}: " ip
    [[ -z "$ip" && ${#suggest[@]} -gt 0 ]] && ip="${suggest[0]}"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    echo "Ongeldig IPv4. Probeer opnieuw."
  done
  echo "$ip"
}

# ----- SSH helpers -----
ssh_base_opts(){
  local -a o
  o=(-p "$SSH_PORT" -o "StrictHostKeyChecking=$SSH_STRICT" -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT")
  [[ -n "$SSH_KEY" ]] && o+=(-i "$SSH_KEY")
  printf "%q " "${o[@]}"
}
ssh_run(){
  local host="$1"
