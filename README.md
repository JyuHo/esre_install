# esre_install

Scripts d'installation pour **EmulationStation-RE** sur Arch Linux (x86_64) et Armbian/Debian (arm64).

## Contenu

- `pre_install.sh` — prépare l'installation d'Arch Linux à l'image d'Archinstall :
  partitionnement GPT, formatage btrfs avec subvolumes, pacstrap minimal,
  création de l'utilisateur et des mots de passe, bootloader systemd-boot,
  snapper + snapshot initial, installation uniquement des pilotes/firmware détectés.
  Si une **AMD BC-250** est détectée, le dépôt `bc250-cachyos` est ajouté et le
  kernel `linux-cachyos-bc250` est installé à la place du kernel standard.

- `post_install.sh` — installe EmulationStation-RE (dernière release GitHub) sur le
  système installé (Arch ou Armbian/Debian), ainsi que les scripts helper.

## Usage

Depuis l'ISO Arch (root) :

```bash
curl -fsSL https://raw.githubusercontent.com/JyuHo/esre_install/master/pre_install.sh -o pre_install.sh
chmod +x pre_install.sh
./pre_install.sh
```

Après redémarrage, sur le système installé (root) :

```bash
./post_install.sh
```

## Variables d'environnement (pre_install.sh)

`DISK`, `SWAP_SIZE`, `HOSTNAME`, `TIMEZONE`, `LANG`, `USERNAME`,
`USER_PASSWORD`, `ROOT_PASSWORD`, `BC250_FORCE`.
