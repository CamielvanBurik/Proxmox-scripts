#!/usr/bin/env bash
set -euo pipefail

# =========================================
# Proxmox host rotating backup (refactor + fixes + self-test + partclone + auto-install)
# - Weekly / Monthly / Semiannual (ZFS & LVM)
# - --snapshot-only [NAAM]   (alleen snapshot bewaren)
# - --snapshot [NAAM]        (snapshot + dump; snapshot blijft staan; dump in MANUAL_DIR)
# - --snapshot-delete NAAM   (verwijder ZFS of LVM snapshot met gegeven naam)
# - --cleanup                (partials/empty weg; checksum-verify; quarantine; stale snapshots)
# - --verify                 (alle archieven via checksum controleren; exit 1 bij mismatch)
# - --self-test              (niet-invasieve systeemcheck)
# - LVM-dumps: partclone (ext4/xfs) -> kleiner & sneller; fallback naar dd
# - Full-disk dumps: sparse .img (+conv=sparse) -> atomisch .img.xz
# - Atomisch wegschrijven + checksums (b3sum of sha256sum)
# - Auto-install: partclone, pigz, xz (als root; apt/dnf/yum/zypper/pacman)
# =========================================

# ========= Config =========
BASE_DIR="/mnt/pve/BackupHD/HDproxmox-host"
W_DIR="$BASE_DIR/weekly"
M_DIR="$BASE_DIR/monthly"
H_DIR="$BASE_DIR/semiannual"
MANUAL_DIR="$BASE_DIR/manual"
QUARANTINE_DIR="$BASE_DIR/quarantine"

RETENTION_WEEKLY=6
RETENTION_MONTHLY=6
RETENTION_SEMIANNUAL=2
RETENTION_MANUAL=12           # aantal manual dumps (*.gz|*.xz) bewaren

ZFS_ROOT_DATASET_DEFAULT="rpool/ROOT/pve-1"
LVM_SNAP_SIZE="10G"           # COW size (bv. 10G of 1024M)

LOG_FILE="/var/log/proxmox-host-rotating-backup.log"
LOCK_FILE="/var/lock/proxmox-host-rotating-backup.lock"

# Cleanup/verify toggles
CLEANUP_VALIDATE_ARCHIVES=true
CLEANUP_REMOVE_EMPTY_AND_PARTS=true
CLEANUP_REMOVE_STALE_SNAPSHOTS=true   # verwijder alleen "rootsnap-*" (LVM) en S/M/H-... (ZFS)
CLEANUP_QUICK_ONLY=false
CLEANUP_QUARANTINE_CORRUPT=true

# Checksums
CHECKSUM_CREATE_ON_WRITE=true
CHECKSUM_CREATE_IF_MISSING=true

# Auto-install toggles
AUTO_INSTALL_PKGS=true         # zet uit om nooit pakketten te installeren
AUTO_INSTALL_UPDATE=true       # apt/dnf/... eerst update uitvoeren
# ==========================

# ========= Globals =========
HOST="$(hostname -s)"
TODAY="$(date +%F)"                 # YYYY-MM-DD
NOWHM="$(date +%Y%m%d-%H%M%S)"
YEAR="$(date +%Y)"; MONTH="$(date +%m)"; WEEK="$(date +%V)"
NEXTW_MONTH="$(date -d "$TODAY +7 days" +%m || true)"
IS_LAST_WEEK_OF_MONTH=$([[ "$NEXTW_MONTH" != "$MONTH" ]] && echo 1 || echo 0)
IS_SEMIANNUAL_MONTH=$([[ "$MONTH" == "01" || "$MONTH" == "07" ]] && echo 1 || echo 0)

ROOT_FSTYPE="$(findmnt -no FSTYPE / || true)"
ROOT_SOURCE="$(findmnt -no SOURCE / || true)"

CHECKSUM_CMD=""; CHECKSUM_EXT=""
COMP=""   # pigz of gzip
# ==========================

