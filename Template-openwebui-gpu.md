
# OpenWebUI + Ollama + ROCm (AMD iGPU) – LXC Template voor Proxmox

Deze README beschrijft twee host-side scripts voor Proxmox die een **Ubuntu 24.04 LXC** klaarmaken als **AI-workstation** met **OpenWebUI** (webinterface) + **Ollama** (modelruntime) op **AMD GPU/ROCm** — ideaal voor Strix/880M/890M (gfx1150).

* `build-openwebui-ollama-rocm-lxc.sh` – maakt en configureert een nieuwe LXC met alles erop en eraan (optioneel direct als **template** markeren).
* `post-clone-openwebui-gpu-fixup.sh` – fix & self-test voor gekloonde containers (mounts, services, kleine GPU-test).

---

## Inhoud

* [Overzicht](#overzicht)
* [Randvoorwaarden (host)](#randvoorwaarden-host)
* [Wat de scripts doen](#wat-de-scripts-doen)
* [Snelstart](#snelstart)
* [Template maken & clonen](#template-maken--clonen)
* [Healthchecks](#healthchecks)
* [Probleemoplossing](#probleemoplossing)
* [Poorten & paden](#poorten--paden)
* [Tips voor modellen](#tips-voor-modellen)
* [Security-notes](#security-notes)

---

## Overzicht

De LXC draait:

* **OpenWebUI** op `:8080` (web UI)
* **Ollama** op `:11434` (REST API)
* **ROCm user-space** (zonder DKMS in de container)
* **AMD iGPU** gedeeld via **/dev/dri** en **/dev/kfd** (host gebruikt amdgpu)

Strix/880M/890M (`gfx1150`) is **ondersteund met override**:

```
HSA_OVERRIDE_GFX_VERSION=11.0.0
```

---

## Randvoorwaarden (host)

* Proxmox host gebruikt **amdgpu** (niet vfio) en heeft devices:

  ```bash
  ls -l /dev/kfd /dev/dri/renderD*
  ```
* **Ubuntu 24.04 LXC template** beschikbaar (script downloadt ‘m zonodig):
  `ubuntu-24.04-standard_24.04-1_amd64.tar.zst`
* LXC draait **privileged** (`-unprivileged 0`) i.v.m. ROCm device-toegang.
* Netwerk: bridge (bv. `vmbr0`) met LAN-IP, zodat je UI/API kunt benaderen.

---

## Wat de scripts doen

### `build-openwebui-ollama-rocm-lxc.sh`

* Maakt een **privileged** Ubuntu 24.04 LXC (standaard `CTID=250`, `vmbr0`, DHCP).
* Bind-mount **/dev/dri** en **/dev/kfd** de container in.
* Installeert **ROCm user-space** (`amdgpu-install … --usecase=rocm --no-dkms`).
* Installeert **Ollama** + systemd drop-in:

  * `OLLAMA_USE_ROCM=1`
  * `HSA_OVERRIDE_GFX_VERSION=11.0.0`
  * `HIP_VISIBLE_DEVICES=0`, `ROCR_VISIBLE_DEVICES=0`
* Installeert **OpenWebUI** in venv + systemd unit (bindt op `0.0.0.0:8080`).
* Maakt een **secret key** voor OpenWebUI in `/home/openwebui/.webui_secret_key`
  (voorkomt crash door `/root/.webui_secret_key`-pad).
* **Healthchecks**: poorten, `/health`, `rocminfo`, `rocm-smi`.
* Optioneel: markeer CT als **template** na afloop (`MAKE_TEMPLATE=1`).

### `post-clone-openwebui-gpu-fixup.sh`

* Voor **gekloneerde** containers:

  * (Her)voegt **/dev/dri** en **/dev/kfd** mounts toe.
  * Zet ROCm env voor Ollama (incl. **gfx1150 override**).
  * Zorgt dat `ollama` en `openwebui` in groepen **render**/**video** zitten.
  * Fix OpenWebUI (HOME, secret, unit).
  * Herstart services.
  * **Self-test**: pull klein model + korte prompt.
  * Print **health-samenvatting** (IP/poorten).

---

## Snelstart

1. **Plaats scripts op de Proxmox host** (bijv. in `/root/ai/`) en maak uitvoerbaar:

```bash
chmod +x build-openwebui-ollama-rocm-lxc.sh post-clone-openwebui-gpu-fixup.sh
```

2. **Controleer host-GPU devices**:

```bash
ls -l /dev/kfd /dev/dri/renderD*  # moeten bestaan
```

3. **Run build-script** (maakt CTID 250 standaard):

```bash
bash build-openwebui-ollama-rocm-lxc.sh
```

4. **Vind het container-IP**:

```bash
pct exec 250 -- ip -4 addr show dev eth0 | grep inet
```

5. **Gebruik**:

* OpenWebUI: `http://<LXC-IP>:8080/`
* Ollama API: `http://<LXC-IP>:11434/api/version`

> NB: Sommige Ollama CLI builds hebben geen `generate` subcommand; gebruik dan:
>
> ```bash
> echo "Hallo" | ollama run llama3.2:1b
> ```

---

## Template maken & clonen

**Template direct maken**:

```bash
MAKE_TEMPLATE=1 bash build-openwebui-ollama-rocm-lxc.sh
```

**Clone maken** (via GUI of CLI) en daarna **fixup** + self-test:

```bash
# voorbeeld: nieuwe CTID 260
bash post-clone-openwebui-gpu-fixup.sh 260
```

---

## Healthchecks

**In de LXC** (of via `pct exec <CTID> -- ...`):

```bash
# Services
systemctl status ollama --no-pager
systemctl status open-webui --no-pager

# Luistert er iets op 11434/8080?
ss -ltnp | egrep ':(11434|8080)'

# HTTP checks
curl -s http://127.0.0.1:11434/api/version
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/health

# ROCm zichtbaar?
/opt/rocm/bin/rocminfo | egrep -i 'Agent|gfx|AMD Radeon' -n
watch -n1 /opt/rocm/bin/rocm-smi  # tijdens model-run moet je activiteit zien
```

---

## Probleemoplossing

**Geen `/dev/kfd` in container**

* Host mist `/dev/kfd` → update kernel/firmware, zorg dat `amdgpu` geladen is, reboot host.
* Mounts vergeten → run `post-clone-openwebui-gpu-fixup.sh <CTID>` of:

  ```bash
  pct set <CTID> -mp0 /dev/dri,mp=/dev/dri
  pct set <CTID> -mp1 /dev/kfd,mp=/dev/kfd
  pct restart <CTID>
  ```

**Ollama: “no compatible GPUs / gfx1150 unsupported”**

* RDNA3(.5) override staat in drop-in:

  ```
  HSA_OVERRIDE_GFX_VERSION=11.0.0
  ```
* Herstart:

  ```bash
  systemctl daemon-reload
  systemctl restart ollama
  journalctl -u ollama -n 50 --no-pager
  ```

**OpenWebUI crasht met `/root/.webui_secret_key`**

* In unit zetten we `HOME=/home/openwebui` en maken we de secret daar.
  Run desnoods opnieuw:

  ```bash
  bash post-clone-openwebui-gpu-fixup.sh <CTID>
  ```

**Poort :8080/ :11434 onbereikbaar**

* Check bind:

  ```bash
  systemctl cat open-webui | grep ExecStart
  # verwacht: ... serve --host 0.0.0.0 --port 8080
  ```
* Check firewall (meestal uit in LXC):

  ```bash
  ufw status || true
  ```
* Luistert proces wel? `ss -ltnp | egrep ':(11434|8080)'`

**“model runner has unexpectedly stopped”**

* Vaak **geheugen**: test klein model eerst:

  ```bash
  ollama pull llama3.2:1b
  echo "Test" | ollama run llama3.2:1b
  ```
* Download model vooraf (minder piek):

  ```bash
  ollama pull llama3.2:3b
  ```
* Houd `journalctl -f -u ollama` open tijdens een run.

**CLI flags verschillen per Ollama build**

* Als `generate` ontbreekt, gebruik `ollama run` met stdin:

  ```bash
  echo "Zeg: GPU test?" | ollama run llama3.2:1b
  ```

---

## Poorten & paden

* **OpenWebUI**: `:8080`
  Unit: `/etc/systemd/system/open-webui.service`
  Home/secret: `/home/openwebui/.webui_secret_key`

* **Ollama**: `:11434`
  Drop-in: `/etc/systemd/system/ollama.service.d/rocm.conf`
  Env (belangrijk):

  ```
  OLLAMA_USE_ROCM=1
  HSA_OVERRIDE_GFX_VERSION=11.0.0
  HSA_ENABLE_SDMA=0
  HIP_VISIBLE_DEVICES=0
  ROCR_VISIBLE_DEVICES=0
  ```

* **ROCm tools**:
  `/opt/rocm/bin/rocminfo` • `/opt/rocm/bin/rocm-smi`

* **GPU devices (in CT)**:
  `/dev/kfd` • `/dev/dri/renderD*`

---

## Tips voor modellen

* **Eerst klein testen**: `llama3.2:1b` → daarna `llama3.2:3b`
* **8B** modellen werken soms, maar iGPU (gedeeld geheugen) kan krap zijn.
* Gebruik **gequantiseerde** varianten (Q4) voor lagere geheugenpiek.
* Houd **`rocm-smi`** open om gebruik te zien.

---

## Security-notes

* OpenWebUI draait als **user `openwebui`**, niet als root.
* Secret key staat in **HOME** van `openwebui`.
* Toegang tot GPU: users in groepen **render**/**video**.
* Publiceren van de UI/API buiten je LAN? Gebruik een **reverse proxy** met auth/TLS.

---

### Mini-cheat sheet

```bash
# IP van de container
pct exec <CTID> -- ip -4 addr show dev eth0 | grep inet

# Health
curl -s http://127.0.0.1:11434/api/version
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/health

# ROCm
/opt/rocm/bin/rocminfo | egrep -i 'Agent|gfx|AMD Radeon' -n
watch -n1 /opt/rocm/bin/rocm-smi

# Klein model test
ollama pull llama3.2:1b
echo "Hallo GPU?" | ollama run llama3.2:1b
```


