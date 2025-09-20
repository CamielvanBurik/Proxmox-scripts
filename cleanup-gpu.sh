#!/usr/bin/env bash
# Cleanup GPU passthrough to return Proxmox host to "stock"
# - Detect AMD GPU (VGA/Display/3D), find its BDF & PCI ID
# - Report and optionally remove: VM hostpci lines, vfio-pci ids, amdgpu blacklists
# - Restores amdgpu as default and updates grub/initramfs
# Usage:  ./cleanup-gpu.sh          # dry-run (report only)
#         ./cleanup-gpu.sh --apply  # apply changes

set -euo pipefail
shopt -s nullglob

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

log(){ printf "%b\n" "$*"; }
step(){ log "\n==> $*"; }
changed=0

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "${f}.bak.${ts}"
}

# --- Detect AMD GPU (VGA/Display/3D) ---
step "Detecteer AMD GPU"
mapfile -t GPU_LINES < <(lspci -Dnns | awk '/VGA|3D|Display/ && /AMD|ATI/')
if (( ${#GPU_LINES[@]} == 0 )); then
  log "  [!] Geen AMD VGA/3D/Display device gevonden. Stop."
  exit 0
fi

GPU_BDF="$(awk '{print $1}' <<<"${GPU_LINES[0]}")"               # e.g. 0000:c5:00.0
GPU_ID="$(sed -n 's/.*\[\([0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\}\)\].*/\1/p' <<<"${GPU_LINES[0]}")"  # e.g. 1002:150e
GPU_NAME="$(lspci -nn | awk -v a="${GPU_BDF#0000:}" '$0 ~ a {sub(/^[^ ]+ /,""); print}')"

log "  BDF : ${GPU_BDF}"
log "  PCI : ${GPU_ID}"
log "  Naam: ${GPU_NAME}"

# --- Driver status ---
step "Huidige kernel driver binding"
DRIVER_PATH="/sys/bus/pci/devices/${GPU_BDF}/driver"
if [[ -e "$DRIVER_PATH" ]]; then
  CUR_DRV="$(readlink -f "$DRIVER_PATH")"; CUR_DRV="${CUR_DRV##*/}"
else
  CUR_DRV="none"
fi
log "  Kernel driver in use: ${CUR_DRV}"

# --- 1) VM hostpci verwijzingen verwijderen ---
step "Zoek VM-configs met hostpci voor ${GPU_BDF#0000:}"
mapfile -t VM_HOSTPCI < <(grep -H "hostpci.*${GPU_BDF#0000:}" /etc/pve/qemu-server/*.conf 2>/dev/null || true)
if ((${#VM_HOSTPCI[@]})); then
  printf "  Gevonden:\n"; printf "    %s\n" "${VM_HOSTPCI[@]}"
  if (( APPLY )); then
    for line in "${VM_HOSTPCI[@]}"; do
      f="${line%%:*}"
      backup_file "$f"
      # comment alleen de regels met specifiek BDF
      sed -i '/hostpci/ s/^\(.*'"${GPU_BDF#0000:}"'.*\)$/# removed by cleanup-gpu.sh: \1/' "$f"
      changed=1
    done
    log "  [OK] hostpci-regels voor ${GPU_BDF#0000:} gecommentarieerd."
  else
    log "  [DRY] Zou hostpci-regels voor ${GPU_BDF#0000:} uit VM-configs verwijderen."
  fi
else
  log "  Geen VM hostpci-regels gevonden."
fi

# --- 2) vfio-pci force bindings & amdgpu blacklist opruimen ---
step "Zoek vfio/amdgpu instellingen in modprobe.d, modules-load.d, grub"
mapfile -t VFIO_FILES < <(grep -El '\b(vfio|vfio-pci)\b' /etc/modprobe.d/* /etc/modules-load.d/* 2>/dev/null || true)
[[ -f /etc/default/grub ]] && VFIO_FILES+=(/etc/default/grub)

# scan en wijzig
for f in "${VFIO_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  # preview
  MATCHES="$(grep -En 'vfio|vfio-pci|blacklist.*amdgpu|options[[:space:]]+vfio-pci|ids=' "$f" || true)"
  [[ -n "$MATCHES" ]] || continue
  log "  -> $f"; printf "%s\n" "$MATCHES" | sed 's/^/     /'
  if (( APPLY )); then
    backup_file "$f"
    # comment problematische regels
    sed -i -E \
      -e 's/^\s*(options\s+vfio-pci\b.*)$/# removed by cleanup-gpu.sh: \1/' \
      -e 's/^\s*(blacklist\s+amdgpu\b.*)$/# removed by cleanup-gpu.sh: \1/' \
      "$f"
    # GRUB: verwijder vfio-pci.ids=… uit CMDLINE
    if [[ "$f" == "/etc/default/grub" ]]; then
      sed -i -E 's/\s*vfio-pci\.ids=[^" ]+//g' "$f"
    fi
    changed=1
  else
    log "  [DRY] Zou vfio/amdgpu regels uit $f neutraliseren."
  fi
done

# --- 3) amdgpu als modules-load waarborgen ---
step "amdgpu module laden bij boot waarborgen"
if (( APPLY )); then
  echo "amdgpu" > /etc/modules-load.d/amdgpu.conf
  changed=1
  log "  [OK] /etc/modules-load.d/amdgpu.conf gezet."
else
  log "  [DRY] Zou /etc/modules-load.d/amdgpu.conf = amdgpu schrijven."
fi

# --- 4) update-grub & initramfs indien wijzigingen ---
if (( APPLY && changed )); then
  step "Update GRUB en initramfs"
  if command -v update-grub >/dev/null 2>&1; then
    update-grub || true
  fi
  update-initramfs -u
  log "  [OK] GRUB/initramfs bijgewerkt."
else
  step "Geen systeemupdates nodig of DRY-run."
fi

# --- 5) Live unbind/bind (optioneel best effort); reboot blijft aan te raden ---
step "Live unbind/bind (best effort; reboot aangeraden)"
if (( APPLY )); then
  # probeer vfio los te koppelen en amdgpu te claimen
  if [[ "$CUR_DRV" == "vfio-pci" && -e "$DRIVER_PATH/unbind" ]]; then
    echo "${GPU_BDF}" > "$DRIVER_PATH/unbind" || true
    sleep 1
  fi
  modprobe amdgpu || true
  # trigger rescan
  echo 1 > /sys/bus/pci/rescan || true
  sleep 1
fi

# --- 6) Eindstatus ---
step "Eindstatus (na cleanup; herstart mogelijk nodig)"
lspci -nnk -s "${GPU_BDF#0000:}" || true
echo
log "Klaar."
if (( APPLY )); then
  log "⚠️  Advies: herstart de host om zeker te zijn dat 'amdgpu' de GPU claimt:"
  log "    reboot"
else
  log "Dry-run uitgevoerd. Run met '--apply' om wijzigingen door te voeren."
fi