# ========= Utils =========
log()      { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
fail()     { log "ERROR: $*"; exit 1; }
unlock()   { [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"; }
trap unlock EXIT

have_cmd() { command -v "$1" >/dev/null 2>&1; }

pkgmgr_detect() {
  if have_cmd apt-get; then echo apt; return 0
  elif have_cmd dnf; then echo dnf; return 0
  elif have_cmd yum; then echo yum; return 0
  elif have_cmd zypper; then echo zypper; return 0
  elif have_cmd pacman; then echo pacman; return 0
  else echo none; return 1; fi
}

try_install_pkgs() {
  # Args: pkgs...
  [[ "$AUTO_INSTALL_PKGS" == "true" ]] || return 1
  (( EUID == 0 )) || { log "Auto-install: root vereist; sla installatie over"; return 1; }
  local mgr; mgr="$(pkgmgr_detect || true)"
  [[ "$mgr" == "none" ]] && { log "Auto-install: geen ondersteunde package manager gevonden"; return 1; }

  local pkgs=("$@")
  log "Auto-install: pakket(ten) proberen te installeren: ${pkgs[*]} (mgr=$mgr)"

  case "$mgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      [[ "$AUTO_INSTALL_UPDATE" == "true" ]] && { apt-get -y update || true; }
      apt-get install -y --no-install-recommends "${pkgs[@]}" || return 1
      ;;
    dnf)
      [[ "$AUTO_INSTALL_UPDATE" == "true" ]] && { dnf -y makecache || true; }
      dnf install -y "${pkgs[@]}" || return 1
      ;;
    yum)
      [[ "$AUTO_INSTALL_UPDATE" == "true" ]] && { yum -y makecache || true; }
      yum install -y "${pkgs[@]}" || return 1
      ;;
    zypper)
      [[ "$AUTO_INSTALL_UPDATE" == "true" ]] && { zypper --non-interactive refresh || true; }
      zypper --non-interactive install --no-recommends "${pkgs[@]}" || return 1
      ;;
    pacman)
      [[ "$AUTO_INSTALL_UPDATE" == "true" ]] && { pacman -Sy --noconfirm || true; }
      pacman -S --noconfirm --needed "${pkgs[@]}" || return 1
      ;;
  esac
  return 0
}

ensure_tools() {
  local want=() mgr
  mgr="$(pkgmgr_detect || true)"

  # pigz (sneller comprimeren)
  if ! have_cmd pigz; then want+=("pigz"); fi
  # partclone (used-blocks dump voor ext4/xfs)
  if ! have_cmd partclone.extfs && ! have_cmd partclone.xfs; then want+=("partclone"); fi
  # xz (voor sparse raw -> .xz compressie)
  if ! have_cmd xz; then
    if [[ "$mgr" == "apt" ]]; then want+=("xz-utils"); else want+=("xz"); fi
  fi

  if (( ${#want[@]} )); then
    try_install_pkgs "${want[@]}" || log "Auto-install: installatie mislukt of niet mogelijk; ga door met bestaande tools"
  fi
  # b3sum installeren we niet automatisch; sha256sum is vrijwel altijd aanwezig.
}

compressor() { have_cmd pigz && echo pigz || echo gzip; }

init_checksum() {
  if have_cmd b3sum; then
    CHECKSUM_CMD="b3sum"; CHECKSUM_EXT="b3"
  elif have_cmd sha256sum; then
    CHECKSUM_CMD="sha256sum"; CHECKSUM_EXT="sha256"
  else
    log "Waarschuwing: geen b3sum/sha256sum gevonden; checksums uitgeschakeld."
    CHECKSUM_CMD=""; CHECKSUM_EXT=""
  fi
}

write_checksum() {
  [[ -n "$CHECKSUM_CMD" ]] || return 0
  local f="$1" dir base tmp
  dir="$(dirname "$f")"; base="$(basename "$f")"; tmp="${base}.${CHECKSUM_EXT}.part"
  ( cd "$dir" && $CHECKSUM_CMD "$base" > "$tmp" && sync -f "$tmp" 2>/dev/null || true && mv -f "$tmp" "${base}.${CHECKSUM_EXT}" )
}

verify_checksum() {
  [[ -n "$CHECKSUM_CMD" ]] || return 2
  local f="$1" dir base chk
  dir="$(dirname "$f")"; base="$(basename "$f")"; chk="${base}.${CHECKSUM_EXT}"
  if [[ ! -f "$dir/$chk" ]]; then
    [[ "$CHECKSUM_CREATE_IF_MISSING" == "true" ]] && write_checksum "$f"
    return 2
  fi
  ( cd "$dir" && $CHECKSUM_CMD -c "$chk" >/dev/null 2>&1 ) && return 0 || return 1
}

write_atomic_from_stdin() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    log "INTERNAL: write_atomic_from_stdin zonder target aangeroepen"
    return 1
  fi
  local dir tmp
  dir="$(dirname -- "$target")"
  tmp="${target}.part"
  [[ -d "$dir" && -w "$dir" ]] || fail "Doelmap niet (schrijfbaar): $dir"
  if ! cat > "$tmp"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  sync -f "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$target"
  [[ "$CHECKSUM_CREATE_ON_WRITE" == "true" ]] && write_checksum "$target"
}

bytes_from_size() {
  local s="$1"
  if have_cmd numfmt; then
    numfmt --from=iec "$s"
  else
    case "$s" in
      *G|*g) echo $(( ${s%[Gg]} * 1073741824 )) ;;
      *M|*m) echo $(( ${s%[Mm]} * 1048576 )) ;;
      *K|*k) echo $(( ${s%[Kk]} * 1024 )) ;;
      *)     echo "$s" ;;
    esac
  fi
}

