Ja, zeker! Hieronder een **README.md** die je direct naast je hookscript kunt plaatsen. Hij legt uit wat het script doet, hoe je het installeert en test.

---

````markdown
# Proxmox GPU Toggle Hookscript

Dit project bevat een **hookscript** voor Proxmox om automatisch een **AMD iGPU** (Radeon 880M/890M in dit voorbeeld) te wisselen tussen:

- **Host mode (amdgpu)** → GPU wordt gebruikt door de Proxmox host.
- **Passthrough mode (vfio-pci)** → GPU wordt vrijgegeven aan een VM.

Het hookscript schakelt automatisch:
- **Pre-start** van de VM → zet GPU naar **passthrough**.
- **Post-stop** van de VM → zet GPU terug naar **host**.

Dit voorkomt handmatig omschakelen en maakt iGPU passthrough robuuster.

---

## Bestandsoverzicht

- `proxmox-gpu-toggle.sh`  
  Hulpscript dat drivers unbind/bind uitvoert, vfio.conf aanmaakt/verwijdert en kernel cmdline opties kan beheren (`amd_iommu`, `video=efifb:off`).

- `gpu-vfio-hook.sh`  
  Proxmox hookscript dat `proxmox-gpu-toggle.sh` aanroept op de juiste momenten (pre-start, post-stop).

---

## Installatie

1. **Zet toggle-script klaar**

   Plaats `proxmox-gpu-toggle.sh` ergens, bijv.:
   ```bash
   /root/.cache/proxmox-scripts/repo/proxmox-gpu-toggle.sh
   chmod +x /root/.cache/proxmox-scripts/repo/proxmox-gpu-toggle.sh
````

Test handmatig:

```bash
./proxmox-gpu-toggle.sh --slot 0000:c5:00.0 --audio-slot 0000:c5:00.1 status
```

2. **Plaats hookscript**

   Sla `gpu-vfio-hook.sh` op in de snippets-directory van Proxmox:

   ```bash
   /var/lib/vz/snippets/gpu-vfio-hook.sh
   chmod +x /var/lib/vz/snippets/gpu-vfio-hook.sh
   ```

3. **Koppel hookscript aan VM**

   Voor VMID `101` bijvoorbeeld:

   ```bash
   qm set 101 -hookscript local:snippets/gpu-vfio-hook.sh
   ```

   (of via Proxmox GUI → VM → Options → Hookscript)

---

## Configuratie

Open `gpu-vfio-hook.sh` en pas bovenaan aan:

```bash
GPU_SLOT="0000:c5:00.0"          # jouw GPU device
AUDIO_SLOT="0000:c5:00.1"        # HDMI-audio device (leeg laten als je geen audio wilt)
GPU_TOGGLE="/root/.cache/proxmox-scripts/repo/proxmox-gpu-toggle.sh"
```

Optionele variabelen:

* `TIMEOUT=25`  → max tijd per toggle in seconden.
* `DRYRUN=1`    → logt alleen, voert geen acties uit (handig voor testen).

---

## Logbestand

Alle acties worden gelogd naar:

```
/var/log/proxmox-gpu-vfio-hook.log
```

Voorbeeldregels:

```
[2025-09-12 14:00:01] [vmid:101] [pre-start] schakel iGPU naar PASSTHROUGH (vfio-pci)
[OK] Passthrough-mode geactiveerd (live). Reboot sterk aanbevolen voor VM-start.
[2025-09-12 14:45:10] [vmid:101] [post-stop] schakel iGPU terug naar HOST (amdgpu)
[OK] Host-mode geactiveerd (live). Reboot kan nog nodig zijn.
```

---

## Testen

1. **Droogtest zonder acties**

   ```bash
   DRYRUN=1 /var/lib/vz/snippets/gpu-vfio-hook.sh 101 pre-start
   DRYRUN=1 /var/lib/vz/snippets/gpu-vfio-hook.sh 101 post-stop
   ```

2. **Echte test**
   Start en stop je VM:

   ```bash
   qm start 101
   qm stop 101
   tail -f /var/log/proxmox-gpu-vfio-hook.log
   ```

---

## Tips

* Zet **`video=efifb:off`** in `/etc/kernel/cmdline` als framebuffer in de weg zit voor passthrough (via wizard-optie in `proxmox-gpu-toggle.sh`).
* Gebruik `AUDIO_SLOT=""` als je geen HDMI-audio wilt doorgeven.
* Je kunt het hookscript beperken tot een specifieke VM door bovenaan toe te voegen:

  ```bash
  ONLY_FOR="101"
  [[ "$vmid" == "$ONLY_FOR" ]] || exit 0
  ```

---

## Bekende issues

* Eerste keer na wijziging van kernel cmdline (`amd_iommu`, `video=efifb`) moet je **herstarten**.
* Sommige onboard audio controllers (bijv. `1022:15e3`) lijken op GPU-audio maar horen er niet bij → die worden bewust genegeerd.

---

## Licentie

Vrij te gebruiken en aan te passen. Geen garanties: gebruik op eigen risico.

```

---

Wil je dat ik er ook een **diagrammetje** (flow: VM start → pre-start hook → passthrough … etc.) bij teken in ASCII of mermaid, zodat je dit in je README visueel hebt?
```
