#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Proxmox Host Restore Wizard (+ dry-run)
# Herstelt back-ups gemaakt door proxmox-host-rotating-backup.sh
# - ZFS streams (*.zfs.gz)
# - LVM partclone/RAW (*.img.gz)
# - Full-disk RAW (*.img.xz | *.img.gz)
#
# Draai als root voor echte restore. Dry-run (-n/--dry-run) doet niets destructiefs.
# =========================================================

# ---------- Config ----------
BASE_DIR="${BASE_DIR:-/mnt/pve/BackupHD/HDproxmox-host}"
LOG_FILE="${LOG_FILE:-/var/log/proxmox-host-restore.log}"
# ----------------------------

# ---------- Globals ----------
DRY_RUN=false
# ----------------------------

# ---------- Utils ----------
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
fail(){ log "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

yesno(){
  local q="$1" def="${2:-defaultY}" ans
  case "$def" in
    defaultY) read -r -p "$q [Y/n] " ans || true; [[ "${ans:-}" =~ ^([Yy]|)$ ]];;
    defaultN) read -r -p "$q [y/N] " ans || true; [[ "${ans:-}" =~ ^([Yy])$ ]];;
    *)        read -r -p "$q [y/n] "   ans || true; [[ "${ans:-}" =~ ^([Yy])$ ]];;
  esac
}

decompress_cmd(){
  local f="$1"
  case "$f" in
    *.zfs.gz|*.img.gz) echo "gzip -dc" ;;
    *.img.xz)          echo "xz -dc --sparse" ;;
    *) fail "Onbekend archieftype: $f" ;;
  esac
}

# "Benodigde tool" die in dry-run niet hard faalt
require_tool(){
  local t="$1"
  if ! have "$t"; then
    if $DRY_RUN; then
      log "DRY-RUN: tool '$t' ontbreekt (zou nodig zijn bij echte restore)"
      return 0
    else
      fail "Tool ontbreekt: $t"
    fi
  fi
}

# Voer een shell pipeline uit, of toon hem alleen in dry-run
run_or_echo(){
  local cmd="$1"
  if $DRY_RUN; then
    log "DRY-RUN: zou uitvoeren:"
    echo "  $cmd"
    return 0
  else
    # shellcheck disable=SC2086
    bash -c "$cmd"
  fi
}

checksum_verify(){
  local f="$1" ok=2
  if [[ -f "${f}.b3" ]] && have b3sum; then
    ( cd "$(dirname -- "$f")" && b3sum -c "$(basename -- "$f").b3" ) && ok=0 || ok=1
  elif [[ -f "${f}.sha256" ]] && have sha256sum; then
    ( cd "$(dirname -- "$f")" && sha256sum -c "$(basename -- "$f").sha256" ) && ok=0 || ok=1
  else
    ok=2
  fi
  return $ok  # 0=match, 1=bad, 2=missing
}

list_backups(){
  local globs=(
    "$BASE_DIR/weekly/"*.zfs.gz "$BASE_DIR/monthly/"*.zfs.gz "$BASE_DIR/semiannual/"*.zfs.gz "$BASE_DIR/manual/"*.zfs.gz
    "$BASE_DIR/weekly/"*.img.gz "$BASE_DIR/monthly/"*.img.gz "$BASE_DIR/semiannual/"*.img.gz "$BASE_DIR/manual/"*.img.gz
    "$BASE_DIR/weekly/"*.img.xz "$BASE_DIR/monthly/"*.img.xz "$BASE_DIR/semiannual/"*.img.xz "$BASE_DIR/manual/"*.img.xz
  )
  ls -1t "${globs[@]}" 2>/dev/null || true
}

mounted_anywhere(){
  local dev="$1"
  if have lsblk; then
    lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null | grep -qE '\S' && return 0
    lsblk -nr -o PATH,MOUNTPOINT "$dev" 2>/dev/null | awk 'NF==2 && $2 != ""' | grep -q . && return 0
  fi
  findmnt -n "$dev" >/dev/null 2>&1 && return 0 || return 1
}

