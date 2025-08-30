Proxmox Host Restore Wizard

Interactieve wizard om host-back-ups terug te zetten die zijn gemaakt met proxmox-host-rotating-backup.sh.

Ondersteunt:

ZFS streams: *.zfs.gz → zfs receive

LVM/partitie-images: *.img.gz → probeert partclone (ext4/xfs), anders dd

Volledige schijf-images: *.img.xz (of *.img.gz) → dd naar hele disk

Bevat dry-run‐modus (geen wijzigingen; toont alleen wat er zou gebeuren).

Inhoud

Features

Vereisten

Installatie

Standaardpaden

Gebruik

Hoe de wizard kiest

Voorbeelden

Veiligheid & checksums

Probleemoplossing

Opmerkingen

Features

Interactieve selectie van een back-up uit weekly/, monthly/, semiannual/, manual/

Dry-run: --dry-run toont alle geplande commando’s, doet niets destructiefs

Automatische detectie van partclone-streams (ext4/xfs)

Controle op mounts en (optioneel) automatisch ontkoppelen (in echte modus)

Checksumcontrole (indien .b3/.sha256 aanwezig)

Strenge bevestiging bij full-disk restores

Uitgebreide logging: /var/log/proxmox-host-restore.log

Vereisten

Back-ups staan onder één basispad (standaard: /mnt/pve/BackupHD/HDproxmox-host)

Tools:

Altijd: bash, gzip, coreutils (dd, lsblk), findmnt

Voor ZFS: zfs

Voor LVM restores (optioneel, voor info): lvm2 (lvs)

Voor partclone-restores: partclone.extfs (ext4) / partclone.xfs (xfs)

Voor *.img.xz: xz

Voor checksums (optioneel): b3sum of sha256sum

Root is vereist voor echte restore (dry-run kan zonder)

Installatie

Sla het script op:

sudo install -m 0755 proxmox-host-restore-wizard.sh /usr/local/bin/proxmox-host-restore-wizard.sh


(Optioneel) Zet omgeving:

export BASE_DIR=/mnt/pve/BackupHD/HDproxmox-host
export LOG_FILE=/var/log/proxmox-host-restore.log

Standaardpaden

BASE_DIR: /mnt/pve/BackupHD/HDproxmox-host

De wizard zoekt in:

$BASE_DIR/{weekly,monthly,semiannual,manual}/*.{zfs.gz,img.gz,img.xz}


LOG_FILE: /var/log/proxmox-host-restore.log

Je kunt deze via environment variabelen overschrijven:

BASE_DIR=/mijn/pad LOG_FILE=/var/log/restore.log proxmox-host-restore-wizard.sh

Gebruik

Basis:

# Interactieve wizard (echte restore, root vereist)
sudo proxmox-host-restore-wizard.sh


Hulp en simulatie:

proxmox-host-restore-wizard.sh --help
proxmox-host-restore-wizard.sh --dry-run


De wizard toont een lijst met back-ups, jij kiest een nummer en volgt de vragen.

Hoe de wizard kiest

*.zfs.gz → zfs receive -F naar door jou opgegeven dataset

*.img.gz:

Probeert te detecteren of het een partclone-stream is

Bij partclone: vraagt doel block device (LV/partitie) en gebruikt partclone.extfs of partclone.xfs

Zo niet: RAW restore met dd naar block device

*.img.xz → hele schijf via dd (zeer destructief; dubbele bevestiging)

Mounts op het doelsysteem worden gedetecteerd. In echte modus kun je automatisch ontkoppelen; in dry-run wordt alleen gemeld wat zou gebeuren.

Voorbeelden

Dry-run (niets wordt uitgevoerd):

proxmox-host-restore-wizard.sh --dry-run


ZFS-restore (je kiest daarna het bestand en dataset):

sudo proxmox-host-restore-wizard.sh
# Kies *.zfs.gz
# Voer bv. pool/ROOT/pve-1 in als target dataset


LVM/partitie-restore met partclone:

sudo proxmox-host-restore-wizard.sh
# Kies *.img.gz (partclone-stream)
# Kies target bv. /dev/pve/root


Volledige schijf-restore:

sudo proxmox-host-restore-wizard.sh
# Kies *.img.xz
# Kies target bv. /dev/sdb (complete disk)
# Dubbele bevestiging vereist

Veiligheid & checksums

Als een *.b3 of *.sha256 naast het archief staat, wordt deze gecontroleerd.

Geen checksum aanwezig? Dan gaat de wizard verder met waarschuwing.

Volledige schijf-restores vereisen bewuste dubbele bevestiging (type de device-naam exact).

In dry-run worden nooit umounts of writes gedaan; je ziet alleen de commando’s.

Probleemoplossing

“Geen back-ups gevonden”: controleer BASE_DIR en submappen/uitbreidingen.

“Tool ontbreekt”: installeer de gemelde tool (bv. apt install zfsutils-linux, apt install partclone, apt install xz-utils).

“Doel is aangekoppeld”: unmount handmatig of laat de wizard (echte modus) dit doen.

“Checksum mismatch”: gebruik een ander bestand of herstel de integriteit; forceer nooit restores met corrupte back-ups.

“Geen root”: draai met sudo (behalve bij --dry-run).

Opmerkingen

De wizard is bedoeld voor back-ups die met proxmox-host-rotating-backup.sh zijn gemaakt.

Partclone wordt alleen gebruikt voor ext4/xfs partities; anders valt de wizard terug op dd.

Voor ZFS wordt zfs receive -F gebruikt (kan bestaande snapshots onder de target overschrijven).
