#!/usr/bin/env bash
# pre_install.sh — Prépare l'installation d'Arch Linux pour EmulationStation-RE.
#
# À lancer depuis l'ISO Arch (root), à l'image d'Archinstall :
#   - partitionnement GPT (EFI + swap optionnel + root btrfs)
#   - formatage btrfs avec subvolumes (@, @home, @snapshots, @var_log)
#   - pacstrap d'un système minimal
#   - configuration (locale, timezone, hostname, users, mots de passe)
#   - bootloader systemd-boot
#   - snapper + snapshot initial
#   - installation uniquement des pilotes/firmware nécessaires (détection matérielle)
#   - si AMD BC-250 détectée : dépôt bc250-cachyos + kernel linux-cachyos-bc250
#
# Variables d'environnement optionnelles :
#   DISK=/dev/nvme0n1   TARGET_DISK (sinon sélection interactive)
#   SWAP_SIZE=4          taille du swap en Go (0 = pas de swap)
#   HOSTNAME=esre        TIMEZONE=Europe/Paris   LANG=fr_FR.UTF-8
#   USERNAME=gamer       USER_PASSWORD=...       ROOT_PASSWORD=...
#   BC250_FORCE=1        force le mode BC-250
set -euo pipefail

# ---------- Couleurs / log ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en root (depuis l'ISO Arch)."

# ---------- Détection matérielle ----------
detect_cpu_vendor() {
    if grep -qi 'GenuineIntel' /proc/cpuinfo; then echo intel
    elif grep -qi 'AuthenticAMD' /proc/cpuinfo; then echo amd
    else echo unknown; fi
}

detect_gpu() {
    # renvoie la liste des types GPU détectés (amd intel nvidia)
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
    # BC-250 : PCI 1002:13fe / 1002:143f, ou nom "BC-250"
    if lspci -nn 2>/dev/null | grep -qi 'BC-250\|BC250\|\[1002:13fe\]\|\[1002:143f\]'; then
        return 0
    fi
    # nom alternatif
    if lspci 2>/dev/null | grep -qi 'bc-250\|bc250'; then
        return 0
    fi
    return 1
}

CPU_VENDOR="$(detect_cpu_vendor)"
GPU_TYPES="$(detect_gpu)"
if is_bc250; then BC250=1; else BC250=0; fi

info "CPU vendor : $CPU_VENDOR"
info "GPU types  : $GPU_TYPES"
info "BC-250     : $BC250"

# ---------- Configuration ----------
DISK="${DISK:-${TARGET_DISK:-}}"
if [[ -z "$DISK" ]]; then
    echo
    lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -i disk
    echo
    read -rp "Disque cible (ex: /dev/sda, /dev/nvme0n1) : " DISK
fi
[[ -b "$DISK" ]] || die "Disque invalide : $DISK"

SWAP_SIZE="${SWAP_SIZE:-4}"
HOSTNAME="${HOSTNAME:-esre}"
TIMEZONE="${TIMEZONE:-Europe/Paris}"
LANG="${LANG:-fr_FR.UTF-8}"
USERNAME="${USERNAME:-gamer}"

if [[ -z "${USER_PASSWORD:-}" ]]; then
    read -rsp "Mot de passe utilisateur ($USERNAME) : " USER_PASSWORD; echo
fi
if [[ -z "${ROOT_PASSWORD:-}" ]]; then
    read -rsp "Mot de passe root : " ROOT_PASSWORD; echo
fi

echo
warn "Le disque $DISK va être EFFACÉ."
read -rp "Confirmer ? (oui/non) : " CONFIRM
[[ "$CONFIRM" == "oui" ]] || die "Annulé."

# ---------- Partitionnement ----------
log "Partitionnement GPT de $DISK"
sgdisk --zap-all "$DISK"

# EFI 512M
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
PAC_PKGS=(base base-devel btrfs-progs snapper snap-pac sudo networkmanager
           pipewire wireplumber pipewire-alsa pipewire-pulse alsa-utils
           xorg-server xorg-xinit git curl wget unzip
           reflector)

# microcode
case "$CPU_VENDOR" in
    amd) PAC_PKGS+=(amd-ucode) ;;
    intel) PAC_PKGS+=(intel-ucode) ;;
esac

# firmware de base
PAC_PKGS+=(linux-firmware)

# kernel : standard sauf BC-250
if [[ "$BC250" -eq 0 ]]; then
    PAC_PKGS+=(linux linux-headers)
