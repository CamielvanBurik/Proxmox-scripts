#!/usr/bin/env bash
set -euo pipefail

# ============================================
# TrueNAS NFS mount setup voor Proxmox LXC's (Host-wizard, interactief)
# - Draai op de Proxmox host (met 'pct') om meerdere LXC's te configureren
# - Draai binnen een LXC om alleen die container te configureren (valt terug op lokale setup)
# ============================================

# ---- Defaults (kun je via env overschrijven vóór start) ----
NAS_HOST="${NAS_HOST:-192.168.1.42}"
REMOTE_PATH="${REMOTE_PATH:-/mnt/Files/Share/downloads}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/downloads}"

# Robuuste fstab-opties (NFSv4.1, systemd, nofail, etc.)
FSTAB_OPTS="${FSTAB_OPTS:-vers=4.1,proto=tcp,_netdev,bg,noatime,timeo=150,retrans=2,nofail,nosuid,nodev,x-systemd.requires=network-online.target,x-systemd.after=network-online.target,x-systemd.device-timeout=0,x-systemd.mount-timeout=infinity}"

LOG_FILE="${LOG_FILE:-/var/log/truenas-nfs-lxc-setup.log}"

# -----------------------------------------------
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
fail(){ log "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ $EUID -eq 0 ]] || fail "Root is vereist."; }
on_host(){ have pct; }

ask_default() {
  local q="$1" def="$2" ans=""
  read -r -p "$q [$def]: " ans || true
  echo "${ans:-$def}"
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

# --------- Host: LXC selectie & configuratie ----------
pct_list_ctids(){
  pct list | awk 'NR>1{print $1}'
}

pct_is_running(){
  local id="$1"
  [[ "$(pct status "$id" | awk '{print $2}')" == "running" ]]
}

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
  local cfg="/etc/pve/lxc/${id}.conf"
  if [[ -r "$cfg" ]]; then
    if grep -Eq '(^|\s)features:\s*.*(mount=nfs|nfs=1).*' "$cfg"; then
      log "CT $id: NFS feature al aanwezig."
      return 0
    fi
  fi
  log "CT $id: probeer NFS feature te activeren (pct set -features mount=nfs)…"
  if pct set "$id" -features mount=nfs >/dev/null 2>&1; then
    log "CT $id: NFS feature gezet. (Herstart kan nodig zijn)"
  else
    log "CT $id: Kon NFS feature niet automatisch zetten. Controleer handmatig in ${cfg} (features: mount=nfs)."
  fi
}

pct_exec(){
  local id="$1"; shift
  pct exec "$id" -- bash -lc "$*"
}

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

select_cts(){
  local tmp="$(mktemp)"
  pct_list_ctids > "$tmp"
  local all_cts=()
  while IFS= read -r c; do [[ -n "$c" ]] && all_cts+=("$c"); done < "$tmp"
  rm -f "$tmp"

  (( ${#all_cts[@]} )) || fail "Geen LXC containers gevonden (pct list)."

  echo
  echo "Beschikbare LXC CTIDs:"
  pct list

  echo
  echo "Kies CTID(s) gescheiden door spaties, of 'all' voor allemaal."
  local sel; read -r -p "CTIDs: " sel

  if [[ "$sel" == "all" ]]; then
    printf "%s\n" "${all_cts[@]}"
    return 0
  fi

  local chosen=()
  for x in $sel; do
    [[ "$x" =~ ^[0-9]+$ ]] || { echo "Ongeldige CTID: $x"; continue; }
    if printf "%s\n" "${all_cts[@]}" | grep -qx "$x"; then
      chosen+=("$x")
    else
      echo "CTID niet gevonden: $x"
    fi
  done
  (( ${#chosen[@]} )) || fail "Geen geldige CTIDs gekozen."
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
    echo "Let op: containers moeten NFS mogen mounten (feature 'mount=nfs')."

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
