#!/usr/bin/env bash
# pre_install.sh — Prépare l'installation d'Arch Linux pour EmulationStation-RE.
#
# Interface interactive (dialog) à l'image d'Archinstall :
#   - sélection du disque, saisie hostname/timezone/locale/utilisateur/mots de passe
#   - cases à cocher pour les options (swap, snapper, pipewire, Xorg, autologin, ...)
#   - partitionnement GPT, formatage btrfs + subvolumes, pacstrap minimal
#   - uniquement les pilotes/firmware nécessaires (détection matérielle)
#   - si AMD BC-250 détectée : dépôt bc250-cachyos + kernel linux-cachyos-bore-bc250
#   - bootloader Limine
#
# Variables d'environnement optionnelles (sautent les invites) :
#   DISK, SWAP_SIZE, HOSTNAME, TIMEZONE, LANG, USERNAME, USER_PASSWORD,
#   ROOT_PASSWORD, BC250_FORCE, NONINTERACTIVE=1
set -euo pipefail

# ---------- Couleurs / log ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en root (depuis l'ISO Arch)."

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ---------- Outils dialog ----------
USE_DIALOG=0
if command -v dialog >/dev/null 2>&1 && [[ -t 0 ]] && [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
    USE_DIALOG=1
fi

# fallback readline si pas de dialog
prompt() {
    local label="$1" default="${2:-}"
    local val
    if [[ $USE_DIALOG -eq 1 ]]; then
        dialog --inputbox "$label" 8 60 "$default" 2>"$TMPDIR/out" || true
        val="$(cat "$TMPDIR/out" 2>/dev/null || true)"
    else
        read -rp "$label [$default] : " val
        val="${val:-$default}"
    fi
    printf '%s' "$val"
}

prompt_password() {
    local label="$1"
    local val
    if [[ $USE_DIALOG -eq 1 ]]; then
        dialog --passwordbox "$label" 8 60 2>"$TMPDIR/out" || true
        val="$(cat "$TMPDIR/out" 2>/dev/null || true)"
    else
        read -rsp "$label : " val; echo >&2
    fi
    printf '%s' "$val"
}

msg() {
    if [[ $USE_DIALOG -eq 1 ]]; then
        dialog --msgbox "$1" 12 70
    else
        echo "$1"
    fi
}

confirm() {
    if [[ $USE_DIALOG -eq 1 ]]; then
        dialog --yesno "$1" 8 60
    else
        read -rp "$1 (oui/non) : " c
        [[ "$c" == "oui" ]]
    fi
}

# ---------- Détection matérielle ----------
detect_cpu_vendor() {
    if grep -qi 'GenuineIntel' /proc/cpuinfo; then echo intel
    elif grep -qi 'AuthenticAMD' /proc/cpuinfo; then echo amd
    else echo unknown; fi
}

detect_gpu() {
    local out=""
    if lspci 2>/dev/null | grep -qi 'VGA\|3D\|Display'; then
        lspci 2>/dev/null | grep -i 'VGA\|3D\|Display' | grep -qi 'AMD\|ATI\|Radeon' && out+="amd "
        lspci 2>/dev/null | grep -i 'VGA\|3D\|Display' | grep -qi 'Intel' && out+="intel "
        lspci 2>/dev/null | grep -i 'VGA\|3D\|Display' | grep -qi 'NVIDIA' && out+="nvidia "
    fi
    echo "${out:-unknown}"
}

is_bc250() {
    if [[ "${BC250_FORCE:-0}" == "1" ]]; then return 0; fi
    if lspci -nn 2>/dev/null | grep -qi 'BC-250\|BC250\|\[1002:13fe\]\|\[1002:143f\]'; then return 0; fi
    if lspci 2>/dev/null | grep -qi 'bc-250\|bc250'; then return 0; fi
    return 1
}

CPU_VENDOR="$(detect_cpu_vendor)"
GPU_TYPES="$(detect_gpu)"
if is_bc250; then BC250=1; else BC250=0; fi

# ---------- Écran d'accueil ----------
if [[ $USE_DIALOG -eq 1 ]]; then
    dialog --msgbox "EmulationStation-RE — Installation Arch Linux\n\nCPU : ${CPU_VENDOR}\nGPU : ${GPU_TYPES}\nBC-250 : ${BC250}\n\nAppuyez sur OK pour continuer." 12 60
fi

# ---------- Sélection du disque ----------
if [[ -z "${DISK:-}" ]]; then
    # construire la liste des disques
    if [[ $USE_DIALOG -eq 1 ]]; then
        disk_opts=()
        while read -r name size model; do
            disk_opts+=("/dev/$name" "$size $model")
        done < <(lsblk -d -n -o NAME,SIZE,MODEL | grep -v '^loop')
        dialog --menu "Choisir le disque cible" 18 70 10 "${disk_opts[@]}" 2>"$TMPDIR/disk" || true
        DISK="$(cat "$TMPDIR/disk" 2>/dev/null || true)"
    else
        echo "Disques disponibles :"; lsblk -d -o NAME,SIZE,MODEL
        DISK="$(prompt "Disque cible (ex: /dev/sda)" "")"
    fi
fi
[[ -b "$DISK" ]] || die "Disque invalide : $DISK"

# ---------- Options (cases à cocher) ----------
# valeurs par défaut
# swap par défaut : 16 Go pour BC-250, 4 Go sinon
if [[ -z "${SWAP_SIZE:-}" ]]; then
    if [[ "${BC250:-0}" == "1" ]]; then SWAP_SIZE=16; else SWAP_SIZE=4; fi
fi
HOSTNAME="${HOSTNAME:-esre}"
TIMEZONE="${TIMEZONE:-Europe/Paris}"
LANG="${LANG:-fr_FR.UTF-8}"
USERNAME="${USERNAME:-gamer}"
SNAPPER_OPT=1; AUTOLOGIN_OPT=1; PIPEWIRE_OPT=1; XORG_OPT=1; NETWORK_OPT=1; REFLECTOR_OPT=0

if [[ $USE_DIALOG -eq 1 ]]; then
    dialog --checklist "Options à installer" 18 70 8 \
        SWAP "Partition swap (${SWAP_SIZE} Go)" on \
        SNAPPER "Snapper + snapshots (btrfs)" on \
        AUTOLOGIN "Autologin tty1 + startx" on \
        PIPEWIRE "Pipewire (audio)" on \
        XORG "Serveur Xorg" on \
        NETWORK "NetworkManager" on \
        REFLECTOR "Reflector (miroirs)" off \
        2>"$TMPDIR/opts" || true
    OPTS="$(cat "$TMPDIR/opts" 2>/dev/null || true)"
    # swap toggle
    echo "$OPTS" | grep -q SWAP || SWAP_SIZE=0
    echo "$OPTS" | grep -q SNAPPER || SNAPPER_OPT=0
    echo "$OPTS" | grep -q AUTOLOGIN || AUTOLOGIN_OPT=0
    echo "$OPTS" | grep -q PIPEWIRE || PIPEWIRE_OPT=0
    echo "$OPTS" | grep -q XORG || XORG_OPT=0
    echo "$OPTS" | grep -q NETWORK || NETWORK_OPT=0
    echo "$OPTS" | grep -q REFLECTOR || REFLECTOR_OPT=0
else
    # mode texte : questions simples
    read -rp "Activer snapper ? (o/n) [o] : " v; [[ "${v:-o}" == "o" ]] || SNAPPER_OPT=0
    read -rp "Autologin ? (o/n) [o] : " v; [[ "${v:-o}" == "o" ]] || AUTOLOGIN_OPT=0
fi

# ---------- Saisie des données ----------
HOSTNAME="$(prompt "Hostname" "$HOSTNAME")"
TIMEZONE="$(prompt "Timezone (ex: Europe/Paris)" "$TIMEZONE")"
LANG="$(prompt "Locale (ex: fr_FR.UTF-8)" "$LANG")"
USERNAME="$(prompt "Nom d'utilisateur" "$USERNAME")"
if [[ -z "${USER_PASSWORD:-}" ]]; then USER_PASSWORD="$(prompt_password "Mot de passe utilisateur ($USERNAME)")"; fi
if [[ -z "${ROOT_PASSWORD:-}" ]]; then ROOT_PASSWORD="$(prompt_password "Mot de passe root")"; fi

if [[ $SWAP_SIZE -gt 0 ]]; then
    v="$(prompt "Taille du swap en Go (0 = désactivé)" "$SWAP_SIZE")"
    SWAP_SIZE="${v:-$SWAP_SIZE}"
fi

# ---------- Confirmation ----------
SUMMARY="Disque : $DISK
Swap : ${SWAP_SIZE} Go
Hostname : $HOSTNAME
Timezone : $TIMEZONE
Locale : $LANG
Utilisateur : $USERNAME
BC-250 : $BC250
Options : snapper=$SNAPPER_OPT autologin=$AUTOLOGIN_OPT pipewire=$PIPEWIRE_OPT xorg=$XORG_OPT network=$NETWORK_OPT"
if ! confirm "Confirmer l'installation ?\n\n$SUMMARY"; then
    die "Annulé par l'utilisateur."
fi

# ---------- Partitionnement ----------
log "Partitionnement GPT de $DISK"
sgdisk --zap-all "$DISK"

sgdisk -n 1:0:+512M -t 1:ef00 -c 1:EFI "$DISK"

PART_NO=2
if [[ "$SWAP_SIZE" -gt 0 ]]; then
    sgdisk -n "${PART_NO}":0:+${SWAP_SIZE}G -t "${PART_NO}":8200 -c "${PART_NO}":swap "$DISK"
    SWAP_PART="${DISK}$( [[ "$DISK" =~ nvme|mmcblk ]] && echo p )${PART_NO}"
    PART_NO=$((PART_NO+1))
fi

sgdisk -n "${PART_NO}":0:0 -t "${PART_NO}":8300 -c "${PART_NO}":root "$DISK"
ROOT_PART="${DISK}$( [[ "$DISK" =~ nvme|mmcblk ]] && echo p )${PART_NO}"
EFI_PART="${DISK}$( [[ "$DISK" =~ nvme|mmcblk ]] && echo p )1"

# ---------- Formatage ----------
log "Formatage EFI (FAT32)"
mkfs.fat -F32 -n EFI "$EFI_PART"

if [[ "$SWAP_SIZE" -gt 0 ]]; then
    log "Formatage swap"
    mkswap -L swap "$SWAP_PART"
    swapon "$SWAP_PART"
fi

log "Formatage btrfs (root)"
mkfs.btrfs -L root -f "$ROOT_PART"

# ---------- Subvolumes ----------
log "Création des subvolumes btrfs"
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
umount /mnt

BTRFS_OPTS="rw,noatime,compress=zstd:3,space_cache=v2"
mount -o "${BTRFS_OPTS},subvol=@" "$ROOT_PART" /mnt
mkdir -p /mnt/{home,.snapshots,var/log,boot}
mount -o "${BTRFS_OPTS},subvol=@home" "$ROOT_PART" /mnt/home
mount -o "${BTRFS_OPTS},subvol=@snapshots" "$ROOT_PART" /mnt/.snapshots
mount -o "${BTRFS_OPTS},subvol=@var_log" "$ROOT_PART" /mnt/var/log
mount "$EFI_PART" /mnt/boot

# ---------- Pacstrap ----------
log "Installation du système de base (pacstrap)"
PAC_PKGS=(base base-devel btrfs-progs sudo)
[[ $SNAPPER_OPT -eq 1 ]] && PAC_PKGS+=(snapper snap-pac)
[[ $NETWORK_OPT -eq 1 ]] && PAC_PKGS+=(networkmanager)
if [[ $PIPEWIRE_OPT -eq 1 ]]; then
    PAC_PKGS+=(pipewire wireplumber pipewire-alsa pipewire-pulse alsa-utils)
fi
if [[ $XORG_OPT -eq 1 ]]; then
    PAC_PKGS+=(xorg-server xorg-xinit)
fi
PAC_PKGS+=(git curl wget unzip limine efibootmgr)

[[ $REFLECTOR_OPT -eq 1 ]] && PAC_PKGS+=(reflector)

case "$CPU_VENDOR" in
    amd) PAC_PKGS+=(amd-ucode) ;;
    intel) PAC_PKGS+=(intel-ucode) ;;
