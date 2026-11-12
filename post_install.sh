#!/usr/bin/env bash
# post_install.sh — Installe EmulationStation-RE (et scripts associés) sur le système.
#
# À lancer en root sur le système installé (Arch Linux ou Armbian/Debian) :
#   sudo ./post_install.sh
#
# - détecte l'OS et l'architecture
# - télécharge la dernière release depuis GitHub
# - installe le paquet (pacman/apt)
# - installe les scripts helper (start-es.sh, ...)
# - configure l'autostart / les groupes utilisateur
# - snapshot btrfs si snapper est présent
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en root."

# Sur une fresh install on est root directement : vérification des outils de base.
for cmd in curl; do
    command -v "$cmd" >/dev/null 2>&1 || die "Outil manquant : $cmd"
done

REPO="JyuHo/emulationstation-re"
API="https://api.github.com/repos/${REPO}/releases/latest"

is_bc250() {
    if [[ "${BC250_FORCE:-0}" == "1" ]]; then return 0; fi
    if lspci -nn 2>/dev/null | grep -qi 'BC-250\|BC250\|\[1002:13fe\]\|\[1002:143f\]'; then return 0; fi
    if lspci 2>/dev/null | grep -qi 'bc-250\|bc250'; then return 0; fi
    return 1
}

# ---------- Détection OS / arch ----------
if command -v pacman >/dev/null 2>&1; then OS="arch"
elif command -v apt-get >/dev/null 2>&1; then OS="debian"
else die "OS non supporté (ni pacman ni apt-get)."; fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) ARCH_NORM="x86_64" ;;
    aarch64|arm64) ARCH_NORM="arm64" ;;
    *) die "Architecture non supportée : $ARCH" ;;
esac

BC250=0
if is_bc250; then BC250=1; fi
info "OS=$OS ARCH=$ARCH_NORM BC250=$BC250"

# ---------- Dépendances outils ----------
ensure_tool() {
    local t="$1"
    command -v "$t" >/dev/null 2>&1 && return 0
    case "$OS" in
        arch) pacman -Sy --noconfirm "$t" 2>/dev/null || pacman -Sy --noconfirm jq curl ;;
        debian) apt-get update -qq && apt-get install -y "$t" ;;
    esac
}
ensure_tool curl
ensure_tool jq

# ---------- BC-250 : dépôt pacman (Arch) ----------
if [[ "$OS" == "arch" && "$BC250" -eq 1 ]]; then
    if ! grep -q '^\[bc250-cachyos\]' /etc/pacman.conf; then
        log "Ajout du dépôt bc250-cachyos"
        cat >> /etc/pacman.conf <<'EOF'

[bc250-cachyos]
SigLevel = Optional TrustAll
Server = https://github.com/MastaG/linux-cachyos-bc250/releases/download/repo
EOF
    fi
    pacman -Sy --noconfirm
    # mesa patché + fan driver
    pacman -S --needed --noconfirm mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon || true
    echo nct6687 > /etc/modules-load.d/nct6687.conf
fi

# ---------- Téléchargement de la release ----------
log "Récupération de la dernière release GitHub"
ASSET_URL=""
case "$OS" in
    arch)
        ASSET_URL="$(curl -s "$API" | jq -r '.assets[] | select(.name | test("pkg\\.tar\\.zst$")) | .browser_download_url' | head -n1)"
        ;;
    debian)
        if [[ "$ARCH_NORM" == "arm64" ]]; then
            ASSET_URL="$(curl -s "$API" | jq -r '.assets[] | select(.name | test("_arm64\\.deb$")) | .browser_download_url' | head -n1)"
        else
            ASSET_URL="$(curl -s "$API" | jq -r '.assets[] | select(.name | test("_amd64\\.deb$")) | .browser_download_url' | head -n1)"
        fi
        ;;
esac

[[ -n "$ASSET_URL" && "$ASSET_URL" != "null" ]] || die "Aucun asset compatible trouvé dans la release."
info "Asset : $ASSET_URL"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
FILENAME="${TMPDIR}/$(basename "$ASSET_URL")"
log "Téléchargement..."
curl -fL -o "$FILENAME" "$ASSET_URL"

# ---------- Installation ----------
case "$OS" in
    arch)
        log "Installation via pacman"
        pacman -Sy --noconfirm
        pacman -U --noconfirm "$FILENAME"
        ;;
    debian)
        log "Installation via apt"
        apt-get update -qq
        apt-get install -y "$FILENAME" || { dpkg -i "$FILENAME"; apt-get -f install -y; }
        ;;
esac

# ---------- Utilisateur / groupes ----------
# trouver un utilisateur non-root avec home
TARGET_USER=""
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    TARGET_USER="$SUDO_USER"
else
    # premier utilisateur UID>=1000
    TARGET_USER="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)"
fi

if [[ -n "$TARGET_USER" ]]; then
    log "Configuration de l'utilisateur $TARGET_USER"
    for g in video audio input storage optical render; do
        getent group "$g" >/dev/null && usermod -aG "$g" "$TARGET_USER" 2>/dev/null || true
    done
    USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    mkdir -p "$USER_HOME/.config/emulationstation" \
             "$USER_HOME/.local/share/emulationstation" \
             "$USER_HOME/.cache/emulationstation" \
             "$USER_HOME/.local/state/emulationstation"
    # bashrc coloré
    cat > "$USER_HOME/.bashrc" <<'BASHRC'