ensure_vg_free() {
  local vg="$1" need="$2" free
  free="$(vgs --noheadings -o vg_free --units B --nosuffix "$vg" 2>/dev/null | awk '{$1=$1};1')"
  [[ -n "$free" && "$free" -ge "$need" ]] || fail "Onvoldoende vrije ruimte in VG '$vg' (free=${free:-0}B, nodig=$need)"
}

zfs_dataset_root() {
  local ds
  ds="$(zfs list -H -o name / 2>/dev/null || true)"
  [[ -z "$ds" ]] && ds="$ZFS_ROOT_DATASET_DEFAULT"
  echo "$ds"
}
# ==========================

# ========= Dump helper (partclone + fallback dd) =========
dump_block_device_smart() {
  # Args: <DEV> <OUTFILE> <COMP_CMD> <FSTYPE>
  local DEV="$1" OUTFILE="$2" COMP_CMD="$3" FST="$4"
  [[ -n "$OUTFILE" ]] || fail "Internal: OUTFILE is leeg (dump_block_device_smart)"
  if [[ "$FST" == "ext4" && -x "$(command -v partclone.extfs || true)" ]]; then
    log "Dump (partclone.extfs) -> $OUTFILE"
    partclone.extfs -c -s "$DEV" -o - \
      | $COMP_CMD \
      | write_atomic_from_stdin "$OUTFILE"
  elif [[ "$FST" == "xfs" && -x "$(command -v partclone.xfs || true)" ]]; then
    log "Dump (partclone.xfs) -> $OUTFILE"
    partclone.xfs -c -s "$DEV" -o - \
      | $COMP_CMD \
      | write_atomic_from_stdin "$OUTFILE"
  else
    log "Dump (dd fallback) -> $OUTFILE"
    dd if="$DEV" bs=64M status=progress \
      | $COMP_CMD \
      | write_atomic_from_stdin "$OUTFILE"
  fi
}
# ========================================================

# ========= Low-level snapshot/dump =========
createsnapshot() {
  # Args: <VG> <LV> <SNAP_NAME> <OUTFILE> <COMP_CMD> [KEEP=false|true]
  local VG="$1" LV="$2" SNAP_NAME="$3" OUTFILE="$4" COMP_CMD="$5" KEEP="${6:-false}"
  local SNAP_PATH="/dev/${VG}/${SNAP_NAME}"
  [[ -n "$OUTFILE" ]] || fail "Internal: OUTFILE is leeg (createsnapshot)"

  log "LVM: snapshot ${VG}/${SNAP_NAME} <- ${VG}/${LV} (size $LVM_SNAP_SIZE)"
  lvcreate --snapshot -L "$LVM_SNAP_SIZE" -n "$SNAP_NAME" "/dev/${VG}/${LV}" >>"$LOG_FILE" 2>&1 || fail "lvcreate snapshot mislukt"

  if dump_block_device_smart "$SNAP_PATH" "$OUTFILE" "$COMP_CMD" "$ROOT_FSTYPE"; then
    log "OK: $OUTFILE"
  else
    lvremove -f "$SNAP_PATH" >>"$LOG_FILE" 2>&1 || true
    fail "dump van LVM snapshot mislukt"
  fi

  if [[ "$KEEP" == "true" ]]; then
    log "LVM: snapshot behouden: ${VG}/${SNAP_NAME}"
  else
    log "LVM: verwijder snapshot ${VG}/${SNAP_NAME}"
    lvremove -f "$SNAP_PATH" >>"$LOG_FILE" 2>&1 || log "Waarschuwing: snapshot opruimen faalde"
  fi
}

zfs_send_snapshot() {
  # Args: <DATASET> <SNAP_NAME> <OUTFILE> <COMP_CMD> [KEEP=false|true]
  local DATASET="$1" SNAP_NAME="$2" OUTFILE="$3" COMP_CMD="$4" KEEP="${5:-false}"
  local SNAPSHOT="${DATASET}@${SNAP_NAME}"
  have_cmd zfs || fail "zfs niet gevonden"
  [[ -n "$OUTFILE" ]] || fail "Internal: OUTFILE is leeg (zfs_send_snapshot)"

  log "ZFS: snapshot $SNAPSHOT"
  zfs snapshot "$SNAPSHOT" || fail "ZFS snapshot mislukt"

  log "ZFS: send -> $OUTFILE"
  if zfs send -c "$SNAPSHOT" \
     | $COMP_CMD \
     | write_atomic_from_stdin "$OUTFILE"; then
    log "OK: $OUTFILE"
    if [[ "$KEEP" == "true" ]]; then
      log "ZFS: snapshot behouden: $SNAPSHOT"
    else
      log "ZFS: destroy $SNAPSHOT"
      zfs destroy "$SNAPSHOT" || log "Waarschuwing: kon snapshot $SNAPSHOT niet verwijderen"
    fi
  else
    fail "zfs send mislukt"
  fi
}
# ==========================

