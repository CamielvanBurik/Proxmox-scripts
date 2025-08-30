#!/usr/bin/env bash
set -euo pipefail

# ============================================
# TrueNAS NFS mount setup voor Proxmox LXC's & VM's
# - LXC: pct exec
# - VM : SSH (qemu-guest-agent installeren) + NFS-config via agent of via SSH fallback
# - fzf multi-select menu (autom. installatie indien mogelijk)
# ============================================

# ---- Defaults (via env te overriden) ----
NAS_HOST="${NAS_HOST:-192.168.1.42}"
REMOTE_PATH="${REMOTE_PATH:-/mnt/Files/Share/downloads}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/downloads}"

FSTAB_OPTS="${FSTAB_OPTS:-vers=4.1,proto=tcp,_netdev,bg,noatime,timeo=150,retrans=2,nofail,nosuid,nodev,x-systemd.requires=network-online.target,x-systemd.after=network-online.target,x-systemd.device-timeout=0,x-systemd.mount-timeout=infinity}"

LOG_FILE="${LOG_FILE:-/var/log/truenas-nfs-guest-setup.log}"
NO_FZF=false

# SSH defaults voor VM’s
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"            # leeg = standaard sleutel
SSH_STRICT="${SSH_STRICT:-accept-new}" # StrictHostKeyChecking
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
fail(){ log "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ $EUID -eq 0 ]] || fail "Root is vereist."; }
on_host(){ have pct || have qm; }

usage(){
  cat <<EOF
Gebruik: $(basename "$0") [opties]

Opties:
  --no-fzf           Forceer numeriek menu (geen fzf)
  -h, --help         Toon deze hulp en stop

Env (VM-SSH):
  SSH_USER=root      SSH gebruiker
  SSH_PORT=22        SSH poort
  SSH_KEY=~/.ssh/... Pad naar private key (leeg = default keys/agent)
  SSH_STRICT=accept-new | no | yes  StrictHostKeyChecking (default accept-new)

Werking:
  - LXC's via pct exec
  - VM's via SSH: qemu-guest-agent wordt automatisch geïnstalleerd en gestart
    (apt/dnf/yum/zypper/pacman). NFS-config via agent indien beschikbaar,
    anders via SSH fallback (apt nfs-common, fstab, mount).
EOF
}

# ---- parse args
while (("$#")); do
  case "$1" in
    --no-fzf) NO_FZF=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Onbekende optie: $1"; usage; exit 1 ;;
  esac
  shift
done

ask_default() { local q="$1" def="$2" ans=""; read -r -p "$q [$def]: " ans || true; echo "${ans:-$def}"; }

# -------- fzf installer / beslisser --------
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

# -------- Lokale (in-guest) installatie ----------
configure_local(){
  need_root
  log "== NFS mount in huidige omgeving configureren =="
  log "NAS: ${NAS_HOST}:${REMOTE_PATH} -> ${MOUNTPOINT}"
  if have apt; then
    export DEBIAN_FRONTEND=noninteractive
    apt -y update && apt -y install nfs-common
  else
    fail "Deze modus verwacht apt (Debian/Ubuntu)."
  fi
  mkdir -p "${MOUNTPOINT}"
  local FSTAB_LINE="${NAS_HOST}:${REMOTE_PATH}  ${MOUNTPOINT}  nfs  ${FSTAB_OPTS}  0  0"
  sed -i "\|[[:space:]]${MOUNTPOINT}[[:space:]]\+nfs[[:space:]]|d" /etc/fstab || true
  printf '%s\n' "$FSTAB_LINE" >> /etc/fstab
  systemctl daemon-reload || true
  systemctl enable --now systemd-networkd-wait-online.service 2>/dev/null || true
  systemctl enable --now NetworkManager-wait-online.service 2>/dev/null || true
  mount -t nfs4 "${NAS_HOST}:${REMOTE_PATH}" "${MOUNTPOINT}" 2>/dev/null || systemctl restart remote-fs.target || true
  log "Klaar."
}

