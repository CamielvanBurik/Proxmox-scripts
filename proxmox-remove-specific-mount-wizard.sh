#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Proxmox Remove Specific Mount Wizard (LXC + VMs)
# - Verwijder één specifieke mount (server + export/share)
# - LXC: fstab in container + umount; mpN bind mounts in /etc/pve/lxc/<id>.conf
# - VM: via SSH fstab opschonen + umount (met sudo)
# - fzf multi-select (fallback numeriek)
# - --dry-run voor veilige simulatie
# =========================================================

LOG_FILE="${LOG_FILE:-/var/log/proxmox-remove-specific-mount.log}"
DRY_RUN=false
NO_FZF=false

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
warn(){ log "WAARSCHUWING: $*"; }
fail(){ log "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
confirm(){ local a; read -r -p "${1:-Doorgaan?} [Y/n] " a || true; [[ "${a:-Y}" =~ ^([Yy]|)$ ]]; }
need_root(){ [[ $EUID -eq 0 ]] || fail "Root op de Proxmox host is vereist."; }

usage(){
  cat <<EOF
Gebruik: $(basename "$0") [opties]
  --dry-run     Toon acties maar voer niets uit
  --no-fzf      Forceer numeriek menu
  -h, --help    Deze hulp

Wizard verwijdert één specifieke mount:
- NFS bron:   <server>:<export>    (bijv. 192.168.1.43:/mnt/Files/Share/downloads)
- SMB bron:   //<server>/<share>   (als je 'share' invult)

Werkt voor LXC (in-container + mpN op host) en VM's (via SSH).
EOF
}

while (("$#")); do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --no-fzf)  NO_FZF=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Onbekende optie: $1"; usage; exit 1 ;;
  esac
  shift
done

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
  have fzf && { log "fzf geïnstalleerd."; return 0; } || { warn "fzf installatie niet gelukt; numeriek menu."; return 1; }
}

# -------------------- helpers host/LXC/VM --------------------

pct_list_raw(){ pct list 2>/dev/null || true; }
pct_list_ctids(){ pct_list_raw | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }
ct_name(){ pct_list_raw | awk -v id="$1" 'NR>1 && $1==id {print $3; exit}'; }

qm_list_raw(){ qm list 2>/dev/null || true; }
qm_list_vmids(){ qm_list_raw | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }
vm_name(){ qm_list_raw | awk -v id="$1" 'NR>1 && $1==id {print $2; exit}'; }

run_host(){
  if $DRY_RUN; then log "DRY-RUN HOST: $*"; else eval "$@"; fi
}

run_in_ct(){ local id="$1"; shift
  if $DRY_RUN; then log "DRY-RUN CT${id}: $*"; else pct exec "$id" -- bash -lc "$*"; fi
}

run_ssh(){ local target="$1"; shift; local cmd="$*"
  if $DRY_RUN; then log "DRY-RUN SSH ${target}: $cmd"; else ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$target" -- bash -lc "$cmd"; fi
}

# Vind host mountpoints (TARGETs) die precies van deze SOURCE komen
host_targets_for_source(){
  local source="$1"
  findmnt -rn -S "$source" -o TARGET 2>/dev/null || true
}

# LXC mpN-parsing
lxc_conf_mp_lines(){ sed -n 's/^mp\([0-9]\+\): \(.*\)$/\1:\2/p' "/etc/pve/lxc/${1}.conf" 2>/dev/null || true; }

lxc_mp_indexes_for_host_paths(){
  local id="$1"; shift
  local -a bases=("$@")
  local ln idx rhs hostpath
  while IFS= read -r ln; do
    idx="${ln%%:*}"; rhs="${ln#*: }"
    hostpath="${rhs%%,*}"
    for b in "${bases[@]}"; do
      if [[ "$hostpath" == "$b" || "$hostpath" == "$b/"* ]]; then
        echo "$idx"; break
      fi
    done
  done < <(lxc_conf_mp_lines "$id")
}

# -------------------- selectie menus --------------------