# ========= High-level acties =========
snapshot_only() {
  local name="${1:-manual-$NOWHM}"
  if [[ "$ROOT_FSTYPE" == "zfs" ]]; then
    local ds snap; ds="$(zfs_dataset_root)"; snap="${ds}@${name}"
    log "Snapshot-only (ZFS): $snap"; zfs snapshot "$snap" || fail "ZFS snapshot mislukt"
  elif [[ "$ROOT_FSTYPE" =~ ^(ext4|xfs|btrfs|f2fs)$ ]]; then
    [[ "$ROOT_SOURCE" == /dev/*/* || "$ROOT_SOURCE" == /dev/mapper/* ]] || fail "Snapshot-only: root niet op LVM/ZFS"
    local VG LV snap need
    VG="$(lvs --noheadings -o vg_name "$ROOT_SOURCE" | awk '{$1=$1};1' || true)"
    LV="$(lvs --noheadings -o lv_name "$ROOT_SOURCE" | awk '{$1=$1};1' || true)"
    [[ -n "$VG" && -n "$LV" ]] || fail "LVM root niet gevonden"
    need="$(bytes_from_size "$LVM_SNAP_SIZE")"; ensure_vg_free "$VG" "$need"
    snap="manualsnap-${name}"
    log "Snapshot-only (LVM): ${VG}/${snap}"
    lvcreate --snapshot -L "$LVM_SNAP_SIZE" -n "$snap" "/dev/${VG}/${LV}" >>"$LOG_FILE" 2>&1 || fail "lvcreate snapshot mislukt"
  else
    fail "Snapshot-only: onbekend root fs ($ROOT_FSTYPE)"
  fi
}

snapshot_and_dump() {
  local name="${1:-manual-$NOWHM}"
  if [[ "$ROOT_FSTYPE" == "zfs" ]]; then
    local ds outfile; ds="$(zfs_dataset_root)"
    outfile="${MANUAL_DIR}/${HOST}-zfs-manual-${TODAY}.zfs.gz"
    zfs_send_snapshot "$ds" "$name" "$outfile" "$COMP" true
  else
    [[ "$ROOT_SOURCE" == /dev/*/* || "$ROOT_SOURCE" == /dev/mapper/* ]] || fail "Snapshot: root niet op LVM"
    local VG LV snap need outfile
    VG="$(lvs --noheadings -o vg_name "$ROOT_SOURCE" | awk '{$1=$1};1' || true)"
    LV="$(lvs --noheadings -o lv_name "$ROOT_SOURCE" | awk '{$1=$1};1' || true)"
    [[ -n "$VG" && -n "$LV" ]] || fail "LVM root niet gevonden"
    need="$(bytes_from_size "$LVM_SNAP_SIZE")"; ensure_vg_free "$VG" "$need"
    snap="manualsnap-${name}"
    outfile="${MANUAL_DIR}/${HOST}-lvm-manual-${TODAY}.img.gz"
    createsnapshot "$VG" "$LV" "$snap" "$outfile" "$COMP" true
  fi
}

snapshot_delete() {
  local name="$1" deleted=0

  if have_cmd zfs; then
    local target
    if [[ "$name" == *"@"* ]]; then target="$name"; else target="$(zfs_dataset_root)@${name}"; fi
    if zfs list -H -t snapshot -o name 2>/dev/null | grep -Fxq "$target"; then
      log "Verwijder ZFS snapshot: $target"
      zfs destroy "$target" && ((deleted++)) || log "Waarschuwing: kon $target niet verwijderen"
    fi
  fi

  local base="$name"
  [[ "$base" == /dev/*/* ]] && base="${base##*/}"
  if have_cmd lvs; then
    local p1="$base" p2="manualsnap-$base" p3="rootsnap-$base"
    while read -r vg lv attr; do
      if [[ "$attr" =~ ^s ]] && [[ "$lv" == "$p1" || "$lv" == "$p2" || "$lv" == "$p3" ]]; then
        log "Verwijder LVM snapshot: ${vg}/${lv}"
        lvremove -f "/dev/${vg}/${lv}" >>"$LOG_FILE" 2>&1 && ((deleted++)) || log "Waarschuwing: kon ${vg}/${lv} niet verwijderen"
      fi
    done < <(lvs --noheadings -o vg_name,lv_name,lv_attr | awk '{$1=$1};1')
  fi

  if (( deleted == 0 )); then
    fail "Geen snapshot gevonden met naam '$name' (ZFS of LVM)."
  else
    log "Snapshot-delete: verwijderd=$deleted"
  fi
}

