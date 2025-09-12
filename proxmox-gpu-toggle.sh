#!/usr/bin/env bash
# Toggle AMD iGPU tussen host (amdgpu) en passthrough (vfio-pci)
# - Zonder parameters start een interactieve wizard
# - Subcommands: host|passthrough|status|wizard
# - Opties: --slot <BDF> --audio-slot <BDF>  (bijv. 0000:c5:00.0)
set -euo pipefail

# --- debug & banner ---
DEBUG="${DEBUG:-0}"
if [[ "$DEBUG" == "1" ]]; then
  PS4='+ ${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]:-main}()  '
  set -x
fi
trap 'st=$?; echo "? Exit $st at ${BASH_SOURCE}:${LINENO} (cmd: $BASH_COMMAND)" >&2' ERR
echo "[gpu-toggle] start $(date '+%F %T')"

VFIO_CONF="/etc/modprobe.d/vfio.conf"
AMDGPU_ML="/etc/modules-load.d/amdgpu.conf"

# Optioneel: auto-install van minimale deps (alleen pciutils voor lspci)
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-true}"

# -------------------- helpers --------------------
err(){ echo "ERROR: $*" >&2; exit 1; }
msg(){ echo "[*] $*"; }
note(){ echo "[-] $*"; }
ok(){ echo "[OK] $*"; }

usage(){
  cat <<EOF
Usage: $0 [host|passthrough|status|wizard]
       [--slot BDF] [--audio-slot BDF]

Voorbeelden:
  $0 status
  $0 --slot 0000:c5:00.0 --audio-slot 0000:c5:00.1 passthrough
  GPU_SLOT=0000:c5:00.0 AUDIO_SLOT=0000:c5:00.1 $0 host
EOF
}

need_root(){ [[ $(id -u) -eq 0 ]] || err "Run as root"; }
have(){ command -v "$1" >/dev/null 2>&1; }

apt_install_min(){
  $AUTO_INSTALL_DEPS || return 0
  have apt-get || return 0
  DEBIAN_FRONTEND=noninteractive apt-get update -y || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" || true
}

preflight(){
  need_root
  # TTY check (wizard heeft input nodig)
  if [[ ! -t 0 ]]; then
    note "Geen interactieve TTY gedetecteerd. Start in een terminal voor de wizard."
  fi
  # lspci (pciutils) nodig
  if ! have lspci; then
    note "pciutils ontbreekt; installeren..."
    apt_install_min pciutils
    have lspci || err "pciutils (lspci) ontbreekt nog steeds."
  fi
}

# veilige read die niet exit door set -e
read_safe(){
  # usage: read_safe VAR "Prompt" "default"
  local __var="$1"; shift
  local __prompt="${1:-}"; shift || true
  local __def="${1:-}"; shift || true
  local __tmp=""
  read -r -p "$__prompt" __tmp || true
  if [[ -z "${__tmp}" && -n "${__def}" ]]; then __tmp="$__def"; fi
  printf -v "$__var" "%s" "$__tmp"
}

yn(){
  # yn "Vraag?" Y|N
  local q="$1" dflt="${2:-Y}" a=""
  read_safe a "$q [$dflt] " "$dflt"
  [[ "$a" =~ ^[Yy]$ ]]
}

# ---------- hardened helpers (nounset-safe) ----------
pci_path(){
  local slot="${1:-}"
  [[ -n "$slot" ]] || { echo "/sys/bus/pci/devices/"; return 0; }
  echo "/sys/bus/pci/devices/${slot#0000:}"
}

driver_of(){
  local slot="${1:-}"
  [[ -n "$slot" ]] || { echo "none"; return 0; }
  local p="$(pci_path "$slot")/driver"
  [[ -L "$p" ]] && basename "$(readlink -f "$p")" || echo "none"
}

bind_to(){
  local drv="${1:-}" slot="${2:-}"
  [[ -n "$drv" && -n "$slot" ]] || { note "bind_to: ontbrekende args (drv='$drv', slot='$slot')"; return 0; }
  local drvdir="/sys/bus/pci/drivers/${drv}"
  [[ -d "$drvdir" ]] || modprobe "$drv" >/dev/null 2>&1 || true
  echo "${slot#0000:}" > "${drvdir}/bind" 2>/dev/null || true
}

