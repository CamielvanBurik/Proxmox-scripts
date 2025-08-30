#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Proxmox Unmount Server Wizard (LXC + VMs)
# - Verwijder mounts die naar één specifieke server wijzen
# - LXC: fstab in container opschonen + unmount; mpN bind mounts in config verwijderen
# - VM: via SSH fstab opschonen + unmount (met sudo)
# - fzf multi-select (fallback numeriek menu)
# - --dry-run voor veilige simulatie
# =========================================================

LOG_FILE="${LOG_FILE:-/var/log/proxmox-unmount-server-wizard.log}"

# Default opties (interactief aanpasbaar)
DO_LXC=true
DO_VM=true
DRY_RUN=false
NO_FZF=false

# --- helpers ---
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
warn(){ log "WAARSCHUWING: $*"; }
fail(){ log "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
confirm(){ local a; read -r -p "${1:-Doorgaan?} [Y/n] " a || true; [[ "${a:-Y}" =~ ^([Yy]|)$ ]]; }

usage(){
  cat <<EOF
Gebruik: $(basename "$0") [opties]
  --dry-run     Toon acties maar voer niets destructiefs uit
  --no-fzf      Forceer numeriek menu (geen fzf)
  --lxc-only    Alleen LXC bewerken
  --vm-only     Alleen VM's bewerken
  -h, --help    Hulp

Deze wizard verwijdert mounts naar één server uit LXC's en VM's:
- LXC: fstab in container + umount + mpN bind mounts in /etc/pve/lxc/<id>.conf
- VM: via SSH fstab opschonen + umount (sudo nodig binnen VM)
EOF
}

while (("$#")); do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --no-fzf)  NO_FZF=true ;;
    --lxc-only) DO_VM=false ;;
    --vm-only)  DO_LXC=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Onbekende optie: $1"; usage; exit 1 ;;
  esac
  shift
done

need_root(){ [[ $EUID -eq 0 ]] || fail "Root op de Proxmox host is vereist."; }

ensure_fzf(){
  [[ -t 1 ]] || return 1
  [[ "$NO_FZF" == "true" ]] && return 1
  if have fzf; then return 0; fi
  log "fzf niet gevonden; probeer te installeren…"
  local SUDO=""; (( EUID != 0 )) && have sudo && SUDO="sudo"
  if have apt-get;   then $SUDO apt-get -y update || true; $SUDO apt-get -y install fzf || true
  elif have dnf;     then $SUDO dnf -y install fzf || true
  elif have yum;     then $SUDO yum -y install fzf || true
  elif have zypper;  then $SUDO zypper --non-interactive install fzf || true
  elif have pacman;  then $SUDO pacman -Sy --noconfirm fzf || true
  fi
  have fzf && { log "fzf geïnstalleerd."; return 0; } || { warn "fzf installatie niet gelukt; numeriek menu fallback."; return 1; }
}

run_host(){
  # veilig commando uitvoeren op host (respecteer dry-run)
  if $DRY_RUN; then
    log "DRY-RUN HOST: $*"
  else
    eval "$@"
  fi
}

run_in_ct(){
  local id="$1"; shift
  if $DRY_RUN; then
    log "DRY-RUN CT${id}: $*"
  else
    pct exec "$id" -- bash -lc "$*"
  fi
}

run_ssh(){
  local target="$1"; shift
  local cmd="$*"
  if $DRY_RUN; then
    log "DRY-RUN SSH ${target}: $cmd"
  else
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$target" -- bash -lc "$cmd"
  fi
}

# -------------------------- LXC --------------------------

pct_list_raw(){ pct list 2>/dev/null || true; }
pct_list_ctids(){ pct_list_raw | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }
ct_name(){ pct_list_raw | awk -v id="$1" 'NR>1 && $1==id {print $3; exit}'; }

host_mounts_for_server(){
  # Print TARGET mountpoints op de host die afkomstig zijn van deze server (nfs/cifs)
  local server="$1"
  # NFS: SOURCE als 'server:/export'  | CIFS/SMB: SOURCE als '//server/share'
  findmnt -rn -o SOURCE,TARGET,FSTYPE \
    | awk -v s="$server" '
        BEGIN{IGNORECASE=1}
        $1 ~ "^"s":" || $1 ~ "^//"s"/" {print $2}
      ' || true
}

lxc_conf_mp_lines(){
  local id="$1"
  sed -n 's/^mp\([0-9]\+\): \(.*\)$/\1:\2/p' "/etc/pve/lxc/${id}.conf" 2>/dev/null || true
}

lxc_mp_indexes_to_remove(){
  # Bepaal welke mpN weg moeten omdat hun host-pad onder een server-mount valt
  local id="$1"; shift
  local -a server_mpts=("$@")
  local ln idx rhs hostpath
  while IFS= read -r ln; do
    idx="${ln%%:*}"; rhs="${ln#*: }"
    hostpath="${rhs%%,*}"           # eerste veld is hostpad
    for m in "${server_mpts[@]}"; do
      if [[ "$hostpath" == "$m" ]] || [[ "$hostpath" == "$m/"* ]]; then
        echo "$idx"
        break
      fi
    done
  done < <(lxc_conf_mp_lines "$id")
}

