#!/usr/bin/env bash
set -euo pipefail

# ============================================
# TrueNAS NFS mount setup voor Proxmox LXC's & VM's (Host-wizard, interactief, met menu)
# - LXC: via pct exec
# - VM : via qm guest exec (QEMU Guest Agent vereist)
# ============================================

# ---- Defaults (via env te overriden) ----
NAS_HOST="${NAS_HOST:-192.168.1.42}"
REMOTE_PATH="${REMOTE_PATH:-/mnt/Files/Share/downloads}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/downloads}"

# Robuuste fstab-opties
FSTAB_OPTS="${FSTAB_OPTS:-vers=4.1,proto=tcp,_netdev,bg,noatime,timeo=150,retrans=2,nofail,nosuid,nodev,x-systemd.requires=network-online.target,x-systemd.after=network-online.target,x-systemd.device-timeout=0,x-systemd.mount-timeout=infinity}"

LOG_FILE="${LOG_FILE:-/var/log/truenas-nfs-guest-setup.log}"

# CLI toggles
NO_FZF=false

# -----------------------------------------------
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
fail(){ log "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ $EUID -eq 0 ]] || fail "Root is vereist."; }
on_host(){ have pct || have qm; }

usage(){
  cat <<EOF
Gebruik: $(basename "$0") [opties]

Opties:
  --no-fzf     Forceer numeriek menu (geen fzf)
  -h, --help   Toon deze hulp en stop

Werking:
  - Interactieve prompts vragen NAS host, exportpad en mountpoint.
  - Op de Proxmox host toont het menu zowel LXC's (CT) als VM's (VM).
  - LXC: configuratie via pct exec in de guest.
  - VM : configuratie via qm guest exec (QEMU Guest Agent vereist & VM running).
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

ask_default() {
  local q="$1" def="$2" ans=""
  read -r -p "$q [$def]: " ans || true
  echo "${ans:-$def}"
}

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

  have fzf && { log "fzf geïnstalleerd."; return 0; } || { log "Kon fzf niet installeren; val terug op numeriek menu."; return 1; }
}

# -------- Lokale (binnen huidige machine) installatie ----------
configure_local(){
  need_root
  log "== NFS mount in huidige omgeving configureren =="
  log "NAS: ${NAS_HOST}:${REMOTE_PATH} -> ${MOUNTPOINT}"

  if have apt; then
    export DEBIAN_FRONTEND=noninteractive
    log "Packages installeren (nfs-common)…"
    apt -y update
    apt -y install nfs-common
  else
    fail "Deze modus verwacht apt (Debian/Ubuntu)."
  fi

  log "Mountpoint aanmaken: ${MOUNTPOINT}"
  mkdir -p "${MOUNTPOINT}"

  local FSTAB_LINE="${NAS_HOST}:${REMOTE_PATH}  ${MOUNTPOINT}  nfs  ${FSTAB_OPTS}  0  0"
  log "Fstab bijwerken"
  if grep -qE "[[:space:]]${MOUNTPOINT}[[:space:]]+nfs[[:space:]]" /etc/fstab 2>/dev/null; then
    sed -i "\|[[:space:]]${MOUNTPOINT}[[:space:]]\+nfs[[:space:]]|d" /etc/fstab
  fi
  echo "${FSTAB_LINE}" >> /etc/fstab

  log "systemd daemon-reload + wait-online (best effort)"
  systemctl daemon-reload || true
  systemctl enable --now systemd-networkd-wait-online.service 2>/dev/null || true
  systemctl enable --now NetworkManager-wait-online.service 2>/dev/null || true

  log "Nu mounten (nfs4 direct; anders via remote-fs.target)"
  if ! mount -t nfs4 "${NAS_HOST}:${REMOTE_PATH}" "${MOUNTPOINT}" 2>/dev/null; then
    systemctl restart remote-fs.target 2>/dev/null || true
  fi

  log "Klaar. Controle: 'mount | grep ${MOUNTPOINT}'"
}

# ---------------- LXC helpers ----------------
pct_list_ct_raw(){ pct list 2>/dev/null || true; }
pct_list_ctids(){ pct_list_ct_raw | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }
ct_status(){ pct status "$1" 2>/dev/null | awk '{print $2}'; }
ct_name_from_list(){ pct_list_ct_raw | awk -v id="$1" 'NR>1 && $1==id {print $3; exit}'; }
ct_hostname(){
  local id="$1" hn=""
  hn="$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/{print $2; f=1} END{if(!f)print""}')" || true
  [[ -n "$hn" ]] || hn="$(ct_name_from_list "$id" || true)"
  echo "${hn:-unknown}"
}
ct_mountable_now(){
  pct config "$1" 2>/dev/null | grep -Eq '^features:.*(mount=nfs|nfs=1)' && echo yes || echo no
}
pct_is_running(){ [[ "$(ct_status "$1")" == "running" ]]; }
pct_ensure_running(){ pct_is_running "$1" || { log "CT $1 start…"; pct start "$1"; sleep 2; }; }
pct_try_enable_nfs_feature(){
  local id="$1"
  [[ "$(ct_mountable_now "$id")" == "yes" ]] && { log "CT $id: NFS feature al aanwezig."; return 0; }
  log "CT $id: zet features mount=nfs…"
  if pct set "$id" -features mount=nfs >/dev/null 2>&1; then
    log "CT $id: NFS feature gezet."
  else
    log "CT $id: Kon NFS feature niet automatisch zetten. Check /etc/pve/lxc/${id}.conf (features: mount=nfs)."
  fi
}
pct_exec(){ local id="$1"; shift; pct exec "$id" -- bash -lc "$*"; }

setup_in_ct(){
  local id="$1"
  log "=== CT $id: configuratie start ==="
  pct_ensure_running "$id"
  pct_try_enable_nfs_feature "$id"

  if ! pct_exec "$id" 'command -v apt >/dev/null'; then
    log "CT $id: apt niet gevonden; sla over."
    return 1
  fi

  log "CT $id: nfs-common installeren"
  pct_exec "$id" 'export DEBIAN_FRONTEND=noninteractive; apt -y update && apt -y install nfs-common' || { log "CT $id: apt install faalde"; return 1; }

  pct_exec "$id" "mkdir -p '$MOUNTPOINT'"
  local FSTAB_LINE="${NAS_HOST}:${REMOTE_PATH}  ${MOUNTPOINT}  nfs  ${FSTAB_OPTS}  0  0"
  pct_exec "$id" "sed -i '\|[[:space:]]${MOUNTPOINT}[[:space:]]\\+nfs[[:space:]]|d' /etc/fstab || true"
  pct_exec "$id" "printf '%s\n' \"$FSTAB_LINE\" >> /etc/fstab"

  pct_exec "$id" 'systemctl daemon-reload || true'
  pct_exec "$id" 'systemctl enable --now systemd-networkd-wait-online.service 2>/dev/null || true'
  pct_exec "$id" 'systemctl enable --now NetworkManager-wait-online.service 2>/dev/null || true'

  if ! pct_exec "$id" "mount -t nfs4 '${NAS_HOST}:${REMOTE_PATH}' '${MOUNTPOINT}'"; then
    pct_exec "$id" "systemctl restart remote-fs.target" || true
  fi
  log "=== CT $id: configuratie klaar ==="
}

# ---------------- VM helpers ----------------
qm_list_vm_raw(){ qm list 2>/dev/null || true; }
qm_list_vmids(){ qm_list_vm_raw | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }
vm_status(){
  # 'qm status <id>' -> 'status: running'
  qm status "$1" 2>/dev/null | awk -F': ' '/status:/{print $2}'
}
vm_name_from_list(){ qm_list_vm_raw | awk -v id="$1" 'NR>1 && $1==id {print $2; exit}'; }
vm_agent_enabled(){
  # agent: 1  of agent: enabled=1
  local line; line="$(qm config "$1" 2>/dev/null | awk -F': ' '/^agent:/{print $2}' )" || true
  [[ "$line" =~ (^1$|enabled=1) ]] && echo yes || echo no
}
vm_is_running(){ [[ "$(vm_status "$1")" == "running" ]]; }
vm_require_agent_and_running(){
  local id="$1"
  local ag="$(vm_agent_enabled "$id")"
  local st="$(vm_status "$id")"
  [[ "$ag" == "yes" && "$st" == "running" ]]
}
vm_exec(){
  # Best-effort; vereist QEMU Guest Agent in de VM
  local id="$1"; shift
  qm guest exec "$id" -- bash -lc "$*"
}

setup_in_vm(){
  local id="$1"
  log "=== VM $id: configuratie start ==="

  vm_is_running "$id" || fail "VM $id is niet running."
  [[ "$(vm_agent_enabled "$id")" == "yes" ]] || fail "VM $id heeft geen (enabled) QEMU Guest Agent; kan niet binnenin configureren."

  # apt?
  if ! vm_exec "$id" 'command -v apt >/dev/null'; then
    log "VM $id: apt niet gevonden; alleen Debian/Ubuntu wordt automatisch ondersteund."
    return 1
  fi

  log "VM $id: nfs-common installeren"
  vm_exec "$id" 'export DEBIAN_FRONTEND=noninteractive; apt -y update && apt -y install nfs-common' || { log "VM $id: apt install faalde"; return 1; }

  vm_exec "$id" "mkdir -p '$MOUNTPOINT'"
  local FSTAB_LINE="${NAS_HOST}:${REMOTE_PATH}  ${MOUNTPOINT}  nfs  ${FSTAB_OPTS}  0  0"
  vm_exec "$id" "sed -i '\|[[:space:]]${MOUNTPOINT}[[:space:]]\\+nfs[[:space:]]|d' /etc/fstab || true"
  vm_exec "$id" "printf '%s\n' \"$FSTAB_LINE\" >> /etc/fstab"

  vm_exec "$id" 'systemctl daemon-reload || true'
  vm_exec "$id" 'systemctl enable --now systemd-networkd-wait-online.service 2>/dev/null || true'
  vm_exec "$id" 'systemctl enable --now NetworkManager-wait-online.service 2>/dev/null || true'

  if ! vm_exec "$id" "mount -t nfs4 '${NAS_HOST}:${REMOTE_PATH}' '${MOUNTPOINT}'"; then
    vm_exec "$id" "systemctl restart remote-fs.target" || true
  fi
  log "=== VM $id: configuratie klaar ==="
}

# --------- Combined multi-select (CT + VM) ----------
select_targets(){
  log "Resources ophalen…"
  local -a types ids lines

  # LXC’s
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

  # VM’s
  if have qm; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      types+=("VM"); ids+=("$id")
      local st nm ag mark
      st="$(vm_status "$id" 2>/dev/null || true)"
      nm="$(vm_name_from_list "$id" 2>/dev/null || true)"
      ag="$(vm_agent_enabled "$id" 2>/dev/null || echo no)"
      # mountable voor VM ≈ running + agent=yes
      if [[ "$st" == "running" && "$ag" == "yes" ]]; then mark="✓"; else mark="✗"; fi
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
            --header="Spatie=selecteer, Enter=bevestig | [✓]=nu direct mogelijk | [✗]=nu niet (LXC: wizard zet feature; VM: agent+running vereist)" \
            --height=90% --border --ansi \
            --preview 'echo {}' --preview-window=down,10%)" || true
    [[ -n "$selected" ]] || fail "Geen selectie gemaakt."
    # Converteer naar TYPE:ID
    printf "%s\n" "$selected" | awk '{print $1 ":" $2}'
    return 0
  fi

  # Numerieke fallback
  >&2 echo
  >&2 echo "Beschikbare resources:"
  local i
  for ((i=0; i<${#lines[@]}; i++)); do
    >&2 printf "  [%2d] %s\n" "$((i+1))" "${lines[i]}"
  done
  >&2 echo
  >&2 echo "Kies meerdere met nummers of 'CT:ID'/'VM:ID', gescheiden door spaties. Of typ 'all'."
  local sel; read -r -p "Keuze: " sel

  if [[ "$sel" == "all" ]]; then
    for ((i=0; i<${#ids[@]}; i++)); do
      echo "${types[i]}:${ids[i]}"
    done
    return 0
  fi

  local chosen=()
  for tok in $sel; do
    if [[ "$tok" =~ ^[0-9]+$ ]]; then
      local idx=$((tok-1))
      (( idx>=0 && idx<${#ids[@]} )) && chosen+=("${types[idx]}:${ids[idx]}")
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

  # ---- Interactieve prompts met defaults ----
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
    echo "Legenda: [✓] = nu direct mogelijk; [✗] = LXC: feature wordt gezet, VM: agent/running vereist."
    echo

    mapfile -t targets < <(select_targets)
    echo
    echo "Gekozen: ${targets[*]}"
    read -r -p "Doorgaan met configuratie? [Y/n] " go
    [[ "${go:-Y}" =~ ^([Yy]|)$ ]] || fail "Afgebroken."

    local t id
    for entry in "${targets[@]}"; do
      t="${entry%%:*}"; id="${entry##*:}"
      case "$t" in
        CT) setup_in_ct "$id" || log "CT $id: fout (zie log)";;
        VM)
          if vm_require_agent_and_running "$id"; then
            setup_in_vm "$id" || log "VM $id: fout (zie log)"
          else
            log "VM $id: niet geschikt (agent niet enabled of VM niet running); sla over."
          fi
          ;;
      esac
    done

    echo
    log "Alle gekozen resources zijn verwerkt."
    echo "Voorbeeld controle in LXC: pct exec <CTID> -- bash -lc 'mount | grep ${MOUNTPOINT}'"
    echo "Voorbeeld controle in VM : qm guest exec <VMID> -- bash -lc 'mount | grep ${MOUNTPOINT}'"
  else
    echo
    echo "Geen 'pct' of 'qm' gevonden: aannemend dat je binnen een guest draait."
    read -r -p "Deze machine nu configureren? [Y/n] " yn2
    [[ "${yn2:-Y}" =~ ^([Yy]|)$ ]] || fail "Afgebroken."
    configure_local
  fi
}

main "$@"