esac

PAC_PKGS+=(linux-firmware)

if [[ "$BC250" -eq 0 ]]; then
    PAC_PKGS+=(linux linux-headers)
fi

for g in $GPU_TYPES; do
    case "$g" in
        amd) PAC_PKGS+=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon) ;;
        intel) PAC_PKGS+=(mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver) ;;
        nvidia) PAC_PKGS+=(nvidia nvidia-utils lib32-nvidia-utils) ;;
    esac
done

pacstrap -K /mnt "${PAC_PKGS[@]}"

# ---------- fstab ----------
genfstab -U /mnt >> /mnt/etc/fstab

# ---------- Fichiers d'install pour le chroot ----------
mkdir -p /mnt/tmp
cat > /mnt/tmp/install.env <<EOF
export HOSTNAME=$(printf '%q' "$HOSTNAME")
export TIMEZONE=$(printf '%q' "$TIMEZONE")
export LANG=$(printf '%q' "$LANG")
export USERNAME=$(printf '%q' "$USERNAME")
export USER_PASSWORD=$(printf '%q' "$USER_PASSWORD")
export ROOT_PASSWORD=$(printf '%q' "$ROOT_PASSWORD")
export CPU_VENDOR=$(printf '%q' "$CPU_VENDOR")
export GPU_TYPES=$(printf '%q' "$GPU_TYPES")
export BC250=$BC250
export EFI_PART=$(printf '%q' "$EFI_PART")
export ROOT_PART=$(printf '%q' "$ROOT_PART")
export DISK=$(printf '%q' "$DISK")
export SNAPPER_OPT=$SNAPPER_OPT
export AUTOLOGIN_OPT=$AUTOLOGIN_OPT
export PIPEWIRE_OPT=$PIPEWIRE_OPT
export XORG_OPT=$XORG_OPT
export NETWORK_OPT=$NETWORK_OPT
EOF