# ---------------- LXC helpers ----------------
pct_list_ct_raw(){ pct list 2>/dev/null || true; }
pct_list_ctids(){ pct_list_ct_raw | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }
ct_status(){ pct status "$1" 2>/dev/null | awk '{print $2}'; }
ct_name_from_list(){ pct_list_ct_raw | awk -v id="$1" 'NR>1 && $1==id {print $3; exit}'; }
ct_hostname(){ local id="$1" hn=""; hn="$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/{print $2; f=1} END{if(!f)print""}')" || true; [[ -n "$hn" ]] || hn="$(ct_name_from_list "$id" || true)"; echo "${hn:-unknown}"; }
ct_mountable_now(){ pct config "$1" 2>/dev/null | grep -Eq '^features:.*(mount=nfs|nfs=1)' && echo yes || echo no; }
pct_is_running(){ [[ "$(ct_status "$1")" == "running" ]]; }
pct_ensure_running(){ pct_is_running "$1" || { log "CT $1 start…"; pct start "$1"; sleep 2; }; }
pct_try_enable_nfs_feature(){
  local id="$1"
  [[ "$(ct_mountable_now "$id")" == "yes" ]] && { log "CT $id: NFS feature al aanwezig."; return 0; }
  log "CT $id: zet features mount=nfs…"
  if pct set "$id" -features mount=nfs >/dev/null 2>&1; then log "CT $id: NFS feature gezet."; else log "CT $id: kon feature niet zetten; check /etc/pve/lxc/${id}.conf"; fi
}
pct_exec(){ local id="$1"; shift; pct exec "$id" -- bash -lc "$*"; }
setup_in_ct(){
  local id="$1"
  log "=== CT $id: configuratie start ==="
  pct_ensure_running "$id"
  pct_try_enable_nfs_feature "$id"
  if ! pct_exec "$id" 'command -v apt >/dev/null'; then log "CT $id: geen apt; sla over."; return 1; fi
  pct_exec "$id" 'export DEBIAN_FRONTEND=noninteractive; apt -y update && apt -y install nfs-common' || { log "CT $id: apt faalde"; return 1; }
  pct_exec "$id" "mkdir -p '$MOUNTPOINT'"
  local FSTAB_LINE="${NAS_HOST}:${REMOTE_PATH}  ${MOUNTPOINT}  nfs  ${FSTAB_OPTS}  0  0"
  pct_exec "$id" "sed -i '\|[[:space:]]${MOUNTPOINT}[[:space:]]\\+nfs[[:space:]]|d' /etc/fstab || true"
  pct_exec "$id" "printf '%s\n' \"$FSTAB_LINE\" >> /etc/fstab"
  pct_exec "$id" 'systemctl daemon-reload || true'
  pct_exec "$id" 'systemctl enable --now systemd-networkd-wait-online.service 2>/dev/null || true'
  pct_exec "$id" 'systemctl enable --now NetworkManager-wait-online.service 2>/dev/null || true'
  pct_exec "$id" "mount -t nfs4 '${NAS_HOST}:${REMOTE_PATH}' '${MOUNTPOINT}' || systemctl restart remote-fs.target" || true
  log "=== CT $id: configuratie klaar ==="
}

# ---------------- VM helpers ----------------
qm_list_vm_raw(){ qm list 2>/dev/null || true; }
qm_list_vmids(){ qm_list_vm_raw | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }
vm_status(){ qm status "$1" 2>/dev/null | awk -F': ' '/status:/{print $2}'; }
vm_name_from_list(){ qm_list_vm_raw | awk -v id="$1" 'NR>1 && $1==id {print $2; exit}'; }
vm_agent_enabled(){ local line; line="$(qm config "$1" 2>/dev/null | awk -F': ' '/^agent:/{print $2}')" || true; [[ "$line" =~ (^1$|enabled=1) ]] && echo yes || echo no; }
vm_enable_agent(){
  local id="$1"
  if [[ "$(vm_agent_enabled "$id")" == "yes" ]]; then return 0; fi
  log "VM $id: enable QEMU Guest Agent (qm set -agent enabled=1)…"
  qm set "$id" -agent enabled=1 >/dev/null 2>&1 || log "VM $id: kon agent in config niet enablen."
}
vm_is_running(){ [[ "$(vm_status "$1")" == "running" ]]; }
vm_agent_usable(){
  local id="$1"
  vm_is_running "$id" || return 1
  # test of agent luistert
  qm guest exec "$id" -- timeout 1 true >/dev/null 2>&1
}