# ========= NIEUW: full-disk -> sparse raw + xz =========
full_disk_backup() {
  local type="$1" outdir="$2"
  local rootdev pk base rawfile outfile

  rootdev="$(findmnt -no SOURCE /)"
  pk="$(lsblk -no PKNAME "$rootdev" 2>/dev/null || true)"
  base="${pk:+/dev/$pk}"; [[ -n "$base" ]] || base="$rootdev"
  [[ -b "$base" ]] || fail "Kon fysieke disk niet bepalen ($base)"

  rawfile="${outdir}/${HOST}-disk-${type}-${TODAY}.img"      # tijdelijk raw (sparse)
  outfile="${rawfile}.xz"                                    # eindresultaat

  # Optioneel: TRIM vooraf (kan compressie/sparseness helpen op SSD's)
  if command -v fstrim >/dev/null 2>&1; then
    log "TRIM: fstrim -av (pre-image)"
    fstrim -av >>"$LOG_FILE" 2>&1 || log "Waarschuwing: fstrim faalde; ga door"
  else
    log "TRIM: fstrim niet gevonden; sla over"
  fi

  log "Disk raw sparse image: $base -> $rawfile"
  if ! dd if="$base" of="$rawfile" bs=64M status=progress conv=sparse; then
    rm -f -- "$rawfile" 2>/dev/null || true
    fail "dd van volledige disk mislukt"
  fi

  if command -v xz >/dev/null 2>&1; then
    log "Compress (xz --threads=0 --sparse): $rawfile -> $outfile"
    if xz --threads=0 --sparse -c "$rawfile" | write_atomic_from_stdin "$outfile"; then
      rm -f -- "$rawfile" 2>/dev/null || true
      log "OK: $outfile"
    else
      rm -f -- "$outfile.part" 2>/dev/null || true
      log "Let op: raw image blijft staan voor diagnose: $rawfile"
      fail "xz compressie mislukt"
    fi
  else
    local gz_out="${rawfile}.gz"
    log "xz ontbreekt; fallback compress ($COMP): $rawfile -> $gz_out"
    if cat "$rawfile" | $COMP | write_atomic_from_stdin "$gz_out"; then
      rm -f -- "$rawfile" 2>/dev/null || true
      log "OK: $gz_out"
    else
      rm -f -- "$gz_out.part" 2>/dev/null || true
      log "Let op: raw image blijft staan voor diagnose: $rawfile"
      fail "fallback compressie mislukt"
    fi
  fi
}