ensure_unmounted(){
  local dev="$1"
  if mounted_anywhere "$dev"; then
    log "Doel $dev of een child is aangekoppeld."
    if $DRY_RUN; then
      log "DRY-RUN: zou alle mountpoints van $dev ontkoppelen."
      return 0
    fi
    if yesno "Probeer automatisch te ontkoppelen?" defaultY; then
      if have lsblk; then
        while read -r path mp; do
          [[ -n "$mp" ]] && { log "umount $mp"; umount "$mp" || fail "Kon $mp niet ontkoppelen"; }
        done < <(lsblk -nr -o PATH,MOUNTPOINT "$dev" | awk 'NF==2 && $2 != ""' | sort -rk2)
      fi
      if findmnt -n "$dev" >/dev/null 2>&1; then
        mp="$(findmnt -no TARGET "$dev")"
        log "umount $mp"
        umount "$mp" || fail "Kon $mp niet ontkoppelen"
      fi
      mounted_anywhere "$dev" && fail "Nog steeds aangekoppeld; stop." || true
    else
      fail "Afgebroken: doel is aangekoppeld."
    fi
  fi
}

detect_partclone_stream(){
  local f="$1" tmp hcmd
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  hcmd="$(decompress_cmd "$f")"
  bash -c "$hcmd \"$f\" | head -c 65536 > \"$tmp\"" || return 1
  if strings "$tmp" | grep -qi 'partclone'; then return 0; else return 1; fi
}

pick_file(){
  log "Zoek back-ups in: $BASE_DIR"
  local files
  mapfile -t files < <(list_backups)
  (( ${#files[@]} )) || fail "Geen back-ups gevonden onder $BASE_DIR"
  echo; echo "Kies een back-up:"
  local i=1; for f in "${files[@]}"; do printf "  [%2d] %s\n" "$i" "$f"; ((i++)); done
  echo
  local sel
  while true; do
    read -r -p "Nummer (1-${#files[@]}): " sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#files[@]} )) && break
    echo "Ongeldige keuze."
  done
  echo "${files[sel-1]}"
}

# ---------- Restore handelingen ----------
restore_zfs(){
  local file="$1"
  require_tool gzip
  require_tool zfs

  read -r -p "ZFS target dataset (bijv. pool/ROOT/pve-1): " target
  [[ -n "$target" ]] || fail "Geen target opgegeven"

  log "Checksum controleren (indien aanwezig)…"
  if checksum_verify "$file"; then
    log "Checksum OK"
  else
    case $? in
      1) fail "Checksum MISMATCH voor $file";;
      2) log "Geen checksum-bestand; ga verder."; ;;
    esac
  fi

  echo
  echo "WAARSCHUWING: zfs receive -F overschrijft snapshots/changes onder $target."
  $DRY_RUN || yesno "Doorgaan met restore naar '$target'?" defaultN || fail "Afgebroken."

  local dc; dc="$(decompress_cmd "$file")"
  local cmd="$dc \"$file\" | zfs receive -F \"$target\""
  run_or_echo "$cmd" || fail "zfs receive faalde"
  $DRY_RUN && log "DRY-RUN: geen wijzigingen doorgevoerd."
}

restore_lvm_or_raw_img_gz(){
  local file="$1"
  require_tool gzip

  echo "Beschikbare LVs:"
  if have lvs; then lvs -o vg_name,lv_name,lv_size,lv_attr --noheadings | awk '{$1=$1};1' || true
  else echo "(lvs niet beschikbaar)"; fi

  read -r -p "Doel block device (bv. /dev/VG/LV of /dev/sdXN): " dev
  [[ -b "$dev" ]] || fail "Geen block device: $dev"

  ensure_unmounted "$dev"

  log "Checksum controleren (indien aanwezig)…"
  if checksum_verify "$file"; then
    log "Checksum OK"
  else
    case $? in
      1) fail "Checksum MISMATCH voor $file";;
      2) log "Geen checksum-bestand; ga verder."; ;;
    esac
  fi

  local use_partclone=false
  if detect_partclone_stream "$file"; then use_partclone=true; fi

  if $use_partclone; then
    local fstype=""
    if have blkid; then fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"; fi
    if [[ -z "$fstype" ]]; then
      echo "Kon filesystem op $dev niet bepalen. Kies:"
      select fstype in ext4 xfs; do [[ -n "$fstype" ]] && break; done
    fi

    case "$fstype" in
      ext4)
        require_tool partclone.extfs
        echo; echo "WAARSCHUWING: Restore overschrijft data op $dev"
        $DRY_RUN || yesno "Bevestig restore van PARTCLONE (ext4) naar $dev?" defaultN || fail "Afgebroken."
        run_or_echo "gzip -dc \"$file\" | partclone.extfs -r -s - -o \"$dev\"" || fail "partclone restore faalde"
        ;;
      xfs)
        require_tool partclone.xfs
        echo; echo "WAARSCHUWING: Restore overschrijft data op $dev"
        $DRY_RUN || yesno "Bevestig restore van PARTCLONE (xfs) naar $dev?" defaultN || fail "Afgebroken."
        run_or_echo "gzip -dc \"$file\" | partclone.xfs  -r -s - -o \"$dev\"" || fail "partclone restore faalde"
        ;;
      *)
        log "Onbekend/unsupported FS '$fstype' voor partclone; val terug op dd."
        use_partclone=false
        ;;
    esac
  fi

  if ! $use_partclone; then
    echo; echo "WAARSCHUWING: RAW dd-restore overschrijft $dev volledig."
    $DRY_RUN || yesno "Zeker weten dat je RAW (dd) wilt schrijven naar $dev?" defaultN || fail "Afgebroken."
    run_or_echo "gzip -dc \"$file\" | dd of=\"$dev\" bs=64M status=progress conv=fsync" || fail "dd restore faalde"
  fi

  $DRY_RUN && log "DRY-RUN: geen wijzigingen doorgevoerd."
}