# ---- IP detectie / input voor VM ----
vm_guess_ips(){
  local id="$1" name ip
  # 1) cloud-init ipconfig's
  qm config "$id" 2>/dev/null | awk -F'[=, ]' '/^ipconfig[0-9]+:/{for(i=1;i<=NF;i++) if($i ~ /^ip$/){print $(i+1)}}' \
    | sed 's|/.*||' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
  # 2) DNS op VM naam
  name="$(vm_name_from_list "$id" 2>/dev/null || true)"
  if [[ -n "$name" ]]; then
    getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u
  fi
}
vm_prompt_ip(){
  local id="$1" suggest
  mapfile -t suggest < <(vm_guess_ips "$id" | head -n 3)
  local hint=""
  ((${#suggest[@]})) && hint=" (suggesties: ${suggest[*]})"
  local ip=""
  while true; do
    read -r -p "IP-adres voor VM $id${hint}: " ip
    [[ -z "$ip" && ${#suggest[@]} -gt 0 ]] && ip="${suggest[0]}"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    echo "Ongeldig IPv4. Probeer opnieuw."
  done
  echo "$ip"
}

# ---- SSH helpers ----
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
    apt)   ssh_run "$host" "bash -lc '${sudo}DEBIAN_FRONTEND=noninteractive apt -y update && ${sudo}apt -y install qemu-guest-agent && ${sudo}systemctl enable --now qemu-guest-agent'";;
    dnf)   ssh_run "$host" "bash -lc '${sudo}dnf -y install qemu-guest-agent && ${sudo}systemctl enable --now qemu-guest-agent'";;
    yum)   ssh_run "$host" "bash -lc '${sudo}yum -y install qemu-guest-agent && ${sudo}systemctl enable --now qemu-guest-agent'";;
    zypper)ssh_run "$host" "bash -lc '${sudo}zypper --non-interactive install qemu-guest-agent && ${sudo}systemctl enable --now qemu-guest-agent'";;
    pacman)ssh_run "$host" "bash -lc '${sudo}pacman -Sy --noconfirm qemu-guest-agent && ${sudo}systemctl enable --now qemu-guest-agent'";;
    *)     log "VM($host): onbekende package manager; kan agent niet installeren"; return 1;;
  esac
}

ssh_setup_nfs(){
  local host="$1" mgr sudo; mgr="$(ssh_detect_pkgmgr "$host")"; sudo="$(ssh_sudo_prefix)"
  case "$mgr" in
    apt)    ssh_run "$host" "bash -lc '${sudo}DEBIAN_FRONTEND=noninteractive apt -y update && ${sudo}apt -y install nfs-common'";;
    dnf|yum)ssh_run "$host" "bash -lc '${sudo}${mgr} -y install nfs-utils'";;
    zypper) ssh_run "$host" "bash -lc '${sudo}zypper --non-interactive install nfs-client'";;
    pacman) ssh_run "$host" "bash -lc '${sudo}pacman -Sy --noconfirm nfs-utils'";;
    *)      log "VM($host): onbekende package manager; NFS client niet geïnstalleerd"; return 1;;
  esac
  local FSTAB_LINE="${NAS_HOST}:${REMOTE_PATH}  ${MOUNTPOINT}  nfs  ${FSTAB_OPTS}  0  0"
  # fstab + mount
  ssh_run "$host" "bash -lc '${sudo}mkdir -p \"$MOUNTPOINT\" && ${sudo}sed -i \"\\|[[:space:]]${MOUNTPOINT}[[:space:]]\\+nfs[[:space:]]|d\" /etc/fstab || true && echo \"$FSTAB_LINE\" | ${sudo}tee -a /etc/fstab >/dev/null && ${sudo}systemctl daemon-reload || true && (${sudo}mount -t nfs4 \"${NAS_HOST}:${REMOTE_PATH}\" \"$MOUNTPOINT\" || ${sudo}systemctl restart remote-fs.target || true)'"
}

setup_in_vm_via_ssh_then_mount(){
  local id="$1"
  vm_is_running "$id" || fail "VM $id is niet running."
  vm_enable_agent "$id" || true
  local ip; ip="$(vm_prompt_ip "$id")"
  log "VM $id: SSH naar $SSH_USER@$ip (port $SSH_PORT) – guest-agent installeren…"
  ssh_install_guest_agent "$ip" || log "VM $id: installatie guest-agent via SSH faalde (ga verder met NFS via SSH)."
  # check of agent bruikbaar is (nu of na config change)
  if vm_agent_usable "$id"; then
    log "VM $id: agent actief; NFS-config via agent."
    setup_in_vm_via_agent "$id"
  else
    log "VM $id: agent (nog) niet bruikbaar; NFS-config via SSH."
    ssh_setup_nfs "$ip" || fail "VM $id: NFS-config via SSH faalde"
  fi
}

