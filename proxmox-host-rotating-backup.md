Hier is een kant-en-klare **README.md** voor je script. Plak ‘m naast het script in dezelfde map.

---

# Proxmox Host Rotating Backup

Bash-script voor **roterende host-back-ups** op Proxmox-servers met ondersteuning voor:

* **Wekelijks / Maandelijks / Halfjaarlijks** (ZFS & LVM)
* **ZFS snapshots + zfs send**
* **LVM snapshots + partclone** (alleen gebruikte blokken) met fallback naar `dd`
* **Bare-metal full-disk** als **sparse .img → .xz** (klein op schijf)
* **Checksums** (b3sum of sha256) + **verify**
* **Cleanup** (partials/lege files, quarantining bij mismatch, stale snapshots)
* **Handmatige snapshots** & dumps
* **Auto-install** van `pigz`, `partclone` en `xz` (apt/dnf/yum/zypper/pacman)

> ⚠️ Script draait met `set -euo pipefail` en hoort als **root** uitgevoerd te worden.

---

## Inhoud

* [Kenmerken](#kenmerken)
* [Wat wordt er geback-upt?](#wat-wordt-er-geback-upt)
* [Vereisten & Auto-install](#vereisten--auto-install)
* [Installatie](#installatie)
* [Configuratie](#configuratie)
* [Gebruik](#gebruik)
* [Opties](#opties)
* [Retentie & Opslaglocaties](#retentie--opslaglocaties)
* [Checksums, Verify & Cleanup](#checksums-verify--cleanup)
* [Kalenderlogica (standaard run)](#kalenderlogica-standaard-run)
* [Herstellen (restore)](#herstellen-restore)
* [Planning (cron/systemd)](#planning-cronsystemd)
* [Troubleshooting](#troubleshooting)
* [Veiligheidstips](#veiligheidstips)

---

## Kenmerken

* **Extreem betrouwbaar**: single-instance lock, atomisch wegschrijven, checksums.
* **Snel & compact**:

  * ZFS: `zfs send -c` (compressed stream).
  * LVM (ext4/xfs): `partclone` (alleen gebruikte blokken).
  * Full-disk: sparse `.img` + `xz` (compacte archieven).
* **Schoonhouden**: retentie per map, `.part`/lege bestanden weg, corrupt → quarantine.
* **Self-test**: snelle integriteits- en omgevingscheck.

---

## Wat wordt er geback-upt?

* **Weekly (S)**

  * ZFS: snapshot + `zfs send` naar `weekly/*.zfs.gz`.
  * LVM (ext4/xfs): **LVM-snapshot → partclone stream** naar `weekly/*.img.gz` (dd fallback).
* **Monthly (M) / Semiannual (H)**

  * ZFS: snapshot + `zfs send` naar `monthly|semiannual/*.zfs.gz`.
  * Niet-ZFS: **full-disk** image: sparse `.img` → `.img.xz` naar `monthly|semiannual/`.

> Let op: Weekly LVM dumps heten `*.img.gz` maar bevatten bij partclone een **partclone-stream** (niet raw). Zie [Herstellen](#herstellen-restore).

---

## Vereisten & Auto-install

Het script probeert automatisch te installeren (indien root + bekende package manager):

* **pigz** (snelle gzip)
* **partclone** (`partclone.extfs`, `partclone.xfs`)
* **xz** (voor full-disk `.img.xz`)

Fallbacks:

* Geen pigz → **gzip**
* Geen partclone → **dd** voor LVM-dumps
* Geen xz → compressie van full-disk raw via pigz/gzip (`.img.gz`)

---

## Installatie

1. Plaats het script als root:

```bash
install -m 0755 proxmox-host-rotating-backup.sh /usr/local/bin/proxmox-host-rotating-backup.sh
```

2. Maak de doelmappen aan (het script doet dit ook zelf bij run):

```bash
mkdir -p /mnt/pve/BackupHD/HDproxmox-host/{weekly,monthly,semiannual,manual,quarantine}
```

3. (Optioneel) test:

```bash
sudo /usr/local/bin/proxmox-host-rotating-backup.sh --self-test
```

---

## Configuratie

Bovenin het script:

```bash
BASE_DIR="/mnt/pve/BackupHD/HDproxmox-host"
RETENTION_WEEKLY=6
RETENTION_MONTHLY=6
RETENTION_SEMIANNUAL=2
RETENTION_MANUAL=12
LVM_SNAP_SIZE="10G"
ZFS_ROOT_DATASET_DEFAULT="rpool/ROOT/pve-1"
LOG_FILE="/var/log/proxmox-host-rotating-backup.log"
```

Auto-install toggles:

```bash
AUTO_INSTALL_PKGS=true
AUTO_INSTALL_UPDATE=true
```

---

## Gebruik

Help:

```bash
sudo proxmox-host-rotating-backup.sh -h
```

Standaard run:

```bash
sudo proxmox-host-rotating-backup.sh
```

Forceer type:

```bash
sudo proxmox-host-rotating-backup.sh --force S
sudo proxmox-host-rotating-backup.sh --force M
sudo proxmox-host-rotating-backup.sh --force H
```

Cleanup/verify/self-test:

```bash
sudo proxmox-host-rotating-backup.sh --cleanup
sudo proxmox-host-rotating-backup.sh --verify
sudo proxmox-host-rotating-backup.sh --self-test
```

Handmatige snapshot/dump:

```bash
# Alleen snapshot (blijft staan)
sudo proxmox-host-rotating-backup.sh --snapshot-only [NAAM]

# Snapshot + dump naar BASE_DIR/manual (snapshot blijft staan)
sudo proxmox-host-rotating-backup.sh --snapshot [NAAM]

# Snapshot verwijderen (ZFS of LVM)
sudo proxmox-host-rotating-backup.sh --snapshot-delete <naam-of-pool/ds@naam>
```

---

## Opties

* `-h, --help` — Toon hulptekst
* `--force {S|M|H|weekly|monthly|semiannual}` — Forceer specifiek back-uptype

  * **M/H** draaien **eerst S**, daarna **M/H**
* `--cleanup` — Alleen opschonen (geen nieuwe back-ups)
* `--verify` — Controleer checksums voor `*.gz` en `*.xz` (exit 1 bij mismatch)
* `--self-test` — Snelle omgevingscheck (geen back-ups)
* `--snapshot-only [NAAM]` — Alleen snapshot maken en **laten staan**
* `--snapshot [NAAM]` — Snapshot + dump naar `manual/` (snapshot blijft staan)
* `--snapshot-delete <NAAM>` — Verwijder snapshot (ZFS/LVM)

---

## Retentie & Opslaglocaties

```
BASE_DIR/
  weekly/       (bewaar: RETENTION_WEEKLY)
  monthly/      (bewaar: RETENTION_MONTHLY)
  semiannual/   (bewaar: RETENTION_SEMIANNUAL)
  manual/       (bewaar: RETENTION_MANUAL)
  quarantine/   (corrupt/mismatch)
```

Bestanden:

* ZFS: `*-zfs-<TYPE>-YYYY-MM-DD.zfs.gz`
* LVM weekly: `*-lvm-S-YYYY-MM-DD.img.gz` (**partclone stream** bij ext4/xfs; anders raw dd)
* Full-disk: `*-disk-<TYPE>-YYYY-MM-DD.img.xz` (raw disk image gecomprimeerd met xz)

Bij retentie worden oude archieven + bijbehorende `.b3`/`.sha256` verwijderd.

---

## Checksums, Verify & Cleanup

* Bij elk nieuw archief wordt een checksum aangemaakt: **`*.b3`** (BLAKE3) of anders **`*.sha256`**.
* `--verify` telt, controleert en meldt mismatches.
* `--cleanup`:

  * verwijdert `*.part` en 0-byte files,
  * verplaatst corrupt/mismatch naar `quarantine/`,
  * ruimt **stale snapshots** op met bekende naamgeving (`rootsnap-*`, `S/M/H-YYYY-MM-DD`).

---

## Kalenderlogica (standaard run)

Zonder `--force`:

1. **Halfjaarlijks** (januari/juli) — **eerste run** van die maand: **S** + **H**
2. **Laatste week van de maand**: **S** + **M**
3. **Overig**: alleen **S**

*Na elke stap: retentie + cleanup.*

---

## Herstellen (restore)

> Test je restore-stappen vóór je ze in productie nodig hebt!

### ZFS (bestanden `*.zfs.gz`)

```bash
zcat /pad/naar/file.zfs.gz | zfs receive -F pool/dataset
# of: gzip -dc file.zfs.gz | zfs recv -F pool/dataset
```

### LVM weekly (bestanden `*.img.gz`)

* **partclone-stream** (ext4/xfs):

  ```bash
  # Creeër target LV (minstens even groot)
  lvcreate -L <size> -n <lvname> <vg>

  # Restore:
  gzip -dc /pad/naar/file.img.gz | partclone.extfs -r -s - -o /dev/<vg>/<lv>
  # of bij xfs:
  gzip -dc /pad/naar/file.img.gz | partclone.xfs  -r -s - -o /dev/<vg>/<lv>
  ```
* **dd-fallback** (indien partclone niet gebruikt werd):

  ```bash
  gzip -dc /pad/naar/file.img.gz | dd of=/dev/<vg>/<lv> bs=64M status=progress
  ```

> Weet je niet of het partclone of dd was? Kijk in je **log** of probeer `partclone.* -I -s <(zcat file.img.gz)`; bij mislukken gebruik je dd.

### Full-disk (bestanden `*.img.xz`)

Raw disk image inclusief MBR/GPT + partities:

```bash
xz -dc --sparse /pad/naar/disk-*.img.xz | dd of=/dev/sdX bs=64M status=progress
sync
```

---

## Planning (cron/systemd)

**Cron (root)** – wekelijkse run (zondag 03:00):

```
0 3 * * 0 /usr/local/bin/proxmox-host-rotating-backup.sh >> /var/log/proxmox-host-rotating-backup.log 2>&1
```

**Systemd timer** (indicatief): maak een `.service` met ExecStart op het script, plus een `.timer` die bijv. wekelijks triggert.

---

## Troubleshooting

* **`lvcreate snapshot mislukt`**
  Onvoldoende vrije ruimte in VG. Verhoog `LVM_SNAP_SIZE` of maak VG-ruimte vrij. Het script checkt dit vooraf.
* **`zfs send mislukt`**
  Controleer dataset-naam (config `ZFS_ROOT_DATASET_DEFAULT`), permissies en vrije ruimte op doel.
* **`partclone.* niet gevonden`**
  Auto-install zou ‘m moeten ophalen; anders `apt install partclone` (of dnf/yum/zypper/pacman).
* **`xz` ontbreekt**
  Script valt terug op `pigz/gzip` (bestand eindigt dan op `.img.gz`). Installeer `xz-utils` (apt) of `xz`.
* **`tdir: unbound variable` in self-test**
  Is verholpen in deze versie (variabelen gescheiden toegewezen).

Logs: `/var/log/proxmox-host-rotating-backup.log`
Lockfile: `/var/lock/proxmox-host-rotating-backup.lock`

---

## Veiligheidstips

* Draai als **root** en zorg voor **voldoende ruimte/bandbreedte** op je back-uplocatie.
* Voor consistente snapshots van **/ (root)** op LVM: gebruik de ingebouwde **LVM-snapshot** route (weekly/`--snapshot`).
* Full-disk restores **overschrijven** de volledige schijf (`/dev/sdX`). Wees 100% zeker van het doeldevice.
* Test je **restore** regelmatig!


