#!/usr/bin/env bash
# Return Proxmox host to "stock" GPU state (AMD) by undoing passthrough
# Dry-run by default; --apply to make changes (with backups)
set -euo pipefail
shopt -s nullglob

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1
changed=0

say(){ printf "%b\n" "$*"; }
step(){ say "\n==> $*"; }
backup(){ [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)"; }

step "Detecteer AMD GPU (VGA/3D/Display, vendor 1002)"
# Toon eerst alle display devices voor transparantie
ALL_DISP="$(lspci -Dnns | grep -Ei 'VGA|3D|Display' || true)"
if [[ -n "$ALL_DISP" ]]; then
  printf "%s\n" "$ALL_DISP" | sed 's/^/  /'
else
  say "  [!] Geen display devices gevonden via lspci."
fi

# Kies AMD (vendor-id 1002) onder VGA/3D/Display
GPU_LINE="$(lspci -Dnns | grep -Ei 'VGA|3D|Display' | grep -Ei '\[1002:' | head -n1 || true)"
if [[ -z "${GPU_LINE:-}" ]]; then
  say "  [!] Geen AMD (vendor 1002) VGA/3D/Display device gevonden. Stop (dry-run)."
  exit 0
fi

GPU_BDF="$(awk '{print $1}' <<<"$GPU_LINE")"                  # 0000:c5:00.0
GPU_ID="$(sed -n 's/.*\[\([0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\}\)\].*/\1/p' <<<"$GPU_LINE")"
GPU_BDF_SHORT="${GPU_BDF#0000:}"
GPU_NAME="$(lspci -nn | awk -v a="$GPU_BDF_SHORT" '$0 ~ a {sub(/^[^ ]+ /,""); print}')"

say "  BDF : $GPU_BDF"
say "  PCI : $GPU_ID"
say "  Naam: $GPU_NAME"

step "Huidige driver-binding"
DRV_PATH="/sys/bus/pci/devices/$GPU_BDF/driver"
if [[ -e "$DRV_PATH" ]]; then
  CUR_DRV="$(readlink -f "$DRV_PATH")"; CUR_DRV="${CUR_DRV##*/}"
else
  CUR_DRV="none"
fi
say "  Kernel driver in use: $CUR_DRV"

step "Zoek VM-configs die $GPU_BDF_SHORT via hostpci claimen"
VM_HITS="$(grep -H "hostpci.*$GPU_BDF_SHORT" /etc/pve/qemu-server/*.conf 2>/dev/null || true)"
if [[ -n "$VM_HITS" ]]; then
  printf "%s\n" "$VM_HITS" | sed 's/^/  /'
  if (( APPLY )); then
    while IFS= read -r line; do
      f="${line%%:*}"
      backup "$f"
      sed -i "/hostpci/ s/^\(.*$GPU_BDF_SHORT.*\)$/# removed by cleanup-gpu.sh: \1/" "$f"
      changed=1
    done <<<"$VM_HITS"
    say "  [OK] hostpci-regels met $GPU_BDF_SHORT gecommentarieerd."
  else
    say "  [DRY] Zou bovenstaande hostpci-regels uitschakelen."
  fi
else
  say "  Geen hostpci-regels gevonden."
fi

step "Zoek vfio/amdgpu instellingen (modprobe.d, modules-load.d, grub)"
files=()
while IFS= read -r f; do files+=("$f"); done < <(grep -El '\b(vfio|vfio-pci)\b' /etc/modprobe.d/* /etc/modules-load.d/* 2>/dev/null || true)
[[ -f /etc/default/grub ]] && files+=("/etc/default/grub")
for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  matches="$(grep -En 'vfio|vfio-pci|blacklist.*amdgpu|options[[:space:]]+vfio-pci|ids=' "$f" || true)"
  [[ -z "$matches" ]] && continue
  say "  -> $f"; printf "%s\n" "$matches" | sed 's/^/     /'
  if (( APPLY )); then
    backup "$f"
    sed -i -E \
      -e 's/^\s*(options\s+vfio-pci\b.*)$/# removed by cleanup-gpu.sh: \1/' \
      -e 's/^\s*(blacklist\s+amdgpu\b.*)$/# removed by cleanup-gpu.sh: \1/' \
      "$f"
    if [[ "$f" == "/etc/default/grub" ]]; then
      sed -i -E 's/\s*vfio-pci\.ids=[^" ]+//g' "$f"
    fi
    changed=1
  else
    say "  [DRY] Zou bovenstaande regels neutraliseren."
  fi
done

step "Zorg dat amdgpu bij boot geladen wordt"
if (( APPLY )); then
  echo amdgpu > /etc/modules-load.d/amdgpu.conf
  changed=1
  say "  [OK] /etc/modules-load.d/amdgpu.conf = amdgpu"
else
  say "  [DRY] Zou /etc/modules-load.d/amdgpu.conf = amdgpu schrijven."
fi

if (( APPLY && changed )); then
  step "Update GRUB en initramfs"
  command -v update-grub >/dev/null 2>&1 && update-grub || true
  update-initramfs -u
  say "  [OK] GRUB/initramfs bijgewerkt."
else
  step "Geen systeemupdates nodig of DRY-run."
fi

step "Eindstatus hint (volledige zekerheid na reboot)"
if [[ -n "${GPU_BDF_SHORT:-}" ]]; then
  lspci -nnk -s "$GPU_BDF_SHORT" || true
fi
say "\nKlaar."
if (( APPLY )); then
  say "⚠️  Advies: reboot de host zodat 'amdgpu' de GPU weer claimt:  reboot"
else
  say "Dry-run uitgevoerd. Run met '--apply' om wijzigingen door te voeren."
fi
