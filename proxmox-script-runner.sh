#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Proxmox Scripts Runner (GitHub launcher)
# - Altijd nieuwste versie ophalen
# - Repo in tijdelijke directory stage'n
# - Lijst uit temp dir (fzf of numeriek)
# - fzf auto-install (best effort)
# - scripts-menu.sh en dit script zelf verbergen
# =========================================================

REPO_URL="${REPO_URL:-https://github.com/CamielvanBurik/Proxmox-scripts}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/proxmox-scripts}"
REPO_DIR="$CACHE_DIR/repo"
SELF_NAME="$(basename "$0")"

DRY_RUN=false
FORCE_UPDATE=true
ALWAYS_SUDO=false
NEVER_SUDO=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [opties]
  -n, --dry-run   Toon het (sudo) commando i.p.v. uitvoeren
  -u, --update    Forceer update van de repo (git pull of zip her-download)
  -S, --sudo      Altijd met sudo uitvoeren
  -U, --no-sudo   Nooit sudo gebruiken
  -h, --help      Deze hulp
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

ensure_dir(){ mkdir -p "$1"; }

# ---- fzf auto-install ----
ensure_fzf() {
  if have fzf; then return 0; fi
  log "fzf niet gevonden; probeer te installeren…"

  local SUDO=""
  if (( EUID != 0 )) && have sudo; then SUDO="sudo"; fi

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
  else
    log "Geen ondersteunde package manager; installeer fzf handmatig a.u.b."
  fi

  if have fzf; then
    log "fzf succesvol geïnstalleerd."
  else
    log "Kon fzf niet installeren; val terug op numeriek menu."
  fi
}

# ---- Repo sync (altijd laatste) ----
clone_or_update_git() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    log "Git repo gevonden, forceer sync naar laatste origin/HEAD"
    git -C "$REPO_DIR" fetch --all --prune
    if git -C "$REPO_DIR" rev-parse --abbrev-ref origin/HEAD >/dev/null 2>&1; then
      git -C "$REPO_DIR" reset --hard origin/HEAD
      git -C "$REPO_DIR" clean -fdx
    else
      git -C "$REPO_DIR" pull --ff-only || true
      git -C "$REPO_DIR" clean -fdx || true
    fi
  else
    log "Git clone -> $REPO_DIR"
    rm -rf "$REPO_DIR" 2>/dev/null || true
    git clone --depth 1 "$REPO_URL" "$REPO_DIR"
  fi
}

download_zip_branch() {
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
    clone_or_update_git
  else
    log "git niet gevonden; val terug op curl+unzip (altijd vers ophalen)"
    have curl || { echo "curl ontbreekt"; exit 1; }
    have unzip || { echo "unzip ontbreekt"; exit 1; }
    download_zip_branch || { echo "Zip download mislukt"; exit 1; }
  fi
}

# ---- Staging naar tijdelijke map ----
TMP_DIR=""
stage_repo_to_tmp() {
  TMP_DIR="$(mktemp -d -t proxmox-scripts-XXXXXX)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  if have rsync; then
    rsync -a --delete --exclude '.git' "$REPO_DIR"/ "$TMP_DIR"/
  else
    ( shopt -s dotglob; cp -a "$REPO_DIR"/* "$TMP_DIR"/ )
    rm -rf "$TMP_DIR/.git" 2>/dev/null || true
  fi
}

# ---- Scripts zoeken (in temp dir) ----
find_scripts() {
  find "$TMP_DIR" -type f \( -name "*.sh" -o -perm -111 \) \
    ! -path "*/.git/*" ! -path "*/.github/*" 2>/dev/null \
  | awk -v skip1="scripts-menu.sh" -v skip2="$SELF_NAME" '
      { n=$0; sub(/^.*\//,"",n); if (n==skip1 || n==skip2) next; print $0 }
    ' \
  | sort
}

# ---- Menu (FIX: items -> fzf via stdin) ----
menu_choose() {
  local -a items=("$@")
  (( ${#items[@]} )) || { echo ""; return 1; }

  if have fzf; then
    # Pijp de lijst naar fzf (anders neemt fzf de cwd-bestanden!)
    printf '%s\n' "${items[@]}" \
    | fzf --prompt="Selecteer script > " \
          --preview 'sed -n "1,120p" {}' \
          --preview-window=down,60%:wrap \
          --height=90% --border \
          --header "Tip: Ctrl-Y kopieert pad (indien xclip)" \
          --bind "ctrl-y:execute-silent(echo {} | xclip -selection clipboard)+abort"
  else
    >&2 echo "Geen fzf gevonden. Numeriek menu:"
    local i=1 rel
    for f in "${items[@]}"; do
      rel="${f#$TMP_DIR/}"
      >&2 printf "  [%2d] %s\n" "$i" "$rel"
      ((i++))
    done
    local sel
    while true; do
      read -r -p "Nummer (1-$((i-1))): " sel
      [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<i )) && break
      >&2 echo "Ongeldige keuze."
    done
    echo "${items[sel-1]}"
  fi
}

# ---- Interpreter detectie ----
detect_interpreter() {
  local f="$1" line=""
  if [[ -x "$f" ]]; then
    read -r line < "$f" || true
    [[ "$line" =~ ^#! ]] && echo "" || echo "bash"
  else
    read -r line < "$f" || true
    case "$line" in
      "#!"*bash*   ) echo "bash" ;;
      "#!"*sh*     ) echo "sh"   ;;
      "#!"*python3*) echo "python3" ;;
      "#!"*python* ) echo "python3" ;;
      "#!"*node*   ) echo "node" ;;
      *            ) echo "bash" ;;
    esac
  fi
}

confirm() { local a; read -r -p "$1 [Y/n] " a || true; [[ "${a:-Y}" =~ ^([Yy]|)$ ]]; }

# ---- Runner ----
run_selected() {
  local f="$1"
  [[ -f "$f" ]] || { echo "Bestand niet gevonden: $f"; return 1; }

  local rel="${f#$TMP_DIR/}"
  echo "=================================================="
  echo "Bestand : $rel"
  echo "Pad     : $f"
  echo "Preview :"
  sed -n '1,25p' "$f" || true
  echo "=================================================="

  local args=""
  read -r -e -p "Optionele arguments voor dit script (Enter voor geen): " args

  local interp; interp="$(detect_interpreter "$f")"
  [[ -x "$f" ]] || chmod +x "$f" || true

  local use_sudo=""
  if $NEVER_SUDO; then
    use_sudo=""
  elif $ALWAYS_SUDO; then
    use_sudo="sudo"
  else
    if confirm "Met sudo uitvoeren?"; then use_sudo="sudo"; fi
  fi

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
  stage_repo_to_tmp
  ensure_fzf

  mapfile -t scripts < <(find_scripts)
  (( ${#scripts[@]} )) || { echo "Geen scripts gevonden in $REPO_URL"; exit 1; }

  local chosen
  chosen="$(menu_choose "${scripts[@]}")" || { echo "Geen keuze"; exit 1; }
  [[ -n "$chosen" ]] || { echo "Geen keuze gemaakt"; exit 1; }

  run_selected "$chosen"
}

main
