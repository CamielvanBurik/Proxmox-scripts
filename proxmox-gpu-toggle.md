Zeker! Hier is een **README.md** die past bij jouw `proxmox-gpu-toggle.sh`.

````markdown
# Proxmox AMD iGPU Toggle (amdgpu ↔ vfio-pci)

`proxmox-gpu-toggle.sh` wisselt een **AMD iGPU** op een Proxmox-host tussen:

- **Host mode** — driver **`amdgpu`** (GPU voor de host),
- **Passthrough mode** — driver **`vfio-pci`** (GPU voor een VM).

Het script kan **live (un)binds** doen, **persistente** instellingen schrijven (bijv. `/etc/modprobe.d/vfio.conf`), en kernel-cmdline-opties beheren (zoals `amd_iommu=on`, `iommu=pt`, `video=efifb:off`). Inclusief wizard en handmatige overrides voor PCI-slots.

---

## Kenmerken

- Automatische detectie van iGPU + (optioneel) iGPU-HDMI/DP-audio.
- Live switchen tussen `amdgpu` en `vfio-pci`.
- Schrijft/disable’t **`/etc/modprobe.d/vfio.conf`** met de juiste PCI IDs.
- Houdt rekening met **Proxmox** boot (kan `proxmox-boot-tool refresh` uitvoeren).
- Wizard met menu; non-interactief via subcommands/flags.
- **Overtures**: `--slot` en `--audio-slot` om BDF’s te forceren (bijv. `0000:c5:00.0`).

---

## Vereisten

- Proxmox host (root).
- `pciutils` (`lspci`); wordt automatisch geïnstalleerd als `AUTO_INSTALL_DEPS=true`.
- Kernel: IOMMU-ondersteuning (kan via script worden aangezet).
- Aanbevolen voor passthrough: `video=efifb:off` (kan via script).

---

## Installatie

```bash
# Plaats het script
install -Dvm 0755 proxmox-gpu-toggle.sh /root/.cache/proxmox-scripts/repo/proxmox-gpu-toggle.sh

# (Optioneel) symlink in PATH
ln -s /root/.cache/proxmox-scripts/repo/proxmox-gpu-toggle.sh /usr/local/sbin/gpu-toggle
````

---

## Gebruik

### Wizard (interactief)

```bash
/root/.cache/proxmox-scripts/repo/proxmox-gpu-toggle.sh
```

Toont status en een menu met acties:

* 1. Host (amdgpu)
* 2. Passthrough (vfio-pci)
* 3. Status opnieuw
* 4. Alleen persisterende config (vfio.conf aan/uit)
* 5. Reboot
* 6. Toggle `video=efifb:off` + `proxmox-boot-tool refresh`

### Subcommands (non-interactief)

```bash
# Status
proxmox-gpu-toggle.sh status

# Naar passthrough en terug:
proxmox-gpu-toggle.sh passthrough
proxmox-gpu-toggle.sh host
```

### Handmatige PCI-slot overrides

Als autodetectie niet klopt of je wilt expliciet sturen:

```bash
# Forceren met flags:
proxmox-gpu-toggle.sh --slot 0000:c5:00.0 --audio-slot 0000:c5:00.1 status
proxmox-gpu-toggle.sh --slot 0000:c5:00.0 --audio-slot 0000:c5:00.1 passthrough
proxmox-gpu-toggle.sh --slot 0000:c5:00.0 host

# Of via environment variables:
GPU_SLOT=0000:c5:00.0 AUDIO_SLOT=0000:c5:00.1 proxmox-gpu-toggle.sh status
```

> **Tip:** laat `AUDIO_SLOT` leeg als je geen HDMI/DP-audio wil doorgeven.

---

## Wat het script precies doet

* **Detectie**

  * Zoekt AMD GPU via `lspci`, robuuste regex (class ↔ vendor volgorde).
  * Audio: prefereert iGPU-HDMI/DP-audio (vendor `1002:`) op dezelfde bus.
* **Host → Passthrough**

  * Schrijft `/etc/modprobe.d/vfio.conf` met `vfio-pci ids=...`.
  * Laadt `vfio-pci`, unbind `amdgpu`, bind `vfio-pci` (en evt. audio).
  * Controleert/zet IOMMU (`amd_iommu=on iommu=pt`) en kan boot refreshen.
* **Passthrough → Host**

  * Disable’t `vfio.conf`, zorgt dat `amdgpu` autoloaded.
  * Unbind `vfio-pci`, bind `amdgpu` (en evt. `snd_hda_intel`).
* **Kernel-cmdline beheer (optioneel)**

  * Toggle **`video=efifb:off`** (handig om framebuffer te bevrijden).
  * Voert `proxmox-boot-tool refresh` uit als aanwezig.

---

## Veelvoorkomende workflows

### 1) Eerste keer klaarmaken voor passthrough

1. Run wizard → optie 6 → **`video=efifb:off`** toevoegen → refresh.
2. Wizard vraagt voor IOMMU: **Ja** om `amd_iommu=on iommu=pt` toe te voegen → refresh.
3. Reboot host.
4. Zet GPU op **passthrough**:

```bash
proxmox-gpu-toggle.sh --slot 0000:c5:00.0 --audio-slot 0000:c5:00.1 passthrough
```

### 2) Snel wisselen

```bash
# Naar de host:
proxmox-gpu-toggle.sh host

