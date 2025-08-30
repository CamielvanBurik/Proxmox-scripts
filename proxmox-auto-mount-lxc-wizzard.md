# TrueNAS NFS Mount Wizard (Proxmox LXC)

Een interactieve **host-wizard** om in één keer NFS-mounts te configureren voor één of meerdere **Proxmox LXC** containers. Je krijgt eerst prompts voor **NAS\_HOST**, **REMOTE\_PATH** en **MOUNTPOINT**, daarna kies je de **CTID(s)** die de mount moeten krijgen. De wizard kan ook **binnen een LXC** draaien (dan configureert hij alleen die container).

---

## Inhoudsopgave

* [Wat doet deze wizard?](#wat-doet-deze-wizard)
* [Vereisten](#vereisten)
* [Installatie](#installatie)
* [Gebruik](#gebruik)
* [Wat wordt er aangepast?](#wat-wordt-er-aangepast)
* [Instellingen & omgevingsvariabelen](#instellingen--omgevingsvariabelen)
* [Bevestigen dat het werkt](#bevestigen-dat-het-werkt)
* [Troubleshooting](#troubleshooting)
* [Veiligheid & best practices](#veiligheid--best-practices)
* [Verwijderen / rollback](#verwijderen--rollback)

---

## Wat doet deze wizard?

* **Vraagt interactief** om:

  * `NAS_HOST` (IP/hostname van TrueNAS)
  * `REMOTE_PATH` (exportpad op je TrueNAS, bv. `/mnt/tank/share`)
  * `MOUNTPOINT` (pad *in* de container, bv. `/mnt/share`)
* **Detecteert** of je op de **Proxmox host** bent (`pct` aanwezig):

  * Zo ja: toont **pct list**, laat je **één of meerdere CTIDs** kiezen, en configureert elke CT.
  * Zo nee: gaat ervan uit dat je **in een LXC** zit en configureert **alleen die** container.
* **In elke gekozen LXC**:

  * Installeert `nfs-common` (Debian/Ubuntu containers).
  * Maakt het mountpoint aan.
  * Voegt/actualiseert een NFS-regel in **`/etc/fstab`**.
  * Doet een **eerste mount** en zet `systemd` “wait-online” services **best effort** aan.
* Probeert op de host de LXC-feature **`mount=nfs`** te activeren voor de container (via `pct set … -features mount=nfs`).

Logbestand (op de host): `/var/log/truenas-nfs-lxc-setup.log`.

---

## Vereisten

* Proxmox host met **LXC** containers.
* Containers gebaseerd op **Debian/Ubuntu** (apt aanwezig) of pas het script aan.
* **TrueNAS NFS export** die toegankelijk is vanaf de containers:

  * TrueNAS → *Sharing → Unix Shares (NFS)*: exportpad, toegestane clients, eventueel `mapall`/`maproot`.
  * NFSv4 aanbevolen (script gebruikt `-t nfs4` bij de eerste mount).
* Netwerk/firewall: NFS-verkeer van CTs naar TrueNAS toegestaan.
* Root-toegang op de host (en in containers via `pct exec`).

---

## Installatie

1. Plaats het script op de Proxmox host:

   ```bash
   sudo install -m 0755 truenas-nfs-lxc-setup.sh /usr/local/bin/truenas-nfs-lxc-setup.sh
   ```

2. (Optioneel) Controleer dat `pct` aanwezig is:

   ```bash
   which pct
   ```

---

## Gebruik

### Interactief op de **host** (aanbevolen)

```bash
sudo /usr/local/bin/truenas-nfs-lxc-setup.sh
```

* Je krijgt prompts voor `NAS_HOST`, `REMOTE_PATH`, `MOUNTPOINT`.
* Daarna kies je **CTID(s)** (of type `all`).
* De wizard doet de rest per container.

### Interactief **in een LXC**

```bash
sudo /usr/local/bin/truenas-nfs-lxc-setup.sh
```

* De wizard merkt dat `pct` mist en configureert **alleen deze** container.

### Defaults vooraf instellen via **env**

Deze waarden verschijnen als default in de prompts:

```bash
sudo NAS_HOST=192.168.1.50 \
     REMOTE_PATH=/mnt/tank/media \
     MOUNTPOINT=/mnt/media \
     /usr/local/bin/truenas-nfs-lxc-setup.sh
```

---

## Wat wordt er aangepast?

Per gekozen container:

* **Packages**: `apt update && apt install -y nfs-common`
* **Mountpoint**: `mkdir -p <MOUNTPOINT>`
* **/etc/fstab**: oude NFS-regel voor het mountpoint verwijderd, nieuwe regel toegevoegd:

  ```
  <NAS_HOST>:<REMOTE_PATH>  <MOUNTPOINT>  nfs  vers=4.1,proto=tcp,_netdev,bg,noatime,timeo=150,retrans=2,nofail,nosuid,nodev,x-systemd.requires=network-online.target,x-systemd.after=network-online.target,x-systemd.device-timeout=0,x-systemd.mount-timeout=infinity  0  0
  ```
* **systemd**: `daemon-reload`, probeert “wait-online” services te enablen (best effort).
* **Eerste mount**: `mount -t nfs4 NAS:PATH MOUNTPOINT` (anders `systemctl restart remote-fs.target`).

Op de host voor die CT:

* Probeert **`mount=nfs`** te zetten in de containerconfig (`pct set CTID -features mount=nfs`). Als dit niet lukt, krijg je een waarschuwing om het handmatig in `/etc/pve/lxc/<CTID>.conf` te zetten.

---

## Instellingen & omgevingsvariabelen

Je kunt deze **vooraf** meegeven (en ze verschijnen als default in de prompts):

* `NAS_HOST` — bv. `192.168.1.42`
* `REMOTE_PATH` — bv. `/mnt/Files/Share/downloads`
* `MOUNTPOINT` — bv. `/mnt/downloads`
* `FSTAB_OPTS` — volledige optiestring voor fstab (standaard robuuste set; pas aan als je read-only wilt, enz.)
* `LOG_FILE` — logpad (standaard: `/var/log/truenas-nfs-lxc-setup.log`)

Voorbeeld met aangepaste opties (read-only):

```bash
sudo FSTAB_OPTS="vers=4.1,proto=tcp,ro,_netdev,bg,noatime,nosuid,nodev,nofail" \
     /usr/local/bin/truenas-nfs-lxc-setup.sh
```

---

## Bevestigen dat het werkt

**In de container**:

```bash
pct exec <CTID> -- bash -lc "mount | grep <MOUNTPOINT>"
pct exec <CTID> -- bash -lc "grep -E '\\s< MOUNTPOINT >\\s+nfs\\s' /etc/fstab"
pct exec <CTID> -- bash -lc "ls -la <MOUNTPOINT>"
```

**Logs bekijken**:

```bash
# Op de host (wizard log)
sudo tail -n 200 /var/log/truenas-nfs-lxc-setup.log

# In de container: systemd mount-unit log
pct exec <CTID> -- bash -lc 'systemd-escape -p "<MOUNTPOINT>"'
# Neem de output, bijv. mnt-downloads.mount:
pct exec <CTID> -- bash -lc 'journalctl -u mnt-downloads.mount -b | tail -n 100'
```

---

## Troubleshooting

* **“Operation not permitted” bij mounten**
  Zet in `/etc/pve/lxc/<CTID>.conf`:

  ```
  features: mount=nfs
  ```

  Herstart de container:

  ```bash
  pct restart <CTID>
  ```

* **Unprivileged CT & permissies**
  NFS en unprivileged LXC kan ongemak geven qua UID/GID mapping. Overweeg:

  * TrueNAS export met passende **mapall/maproot** (of `root_squash`-instellingen).
  * Privileged container (alleen als je de security-implicaties kent).
  * Alternatief: **bind-mount** NFS op host → mount in CT met `mpX:` in CT-config.

* **NFSv4 vs v3**
  Script probeert **v4**. Als jouw TrueNAS alleen v3 aanbiedt, pas `FSTAB_OPTS` aan (bijv. `vers=3`) en de eerste mount in de wizard laat de systemd restart het oppakken.

* **Network Online**
  Niet alle CT-templates hebben `systemd-networkd-wait-online` of `NetworkManager-wait-online`. Het script probeert beide; als ze ontbreken, is dat geen blocker.

* **Fout: apt niet gevonden**
  Dan is je container geen Debian/Ubuntu. Installeer handmatig de NFS-clienttools voor jouw distro of pas het script aan.

* **Firewall / TrueNAS export**
  Controleer dat de CT IP’s toegestaan zijn bij de NFS-share. Test vanaf de CT:

  ```bash
  pct exec <CTID> -- bash -lc "showmount -e <NAS_HOST>"  # vereist nfs-common / nfs-client tools
  ```

---

## Veiligheid & best practices

* De fstab gebruikt standaard **`nosuid,nodev,nofail,noatime,_netdev,bg`** voor veiligheid/robustheid.
* Overweeg **read-only** (`ro`) als containers alleen hoeven te lezen.
* Let op **UID/GID**-mapping voor schrijfpermissies (NFS + unprivileged CT).
* Voor gevoelige data: overweeg **bind-mount** vanaf de host in plaats van direct NFS in de CT.

---

## Verwijderen / rollback

1. Verwijder de regel uit `/etc/fstab` **in de container**:

   ```bash
   pct exec <CTID> -- bash -lc "sed -i '\|\\s<MOUNTPOINT>\\s\\+nfs\\s|d' /etc/fstab"
   ```

2. Umount:

   ```bash
   pct exec <CTID> -- bash -lc "umount <MOUNTPOINT>" || true
   ```

3. (Optioneel) Verwijder mountpoint:

   ```bash
   pct exec <CTID> -- bash -lc "rmdir <MOUNTPOINT>" || true
   ```

4. (Optioneel) Haal `mount=nfs` uit `/etc/pve/lxc/<CTID>.conf` en herstart de CT:

   ```bash
   sed -i '/^features:.*mount=nfs/d' /etc/pve/lxc/<CTID>.conf
   pct restart <CTID>
   ```

5. Wizard verwijderen (host):

   ```bash
   sudo rm -f /usr/local/bin/truenas-nfs-lxc-setup.sh
   ```