unbind_from(){
  local drv="${1:-}" slot="${2:-}"
  [[ -n "$drv" && -n "$slot" ]] || { note "unbind_from: ontbrekende args (drv='$drv', slot='$slot')"; return 0; }
  local drvdir="/sys/bus/pci/drivers/${drv}"
  [[ -d "$drvdir" ]] && echo "${slot#0000:}" > "${drvdir}/unbind" 2>/dev/null || true
}

# ---------------- detect GPU/audio ----------------
GPU_SLOT="${GPU_SLOT:-}"; GPU_ID=""
AUDIO_SLOT="${AUDIO_SLOT:-}"; AUDIO_ID=""

detect_devices(){
  have lspci || err "lspci not found (install: apt install pciutils)"

  # Haal PCI-lijst op; laat het script niet falen als lspci non-zero geeft
  local all line
  all="$(lspci -Dnn 2>/dev/null || true)"
  [[ -n "$all" ]] || err "lspci gaf geen output; draai op de host (niet in LXC) en check pciutils."

  # Als gebruiker een GPU_SLOT doorgaf, pak die regel; anders zoeken.
  if [[ -n "${GPU_SLOT:-}" ]]; then
    line="$(grep -E "^${GPU_SLOT}[[:space:]]|^${GPU_SLOT#0000:}[[:space:]]" <<<"$all" || true)"
  fi

  # Match AMD + (VGA/Display), in welke volgorde dan ook
  if [[ -z "${line:-}" ]]; then
    line="$(awk '
      /(VGA compatible controller|Display controller).*\[1002:[0-9a-fA-F]{4}\]/ {print; exit}
      /\[1002:[0-9a-fA-F]{4}\].*(VGA compatible controller|Display controller)/ {print; exit}
    ' <<<"$all")"
  fi

  # Fallback: puur op vendor 1002 en device heeft een DRM-koppeling
  if [[ -z "$line" ]]; then
    while read -r l; do
      local s
      s="$(awk '{print $1}' <<<"$l")"
      if [[ -e "/sys/bus/pci/devices/${s#0000:}/drm" ]]; then
        line="$l"; break
      fi
    done < <(awk '/\[1002:[0-9a-fA-F]{4}\]/{print}' <<<"$all")
  fi

  [[ -n "$line" ]] || err "Geen AMD GPU gevonden via lspci (/sys fallback faalde ook)"

  GPU_SLOT="$(awk '{print $1}' <<<"$line")"
  # Normaliseer naar 0000: domain-prefix
  [[ "$GPU_SLOT" =~ ^0000: ]] || GPU_SLOT="0000:${GPU_SLOT}"
  GPU_ID="$(grep -o '\[1002:[0-9a-fA-F]\{4\}\]' <<<"$line" | head -n1 | tr -d '[]')"

  # ---------------- AUDIO-detectie (lspci-first) ----------------
  # 1) Als expliciet opgegeven, gebruik die; anders probeer <gpu>.1 als kandidaat.
  if [[ -z "${AUDIO_SLOT:-}" ]]; then
    local base="${GPU_SLOT%.*}"
    AUDIO_SLOT="${base}.1"
  fi

  # 2) Probeer lspci-regel te vinden voor AUDIO_SLOT; zo niet, zoek op dezelfde bus.
  local aline=""
  if [[ -n "${AUDIO_SLOT:-}" ]]; then
    aline="$(grep -E "^${AUDIO_SLOT}[[:space:]]|^${AUDIO_SLOT#0000:}[[:space:]]" <<<"$all" || true)"
  fi
  if [[ -z "$aline" ]]; then
    # Zoek op dezelfde gbus (segment:slot) naar AMD Audio eerst, anders 'Audio' generiek.
    local gbus="${GPU_SLOT#0000:}"   # bijv. c5:00.0
    gbus="${gbus%%:*}:"              # -> c5:
    # voorkeur: AMD (vendor 1002) audio op dezelfde bus
    aline="$(awk -v gbus="$gbus" '
      $1 ~ "^"gbus && /Audio/ && /\[1002:[0-9a-fA-F]{4}\]/ {print; exit}
    ' <<<"$all" || true)"
    # fallback: eender audio op dezelfde bus
    [[ -n "$aline" ]] || aline="$(awk -v gbus="$gbus" '$1 ~ "^"gbus && /Audio/ {print; exit}' <<<"$all" || true)"
  fi

  # 3) Valideer vendor: alleen AMD (1002) HDMI/DP audio meenemen; anders leeg laten.
  if [[ -n "$aline" ]]; then
    AUDIO_SLOT="$(awk '{print $1}' <<<"$aline")"
    [[ "$AUDIO_SLOT" =~ ^0000: ]] || AUDIO_SLOT="0000:${AUDIO_SLOT}"
    AUDIO_ID="$(grep -o '\[1002:[0-9a-fA-F]\{4\}\]' <<<"$aline" | head -n1 | tr -d '[]')"
    if [[ -z "$AUDIO_ID" || "$AUDIO_ID" != 1002:* ]]; then
      note "Gevonden audio op ${AUDIO_SLOT}, maar geen AMD (iGPU) — onboard HDA? Ga verder zonder audio-bind."
      AUDIO_SLOT=""; AUDIO_ID=""
    fi
  else
    note "Geen iGPU-audio gevonden op dezelfde bus; ga verder zonder audio."
    AUDIO_SLOT=""; AUDIO_ID=""
  fi
}

iommu_flags(){
  [[ -f /etc/kernel/cmdline ]] || { echo "(no /etc/kernel/cmdline)"; return; }
  grep -Eo 'amd_iommu=[^ ]+|iommu=pt|video=efifb:[^ ]+' /etc/kernel/cmdline || true
}

vfio_present(){ [[ -f "$VFIO_CONF" ]] && echo "present" || echo "absent"; }

render_nodes(){ ls -1 /dev/dri 2>/dev/null | sed 's/^/\/dev\/dri\//' || true; }

show_status(){
  detect_devices
  echo "=== Huidige status ==="
  echo "GPU   : $GPU_SLOT (id $GPU_ID) -> driver: $(driver_of "$GPU_SLOT")"
  if [[ -n "${AUDIO_SLOT:-}" ]]; then
    echo "Audio : $AUDIO_SLOT (id ${AUDIO_ID:-unknown}) -> driver: $(driver_of "$AUDIO_SLOT")"
  fi
  echo "vfio.conf : $(vfio_present)"
  echo "Kernel cmdline flags : $(iommu_flags)"
  echo "Render nodes :"; render_nodes | sed 's/^/  /'
  echo "======================"
}

# -------------- persistent config ---------------
write_vfio_conf(){
  [[ -n "${GPU_ID:-}" ]] || err "GPU_ID niet bekend"
  msg "Schrijf ${VFIO_CONF} (vfio-pci ids=${GPU_ID}${AUDIO_ID:+,${AUDIO_ID}})"
  cat >"$VFIO_CONF" <<EOF
# Auto-generated by gpu-toggle.sh
options vfio-pci ids=${GPU_ID}${AUDIO_ID:+,${AUDIO_ID}}
softdep amdgpu pre: vfio-pci
blacklist amdgpu
blacklist radeon
# blacklist snd_hda_intel
EOF
}

disable_vfio_conf(){
  if [[ -f "$VFIO_CONF" ]]; then
    msg "Disable ${VFIO_CONF}"
    mv "$VFIO_CONF" "${VFIO_CONF}.disabled.$(date +%s)"
  fi
}

ensure_amdgpu_autoload(){ echo amdgpu > "$AMDGPU_ML"; }

ensure_iommu(){
  local cmdline="/etc/kernel/cmdline"
  [[ -f "$cmdline" ]] || { note "$cmdline ontbreekt; sla IOMMU-check over."; return; }
  if ! grep -q 'amd_iommu=on' "$cmdline"; then
    if yn "IOMMU niet gevonden. amd_iommu=on iommu=pt toevoegen aan kernel cmdline en refresh?" Y; then
      sed -i 's/$/ amd_iommu=on iommu=pt/' "$cmdline"
      proxmox-boot-tool refresh || true
      ok "IOMMU flags toegevoegd. Reboot aanbevolen."
    fi
  fi
}

# ------------------- modes ----------------------
do_host(){
  detect_devices
  msg "Schakel naar HOST (amdgpu)"
  disable_vfio_conf
  ensure_amdgpu_autoload

  modprobe amdgpu || true
  unbind_from vfio-pci "$GPU_SLOT"
  bind_to amdgpu "$GPU_SLOT"

  if [[ -n "${AUDIO_SLOT:-}" ]]; then
    modprobe snd_hda_intel || true
    unbind_from vfio-pci "$AUDIO_SLOT"
    bind_to snd_hda_intel "$AUDIO_SLOT"
  fi

  update-initramfs -u || true
  ok "Host-mode geactiveerd (live). Reboot kan nog nodig zijn."
  show_status
}

do_passthrough(){
  detect_devices
  msg "Schakel naar PASSTHROUGH (vfio-pci)"
  write_vfio_conf
  modprobe vfio-pci || true

  unbind_from amdgpu "$GPU_SLOT"
  bind_to vfio-pci "$GPU_SLOT"

  if [[ -n "${AUDIO_SLOT:-}" ]]; then
    unbind_from snd_hda_intel "$AUDIO_SLOT"
    bind_to vfio-pci "$AUDIO_SLOT"
  fi

  ensure_iommu
  update-initramfs -u || true
  ok "Passthrough-mode geactiveerd (live). Reboot sterk aanbevolen voor VM-start."
  show_status
}

# ------------------ wizard ----------------------
wizard(){
  show_status
  echo
  local cur; cur="$(driver_of "$GPU_SLOT")"
  local default
  case "$cur" in
    amdgpu)   default="2" ;; # voorstel: naar passthrough
    vfio-pci) default="1" ;; # voorstel: naar host
    *)        default="3" ;;
  esac

  echo "Kies een actie:"
  echo "  1) Switch naar HOST (amdgpu)"
  echo "  2) Switch naar PASSTHROUGH (vfio-pci)"
  echo "  3) Alleen status opnieuw tonen"
  echo "  4) Alleen persist instellen (schrijf/disable vfio.conf) zonder live (un)bind"
  echo "  5) Reboot nu"
  echo "  0) Afsluiten"
  local sel=""
  read_safe sel "Selectie [${default}]: " "$default"

  case "$sel" in
    1) do_host ;;
    2) do_passthrough ;;
    3) show_status ;;
    4)
      if yn "Persist PASSTHROUGH schrijven (vfio.conf)?" N; then
        detect_devices; write_vfio_conf; update-initramfs -u || true; ok "vfio.conf geschreven."
      elif yn "Persist HOST instellen (vfio.conf uitzetten)?" Y; then
        disable_vfio_conf; update-initramfs -u || true; ok "vfio.conf disabled."
      fi
      ;;
    5) reboot ;;
    0) exit 0 ;;
    *) echo "Ongeldige keuze";;
  esac

  echo
  if yn "Nog een actie uitvoeren?" N; then
    wizard
  fi
}

# ------------------- arg parsing -----------------
# parse optionele --slot / --audio-slot vóór subcommand
SUBCMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot) GPU_SLOT="${2:-}"; shift 2 ;;
    --audio-slot) AUDIO_SLOT="${2:-}"; shift 2 ;;
    host|--host|passthrough|--passthrough|status|--status|wizard|wizzard|wizzart|"")
      SUBCMD="$1"; shift || true; break ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Onbekende optie: $1"; usage; exit 2 ;;
  esac
done

# ------------------- main ------------------------
preflight
case "${SUBCMD:-${1:-}}" in
  host|--host)               do_host ;;
  passthrough|--passthrough) do_passthrough ;;
  status|--status)           show_status ;;
  wizard|wizzard|wizzart|"") wizard ;;
  *)
    if [[ -t 0 ]]; then
      echo "Onbekend subcommando '${SUBCMD:-${1:-}}'"; usage; echo "Start wizard..."
      wizard
    else
      usage
      exit 2
    fi
    ;;
esac