fi

# pilotes GPU conditionnels
for g in $GPU_TYPES; do
    case "$g" in
        amd)
            PAC_PKGS+=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon)
            ;;
        intel)
            PAC_PKGS+=(mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver)
            ;;
        nvidia)
            PAC_PKGS+=(nvidia nvidia-utils lib32-nvidia-utils)
            ;;
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
EOF

# chroot script
cat > /mnt/tmp/chroot.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
source /tmp/install.env

# locale / timezone
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

# BC-250 : dépôt + kernel
if [[ "${BC250}" == "1" ]]; then
    if ! grep -q '^\[bc250-cachyos\]' /etc/pacman.conf; then
        cat >> /etc/pacman.conf <<'EOF'

[bc250-cachyos]
SigLevel = Optional TrustAll
Server = https://github.com/MastaG/linux-cachyos-bc250/releases/download/repo
EOF
    fi
    pacman -Sy --noconfirm
    pacman -S --needed --noconfirm linux-cachyos-bc250 linux-cachyos-bc250-headers
    # mesa patché depuis le dépôt
    pacman -S --needed --noconfirm mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon
    echo nct6687 > /etc/modules-load.d/nct6687.conf
    KERNEL_PKG="linux-cachyos-bc250"
else
    KERNEL_PKG="linux"
fi

# mot de passe root
echo "root:${ROOT_PASSWORD}" | chpasswd

# utilisateur
if ! id "${USERNAME}" &>/dev/null; then
    useradd -m -G wheel,video,audio,input,storage,optical,network -s /bin/bash "${USERNAME}"
fi
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# sudo pour wheel
if ! grep -q '^%wheel' /etc/sudoers; then
    echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers
fi

# hostname déjà fait

# bootloader systemd-boot
bootctl install
ROOT_UUID="$(blkid -s UUID -o value "${ROOT_PART}")"
if [[ "${BC250}" == "1" ]]; then
    VMLINUZ="/vmlinuz-linux-cachyos-bc250"
    INITRD="/initramfs-linux-cachyos-bc250.img"
else
    VMLINUZ="/vmlinuz-linux"
    INITRD="/initramfs-linux.img"
fi

# microcode
UCODE_INITRD=""
if [[ -f /boot/amd-ucode.img ]]; then UCODE_INITRD="/amd-ucode.img"; fi
if [[ -f /boot/intel-ucode.img ]]; then UCODE_INITRD="/intel-ucode.img"; fi

mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf <<EOF
default arch
timeout 3
console-mode max
editor no
EOF

{
  echo "title   Arch Linux"
  echo "linux   ${VMLINUZ}"
  [[ -n "$UCODE_INITRD" ]] && echo "initrd  ${UCODE_INITRD}"
  echo "initrd  ${INITRD}"
  echo "options root=UUID=${ROOT_UUID} rw rootflags=subvol=@ compress=zstd"
} > /boot/loader/entries/arch.conf

mkinitcpio -P

# snapper
if ! snapper list-configs 2>/dev/null | grep -q '^root'; then
    snapper -c root create-config /
fi
# autoriser l'utilisateur
sed -i "s/^ALLOW_USERS=\"\"/ALLOW_USERS=\"${USERNAME}\"/" /etc/snapper/configs/root || true
systemctl enable snapper-timeline.timer snapper-cleanup.timer

# réseau + pipewire user (socket) : rien à activer au niveau système
systemctl enable NetworkManager

# autologin tty1 + startx
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
cat > "${USER_HOME}/.xinitrc" <<'EOF'
exec /usr/local/bin/start-es.sh
EOF
mkdir -p "${USER_HOME}/.config" "${USER_HOME}/.local/share"
chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}"

# snapshot initial
snapper -c root create --description "Installation initiale" --cleanup-algorithm number || true

echo "CHROOT_DONE"
CHROOT

chmod +x /mnt/tmp/chroot.sh
log "Configuration dans le chroot"
arch-chroot /mnt /bin/bash /tmp/chroot.sh

# ---------- Nettoyage ----------
log "Démontage"
umount -R /mnt || true
if [[ "$SWAP_SIZE" -gt 0 ]]; then swapoff "$SWAP_PART" 2>/dev/null || true; fi

log "Installation de base terminée."
info "Redémarrez, puis lancez post_install.sh pour installer EmulationStation-RE."
info "Le script post_install.sh doit être copié sur le système installé (ex: /root ou clé USB)."
