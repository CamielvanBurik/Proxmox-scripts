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
  esac
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
  local host="$1"; shift
  # shellcheck disable=SC2046
  ssh $(ssh_base_opts) "$SSH_USER@$host" "$@"
}
ssh_sudo_prefix(){ [[ "$SSH_USER" == "root" ]] && echo "" || echo "sudo "; }
ssh_detect_pkgmgr(){
  local host="$1"
  ssh_run "$host" "bash -lc 'command -v apt >/dev/null && echo apt || command -v dnf >/dev/null && echo dnf || command -v yum >/dev/null && echo yum || command -v zypper >/dev/null && echo zypper || command -v pacman >/dev/null && echo pacman || echo none'"
}

ssh_install_guest_agent(){
  local host="$1" mgr sudo; mgr="$(ssh_detect_pkgmgr "$host")"; sudo="$(ssh_sudo_prefix)"
  case "$mgr" in
    apt)    ssh_run "$host" "bash -lc '${sudo}DEBIAN_FRONTEND=noninteractive apt -y update && ${sudo}apt -y install qemu-guest-agent && ${sudo}systemctl enable --now qemu-guest-agent'";;
    dnf)    ssh_run "$host" "bash -lc '${sudo}dnf -y install qemu-guest-agent && ${sudo}systemctl enable --now qemu-guest-agent'";;
    yum)    ssh_run "$host" "bash -lc '${sudo}yum -y install qemu-guest-agent && ${sudo}systemctl enable --now qemu-guest-agent'";;
    zypper) ssh_run "$host" "bash -lc '${sudo}zypper --non-interactive install qemu-guest-agent && ${sudo}systemctl enable --now qemu-guest-agent'";;
    pacman) ssh_run "$host" "bash -lc '${sudo}pacman -Sy --noconfirm qemu-guest-agent && ${sudo}systemctl enable --now qemu-guest-agent'";;
    *)      log "VM($host): onbekende package manager; kan agent niet installeren"; return 1;;
  esac
}

# ----- VM selectiemenu -----
find_vms_lines(){
  local ids lines=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    local st nm ag mark
    st="$(vm_status "$id" 2>/dev/null || true)"
    nm="$(vm_name_from_list "$id" 2>/dev/null || true)"
    ag="$(vm_agent_enabled "$id" 2>/dev/null || echo no)"
    [[ "$ag" == "yes" ]] && mark="✓" || mark="✗"
    lines+=("$(printf "%-5s [%-1s] %-28s | status:%-8s | agent:%s" "$id" "$mark" "${nm:-unknown}" "${st:-unknown}" "$ag")")
  done < <(qm_list_vmids)
  printf "%s\n" "${lines[@]}"
}

menu_choose_vms(){
  mapfile -t LINES < <(find_vms_lines)
  ((${#LINES[@]})) || fail "Geen VM's gevonden."
  if ensure_fzf; then
    local sel
    sel="$(printf "%s\n" "${LINES[@]}" \
      | fzf -m --prompt="Selecteer VM's > " \
             --header="Spatie=selecteer, Enter=bevestig | [✓]=agent enabled in config" \
             --height=90% --border --ansi \
             --preview 'echo {}' --preview-window=down,10%)" || true
    [[ -n "$sel" ]] || fail "Geen selectie gemaakt."
    printf "%s\n" "$sel" | awk '{print $1}'
    return 0
  fi
  >&2 echo "Beschikbare VM's:"
  local i=1; for l in "${LINES[@]}"; do >&2 printf "  [%2d] %s\n" "$i" "$l"; ((i++)); done
  >&2 echo
  >&2 echo "Kies meerdere met nummers of VMIDs, gescheiden door spaties. Of typ 'all'."
  local sel; read -r -p "Keuze: " sel
  if [[ "$sel" == "all" ]]; then
    printf "%s\n" $(qm_list_vmids); return 0
  fi
  local ids=() total=$((i-1))
  for tok in $sel; do
    if [[ "$tok" =~ ^[0-9]+$ ]]; then
      if (( tok>=1 && tok<=total )); then
        local id; id="$(printf "%s\n" "${LINES[tok-1]}" | awk '{print $1}')" ; ids+=("$id")
      elif qm_list_vmids | grep -qx "$tok"; then
        ids+=("$tok")
      else
        >&2 echo "  - Onbekende keuze: $tok (genegeerd)"
      fi
    else
      >&2 echo "  - Ongeldig: $tok (genegeerd)"
    fi
  done
  ((${#ids[@]})) || fail "Geen geldige keuze."
  printf "%s\n" "${ids[@]}"
}

# ----- Main flow per VM -----
process_vm(){
  local id="$1"
  log "=== VM $id ==="
  vm_enable_agent "$id" || true
  if ! vm_is_running "$id"; then
    read -r -p "VM $id is niet running. Starten om via SSH te kunnen installeren? [Y/n] " yn
    [[ "${yn:-Y}" =~ ^([Yy]|)$ ]] || { log "VM $id overgeslagen (VM is stopped)."; return 0; }
    qm start "$id" >/dev/null || fail "Kon VM $id niet starten"
    sleep 2
  fi
  local ip; ip="$(vm_prompt_ip "$id")"
  log "VM $id: installeer qemu-guest-agent via SSH op $SSH_USER@$ip (port $SSH_PORT)…"
  ssh_install_guest_agent "$ip" || fail "VM $id: installatie via SSH faalde"
  log "VM $id: klaar."
}

main(){
  have qm || fail "Dit script moet op de Proxmox host draaien (qm vereist)."
  log "== Proxmox VM Guest Agent Setup (geen mounts) =="

  # Vraag 1x naar SSH-parameters (met defaults)
  read -r -p "SSH user voor VM's [$SSH_USER]: " a; SSH_USER="${a:-$SSH_USER}"
  read -r -p "SSH port voor VM's [$SSH_PORT]: " a; SSH_PORT="${a:-$SSH_PORT}"
  read -r -p "Pad naar SSH key (Enter voor default/agent): " a; SSH_KEY="${a:-$SSH_KEY}"
  echo "SSH: user=${SSH_USER} port=${SSH_PORT} key=${SSH_KEY:-<default>} strict=$SSH_STRICT timeout=$SSH_CONNECT_TIMEOUT"

  mapfile -t vmids < <(menu_choose_vms)
  echo "Gekozen VMIDs: ${vmids[*]}"
  read -r -p "Doorvoeren voor deze VM's? [Y/n] " go
  [[ "${go:-Y}" =~ ^([Yy]|)$ ]] || fail "Afgebroken."

  for id in "${vmids[@]}"; do
    process_vm "$id" || log "VM $id: fout (zie log)"
  done
  log "=== Klaar ==="
}

main "$@"
