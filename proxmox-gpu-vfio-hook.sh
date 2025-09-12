#!/usr/bin/env bash
# Proxmox VM hookscript: toggle AMD iGPU voor passthrough/host.
# Phases: pre-start | post-start | pre-stop | post-stop
# Aanpassen:
GPU_SLOT="0000:c5:00.0"
AUDIO_SLOT="0000:c5:00.1"     # leeg laten als je audio niet wilt doorgeven
GPU_TOGGLE="/root/.cache/proxmox-scripts/repo/proxmox-gpu-toggle.sh"
LOG="/var/log/proxmox-gpu-vfio-hook.log"
LOCK="/var/lock/proxmox-gpu-vfio.lock"
TIMEOUT="${TIMEOUT:-25}"      # seconden per toggle-actie
DRYRUN="${DRYRUN:-0}"         # DRYRUN=1 => alleen loggen

vmid="$1"
phase="$2"

ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] [vmid:$vmid] [$phase] $*" | tee -a "$LOG"; }

run_toggle(){
  local mode="$1" args=( "$GPU_TOGGLE" "--slot" "$GPU_SLOT" )
  [[ -n "$AUDIO_SLOT" ]] && args+=( "--audio-slot" "$AUDIO_SLOT" )
  args+=( "$mode" )
  if [[ "$DRYRUN" == "1" ]]; then
    log "DRYRUN: ${args[*]}"
    return 0
  fi
  if [[ ! -x "$GPU_TOGGLE" ]]; then
    log "ERROR: toggle script niet uitvoerbaar: $GPU_TOGGLE"
    return 1
  fi
  # Een simpele lock tegen gelijktijdige calls
  if command -v flock >/dev/null 2>&1; then
    flock -w 30 "$LOCK" timeout "$TIMEOUT" "${args[@]}" >>"$LOG" 2>&1
  else
    timeout "$TIMEOUT" "${args[@]}" >>"$LOG" 2>&1
  fi
}

case "$phase" in
  pre-start)
    log "pre-start: schakel iGPU naar PASSTHROUGH (vfio-pci)"
    if ! run_toggle "passthrough"; then
      log "ERROR: toggle naar passthrough faalde"
      exit 1   # blokkeer start als GPU niet vrij is
    fi
    ;;

  post-start)
    log "post-start: VM gestart"
    ;;

  pre-stop)
    log "pre-stop: VM gaat stoppen (geen actie, wacht tot post-stop)"
    ;;

  post-stop)
    log "post-stop: schakel iGPU terug naar HOST (amdgpu)"
    if ! run_toggle "host"; then
      log "WAARSCHUWING: toggle terug naar host faalde (manuele interventie nodig?)"
      # exit niet hard; VM is al uit
    fi
    ;;

  *)
    log "Onbekende fase: '$phase' (args: $*)"
    ;;
esac

exit 0
