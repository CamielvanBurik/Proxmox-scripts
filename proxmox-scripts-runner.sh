#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Proxmox Scripts Runner (GitHub launcher)
# - Haalt https://github.com/CamielvanBurik/Proxmox-scripts op/updated
# - Toont lijst scripts (fzf-UI als beschikbaar, anders numeriek menu)
# - Voert gekozen script uit met optionele arguments (met/zonder sudo)
# - Dry-run optie om eerst te zien wat er zou gebeuren
# =========================================================

REPO_URL="${REPO_URL:-https://github.com/CamielvanBurik/Proxmox-scripts}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/proxmox-scripts}"
REPO_DIR="$CACHE_DIR/repo"

# Opties
DRY_RUN=false
FORCE_UPDATE=false
ALWAYS_SUDO=false
NEVER_SUDO=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [opties]

Opties:
  -n, --dry-run      Toon het (sudo) commando i.p.v. uitvoeren
  -u, --update       Forceer update van de repo (git pull of zip her-download)
  -S, --sudo         Altijd met sudo uitvoeren (zonder extra prompt)
  -U, --no-sudo      Nooit sudo gebruiken
  -h, --help         Deze hulp

Omgevingsvariabelen:
  REPO_URL  (default: $REPO_URL)
  CACHE_DIR (default: $CACHE_DIR)

Voorbeeld:
  $(basename "$0")                    # normale interactieve run
  $(basename "$0") -n                 # dry-run
  REPO_URL=https://.../fork.git $(basename "$0")
EOF
}

log(){ echo "[$(date '+%F %T')] $*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ---- args
while (("$#")); do
  case "$1" in
    -n|--dry-run)   DRY_RUN=true ;;
    -u|--update)    FORCE_UPDATE=true ;;
    -S|--sudo)      ALWAYS_SUDO=true ;;
    -U|--no-sudo)   NEVER_SUDO=true ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Onbekende optie: $1"; usage; exit 1 ;;
  esac
  shift
done

# ---- helpers
ensure_dir(){ mkdir -p "$1"; }

clone_or_update_git() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    log "Git repo gevonden, pull…"
    git -C "$REPO_DIR" fetch --all --prune
    git -C "$REPO_DIR" reset --hard origin/HEAD || git -C "$REPO_DIR" pull --ff-only
  else
    log "Git clone -> $REPO_DIR"
    rm -rf "$REPO_DIR" 2>/dev/null || true
    git clone --depth 1 "$REPO_URL" "$REPO_DIR"
  fi
}