cat > /mnt/tmp/chroot.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
source /tmp/install.env

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
grep -q "^${LANG}" /etc/locale.gen || echo "${LANG} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LANG}" > /etc/locale.conf

echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

if [[ "${BC250}" == "1" ]]; then
    if ! grep -q '^\[bc250-cachyos\]' /etc/pacman.conf; then
        cat >> /etc/pacman.conf <<'EOF'

[bc250-cachyos]
SigLevel = Optional TrustAll
Server = https://github.com/MastaG/linux-cachyos-bc250/releases/download/repo
EOF
    fi
    pacman -Sy --noconfirm
    pacman -S --needed --noconfirm linux-cachyos-bore-bc250 linux-cachyos-bore-bc250-headers
    pacman -S --needed --noconfirm mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon
    echo nct6687 > /etc/modules-load.d/nct6687.conf
fi

echo "root:${ROOT_PASSWORD}" | chpasswd

if ! id "${USERNAME}" &>/dev/null; then
    useradd -m -G wheel,video,audio,input,storage,optical,network -s /bin/bash "${USERNAME}"
fi
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

if ! grep -q '^%wheel' /etc/sudoers; then
    echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers
fi

# snapper
if [[ "${SNAPPER_OPT}" == "1" ]]; then
    if ! snapper list-configs 2>/dev/null | grep -q '^root'; then
        snapper -c root create-config /
    fi
    sed -i "s/^ALLOW_USERS=\"\"/ALLOW_USERS=\"${USERNAME}\"/" /etc/snapper/configs/root || true
    systemctl enable snapper-timeline.timer snapper-cleanup.timer