# Naar passthrough:
proxmox-gpu-toggle.sh passthrough
```

---

## Integratie met Proxmox VM-hooks (optioneel)

Automatiseer het wisselen rond VM-start/stop met een hookscript:

```bash
/var/lib/vz/snippets/gpu-vfio-hook.sh <vmid> pre-start   # zet naar passthrough
/var/lib/vz/snippets/gpu-vfio-hook.sh <vmid> post-stop   # zet terug naar host
```

Koppel aan VM:

```bash
qm set <VMID> -hookscript local:snippets/gpu-vfio-hook.sh
```

Zie de aparte README van het hookscript voor details.

---

## Troubleshooting

* **“Geen AMD GPU gevonden via lspci”**

  * Controleer of je op de **host** zit (geen LXC/VM).
  * `lspci -Dnn | egrep -i 'vga|display|amd|ati'`
  * Forceer `--slot 0000:BB:DD.F`.

* **Audio-functie niet gevonden**

  * Sommige systemen exposen audio anders; laat `AUDIO_SLOT` leeg of forceer `--audio-slot 0000:c5:00.1`.

* **GPU blijft aan host vastzitten**

  * Zet `video=efifb:off` in de wizard.
  * Controleer IOMMU-flags via `status`.
  * Reboot nadat cmdline is aangepast.

* **VM start niet met GPU**

  * Controleer dat device gebonden is aan `vfio-pci` (via `status`).
  * Gebruik hookscript zodat pre-start automatisch schakelt.

---

## Veiligheid & opmerkingen

* **Root vereist.** Script stopt direct als je geen root bent.
* **Initramfs** wordt geüpdatet; bij kernel-cmdline-wijzigingen is **reboot** nodig.
* Het script is **idempotent** waar mogelijk (herhaalde aanroepen zijn veilig).

---

## Voorbeeldoutput

```
=== Huidige status ===
GPU   : 0000:c5:00.0 (id 1002:150e) -> driver: amdgpu
Audio : 0000:c5:00.1 (id 1002:1640) -> driver: snd_hda_intel
vfio.conf : absent
Kernel cmdline flags : amd_iommu=on iommu=pt video=efifb:off
Render nodes :
  /dev/dri/by-path
  /dev/dri/card0
======================
```



````markdown
# Proxmox iGPU Passthrough Cheat Sheet

## Status check
```bash
./proxmox-gpu-toggle.sh --slot 0000:c5:00.0 --audio-slot 0000:c5:00.1 status
````

→ Laat zien of de GPU/audio op `amdgpu` (host) of `vfio-pci` (passthrough) zit.

---

## Naar Passthrough (voor VM)

```bash
./proxmox-gpu-toggle.sh --slot 0000:c5:00.0 --audio-slot 0000:c5:00.1 passthrough
```

Check:

```bash
lspci -nnk -s c5:00.0
lspci -nnk -s c5:00.1
# Verwacht: Kernel driver in use: vfio-pci
```

---

## Terug naar Host

```bash
./proxmox-gpu-toggle.sh --slot 0000:c5:00.0 --audio-slot 0000:c5:00.1 host
```

Check:

```bash
lspci -nnk -s c5:00.0
# Verwacht: Kernel driver in use: amdgpu
```

---

## VM Configuratie

Toewijzen aan VM (voorbeeld VMID=101):

```bash
qm set 101 -hostpci0 0000:c5:00.0,pcie=1
qm set 101 -hostpci1 0000:c5:00.1,pcie=1   # optioneel audio
```

---

## Extra checks

* IOMMU status:

  ```bash
  dmesg | grep -i iommu | tail
  ```
* Render nodes op host:

  ```bash
  ls -l /dev/dri
  ```


---

## Licentie

Vrij te gebruiken/aan te passen. Geen garanties; gebruik op eigen risico.

```

