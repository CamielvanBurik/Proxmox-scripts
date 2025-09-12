
# GPU Toggle (amdgpu ↔ vfio-pci) voor Proxmox 9 (Debian 13 Trixie)

Dit script (`/usr/local/sbin/gpu-toggle.sh`) laat je snel wisselen tussen:

* **Host-modus**: de AMD iGPU draait op de host met `amdgpu` (voor VA-API, OpenCL, Jellyfin, etc.)
* **Passthrough-modus**: de iGPU (en audiofunctie) worden aan `vfio-pci` gebonden voor passthrough naar een VM.

## Kenmerken

* Detecteert automatisch GPU- en audio-PCI slots en vendor ID’s.
* Past `/etc/modprobe.d/vfio.conf` automatisch aan (aan/uit).
* Probeert **live** te (un)bind’en zonder reboot; werkt ook met reboot.
* Laat status zien (huidige driverbinding, kernel cmdline hints).

---

## Vereisten

* Proxmox VE 9.x (Debian 13 Trixie).
* Rootrechten.
* `pciutils` (voor `lspci`):

  ```bash
  apt install -y pciutils
  ```
* (Aanbevolen) Kernel ≥ 6.8 en firmware up-to-date:

  ```bash
  apt install -y pve-kernel-6.8 pve-firmware firmware-amd-graphics
  ```

---

## Installatie

1. Sla het script op:

```bash
nano /usr/local/sbin/gpu-toggle.sh
# (plak de inhoud van het script)
chmod +x /usr/local/sbin/gpu-toggle.sh
```

2. (Optioneel) Voeg een korte alias toe:

```bash
echo 'alias gputoggle="/usr/local/sbin/gpu-toggle.sh"' >> /root/.bashrc
```

---

## Gebruik

### Status

Toont gedetecteerde GPU/audio en actieve driver:

```bash
gpu-toggle.sh status
```

### Host-modus (amdgpu)

Gebruik de iGPU op de host (VA-API/OpenCL):

```bash
gpu-toggle.sh host
# desnoods reboot voor ‘clean slate’
reboot
```

### Passthrough-modus (vfio-pci)

Bindt GPU + audio aan `vfio-pci` voor VM passthrough:

```bash
gpu-toggle.sh passthrough
```

**Belangrijk voor passthrough**: IOMMU moet aan staan. Eenmalig instellen:

```bash
sed -i 's/$/ amd_iommu=on iommu=pt/' /etc/kernel/cmdline
proxmox-boot-tool refresh
reboot
```

---

## Verifiëren

* **Driverbinding**:

  ```bash
  lspci -nnk | grep -A3 -E "VGA|Display|3D"
  ```

  Verwacht:

  * Host-modus: `Kernel driver in use: amdgpu`
  * Passthrough-modus: `Kernel driver in use: vfio-pci`

* **Render device aanwezig (host-modus)**:

  ```bash
  ls -l /dev/dri
  ```

* **Video-accel en OpenCL (host-modus)**:

  ```bash
  apt install -y mesa-va-drivers vainfo mesa-opencl-icd ocl-icd-libopencl1 clinfo libclc-19 || true
  vainfo | head
  RUSTICL_ENABLE=radeonsi clinfo | grep -E 'Platform|Device'
  ```

---

## Veelvoorkomende issues & oplossingen

* **VM start niet / black screen bij passthrough**

  * Gebruik VM-firmware **OVMF (UEFI)** en **Machine type: q35**.
  * Voeg zowel **GPU (…:…:… .0)** als **Audio (… .1)** toe.
  * Controleer IOMMU:

    ```bash
    dmesg | grep -E 'IOMMU|AMD-Vi'
    ```

* **`amdgpu` blijft niet binden**

  * Kijk of er nog een blacklist of oude `vfio.conf` rondslingert:

    ```bash
    grep -RniE 'vfio-pci|blacklist.*amdgpu' /etc/modprobe.d/
    ```
  * Pas aan/verwijder, run `update-initramfs -u` en reboot.

* **OpenCL zegt “0 devices, multiple matching platforms” (host-modus)**

  * Houd alleen Mesa’s RustiCL ICD aan:

    ```bash
    mkdir -p /root/icd-backup
    mv /etc/OpenCL/vendors/pocl.icd /root/icd-backup/ 2>/dev/null || true
    echo "mesa" > /etc/OpenCL/vendors/mesa.icd
    ```

* **Firmware missing in dmesg**

  * Update firmware:

    ```bash
    apt update
    apt install -y pve-firmware firmware-amd-graphics
    reboot
    ```

---

## Veiligheidsadvies

* **Stop VM’s** die de GPU gebruiken vóór je togglet.
* Gebruik **één** methode tegelijk: of host-gebruik, of passthrough.
* Bij twijfel: run een **reboot** na het wisselen voor een schone toestand.

---

## Rollback

Mocht er iets misgaan:

```bash
# vfio uitschakelen
mv /etc/modprobe.d/vfio.conf /etc/modprobe.d/vfio.conf.disabled 2>/dev/null || true
update-initramfs -u
reboot
```

---

## Support/Notes

* De audiofunctie zit meestal op hetzelfde device als de GPU met functie **`.1`** (bijv. `c5:00.1`).
* Het script werkt ook als de audiofunctie ontbreekt; dan wordt alleen de GPU gewisseld.
* Voor geavanceerde use-cases (multi-GPU, dGPU + iGPU) kun je het script uitbreiden met vaste PCI-slots.