fi

[[ "${NETWORK_OPT}" == "1" ]] && systemctl enable NetworkManager

ROOT_UUID="$(blkid -s UUID -o value "${ROOT_PART}")"
if [[ "${BC250}" == "1" ]]; then
    VMLINUZ="/vmlinuz-linux-cachyos-bore-bc250"
    INITRD="/initramfs-linux-cachyos-bore-bc250.img"
else
    VMLINUZ="/vmlinuz-linux"
    INITRD="/initramfs-linux.img"
fi

UCODE_INITRD=""
if [[ -f /boot/amd-ucode.img ]]; then UCODE_INITRD="/amd-ucode.img"; fi
if [[ -f /boot/intel-ucode.img ]]; then UCODE_INITRD="/intel-ucode.img"; fi

{
    echo "timeout: 3"
    echo
    echo "/Arch Linux"
    echo "    protocol: linux"
    echo "    kernel_path: boot():${VMLINUZ}"
    if [[ -n "$UCODE_INITRD" ]]; then
        echo "    initrd_path: boot():${UCODE_INITRD}"
    fi
    echo "    initrd_path: boot():${INITRD}"
    if [[ "${BC250}" == "1" ]]; then
        CMDLINE="root=UUID=${ROOT_UUID} rw rootflags=subvol=@ compress=zstd zswap.enabled=1 zswap.compressor=zstd zswap.zpool=zsmalloc"
    else
        CMDLINE="root=UUID=${ROOT_UUID} rw rootflags=subvol=@ compress=zstd"
    fi
    echo "    cmdline: ${CMDLINE}"
} > /boot/limine.conf