# Couleurs et alias
alias ls="ls --color=auto"
alias ll="ls -la --color=auto"
alias grep="grep --color=auto"
alias ip="ip -color=auto"
if command -v eza >/dev/null 2>&1; then
    alias ls="eza --color=auto --icons"
    alias ll="eza -la --color=auto --icons"
fi
if command -v bat >/dev/null 2>&1; then
    alias cat="bat --paging=never"
fi
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
BASHRC
    chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/.bashrc"
    chown -R "$TARGET_USER:$TARGET_USER" "$USER_HOME/.config/emulationstation" \
        "$USER_HOME/.local/share/emulationstation" "$USER_HOME/.cache/emulationstation" \
        "$USER_HOME/.local/state/emulationstation" 2>/dev/null || true

    # xinitrc
    if [[ -f "$USER_HOME/.xinitrc" ]] || [[ ! -f "$USER_HOME/.xinitrc" ]]; then
        cat > "$USER_HOME/.xinitrc" <<'EOF'
exec /usr/local/bin/esre-session
EOF
        chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/.xinitrc"
    fi
fi

# ---------- Scripts helper ----------
log "Installation des scripts helper"
cat > /usr/local/bin/start-es.sh <<'EOF'
#!/usr/bin/env bash
# Lance EmulationStation-RE avec un environnement propre.
set -euo pipefail
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
exec /usr/bin/emulationstation "$@"
EOF
chmod +x /usr/local/bin/start-es.sh

# Session ES-RE avec gamescope (sans DE)
cat > /usr/local/bin/esre-session <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
if command -v gamescope >/dev/null 2>&1; then
    exec gamescope -e -- /usr/bin/emulationstation "$@"
else
    exec /usr/bin/emulationstation "$@"
fi
EOF
chmod +x /usr/local/bin/esre-session

mkdir -p /usr/share/xsessions
cat > /usr/share/xsessions/esre-session.desktop <<'EOF'
[Desktop Entry]
Name=ES-RE Session
Comment=EmulationStation-RE running under Gamescope
Exec=/usr/local/bin/esre-session
Type=Application
EOF

# wrapper de mise à jour manuelle (optionnel)
cat > /usr/local/bin/esre-selfupdate <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Utilisez le menu 'Updates & downloads > Check for updates' dans EmulationStation-RE."
echo "Ou relancez post_install.sh pour réinstaller la dernière release."
EOF
chmod +x /usr/local/bin/esre-selfupdate

# ---------- Paquets supplémentaires ----------
if [[ "$OS" == "arch" ]]; then
    # steam (x86_64 uniquement)
    if [[ "$ARCH_NORM" == "x86_64" ]]; then
        pacman -S --needed --noconfirm steam 2>/dev/null || true
    fi
    pacman -S --needed --noconfirm v4l-utils dolphin firefox 2>/dev/null || true

    if [[ "$BC250" -eq 1 ]]; then
        pacman -S --needed --noconfirm proton-cachyos-slr-bc250 bc250-dual-audio bc250-cec bc250-fixes 2>/dev/null || true

        # bc250-control-center (dernière release GitHub)
        CC_URL="$(curl -s "https://api.github.com/repos/movacx/bc250-control-center/releases/latest" | jq -r '.assets[] | select(.name | test("pkg\\\\.tar\\\\.zst$")) | .browser_download_url' | head -n1)"
        if [[ -n "$CC_URL" && "$CC_URL" != "null" ]]; then
            CC_FILE="${TMPDIR}/$(basename "$CC_URL")"
            if curl -fL -o "$CC_FILE" "$CC_URL" 2>/dev/null; then
                pacman -U --noconfirm "$CC_FILE" 2>/dev/null || true
            fi
        fi
    fi
elif [[ "$OS" == "debian" ]]; then
    if [[ "$ARCH_NORM" == "x86_64" ]]; then
        apt-get install -y steam 2>/dev/null || true
    fi
    apt-get install -y v4l-utils dolphin firefox 2>/dev/null || true
fi

# ---------- Service systemd (optionnel, désactivé par défaut) ----------
cat > /etc/systemd/system/emulationstation.service <<'EOF'
[Unit]
Description=EmulationStation-RE
After=graphical.target

[Service]
Type=simple
User=%i
Environment=DISPLAY=:0
ExecStart=/usr/local/bin/start-es.sh
Restart=on-failure

[Install]
WantedBy=graphical.target
EOF
# laissé désactivé ; l'autologin tty1 + startx est utilisé par défaut

# ---------- Snapshot btrfs ----------
if command -v snapper >/dev/null 2>&1; then
    log "Création d'un snapshot post-installation"
    snapper -c root create --description "Post-install EmulationStation-RE" --cleanup-algorithm number 2>/dev/null || true
fi

log "Installation d'EmulationStation-RE terminée."
info "Lancez 'startx' (ou redémarrez) pour démarrer EmulationStation-RE."
