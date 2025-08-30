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

# -------- fzf (multi-select) installer --------
ensure_fzf() {
  if have fzf; then return 0; fi
  log "fzf niet gevonden; probeer te installeren…"
  local SUDO=""; (( EUID != 0 )) && have sudo && SUDO="sudo"
  if have apt-get; then
    $SUDO apt-get update -y || true
    $SUDO apt-get install -y fzf || true
  elif have dnf; then
    $SUDO dnf install -y fzf || true
  elif have yum; then
    $SUDO yum install -y fzf || true
  elif have zypper; then
    $SUDO zypper --non-interactive install fzf || true
  elif have pacman; then
    $SUDO pacman -Sy --noconfirm fzf || true
  fi
  have fzf || log "Kon fzf niet installeren; val terug op numeriek menu."
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
  # Pakt alleen een numerieke eerste kolom (VMID), slaat header/lege regels over
  pct_list_ct_raw | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'
}

ct_status(){
  local id="$1"
  pct status "$id" 2>/dev/null | awk '{print $2}'
}

ct_name_from_list(){
  # Snelle naam uit `pct list` (3e kolom)
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
    log "CT