restore_full_disk_img(){
  local file="$1"
  case "$file" in
    *.img.xz) require_tool xz ;;
    *.img.gz) require_tool gzip ;;
  esac

  echo "Disks:"
  if have lsblk; then lsblk -d -o NAME,SIZE,MODEL,TYPE | awk 'NR==1 || $4=="disk"'; fi
  read -r -p "Doel schijf (bv. /dev/sdX): " disk
  [[ -b "$disk" ]] || fail "Geen block device: $disk"

  ensure_unmounted "$disk"

  log "Checksum controleren (indien aanwezig)…"
  if checksum_verify "$file"; then
    log "Checksum OK"
  else
    case $? in
      1) fail "Checksum MISMATCH voor $file";;
      2) log "Geen checksum-bestand; ga verder."; ;;
    esac
  fi

  echo; echo "MEGA-WAARSCHUWING: Je gaat de HELE schijf overschrijven: $disk"
  if $DRY_RUN; then
    log "DRY-RUN: zou dubbele bevestiging vragen en vervolgens dd uitvoeren."
  else
    yesno "Bevestig volledig terugschrijven naar $disk" defaultN || fail "Afgebroken."
    read -r -p "Typ exact de device-naam om te bevestigen ($disk): " confirm
    [[ "$confirm" == "$disk" ]] || fail "Bevestiging mismatch."
  fi

  local dc; dc="$(decompress_cmd "$file")"
  run_or_echo "$dc \"$file\" | dd of=\"$disk\" bs=64M status=progress conv=fsync" || fail "dd restore faalde"
  $DRY_RUN && log "DRY-RUN: geen wijzigingen doorgevoerd." || sync
}

# ---------- Wizard ----------
print_help(){
  cat <<EOF
Proxmox Host Restore Wizard

Gebruik:
  $0                # interactieve wizard
  $0 -h|--help      # deze hulp
  $0 -n|--dry-run   # toon wat er zou gebeuren, voer niets uit

Zoekpad:
  $BASE_DIR/{weekly,monthly,semiannual,manual}/*.{zfs.gz,img.gz,img.xz}

Types:
  *.zfs.gz   -> ZFS 'zfs receive'
  *.img.gz   -> LVM partclone-stream (ext4/xfs) of RAW dd (fallback)
  *.img.xz   -> RAW hele schijf via dd

Dry-run:
  - Geen umounts, geen schrijven. Alle geplande commando's worden gelogd.
EOF
}

main(){
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_help; exit 0
  fi
  if [[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true; shift || true
  fi

  if ! $DRY_RUN; then
    [[ $EUID -eq 0 ]] || fail "Draai als root voor echte restore. Gebruik --dry-run voor simulatie."
  fi
  [[ -d "$BASE_DIR" ]] || fail "BASE_DIR bestaat niet: $BASE_DIR"

  log "=== Proxmox Host Restore Wizard (dry-run=$DRY_RUN) ==="
  local file
  file="$(pick_file)"
  log "Gekozen: $file"

  case "$file" in
    *.zfs.gz) restore_zfs "$file" ;;
    *.img.gz) restore_lvm_or_raw_img_gz "$file" ;;
    *.img.xz) restore_full_disk_img "$file" ;;
    *) fail "Onbekend bestandsformaat: $file" ;;
  esac

  log "=== Klaar ==="
}

main "$@"
