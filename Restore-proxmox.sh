#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Proxmox Host Restore Wizard
# Herstelt back-ups gemaakt door proxmox-host-rotating-backup.sh
# - ZFS streams (*.zfs.gz)
# - LVM partclone-streams / RAW (*.img.gz)
# - Full-disk RAW (*.img.xz | *.img.gz)
#
# Draai als root.
# =========================================================

# ---------- Config ----------
BASE_DIR="${BASE_DIR:-/mnt/pve/BackupHD/HDproxmox-host}"
LOG_FILE="${LOG_FILE:-/var/log/proxmox-host-restore.log}"
# ----------------------------

# ---------- Utils ----------
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
fail(){ log "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

pause(){ read -r -p "Enter om door te gaan..." _; }

yesno(){
  # yesno "Vraag?" defaultY|defaultN  -> returns 0 voor JA
  local q="$1" def="${2:-defaultY}" ans
  case "$def" in
    defaultY) read -r -p "$q [Y/n] " ans || true; [[ "${ans:-}" =~ ^([Yy]|)$ ]];;
    defaultN) read -r -p "$q [y/N] " ans || true; [[ "${ans:-}" =~ ^([Yy])$ ]];;
    *) read -r -p "$q [y/n] " ans || true; [[ "${ans:-}" =~ ^([Yy])$ ]];;
  esac
}

decompress_cmd(){
  # prints command (array) to stdout for decompression to STDOUT
  local f="$1"
  case "$f" in
    *.zfs.gz|*.img.gz) echo "gzip -dc" ;;
    *.img.xz)          echo "xz -dc --sparse" ;;
    *) fail "Onbekend archieftype: $f" ;;
  esac
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
  # echo een tijd-gesorteerde lijst met paden
  local globs=(
    "$BASE_DIR/weekly/"*.zfs.gz "$BASE_DIR/monthly/"*.zfs.gz "$BASE_DIR/semiannual/"*.zfs.gz "$BASE_DIR/manual/"*.zfs.gz
    "$BASE_DIR/weekly/"*.img.gz "$BASE_DIR/monthly/"*.img.gz "$BASE_DIR/semiannual/"*.img.gz "$BASE_DIR/manual/"*.img.gz
    "$BASE_DIR/weekly/"*.img.xz "$BASE_DIR/monthly/"*.img.xz "$BASE_DIR/semiannual/"*.img.xz "$BASE_DIR/manual/"*.img.xz
  )
  # shellcheck disable=SC2012
  ls -1t "${globs[@]}" 2>/dev/null || true
}

mounted_anywhere(){
  local dev="$1"
  if have lsblk; then
    # voor disks: check ook partities
    lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null | grep -qE '\S' && return 0
    # Check subdevices (partities/LVs)
    lsblk -nr -o PATH,MOUNTPOINT "$dev" 2>/dev/null | awk 'NF==2 && $2 != ""' | grep -q . && return 0
  fi
  # fallback: try findmnt
  findmnt -n "$dev" >/dev/null 2>&1 && return 0 || return 1
}

ensure_unmounted(){
  local dev="$1"
  if mounted_anywhere "$dev"; then
    log "Doel $dev of een child is aangekoppeld."
    if yesno "Probeer automatisch te ontkoppelen?" defaultY; then
      # Unmount alle submounts eerst
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
  # Retourneer 0 als header op partclone lijkt (extfs/xfs), anders 1
  local f="$1"
  local tmp hcmd
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  hcmd="$(decompress_cmd "$f")"
  # lees de eerste 64 KiB van de gedecomprimeerde stream
  bash -c "$hcmd \"$f\" | head -c 65536 > \"$tmp\"" || return 1
  # partclone header bevat vaak 'partclone'
  if strings "$tmp" | grep -qi 'partclone'; then
    return 0
  else
    return 1
  fi
}