select_cts(){
  have pct || fail "pct ontbreekt (Proxmox host)."
  local -a ids=() lines=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    ids+=("$id"); lines+=("$(printf "%-5s %-28s" "$id" "$(ct_name "$id" 2>/dev/null || echo '-')")")
  done < <(pct_list_ctids)
  ((${#ids[@]})) || fail "Geen LXC containers gevonden."
  if ensure_fzf; then
    local sel
    sel="$(printf "%s\n" "${lines[@]}" | fzf -m --prompt="Selecteer LXC's > " --height=80% --border --ansi --header="Spatie=selecteer, Enter=bevestig")" || true
    [[ -n "$sel" ]] || fail "Geen LXC selectie."
    printf "%s\n" "$sel" | awk '{print $1}'
    return 0
  fi
  >&2 echo "Beschikbare LXC's:"; local i=1
  for L in "${lines[@]}"; do >&2 printf "  [%2d] %s\n" "$i" "$L"; ((i++)); done
  >&2 read -r -p "Kies nummers of CTIDs (spaties), of 'all': " inp
  if [[ "$inp" == "all" ]]; then printf "%s\n" "${ids[@]}"; return 0; fi
  local chosen=() total=$((i-1))
  for tok in $inp; do
    if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok>=1 && tok<=total )); then chosen+=("${ids[tok-1]}")
    elif printf "%s\n" "${ids[@]}" | grep -qx "$tok"; then chosen+=("$tok")
    else >&2 echo "  - Ongeldig: $tok"; fi
  done
  ((${#chosen[@]})) || fail "Geen geldige LXC-keuze."; printf "%s\n" "${chosen[@]}"
}

select_vms(){
  have qm || fail "qm ontbreekt (Proxmox host)."
  local -a ids=() lines=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    ids+=("$id"); lines+=("$(printf "%-5s %-28s" "$id" "$(vm_name "$id" 2>/dev/null || echo '-')")")
  done < <(qm_list_vmids)
  ((${#ids[@]})) || fail "Geen VM's gevonden."
  if ensure_fzf; then
    local sel
    sel="$(printf "%s\n" "${lines[@]}" | fzf -m --prompt="Selecteer VM's > " --height=80% --border --ansi --header="Spatie=selecteer, Enter=bevestig")" || true
    [[ -n "$sel" ]] || fail "Geen VM selectie."
    printf "%s\n" "$sel" | awk '{print $1}'
    return 0
  fi
  >&2 echo "Beschikbare VM's:"; local i=1
  for L in "${lines[@]}"; do >&2 printf "  [%2d] %s\n" "$i" "$L"; ((i++)); done
  >&2 read -r -p "Kies nummers of VMIDs (spaties), of 'all': " inp
  if [[ "$inp" == "all" ]]; then printf "%s\n" "${ids[@]}"; return 0; fi
  local chosen=() total=$((i-1))
  for tok in $inp; do
    if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok>=1 && tok<=total )); then chosen+=("${ids[tok-1]}")
    elif printf "%s\n" "${ids[@]}" | grep -qx "$tok"; then chosen+=("$tok")
    else >&2 echo "  - Ongeldig: $tok"; fi
  done
  ((${#chosen[@]})) || fail "Geen geldige VM-keuze."; printf "%s\n" "${chosen[@]}"
}

# -------------------- kernactions --------------------

remove_from_fstab_and_unmount_in_ct(){
  local id="$1" src_nfs="$2" src_cifs="$3" ts="$4"
  # backup + filter fstab met awk (behoud comments/lege regels)
  run_in_ct "$id" "if [ -f /etc/fstab ]; then cp -a /etc/fstab /etc/fstab.bak.$ts || true; awk -v s1='$src_nfs' -v s2='$src_cifs' '(\$1==s1 || \$1==s2){next} {print}' /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab; fi"
  # unmount targets met exacte bron (findmnt of fallback via mount)
  run_in_ct "$id" "t=\$(findmnt -rn -S '$src_nfs' -o TARGET 2>/dev/null); for m in \$t; do umount -l \"\$m\" || true; done"
  run_in_ct "$id" "t=\$(findmnt -rn -S '$src_cifs' -o TARGET 2>/dev/null); for m in \$t; do umount -l \"\$m\" || true; done"
  run_in_ct "$id" "if ! command -v findmnt >/dev/null 2>&1; then mount | awk -v s1='$src_nfs' -v s2='$src_cifs' '\$1==s1||\$1==s2{print \$3}' | xargs -r -n1 umount -l || true; fi"
  run_in_ct "$id" "systemctl daemon-reload || true"
}

process_lxc(){
  local server="$1" remote="$2"
  local src_nfs="${server}:${remote}"
  local src_cifs="//${server}/${remote#/}"   # alleen zinvol als remote een share is (bij SMB)
  local ts; ts="$(date +%Y%m%d-%H%M%S)"

  mapfile -t CTIDS < <(select_cts)
  echo "Gekozen LXC's: ${CTIDS[*]}"; confirm "LXC acties bevestigen?" || fail "Afgebroken."

  # host targets (precieze match van bron)
  mapfile -t HOST_BASES < <(host_targets_for_source "$src_nfs")
  mapfile -t TMP_BASES  < <(host_targets_for_source "$src_cifs")
  HOST_BASES+=("${TMP_BASES[@]}")

  log "Host mountpoints voor deze bron(nen): ${#HOST_BASES[@]}"
  for b in "${HOST_BASES[@]:-}"; do log "  - $b"; done

  for id in "${CTIDS[@]}"; do
    local name; name="$(ct_name "$id" || echo '-')"
    log "=== LXC $id ($name) ==="
    remove_from_fstab_and_unmount_in_ct "$id" "$src_nfs" "$src_cifs" "$ts"
    # mpN in config verwijderen waarvoor hostpad onder één van HOST_BASES valt
    if ((${#HOST_BASES[@]})); then
      mapfile -t IDX < <(lxc_mp_indexes_for_host_paths "$id" "${HOST_BASES[@]}")
      if ((${#IDX[@]})); then
        log "Bind mounts (mpN) te verwijderen: ${IDX[*]}"
        for n in "${IDX[@]}"; do
          if $DRY_RUN; then log "DRY-RUN HOST: pct set $id -delete mp${n}"; else pct set "$id" -delete "mp${n}" >/dev/null || warn "mp${n} verwijderen faalde"; fi
        done
      else
        log "Geen mpN bind-mounts gevonden voor deze bron."
      fi
    fi
    log "LXC $id klaar."
  done
}

process_vms(){
  local server="$1" remote="$2"
  local src_nfs="${server}:${remote}"
  local src_cifs="//${server}/${remote#/}"
  have ssh || fail "ssh ontbreekt (installeer openssh-client)."

  mapfile -t VMIDS < <(select_vms)
  echo "Gekozen VM's: ${VMIDS[*]}"; confirm "VM acties bevestigen?" || fail "Afgebroken."

  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  for id in "${VMIDS[@]}"; do
    local name; name="$(vm_name "$id" || echo '-')"
    echo; echo "=== VM $id ($name) ==="
    local target; read -r -p "SSH target (bijv. root@192.168.x.y) of leeg om te skippen: " target
    [[ -z "$target" ]] && { warn "VM $id overgeslagen (geen SSH target)."; continue; }
    local cmd="
      set -e
      S1='$src_nfs'; S2='$src_cifs'
      if [ -f /etc/fstab ]; then
        sudo cp -a /etc/fstab /etc/fstab.bak.$ts || true
        sudo awk -v s1=\"\$S1\" -v s2=\"\$S2\" '(\$1==s1 || \$1==s2){next} {print}' /etc/fstab | sudo tee /etc/fstab.new >/dev/null && sudo mv /etc/fstab.new /etc/fstab
      fi
      # unmount targets met exacte bron
      for s in \"\$S1\" \"\$S2\"; do
        t=\$(findmnt -rn -S \"\$s\" -o TARGET 2>/dev/null || true)
        for m in \$t; do sudo umount -l \"\$m\" || true; done
      done
      if ! command -v findmnt >/dev/null 2>&1; then
        sudo bash -lc 'mount | awk -v s1='\"'\$S1'\"' -v s2='\"'\$S2'\"' \"\$1==s1||\$1==s2{print \\$3}\" | xargs -r -n1 umount -l' || true
      fi
      sudo systemctl daemon-reload || true
    "
    run_ssh "$target" "$cmd" || warn "SSH/actie faalde voor $target"
  done
}

# -------------------- MAIN --------------------

main(){
  need_root
  echo "== Remove Specific Mount (LXC + VM) =="
  read -r -p "Server host/IP (bijv. 192.168.1.43): " SERVER
  [[ -n "$SERVER" ]] || fail "Server mag niet leeg zijn."
  read -r -p "Remote pad/export of SMB share (bijv. /mnt/Files/Share/downloads of Media): " REMOTE
  [[ -n "$REMOTE" ]] || fail "Remote pad/share mag niet leeg zijn."

  echo
  echo "We verwijderen exact deze bronnen (indien aanwezig):"
  echo "  - NFS : ${SERVER}:${REMOTE}"
  echo "  - SMB : //${SERVER}/${REMOTE#/}"
  $DRY_RUN && echo "LET OP: DRY-RUN AAN (geen wijzigingen worden echt doorgevoerd)."
  confirm "Doorgaan?" || fail "Afgebroken."

  echo
  echo "Wat wil je bewerken?"
  echo "  1) LXC + VM (standaard)"
  echo "  2) Alleen LXC"
  echo "  3) Alleen VM"
  read -r -p "Keuze [1/2/3]: " mode
  case "${mode:-1}" in
    2) process_lxc "$SERVER" "$REMOTE" ;;
    3) process_vms "$SERVER" "$REMOTE" ;;
    *) process_lxc "$SERVER" "$REMOTE"; process_vms "$SERVER" "$REMOTE" ;;
  esac

  echo
  log "Klaar."
}

main "$@"