setup_in_vm_via_agent(){
  local id="$1"
  # apt?
  if ! qm guest exec "$id" -- bash -lc 'command -v apt >/dev/null' >/dev/null 2>&1; then
    log "VM $id: geen apt via agent; val terug op SSH in voorgaande stap."
    return 1
  fi
  qm guest exec "$id" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt -y update && apt -y install nfs-common' || { log "VM $id: apt via agent faalde"; return 1; }
  qm guest exec "$id" -- bash -lc "mkdir -p '$MOUNTPOINT'"
  local esc_fstab="$(printf "%q" "${NAS_HOST}:${REMOTE_PATH}  ${MOUNTPOINT}  nfs  ${FSTAB_OPTS}  0  0")"
  qm guest exec "$id" -- bash -lc "sed -i '\|[[:space:]]${MOUNTPOINT}[[:space:]]\\+nfs[[:space:]]|d' /etc/fstab || true; printf '%s\n' ${esc_fstab} >> /etc/fstab"
  qm guest exec "$id" -- bash -lc 'systemctl daemon-reload || true'
  qm guest exec "$id" -- bash -lc 'systemctl enable --now systemd-networkd-wait-online.service 2>/dev/null || true'
  qm guest exec "$id" -- bash -lc 'systemctl enable --now NetworkManager-wait-online.service 2>/dev/null || true'
  qm guest exec "$id" -- bash -lc "mount -t nfs4 '${NAS_HOST}:${REMOTE_PATH}' '${MOUNTPOINT}' || systemctl restart remote-fs.target" || true
  log "VM $id: NFS-config via agent voltooid."
}