pick_file(){
  log "Zoek back-ups in: $BASE_DIR"
  local files
  mapfile -t files < <(list_backups)
  (( ${#files[@]} )) || fail "Geen back-ups gevonden onder $BASE_DIR"
  echo
  echo "Kies een back-up:"
  local i=1
  for f in "${files[@]}"; do
    printf "  [%2d] %s\n" "$i" "$f"
    ((i++))
  done
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
  have zfs || fail "zfs niet gevonden"
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
  echo "WAARSCHUWING: zfs receive -F overschrijft nieuwere snapshots/changes onder $target."
  yesno "Doorgaan met restore naar '$target'?" defaultN || fail "Afgebroken."

  local dc; dc="$(decompress_cmd "$file")"
  log "Start: $file -> zfs receive -F $target"
  # shellcheck disable=SC2086
  bash -c "$dc \"$file\" | zfs receive -F \"$target\"" || fail "zfs receive faalde"
  log "ZFS restore voltooid."
}

restore_lvm_or_raw_img_gz(){
  local file="$1"
  # Doel = block device (LV of partitie)
  echo "Beschikbare LVs:"
  if have lvs; then
    lvs -o vg_name,lv_name,lv_size,lv_attr --noheadings | awk '{$1=$1};1' || true
  else
    echo "(lvs niet beschikbaar)"
  fi
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

  # Probeer partclone-stream te detecteren
  local use_partclone=false
  if detect_partclone_stream "$file"; then
    use_partclone=true
  fi

  # Als partclone: kies type (ext4/xfs). Probeer target FS te raden.
  if $use_partclone; then
    local fstype=""
    if have blkid; then
      fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
    fi
    if [[ -z "$fstype" ]]; then
      echo "Kon filesystem op $dev niet bepalen. Kies:"
      select fstype in ext4 xfs; do [[ -n "$fstype" ]] && break; done
    fi
    case "$fstype" in
      ext4)
        have partclone.extfs || fail "partclone.extfs ontbreekt"
        echo
        echo "WAARSCHUWING: Restore overschrijft data op $dev"
        yesno "Bevestig restore van PARTCLONE stream naar $dev?" defaultN || fail "Afgebroken."
        log "Restore (partclone.extfs): $file -> $dev"
        gzip -dc "$file" | partclone.extfs -r -s - -o "$dev" || fail "partclone restore faalde"
        ;;
      xfs)
        have partclone.xfs  || fail "partclone.xfs ontbreekt"
        echo
        echo "WAARSCHUWING: Restore overschrijft data op $dev"
        yesno "Bevestig restore van PARTCLONE stream naar $dev?" defaultN || fail "Afgebroken."
        log "Restore (partclone.xfs): $file -> $dev"
        gzip -dc "$file" | partclone.xfs -r -s - -o "$dev"  || fail "partclone restore faalde"
        ;;
      *)
        echo "Onbekend/unsupported FS '$fstype' voor partclone; val terug op dd."
        use_partclone=false
        ;;
    esac
  fi

  if ! $use_partclone; then
    echo
    echo "WAARSCHUWING: RAW dd-restore overschrijft $dev volledig."
    yesno "Zeker weten dat je RAW (dd) wilt schrijven naar $dev?" defaultN || fail "Afgebroken."
    log "Restore (dd): $file -> $dev"
    gzip -dc "$file" | dd of="$dev" bs=64M status=progress conv=fsync || fail "dd restore faalde"
  fi

  log "Restore voltooid."
}

restore_full_disk_img(){
  local file="$1"
  # target = hele schijf, bv /dev/sdX
  echo "Disks:"
  if have lsblk; then
    lsblk -d -o NAME,SIZE,MODEL,TYPE | awk 'NR==1 || $4=="disk"'
  fi
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

  echo
  echo "MEGA-WAARSCHUWING: Je gaat de HELE schijf overschrijven: $disk"
  yesno "Bevestig volledig terugschrijven naar $disk" defaultN || fail "Afgebroken."
  read -r -p "Typ exact de device-naam om te bevestigen ($disk): " confirm
  [[ "$confirm" == "$disk" ]] || fail "Bevestiging mismatch."

  local dc; dc="$(decompress_cmd "$file")"
  log "Restore (RAW disk via dd): $file -> $disk"
  # shellcheck disable=SC2086
  bash -c "$dc \"$file\" | dd of=\"$disk\" bs=64M status=progress conv=fsync" || fail "dd restore faalde"

  sync
  log "Full-disk restore voltooid."
}

# ---------- Wizard ----------
print_help(){
  cat <<EOF
Proxmox Host Restore Wizard

Gebruik:
  $0                # interactieve wizard
  $0 -h|--help      # deze hulp

Standaard zoekt het script naar back-ups in:
  $BASE_DIR/{weekly,monthly,semiannual,manual}/*.{zfs.gz,img.gz,img.xz}

Types:
  *.zfs.gz   -> ZFS 'zfs receive'
  *.img.gz   -> LVM partclone-stream (ext4/xfs) of RAW dd (fallback)
  *.img.xz   -> RAW hele schijf via dd

Let op:
  - Doelen mogen NIET aangekoppeld zijn.
  - Voor full-disk restore wordt de HELE schijf overschreven.
  - Checksums (.b3/.sha256) worden gecontroleerd als ze aanwezig zijn.
EOF
}

main(){
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_help; exit 0
  fi

  [[ $EUID -eq 0 ]] || fail "Draai als root."
  [[ -d "$BASE_DIR" ]] || fail "BASE_DIR bestaat niet: $BASE_DIR"

  log "=== Proxmox Host Restore Wizard ==="
  local file
  file="$(pick_file)"
  log "Gekozen: $file"

  case "$file" in
    *.zfs.gz)
      restore_zfs "$file"
      ;;
    *.img.gz)
      restore_lvm_or_raw_img_gz "$file"
      ;;
    *.img.xz)
      restore_full_disk_img "$file"
      ;;
    *)
      fail "Onbekend bestandsformaat: $file"
      ;;
  esac

  log "=== Klaar ==="
}

main "$@"