mkinitcpio -P

if [[ -d /sys/firmware/efi ]]; then
    mkdir -p /boot/EFI/limine
    install -Dm644 /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/BOOTX64.EFI
    efibootmgr 2>/dev/null | grep -i limine | sed -E 's/^Boot([0-9A-Fa-f]+).*/\1/' | while read -r _id; do
        efibootmgr -b "$_id" -B >/dev/null 2>&1 || true
    done
    efibootmgr --create --disk "${DISK}" --part 1 --label "Limine" \
        --loader '\EFI\limine\BOOTX64.EFI' --unicode >/dev/null 2>&1 || true
else
    if [[ -f /usr/share/limine/limine-bios.sys ]]; then
        cp -f /usr/share/limine/limine-bios.sys /boot/limine-bios.sys
    fi
    if command -v limine-install >/dev/null 2>&1; then
        limine-install "${DISK}" >/dev/null 2>&1 || true
    elif [[ -x /usr/bin/limine-install ]]; then
        /usr/bin/limine-install "${DISK}" >/dev/null 2>&1 || true
    fi
fi

# autologin
if [[ "${AUTOLOGIN_OPT}" == "1" ]]; then
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin ${USERNAME} %I \$TERM
EOF
    USER_HOME="/home/${USERNAME}"
    cat > "${USER_HOME}/.bash_profile" <<'EOF'
[[ -z $DISPLAY && $XDG_VTNR -eq 1 ]] && exec startx
EOF
    if [[ "${XORG_OPT}" == "1" ]]; then
        cat > "${USER_HOME}/.xinitrc" <<'EOF'
exec /usr/local/bin/start-es.sh
EOF
    fi
    chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}"
fi

if [[ "${SNAPPER_OPT}" == "1" ]]; then
    snapper -c root create --description "Installation initiale" --cleanup-algorithm number || true
fi

echo "CHROOT_DONE"
CHROOT

chmod +x /mnt/tmp/chroot.sh
log "Configuration dans le chroot"
arch-chroot /mnt /bin/bash /tmp/chroot.sh

log "Démontage"
umount -R /mnt || true
if [[ "$SWAP_SIZE" -gt 0 ]]; then swapoff "$SWAP_PART" 2>/dev/null || true; fi

log "Installation de base terminée."
info "Redémarrez, puis lancez post_install.sh pour installer EmulationStation-RE."