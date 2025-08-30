#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Proxmox LXC Bulk IP Assign (CTID -> BASE_PREFIX.CTID/CIDR)
# - Selecteer meerdere containers (fzf of numeriek menu)
# - Voor elke CT: net0 ip=<base>.<ctid>/<cidr>,gw=<gateway> instellen
# - Bestaande net0-opties (bridge=, tag=, firewall=, name= etc.) blijven behouden
# - Optie om containers te herstarten zodat IP actief wordt
# =========================================================

LOG_FILE="${LOG_FILE:-/var/log/proxmox-lxc-bulk-ip.log}"
NO_FZF="${NO_FZF:-false}"

# Defaults (interactief aanpasbaar)
BASE_PREFIX="${BASE_PREFIX:-192.168.1}"   # wordt <BASE_PREFIX>.<CTID>
CIDR_BITS="${CIDR_BITS:-23}"              # bv. 23 -> 255.255.254.0
GATEWAY="${GATEWAY:-192.168.1.1}"         # standaard gateway (moet binnen/netmask vallen)

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
fail(){ log "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

# --- fzf optioneel installeren ---
ensure_fzf(){
  [[ -t 1 ]] || return 1
  [[ "$NO_FZF" == "true" ]] && return 1
  if have fzf; then return 0; fi
  log "fzf niet gevonden; probeer te installeren…"
  local SUDO=""; (( EUID != 0 )) && have sudo && SUDO="sudo"
  if have apt-get;   then $SUDO apt-get -y update || true; $SUDO apt-get -y install fzf || true
  elif have dnf;     then $SUDO dnf -y install fzf || true
  elif have yum;     then $SUDO yum -y install fzf || true
  elif have zypper;  then $SUDO zypper --non-interactive install fzf || true
  elif have pacman;  then $SUDO pacman -Sy --noconfirm fzf || true
  fi
  have fzf && { log "fzf geïnstalleerd."; return 0; } || { log "fzf installatie niet gelukt; numeriek menu fallback."; return 1; }
}

# --- Proxmox LXC helpers ---
pct_list_raw(){ pct list 2>/dev/null || true; }
pct_list_ctids(){ pct_list_raw | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }
ct_status(){ pct status "$1" 2>/dev/null | awk '{print $2}'; }
ct_name(){ pct_list_raw | awk -v id="$1" 'NR>1 && $1==id {print $3; exit}'; }
ct_config_net0(){ pct config "$1" 2>/dev/null | sed -n 's/^net0:\s*//p'; }

# --- net0 string aanpassen (ip/gw injecteren of vervangen) ---
build_net0_with_ipgw(){
  # in:  $1 = huidige net0 string (kan leeg zijn)
  #      $2 = ip/cidr (bijv 192.168.1.103/23)
  #      $3 = gw (bijv 192.168.1.1)
  local cur="${1:-}" ipcidr="$2" gw="$3" out
  # strip bestaand ip=... en gw=...
  local clean
  clean="$(printf '%s' "$cur" \
    | sed -E 's/(^|,)ip=[^,]*,?/\1/g; s/(^|,)gw=[^,]*,?/\1/g; s/,,+/,/g; s/^,|,$//g')"
  # name= en bridge= zeker stellen (laat bestaande staan)
  if ! [[ "$clean" =~ (^|,)name= ]];   then clean="name=eth0${clean:+,}${clean}"; fi
  if ! [[ "$clean" =~ (^|,)bridge= ]]; then clean="bridge=vmbr0,${clean}"; fi
  out="${clean:+$clean,}ip=${ipcidr},gw=${gw}"
  echo "$out"
}

# --- fzf/numeriek menu ---
choose_cts(){
  local ids=() lines=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    ids+=("$id")
    local st nm net0
    st="$(ct_status "$id" 2>/dev/null || true)"
    nm="$(ct_name "$id" 2>/dev/null || true)"
    net0="$(ct_config_net0 "$id")"
    lines+=("$(printf "%-5s %-25s | status:%-8s | net0:%s" "$id" "${nm:-unknown}" "${st:-unknown}" "${net0:-<none>}")")
  done < <(pct_list_ctids)
  ((${#ids[@]})) || fail "Geen containers gevonden."

  if ensure_fzf; then
    local sel
    sel="$(printf "%s\n" "${lines[@]}" \
      | fzf -m --prompt="Selecteer CT's > " \
             --header="Spatie=selecteer, Enter=bevestig" \
             --height=90% --border --ansi \
             --preview 'echo {}' --preview-window=down,10%)" || true
    [[ -n "$sel" ]] || fail "Geen selectie gemaakt."
    printf "%s\n" "$sel" | awk '{print $1}'
    return 0
  fi

  >&2 echo "Beschikbare CTs:"
  local i=1
  for L in "${lines[@]}"; do >&2 printf "  [%2d] %s\n" "$i" "$L"; ((i++)); done
  >&2 echo
  >&2 read -r -p "Kies meerdere met nummers of CTIDs (spaties), of 'all': " sel
  if [[ "$sel" == "all" ]]; then printf "%s\n" "${ids[@]}"; return 0; fi

  local chosen=() total=$((i-1))
  for tok in $sel; do
    if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok>=1 && tok<=total )); then
      chosen+=("${ids[tok-1]}")
    elif printf "%s\n" "${ids[@]}" | grep -qx "$tok"; then
      chosen+=("$tok")
    else
      >&2 echo "  - Ongeldige keuze: $tok (genegeerd)"
    fi
  done
  ((${#chosen[@]})) || fail "Geen geldige keuze."
  printf "%s\n" "${chosen[@]}"
}

# --- validaties ---
valid_prefix(){
  [[ "$1" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c <<<"$1"
  for x in "$a" "$b" "$c"; do (( x>=0 && x<=255 )) || return 1; done
  return 0
}
valid_ipv4(){
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$1"
  for x in "$a" "$b" "$c" "$d"; do (( x>=0 && x<=255 )) || return 1; done
  return 0
}
in_same_subnet(){
  # args: ip1 ip2 cidr
  local ip1="$1" ip2="$2" cidr="$3"
  python3 - "$ip1" "$ip2" "$cidr" <<'PY' 2>/dev/null || return 1
import sys, ipaddress
ip1, ip2, cidr = sys.argv[1], sys.argv[2], int(sys.argv[3])
net1 = ipaddress.ip_network(f"{ip1}/{cidr}", strict=False)
net2 = ipaddress.ip_network(f"{ip2}/{cidr}", strict=False)
print("OK" if net1.network_address == net2.network_address else "NO")
PY
}

# --- main ---
main(){
  have pct || fail "Dit script moet op de Proxmox host draaien (pct vereist)."
  echo "== LXC Bulk IP Assign (CTID -> ${BASE_PREFIX}.CTID/${CIDR_BITS}) =="

  # Interactieve vragen met defaults
  read -r -p "BASE_PREFIX (a.b.c) [$BASE_PREFIX]: " a; BASE_PREFIX="${a:-$BASE_PREFIX}"
  valid_prefix "$BASE_PREFIX" || fail "Ongeldige BASE_PREFIX (verwacht a.b.c bv 192.168.1)"

  read -r -p "CIDR bits [$CIDR_BITS]: " a; CIDR_BITS="${a:-$CIDR_BITS}"
  [[ "$CIDR_BITS" =~ ^[0-9]+$ ]] && (( CIDR_BITS>=8 && CIDR_BITS<=30 )) || fail "Ongeldige CIDR bits"

  read -r -p "Gateway [$GATEWAY]: " a; GATEWAY="${a:-$GATEWAY}"
  valid_ipv4 "$GATEWAY" || fail "Ongeldige gateway"
  in_same_subnet "${BASE_PREFIX}.1" "$GATEWAY" "$CIDR_BITS" >/dev/null || log "Let op: gateway lijkt niet in hetzelfde subnet als ${BASE_PREFIX}.X/${CIDR_BITS}"

  # Selectie van containers
  mapfile -t CTIDS < <(choose_cts)

  echo
  echo "Voorstel toewijzing:"
  printf "  %-6s %-18s %-18s\n" "CTID" "Nieuwe IP/CIDR" "Gateway"
  for id in "${CTIDS[@]}"; do
    if ! [[ "$id" =~ ^[0-9]+$ ]]; then echo "  $id  (onverwacht)"; continue; fi
    if (( id<2 || id>254 )); then
      printf "  %-6s %-18s %-18s  %s\n" "$id" "-" "-" "** overgeslagen: CTID buiten 2..254 voor laatste octet **"
    else
      printf "  %-6s %-18s %-18s\n" "$id" "${BASE_PREFIX}.${id}/${CIDR_BITS}" "$GATEWAY"
    fi
  done
  echo
  read -r -p "Doorvoeren? [Y/n] " go
  [[ "${go:-Y}" =~ ^([Yy]|)$ ]] || fail "Afgebroken."

  # Doorvoeren
  for id in "${CTIDS[@]}"; do
    if (( id<2 || id>254 )); then
      log "CT $id: overslaan (CTID buiten 2..254)."
      continue
    fi
    local ipcidr="${BASE_PREFIX}.${id}/${CIDR_BITS}"
    local cur net0new
    cur="$(ct_config_net0 "$id" || true)"
    net0new="$(build_net0_with_ipgw "$cur" "$ipcidr" "$GATEWAY")"
    log "CT $id: pct set -net0 '$net0new'"
    pct set "$id" -net0 "$net0new" >/dev/null
  done

  echo
  read -r -p "Containers nu herstarten zodat IP actief wordt? [Y/n] " rs
  if [[ "${rs:-Y}" =~ ^([Yy]|)$ ]]; then
    for id in "${CTIDS[@]}"; do
      if (( id<2 || id>254 )); then continue; fi
      log "CT $id: restart…"
      pct restart "$id" >/dev/null || log "CT $id: restart faalde (draait container?)."
    done
  else
    echo "Let op: IP wordt actief na herstart van de container(s)."
  fi

  log "Klaar."
}

main "$@"
