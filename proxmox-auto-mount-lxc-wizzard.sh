#!/usr/bin/env bash
set -euo pipefail

# ============================================
# TrueNAS NFS mount setup voor Proxmox LXC's (Host-wizard, interactief, met menu)
# ============================================

# ---- Defaults (kun je via env overschrijven vóór start) ----
NAS_HOST="${NAS_HOST:-192.168.1.42}"
REMOTE_PATH="${REMOTE_PATH:-/mnt/Files/Share/downloads}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/downloads}"

# Robuuste fstab-opties (NFSv4.1, systemd, nofail, etc.)
FSTAB_OPTS="${FSTAB_OPTS:-vers=4.1,proto=tcp,_netdev,bg,noatime,timeo=150,retrans=2,nofail,nosuid,nodev,x-systemd.requires=network-online.target,x-systemd.after=network-online.target,x-systemd.device-timeout=0,x-systemd.mount-timeout=infinity}"

LOG_FILE="${LOG_FILE:-/var/log/truenas-nfs-lxc-setup.log}"

# CLI toggles
NO_FZF=false

# -----------------------------------------------
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
fail(){ log "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ $EUID -eq 0 ]] || fail "Root is vereist."; }
on_host(){ have pct; }

usage(){
  cat <<EOF
Gebruik: $(basename "$0") [opties]

Opties:
  --no-fzf     Forceer numeriek menu (geen fzf)
  -h, --help   Toon deze hulp en stop

Interactieve prompts vragen NAS host, exportpad en mountpoint.
Op de host kun je meerdere LXC's selecteren via fzf (indien beschikbaar) of via een numeriek menu.
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

# -------- fzf (multi-select) installer / beslisser --------
ensure_fzf() {
  # Gebruik fzf alleen als we op een TTY zitten en de gebruiker het niet heeft uitgezet
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

  if have fzf; then
    log "fzf geïnstalleerd."
    return 0
  else
    log "Kon fzf niet installeren; val terug op numeriek menu."
    return 1
  fi
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

# --------- Host: LXC info helpers ----------
pct_list_ct_raw(){ pct list 2>/dev/null || true; }

pct_list_ctids(){
  pct_list_ct_raw | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'
}

ct_status(){
  local id="$1"
  pct status "$id" 2>/dev/null | awk '{print $2}'
}

ct_name_from_list(){
  local id="$1"
  pct_list_ct_raw | awk -v id="$id" 'NR>1 && $1==id {print $3; exit}'
}

ct_hostname(){
  local id="$1" hn=""
  hn="$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/{print $2; found=1} END{if(!found)print""}')" || true
  [[ -n "$hn" ]] || hn="$(ct_name_from_list "$id" || true)"
  echo "${hn:-unknown}"
}

ct_mountable_now(){
  local id="$1"
  if pct config "$id" 2>/dev/null | grep -Eq '^features:.*(mount=nfs|nfs=1)'; then
    echo "yes"
  else
    echo "no"
  fi
}

pct_is_running(){ [[ "$(ct_status "$1")" == "running" ]]; }

pct_ensure_running(){
  local id="$1"
  if ! pct_is_running "$id"; then
    log "CT $id is niet running; start…"
    pct start "$id"
    sleep 2
  fi
}

pct_try_enable_nfs_feature(){
  local id="$1"
  if [[ "$(ct_mountable_now "$id")" == "yes" ]]; then
    log "CT $id: NFS feature al aanwezig."
    return 0
  fi
  log "CT $id: probeer NFS feature te activeren (pct set -features mount=nfs)…"
  if pct set "$id" -features mount=nfs >/dev/null 2>&1; then
    log "CT $id: NFS feature gezet. (Herstart kan nodig zijn)"
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
  pct_exec "$id" 'export DEBIAN_FRONTEND=noninteractive; apt -y update && apt -y install nfs-common' || {
    log "CT $id: installatie nfs-common faalde"; return 1; }

  log "CT $id: mountpoint aanmaken: '"$MOUNTPOINT"'"
  pct_exec "$id" "mkdir -p '$MOUNTPOINT'"

  local FSTAB_LINE="${NAS_HOST}:${REMOTE_PATH}  ${MOUNTPOINT}  nfs  ${FSTAB_OPTS}  0  0"

  log "CT $id: /etc/fstab bijwerken"
  pct_exec "$id" "sed -i '\|[[:space:]]${MOUNTPOINT}[[:space:]]\\+nfs[[:space:]]|d' /etc/fstab || true"
  pct_exec "$id" "printf '%s\n' \"$FSTAB_LINE\" >> /etc/fstab"

  log "CT $id: systemd daemon-reload + wait-online (best effort)"
  pct_exec "$id" 'systemctl daemon-reload || true'
  pct_exec "$id" 'systemctl enable --now systemd-networkd-wait-online.service 2>/dev/null || true'
  pct_exec "$id" 'systemctl enable --now NetworkManager-wait-online.service 2>/dev/null || true'

  log "CT $id: mounten proberen (nfs4 direct, dan remote-fs.target)"
  if ! pct_exec "$id" "mount -t nfs4 '${NAS_HOST}:${REMOTE_PATH}' '${MOUNTPOINT}'"; then
    pct_exec "$id" "systemctl restart remote-fs.target" || true
  fi

  log "=== CT $id: configuratie klaar ==="
}

# --------- Multi-select menu ----------
select_cts(){
  log "Containers ophalen…"
  local ids=() lines=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    ids+=("$id")
    local st hn mnt mark
    st="$(ct_status "$id" 2>/dev/null || true)"
    hn="$(ct_hostname "$id" 2>/dev/null || true)"
    mnt="$(ct_mountable_now "$id" 2>/dev/null || echo no)"
    [[ "$mnt" == "yes" ]] && mark="✓" || mark="✗"
    lines+=("$(printf "%-6s [%-1s] %-24s | status:%-8s | nfs:%s" "$id" "$mark" "${hn:-unknown}" "${st:-unknown}" "$mnt")")
  done < <(pct_list_ctids)

  (( ${#ids[@]} )) || fail "Geen LXC containers gevonden (pct list)."
  log "Gevonden: ${#ids[@]} container(s)."

  if ensure_fzf; then
    log "fzf-menu openen… (spatie=selecteren, Enter=bevestigen, ESC=annuleren)"
    local selected
    selected="$(printf "%s\n" "${lines[@]}" \
      | fzf -m \
            --prompt="Selecteer CT's > " \
            --header="Spatie=selecteer, Enter=bevestig | [✓]=mountable nu, [✗]=nu niet (wizard probeert te activeren)" \
            --height=90% --border --ansi \
            --preview 'echo {}' --preview-window=down,10%)" || true
    if [[ -n "$selected" ]]; then
      printf "%s\n" "$selected" | awk '{print $1}'
      return 0
    else
      log "Geen keuze via fzf; val terug op numeriek menu."
    fi
  fi

  # Numeriek fallback (multi)
  >&2 echo
  >&2 echo "Beschikbare LXC's:"
  local i=1
  for line in "${lines[@]}"; do
    >&2 printf "  [%2d] %s\n" "$i" "$line"
    ((i++))
  done
  >&2 echo
  >&2 echo "Kies meerdere met nummers of CTIDs, gescheiden door spaties. Of typ 'all'."
  local sel; read -r -p "Keuze: " sel

  if [[ "$sel" == "all" ]]; then
    printf "%s\n" "${ids[@]}"; return 0
  fi

  local chosen=()
  for tok in $sel; do
    if [[ "$tok" =~ ^[0-9]+$ ]]; then
      if (( tok>=1 && tok<i )); then chosen+=("${ids[tok-1]}"); continue; fi
    fi
    if printf "%s\n" "${ids[@]}" | grep -qx "$tok"; then
      chosen+=("$tok")
    else
      >&2 echo "  - Onbekende keuze: $tok (genegeerd)"
    fi
  done
  (( ${#chosen[@]} )) || fail "Geen geldige keuze."
  printf "%s\n" "${chosen[@]}"
}

main(){
  echo "== TrueNAS NFS mount setup (Host-wizard) =="

  # ---- Interactieve prompts met defaults ----
  NAS_HOST="$(ask_default "NAS host/IP" "$NAS_HOST")"
  REMOTE_PATH="$(ask_default "Remote export (pad op NAS)" "$REMOTE_PATH")"
  MOUNTPOINT="$(ask_default "Mountpoint in container" "$MOUNTPOINT")"

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
    echo "Host-modus gedetecteerd (pct gevonden). We gaan containers configureren."
    echo "Let op: [✓] = mountable nu (features: mount=nfs), [✗] = nu niet; de wizard probeert dit zo nodig te activeren."
    echo

    log "Start selectie-menu…"
    mapfile -t targets < <(select_cts)

    echo
    echo "Gekozen CTIDs: ${targets[*]}"
    read -r -p "Doorgaan met configuratie? [Y/n] " go
    [[ "${go:-Y}" =~ ^([Yy]|)$ ]] || fail "Afgebroken."

    for id in "${targets[@]}"; do
      setup_in_ct "$id" || log "CT $id: er trad een fout op (zie log)."
    done

    echo
    log "Alle gekozen containers zijn verwerkt."
    echo "Controlevoorbeeld: pct exec <CTID> -- bash -lc 'mount | grep ${MOUNTPOINT}'"
  else
    echo
    echo "Geen 'pct' gevonden: aannemend dat je binnen een LXC draait."
    read -r -p "Deze container nu configureren? [Y/n] " yn2
    [[ "${yn2:-Y}" =~ ^([Yy]|)$ ]] || fail "Afgebroken."
    configure_local
  fi
}

main "$@"