download_zip_branch() {
  # Probeer main, dan master
  local branch url zip="$CACHE_DIR/repo.zip"
  for branch in main master; do
    url="${REPO_URL%/}.zip/refs/heads/${branch}"
    log "Download zip ($branch)… $url"
    if curl -fsSL "$url" -o "$zip"; then
      rm -rf "$REPO_DIR" 2>/dev/null || true
      mkdir -p "$REPO_DIR"
      unzip -q "$zip" -d "$CACHE_DIR"
      local topdir
      topdir="$(unzip -Z -1 "$zip" | head -n1 | cut -d/ -f1)"
      [[ -d "$CACHE_DIR/$topdir" ]] || { log "Zip structuur onverwacht"; return 1; }
      # verplaats inhoud naar REPO_DIR
      shopt -s dotglob
      mv "$CACHE_DIR/$topdir"/* "$REPO_DIR"/
      shopt -u dotglob
      rm -rf "$CACHE_DIR/$topdir" "$zip"
      return 0
    fi
  done
  return 1
}

sync_repo() {
  ensure_dir "$CACHE_DIR"
  if have git; then
    if $FORCE_UPDATE || [[ ! -d "$REPO_DIR" ]]; then
      clone_or_update_git
    else
      # probeer vriendelijke update
      if [[ -d "$REPO_DIR/.git" ]]; then
        log "Update (git pull) …"
        git -C "$REPO_DIR" pull --ff-only || true
      fi
    end
  else
    log "git niet gevonden; val terug op curl+unzip"
    have curl || { echo "curl ontbreekt"; exit 1; }
    have unzip || { echo "unzip ontbreekt"; exit 1; }
    if $FORCE_UPDATE || [[ ! -d "$REPO_DIR" ]]; then
      download_zip_branch || { echo "Zip download mislukt"; exit 1; }
    fi
  fi
}

find_scripts() {
  # Pak alles dat .sh eindigt of executable shebang heeft
  # (GitHub zip kan exec-bit verliezen, dus ook *.sh meenemen)
  local IFS=$'\n'
  # Filter standaard dingen uit zoals .git en .github
  find "$REPO_DIR" -type f \
    \( -name "*.sh" -o -perm -111 \) \
    ! -path "*/.git/*" ! -path "*/.github/*" \
    ! -path "*/README*/*" 2>/dev/null \
  | sort
}

menu_choose() {
  local -a items=("$@")
  (( ${#items[@]} )) || { echo ""; return 1; }

  if have fzf; then
    # shellcheck disable=SC2016
    fzf --prompt="Selecteer script > " \
        --preview 'sed -n "1,120p" {}' \
        --preview-window=down,60%:wrap \
        --height=90% --border
  else
    echo "Geen fzf gevonden. Numeriek menu:"
    local i=1
    for f in "${items[@]}"; do
      printf "  [%2d] %s\n" "$i" "${f#$REPO_DIR/}"
      ((i++))
    done
    local sel
    while true; do
      read -r -p "Nummer (1-$((i-1))): " sel
      [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<i )) && break
      echo "Ongeldige keuze."
    done
    echo "${items[sel-1]}"
  fi
}

detect_interpreter() {
  # echo het commando (bash|sh|python|node|…) of leeg als executable zelf runbaar is
  local f="$1" line
  if [[ -x "$f" ]]; then
    # heeft exec-bit, probeer direct
    read -r line < "$f" || true
    if [[ "$line" =~ ^#! ]]; then
      echo ""   # laat OS beslissen via shebang
    else
      # geen shebang? fallback bash
      echo "bash"
    fi
  else
    # geen exec-bit: kijk shebang
    read -r line < "$f" || true
    case "$line" in
      "#!"*bash* ) echo "bash" ;;
      "#!"*sh*   ) echo "sh"   ;;
      "#!"*python*) echo "python3" ;;
      "#!"*python3*) echo "python3" ;;
      "#!"*node* ) echo "node" ;;
      *) echo "bash" ;;  # veilige fallback
    esac
  fi
}

confirm() {
  local q="$1" a
  read -r -p "$q [Y/n] " a || true
  [[ "${a:-Y}" =~ ^([Yy]|)$ ]]
}

run_selected() {
  local f="$1"
  [[ -f "$f" ]] || { echo "Bestand niet gevonden: $f"; return 1; }

  # toon korte header
  echo "=================================================="
  echo "Bestand : ${f#$REPO_DIR/}"
  echo "Pad     : $f"
  echo "Preview :"
  sed -n '1,25p' "$f" || true
  echo "=================================================="

  local args=""
  read -r -e -p "Optionele arguments voor dit script (Enter voor geen): " args

  local interp; interp="$(detect_interpreter "$f")"

  # Als script geen exec-bit heeft, voeg het tijdelijk toe voor nette runs
  if [[ ! -x "$f" ]]; then chmod +x "$f" || true; fi

  # sudo-keuze
  local use_sudo=""
  if $NEVER_SUDO; then use_sudo=""; 
  elif $ALWAYS_SUDO; then use_sudo="sudo";
  else
    if confirm "Met sudo uitvoeren?"; then use_sudo="sudo"; fi
  fi

  # Bouw commando
  local cmd
  if [[ -n "$interp" ]]; then
    cmd="$use_sudo $interp \"$f\" $args"
  else
    cmd="$use_sudo \"$f\" $args"
  fi

  echo
  echo "Command:"
  echo "  $cmd"
  echo

  if $DRY_RUN; then
    echo "[dry-run] niet uitgevoerd."
    return 0
  fi

  # shellcheck disable=SC2086
  eval $cmd
}

main() {
  ensure_dir "$CACHE_DIR"
  sync_repo

  mapfile -t scripts < <(find_scripts)
  (( ${#scripts[@]} )) || { echo "Geen scripts gevonden in $REPO_URL"; exit 1; }

  local chosen
  chosen="$(menu_choose "${scripts[@]}")" || { echo "Geen keuze"; exit 1; }
  [[ -n "$chosen" ]] || { echo "Geen keuze gemaakt"; exit 1; }

  run_selected "$chosen"
}

main