# --------- Combined multi-select (CT + VM) ----------
select_targets(){
  log "Resources ophalen…"
  local -a types ids lines

  if have pct; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      types+=("CT"); ids+=("$id")
      local st hn mnt mark
      st="$(ct_status "$id" 2>/dev/null || true)"
      hn="$(ct_hostname "$id" 2>/dev/null || true)"
      mnt="$(ct_mountable_now "$id" 2>/dev/null || echo no)"
      [[ "$mnt" == "yes" ]] && mark="✓" || mark="✗"
      lines+=("$(printf "CT %-5s [%-1s] %-24s | status:%-8s | nfs:%s" "$id" "$mark" "${hn:-unknown}" "${st:-unknown}" "$mnt")")
    done < <(pct_list_ctids)
  fi

  if have qm; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      types+=("VM"); ids+=("$id")
      local st nm ag mark
      st="$(vm_status "$id" 2>/dev/null || true)"
      nm="$(vm_name_from_list "$id" 2>/dev/null || true)"
      ag="$(vm_agent_enabled "$id" 2>/dev/null || echo no)"
      [[ "$st" == "running" && "$ag" == "yes" ]] && mark="✓" || mark="✗"
      lines+=("$(printf "VM %-5s [%-1s] %-24s | status:%-8s | agent:%s" "$id" "$mark" "${nm:-unknown}" "${st:-unknown}" "$ag")")
    done < <(qm_list_vmids)
  fi

  (( ${#ids[@]} )) || fail "Geen LXC’s of VM’s gevonden."

  if ensure_fzf; then
    log "fzf-menu openen… (spatie=selecteren, Enter=bevestigen)"
    local selected
    selected="$(printf "%s\n" "${lines[@]}" \
      | fzf -m \
            --prompt="Selecteer CT/VM > " \
            --header="Spatie=selecteer, Enter=bevestig | [✓]=nu direct mogelijk | [✗]=CT: feature wordt gezet, VM: agent/SSH nodig" \
            --height=90% --border --ansi \
            --preview 'echo {}' --preview-window=down,10%)" || true
    [[ -n "$selected" ]] || fail "Geen selectie gemaakt."
    printf "%s\n" "$selected" | awk '{print $1 ":" $2}'
    return 0
  fi

  >&2 echo
  >&2 echo "Beschikbare resources:"
  local i; for ((i=0; i<${#lines[@]}; i++)); do >&2 printf "  [%2d] %s\n" "$((i+1))" "${lines[i]}"; done
  >&2 echo
  >&2 echo "Kies meerdere met nummers of 'CT:ID'/'VM:ID', gescheiden door spaties. Of typ 'all'."
  local sel; read -r -p "Keuze: " sel
  if [[ "$sel" == "all" ]]; then
    for ((i=0; i<${#ids[@]}; i++)); do echo "${types[i]}:${ids[i]}"; done; return 0
  fi
  local chosen=()
  for tok in $sel; do
    if [[ "$tok" =~ ^[0-9]+$ ]]; then
      local idx=$((tok-1)); (( idx>=0 && idx<${#ids[@]} )) && chosen+=("${types[idx]}:${ids[idx]}")
    elif [[ "$tok" =~ ^(CT|VM):[0-9]+$ ]]; then
      chosen+=("$tok")
    else
      >&2 echo "  - Onbekende keuze: $tok (genegeerd)"
    fi
  done
  (( ${#chosen[@]} )) || fail "Geen geldige keuze."
  printf "%s\n" "${chosen[@]}"
}

main(){
  echo "== TrueNAS NFS mount setup (LXC + VM wizard) =="

  NAS_HOST="$(ask_default "NAS host/IP" "$NAS_HOST")"
  REMOTE_PATH="$(ask_default "Remote export (pad op NAS)" "$REMOTE_PATH")"
  MOUNTPOINT="$(ask_default "Mountpoint in guest" "$MOUNTPOINT")"

  echo
  echo "Samenvatting:"
  echo "  NAS_HOST   = ${NAS_HOST}"
  echo "  REMOTE_PATH= ${REMOTE_PATH}"
  echo "  MOUNTPOINT = ${MOUNTPOINT}"
  read -r -p "Kloppen deze waarden? [Y/n] " yn
  [[ "${yn:-Y}" =~ ^([Yy]|)$ ]] || fail "Afgebroken."

  log "NAS=${NAS_HOST} EXPORT=${REMOTE_PATH} MOUNTPOINT=${MOUNTPOINT}"

  if on_host; then
    need_root
    echo
    echo "Host-modus gedetecteerd. We gaan LXC's en/of VM's configureren."
    echo "Legenda: [✓] = direct mogelijk; [✗] = CT: feature zetten, VM: agent/SSH nodig."
    echo

    mapfile -t targets < <(select_targets)
    echo
    echo "Gekozen: ${targets[*]}"

    # Als er VM’s in zitten: vraag evt. 1x SSH params
    if printf "%s\n" "${targets[@]}" | grep -q '^VM:'; then
      SSH_USER="$(ask_default "SSH user voor VM's" "$SSH_USER")"
      SSH_PORT="$(ask_default "SSH port voor VM's" "$SSH_PORT")"
      read -r -p "Pad naar SSH key (Enter voor default/agent): " SSH_KEY || true
      SSH_KEY="${SSH_KEY:-$SSH_KEY}"
      echo "SSH: user=${SSH_USER} port=${SSH_PORT} key=${SSH_KEY:-<default>}"
    fi

    read -r -p "Doorgaan met configuratie? [Y/n] " go
    [[ "${go:-Y}" =~ ^([Yy]|)$ ]] || fail "Afgebroken."

    local t id
    for entry in "${targets[@]}"; do
      t="${entry%%:*}"; id="${entry##*:}"
      case "$t" in
        CT) setup_in_ct "$id" || log "CT $id: fout (zie log)" ;;
        VM) setup_in_vm_via_ssh_then_mount "$id" || log "VM $id: fout (zie log)" ;;
      esac
    done

    echo
    log "Alle gekozen resources zijn verwerkt."
    echo "Controle LXC: pct exec <CTID> -- bash -lc 'mount | grep ${MOUNTPOINT}'"
    echo "Controle VM : ssh ${SSH_USER}@<ip> 'mount | grep ${MOUNTPOINT}'"
  else
    echo
    echo "Geen 'pct' of 'qm' gevonden: vermoedelijk binnen een guest. Deze machine nu configureren."
    read -r -p "Nu configureren? [Y/n] " yn2
    [[ "${yn2:-Y}" =~ ^([Yy]|)$ ]] || fail "Afgebroken."
    configure_local
  fi
}

main "$@"