select_cts(){
  local -a lines=() ids=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    ids+=("$id")
    lines+=("$(printf "%-5s %-28s" "$id" "$(ct_name "$id" 2>/dev/null || echo '-')")")
  done < <(pct_list_ctids)
  ((${#ids[@]})) || fail "Geen LXC containers gevonden."

  if ensure_fzf; then
    local sel
    sel="$(printf "%s\n" "${lines[@]}" \
      | fzf -m --prompt="Selecteer LXC's > " --height=80% --border --ansi \
             --header="Spatie=selecteer, Enter=bevestig")" || true
    [[ -n "$sel" ]] || fail "Geen LXC selectie gemaakt."
    printf "%s\n" "$sel" | awk '{print $1}'
    return 0
  fi

  >&2 echo "Beschikbare LXC's:"
  local i=1
  for L in "${lines[@]}"; do >&2 printf "  [%2d] %s\n" "$i" "$L"; ((i++)); done
  >&2 read -r -p "Kies nummers of CTIDs (spaties), of 'all': " inp
  if [[ "$inp" == "all" ]]; then printf "%s\n" "${ids[@]}"; return 0; fi

  local chosen=() total=$((i-1))
  for tok in $inp; do
    if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok>=1 && tok<=total )); then
      chosen+=("${ids[tok-1]}")
    elif printf "%s\n" "${ids[@]}" | grep -qx "$tok"; then
      chosen+=("$tok")
    else
      >&2 echo "  - Ongeldige keuze: $tok (genegeerd)"
    fi
  done
  ((${#chosen[@]})) || fail "Geen geldige keuze."
  printf "%s\n" "${chosen[@]}"
}

process_lxc_for_server(){
  local server="$1"; shift
  local -a ctids=("$@")
  need_root
  have pct || fail "pct niet gevonden (Proxmox host)."

  # host-mountpoints die van deze server komen
  mapfile -t SERVER_MPTS < <(host_mounts_for_server "$server")
  log "Host-mountpoints van server '$server': ${#SERVER_MPTS[@]}"
  for m in "${SERVER_MPTS[@]:-}"; do log "  - $m"; done

  local ts; ts="$(date +%Y%m%d-%H%M%S)"

  for id in "${ctids[@]}"; do
    local name; name="$(ct_name "$id" || echo "-")"
    log "=== LXC $id ($name) ==="

    # 1) fstab in de container: verwijder regels met 'server:' of '//server/'
    log "Container fstab opschonen…"
    run_in_ct "$id" "test -f /etc/fstab && cp -a /etc/fstab /etc/fstab.bak.${ts} || true"
    run_in_ct "$id" "test -f /etc/fstab && sed -i -E '/(^|[[:space:]])(${server//./\\.}:|\\/\\/${server//./\\.}\\/)/d' /etc/fstab || true"

    # 2) unmount in de container van entry's die naar server wijzen
    log "Unmount in container (eventuele restmounts)…"
    run_in_ct "$id" "mount | awk '/(^|[[:space:]])(${server//./\\.}:|\\/\\/${server//./\\.}\\/)/{print \$3}' | xargs -r -n1 umount -l || true"
    run_in_ct "$id" "systemctl daemon-reload || true"

    # 3) bind-mounts (mpN) in lxc-config verwijderen als bron onder host server-mount zit
    if ((${#SERVER_MPTS[@]})); then
      local to_del idxs=()
      mapfile -t idxs < <(lxc_mp_indexes_to_remove "$id" "${SERVER_MPTS[@]}")
      if ((${#idxs[@]})); then
        log "Bind mounts (mpN) te verwijderen uit config: ${idxs[*]}"
        for n in "${idxs[@]}"; do
          if $DRY_RUN; then
            log "DRY-RUN HOST: pct set $id -delete mp${n}"
          else
            pct set "$id" -delete "mp${n}" >/dev/null || warn "mp${n} verwijderen faalde"
          fi
        done
      else
        log "Geen mpN bind-mounts gevonden die onder host server-mounts vallen."
      fi
    fi

    log "LXC $id afgerond."
  done
}

# -------------------------- VMs (via SSH) --------------------------

qm_list_raw(){ qm list 2>/dev/null || true; }
qm_list_vmids(){ qm_list_raw | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }
vm_name(){ qm_list_raw | awk -v id="$1" 'NR>1 && $1==id {print $2; exit}'; }

select_vms(){
  local -a lines=() ids=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    ids+=("$id")
    lines+=("$(printf "%-5s %-28s" "$id" "$(vm_name "$id" 2>/dev/null || echo '-')")")
  done < <(qm_list_vmids)
  ((${#ids[@]})) || fail "Geen VM's gevonden."

  if ensure_fzf; then
    local sel
    sel="$(printf "%s\n" "${lines[@]}" \
      | fzf -m --prompt="Selecteer VM's > " --height=80% --border --ansi \
             --header="Spatie=selecteer, Enter=bevestig")" || true
    [[ -n "$sel" ]] || fail "Geen VM selectie gemaakt."
    printf "%s\n" "$sel" | awk '{print $1}'
    return 0
  fi

  >&2 echo "Beschikbare VM's:"
  local i=1
  for L in "${lines[@]}"; do >&2 printf "  [%2d] %s\n" "$i" "$L"; ((i++)); done
  >&2 read -r -p "Kies nummers of VMIDs (spaties), of 'all': " inp
  if [[ "$inp" == "all" ]]; then printf "%s\n" "${ids[@]}"; return 0; fi

  local chosen=() total=$((i-1))
  for tok in $inp; do
    if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok>=1 && tok<=total )); then
      chosen+=("${ids[tok-1]}")
    elif printf "%s\n" "${ids[@]}" | grep -qx "$tok"; then
      chosen+=("$tok")
    else
      >&2 echo "  - Ongeldige keuze: $tok (genegeerd)"
    fi
  done
  ((${#chosen[@]})) || fail "Geen geldige keuze."
  printf "%s\n" "${chosen[@]}"
}

process_vms_via_ssh(){
  local server="$1"; shift
  local -a vmids=("$@")
  have ssh || fail "ssh ontbreekt (installeer openssh-client)."

  echo
  echo "We gaan per VM SSH-gegevens vragen (user@ip). Je account moet sudo kunnen."
  echo "Regels met '${server}:' of '//${server}/' worden uit /etc/fstab verwijderd; mounts worden ge-unmount."
  confirm "Doorgaan?" || fail "Afgebroken."

  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local ESC_SERVER="${server//./\\.}"

  for id in "${vmids[@]}"; do
    local name; name="$(vm_name "$id" || echo '-')"
    echo
    echo "=== VM $id ($name) ==="
    local target
    read -r -p "SSH target voor deze VM (bijv. root@192.168.x.y) of leeg om over te slaan: " target
    [[ -z "$target" ]] && { warn "VM $id overgeslagen (geen SSH target)."; continue; }

    local cmd="
      set -e
      if [ -f /etc/fstab ]; then
        sudo cp -a /etc/fstab /etc/fstab.bak.${ts} || true
        sudo sed -i -E '/(^|[[:space:]])(${ESC_SERVER}:|\\/\\/${ESC_SERVER}\\/)/d' /etc/fstab || true
      fi
      # Unmount alle huidige mounts die naar de server wijzen
      sudo bash -lc \"mount | awk '/(^|[[:space:]])(${ESC_SERVER}:|\\\\/\\\\/${ESC_SERVER}\\\\/)/{print \\$3}' | xargs -r -n1 umount -l\" || true
      sudo systemctl daemon-reload || true
    "
    run_ssh "$target" "$cmd" || warn "SSH/actie faalde voor $target"
  done
}

# -------------------------- MAIN --------------------------

main(){
  need_root
  echo "== Proxmox Unmount Server Wizard =="
  read -r -p "Server host/IP (bijv. 192.168.1.42 of nas.local): " SERVER
  [[ -n "$SERVER" ]] || fail "Geen server opgegeven."

  echo
  echo "Wat wil je opruimen?"
  echo "  1) LXC + VM (standaard)"
  echo "  2) Alleen LXC"
  echo "  3) Alleen VM"
  read -r -p "Keuze [1/2/3]: " mode
  case "${mode:-1}" in
    2) DO_VM=false; DO_LXC=true ;;
    3) DO_VM=true;  DO_LXC=false ;;
    *) DO_VM=true;  DO_LXC=true ;;
  esac

  echo
  $DRY_RUN && echo "LET OP: DRY-RUN is actief (geen wijzigingen worden echt doorgevoerd)."

  if $DO_LXC; then
    echo
    echo "-- LXC selectie --"
    if ! have pct; then warn "pct ontbreekt; LXC deel wordt overgeslagen."; else
      mapfile -t LXC_IDS < <(select_cts)
      echo "Gekozen LXC's: ${LXC_IDS[*]}"
      confirm "LXC acties bevestigen?" || fail "Afgebroken."
      process_lxc_for_server "$SERVER" "${LXC_IDS[@]}"
    fi
  fi

  if $DO_VM; then
    echo
    echo "-- VM selectie (via SSH) --"
    if ! have qm; then warn "qm ontbreekt; VM deel wordt overgeslagen."; else
      mapfile -t VM_IDS < <(select_vms)
      echo "Gekozen VM's: ${VM_IDS[*]}"
      confirm "VM acties bevestigen?" || fail "Afgebroken."
      process_vms_via_ssh "$SERVER" "${VM_IDS[@]}"
    fi
  fi

  echo
  log "Wizard klaar."
}

main "$@"