create_backup() {
  local T="$1" outdir outfile
  case "$T" in S) outdir="$W_DIR" ;; M) outdir="$M_DIR" ;; H) outdir="$H_DIR" ;; *) fail "Onbekend type: $T" ;; esac

  if [[ "$ROOT_FSTYPE" == "zfs" ]]; then
    local ds snap; ds="$(zfs_dataset_root)"
    snap="${T}-${TODAY}"
    outfile="${outdir}/${HOST}-zfs-${snap}.zfs.gz"
    zfs_send_snapshot "$ds" "$snap" "$outfile" "$COMP" false
  elif [[ "$ROOT_FSTYPE" =~ ^(ext4|xfs|btrfs|f2fs)$ ]]; then
    if [[ "$T" == "S" && ( "$ROOT_SOURCE" == /dev/*/* || "$ROOT_SOURCE" == /dev/mapper/* ) ]]; then
      local VG LV snap need
      VG="$(lvs --noheadings -o vg_name "$ROOT_SOURCE" | awk '{$1=$1};1' || true)"
      LV="$(lvs --noheadings -o lv_name "$ROOT_SOURCE" | awk '{$1=$1};1' || true)"
      [[ -n "$VG" && -n "$LV" ]] || fail "LVM root niet gevonden"
      snap="rootsnap-${T}-${TODAY}"
      outfile="${outdir}/${HOST}-lvm-${T}-${TODAY}.img.gz"
      need="$(bytes_from_size "$LVM_SNAP_SIZE")"; ensure_vg_free "$VG" "$need"
      createsnapshot "$VG" "$LV" "$snap" "$outfile" "$COMP" false
    else
      full_disk_backup "$T" "$outdir"
    fi
  else
    log "Onbekend/anders root fs ($ROOT_FSTYPE) -> volledige disk image"
    full_disk_backup "$T" "$outdir"
  fi
}
# ==========================

# ========= Retentie & Cleanup =========
prune_dir() {
  local dir="$1" keep="$2" files=()
  # Tel zowel .gz als .xz (laatste eerst)
  mapfile -t files < <(ls -1t "$dir"/*.gz "$dir"/*.xz 2>/dev/null || true)
  (( ${#files[@]} <= keep )) && return 0
  for f in "${files[@]:$keep}"; do
    log "Retentie: verwijder $f"
    rm -f -- "$f" || log "Waarschuwing: kon $f niet verwijderen"
    rm -f -- "${f}.b3" "${f}.sha256" 2>/dev/null || true
  done
}

cleanup_archives() {
  log "Cleanup: archieven (partials/empty/checksum)"
  if [[ "$CLEANUP_REMOVE_EMPTY_AND_PARTS" == "true" ]]; then
    find "$BASE_DIR" -type f -name '*.part' -print -delete 2>/dev/null || true
    find "$BASE_DIR" -type f -size 0 -print -delete 2>/dev/null || true
  fi
  if [[ "$CLEANUP_VALIDATE_ARCHIVES" == "true" && -n "$CHECKSUM_CMD" ]]; then
    while IFS= read -r -d '' f; do
      [[ "$CLEANUP_QUICK_ONLY" == "true" && -f "${f}.${CHECKSUM_EXT}" ]] && continue
      if verify_checksum "$f"; then
        : # ok
      else
        case $? in
          1)
            local ts base dest; ts="$(date +%s)"; base="$(basename "$f")"; dest="$QUARANTINE_DIR/${base}.bad.${ts}"
            log "Checksum mismatch -> quarantine: $f -> $dest"
            mkdir -p "$QUARANTINE_DIR" 2>/dev/null || true
            mv -f -- "$f" "$dest" || log "Waarschuwing: kon $f niet verplaatsen"
            [[ -f "${f}.${CHECKSUM_EXT}" ]] && mv -f -- "${f}.${CHECKSUM_EXT}" "${dest}.${CHECKSUM_EXT}" || true
            ;;
          2) : ;;
        esac
      fi
    done < <(find "$BASE_DIR" -type f \( -name '*.gz' -o -name '*.xz' \) -print0 2>/dev/null)
  fi
}

cleanup_stale_snapshots() {
  [[ "$CLEANUP_REMOVE_STALE_SNAPSHOTS" == "true" ]] || return 0
  if have_cmd lvs; then
    while read -r vg lv attr; do
      if [[ "$attr" =~ ^s ]] && [[ "$lv" =~ ^rootsnap- ]]; then
        log "Cleanup: LVM stale snapshot ${vg}/${lv}"
        lvremove -f "/dev/${vg}/${lv}" >>"$LOG_FILE" 2>&1 || log "Waarschuwing: kon snapshot ${vg}/${lv} niet verwijderen"
      fi
    done < <(lvs --noheadings -o vg_name,lv_name,lv_attr | awk '{$1=$1};1')
  fi
  if [[ "$ROOT_FSTYPE" == "zfs" ]] && have_cmd zfs; then
    while read -r snap; do
      local base="${snap##*@}"
      if [[ "$base" =~ ^(S|M|H)-[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        log "Cleanup: ZFS stale snapshot $snap"
        zfs destroy "$snap" >>"$LOG_FILE" 2>&1 || log "Waarschuwing: kon snapshot $snap niet verwijderen"
      fi
    done < <(zfs list -H -t snapshot -o name 2>/dev/null || true)
  fi
}

cleanup_all() { cleanup_archives; cleanup_stale_snapshots; log "Cleanup: klaar"; }

verify_archives() {
  [[ -n "$CHECKSUM_CMD" ]] || { log "Verify: geen checksumtool (b3sum/sha256sum)"; return 2; }
  local total=0 ok=0 bad=0 missing=0 created=0
  while IFS= read -r -d '' f; do
    ((total++))
    if [[ ! -f "${f}.${CHECKSUM_EXT}" ]]; then
      ((missing++))
      [[ "$CHECKSUM_CREATE_IF_MISSING" == "true" ]] && { write_checksum "$f" || true; ((created++)); }
    fi
    if verify_checksum "$f"; then
      ((ok++))
    else
      [[ $? -eq 1 ]] && ((bad++))
    fi
  done < <(find "$BASE_DIR" -type f \( -name '*.gz' -o -name '*.xz' \) -print0 2>/dev/null)
  log "Verify: total=$total ok=$ok mismatch=$bad missing=$missing created=$created"
  [[ $bad -eq 0 ]]
}

# ========= Self-test =========
self_test() {
  log "=== Self-test gestart $TODAY ==="
  [[ -d "$BASE_DIR" ]] || fail "BASE_DIR bestaat niet: $BASE_DIR"
  [[ -w "$BASE_DIR" ]] || fail "BASE_DIR niet schrijfbaar: $BASE_DIR"
  for d in "$W_DIR" "$M_DIR" "$H_DIR" "$MANUAL_DIR"; do mkdir -p "$d"; [[ -w "$d" ]] || fail "Doelmap niet schrijfbaar: $d"; done

  # Tools (na auto-install)
  for bin in findmnt lsblk dd; do have_cmd "$bin" || fail "Benodigde tool ontbreekt: $bin"; done
  have_cmd "$COMP" || fail "Compressor ontbreekt: $COMP"
  have_cmd lvs || log "Let op: lvm2 tooling (lvs) niet gevonden; LVM-functionaliteit beperkt"
  have_cmd zfs || true
  have_cmd xz  && log "xz aanwezig" || log "xz ontbreekt (full-disk fallback gebruikt compressor $COMP)"

  # partclone info
  have_cmd partclone.extfs && log "partclone.extfs aanwezig"
  have_cmd partclone.xfs  && log "partclone.xfs aanwezig"

  echo "ok" | $COMP >/dev/null || fail "Compressor faalde: $COMP"

  local tdir tfile
  tdir="$W_DIR"
  tfile="${tdir}/.selftest-${NOWHM}"
  echo "hello-selftest" | write_atomic_from_stdin "$tfile"
  [[ -s "$tfile" ]] || fail "Atomisch wegschrijven faalde ($tfile niet aangemaakt)"
  if [[ -n "$CHECKSUM_CMD" ]]; then
    verify_checksum "$tfile" || true
  fi
  rm -f -- "$tfile" "${tfile}.b3" "${tfile}.sha256" 2>/dev/null || true

  [[ -n "$ROOT_FSTYPE" ]] || fail "Kon root FSTYPE niet bepalen"
  [[ -n "$ROOT_SOURCE" ]] || fail "Kon root SOURCE niet bepalen"
  log "Root FS: type=$ROOT_FSTYPE source=$ROOT_SOURCE"

  if [[ "$ROOT_FSTYPE" == "zfs" ]]; then
    have_cmd zfs || fail "zfs command niet gevonden"
    local ds; ds="$(zfs_dataset_root)"
    [[ -n "$ds" ]] || fail "ZFS dataset root niet gevonden"
    zfs list -H -o name "$ds" >/dev/null 2>&1 || fail "ZFS dataset niet toegankelijk: $ds"
    log "ZFS OK: dataset=$ds"
  fi

  if [[ "$ROOT_SOURCE" == /dev/*/* || "$ROOT_SOURCE" == /dev/mapper/* ]]; then
    if have_cmd lvs && have_cmd vgs; then
      local VG LV need
      VG="$(lvs --noheadings -o vg_name "$ROOT_SOURCE" 2>/dev/null | awk '{$1=$1};1' || true)"
      LV="$(lvs --noheadings -o lv_name "$ROOT_SOURCE" 2>/dev/null | awk '{$1=$1};1' || true)"
      [[ -n "$VG" && -n "$LV" ]] || fail "LVM root niet gevonden (VG/LV leeg)"
      need="$(bytes_from_size "$LVM_SNAP_SIZE")"
      ensure_vg_free "$VG" "$need"
      log "LVM OK: VG=$VG LV=$LV (genoeg vrije VG-ruimte voor $LVM_SNAP_SIZE)"
    else
      log "Let op: LVM tooling onvolledig; LVM-snapshots niet getest"
    fi
  fi

  log "=== Self-test geslaagd ==="
}
# ==========================

# ========= CLI parsing =========
FORCE_TYPE=""            # S|M|H
DO_CLEANUP_ONLY=false
SNAPSHOT_ONLY=false
SNAPSHOT_AND_DUMP=false
VERIFY_ONLY=false
DO_SELF_TEST=false
SNAPSHOT_DELETE_NAME=""
SNAPSHOT_NAME_OVERRIDE=""

while (("$#")); do
  case "$1" in
    --force)
      shift; [[ $# -gt 0 ]] || fail "--force vereist waarde (S|M|H|weekly|monthly|semiannual)"
      case "$1" in
        S|s|weekly|Weekly|WEEKLY) FORCE_TYPE="S" ;;
        M|m|monthly|Monthly|MONTHLY) FORCE_TYPE="M" ;;
        H|h|halfyear|semiannual|Semiannual|SEMIANNUAL) FORCE_TYPE="H" ;;
        *) fail "Ongeldige --force waarde: $1" ;;
      esac
      ;;
    --cleanup)       DO_CLEANUP_ONLY=true ;;
    --verify)        VERIFY_ONLY=true ;;
    --self-test)     DO_SELF_TEST=true ;;
    --snapshot-only) SNAPSHOT_ONLY=true;  [[ ${2:-} =~ ^- || -z ${2:-} ]] || { SNAPSHOT_NAME_OVERRIDE="$2"; shift; } ;;
    --snapshot)      SNAPSHOT_AND_DUMP=true; [[ ${2:-} =~ ^- || -z ${2:-} ]] || { SNAPSHOT_NAME_OVERRIDE="$2"; shift; } ;;
    --snapshot-delete)
      shift; [[ $# -gt 0 ]] || fail "--snapshot-delete vereist een naam"
      SNAPSHOT_DELETE_NAME="$1"
      ;;
    *) fail "Onbekend argument: $1" ;;
  esac
  shift
done
# ==============================

# ========= Init/run =========
[[ -f "$LOCK_FILE" ]] && fail "Lock bestaat al ($LOCK_FILE). Draait er al een job?"
touch "$LOCK_FILE"

mkdir -p "$W_DIR" "$M_DIR" "$H_DIR" "$MANUAL_DIR"
[[ "$CLEANUP_QUARANTINE_CORRUPT" == "true" ]] && mkdir -p "$QUARANTINE_DIR"
test -w "$BASE_DIR" || fail "BASE_DIR ($BASE_DIR) is niet schrijfbaar"

# Zorg eerst voor tools (auto-install indien mogelijk), daarna init compressor/checksum
ensure_tools
COMP="$(compressor)"
init_checksum

# Modes
if [[ -n "$SNAPSHOT_DELETE_NAME" ]]; then
  log "=== Snapshot-delete gestart $TODAY ==="
  snapshot_delete "$SNAPSHOT_DELETE_NAME"
  log "=== Snapshot-delete klaar ==="
  exit 0
fi

if $DO_SELF_TEST; then
  self_test
  exit 0
fi

if $DO_CLEANUP_ONLY; then
  log "=== Cleanup-only gestart $TODAY ==="; cleanup_all; log "=== Cleanup-only klaar ==="; exit 0
fi

if $VERIFY_ONLY; then
  log "=== Verify gestart $TODAY ==="
  verify_archives && { log "=== Verify OK ==="; exit 0; } || { log "=== Verify: mismatches ==="; exit 1; }
fi

if $SNAPSHOT_ONLY; then
  log "=== Snapshot-only gestart ($TODAY $NOWHM) ==="
  snapshot_only "${SNAPSHOT_NAME_OVERRIDE:-}"
  log "=== Snapshot-only klaar ==="
  exit 0
fi

if $SNAPSHOT_AND_DUMP; then
  log "=== Snapshot + dump gestart ($TODAY $NOWHM) ==="
  snapshot_and_dump "${SNAPSHOT_NAME_OVERRIDE:-}"
  prune_dir "$MANUAL_DIR" "$RETENTION_MANUAL"
  log "=== Snapshot + dump klaar ==="
  exit 0
fi

# Kalender-gestuurd of --force
log "=== Start run $TODAY (week $WEEK, month $YEAR-$MONTH) ==="
if [[ -n "$FORCE_TYPE" ]]; then
  case "$FORCE_TYPE" in
    H) log "FORCE: Halfjaarlijks -> eerst S, dan H"; create_backup S; prune_dir "$W_DIR" "$RETENTION_WEEKLY"; create_backup H; prune_dir "$H_DIR" "$RETENTION_SEMIANNUAL" ;;
    M) log "FORCE: Maandelijks -> eerst S, dan M"; create_backup S; prune_dir "$W_DIR" "$RETENTION_WEEKLY"; create_backup M; prune_dir "$M_DIR" "$RETENTION_MONTHLY" ;;
    S) log "FORCE: Wekelijks (S)"; create_backup S; prune_dir "$W_DIR" "$RETENTION_WEEKLY" ;;
  esac
else
  if [[ "$IS_SEMIANNUAL_MONTH" == "1" ]]; then
    if ! ls "$H_DIR"/*"${YEAR}-${MONTH}"* >/dev/null 2>&1; then
      log "Trigger halfjaarlijks (eerste run $YEAR-$MONTH): S + H"
      create_backup S; prune_dir "$W_DIR" "$RETENTION_WEEKLY"
      create_backup H; prune_dir "$H_DIR" "$RETENTION_SEMIANNUAL"
    else
      log "Halfjaarlijks voor $YEAR-$MONTH bestaat al; overslaan"
    fi
  fi
  if [[ "$IS_LAST_WEEK_OF_MONTH" == "1" ]]; then
    log "Laatste week van de maand -> S + M"
    create_backup S; prune_dir "$W_DIR" "$RETENTION_WEEKLY"
    create_backup M; prune_dir "$M_DIR" "$RETENTION_MONTHLY"
  else
    log "Normale week -> S"
    create_backup S; prune_dir "$W_DIR" "$RETENTION_WEEKLY"
  fi
fi

cleanup_all
prune_dir "$MANUAL_DIR" "$RETENTION_MANUAL"

log "=== Klaar ==="
exit 0
