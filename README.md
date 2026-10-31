<h1 align="center">Rane SL2 macOS ARM Driver (Apple Silicon M1 / M2 / M3 / M4)</h1>

<p align="center">
  <strong>Native User-Space CoreAudio Driver + Serato DJ Pro 2.5.5 Bridge (<code>SL2Api.framework</code>) for Rane SL 2 on Modern Macs</strong><br>
  <em>Original idea & project by <strong>pepelee (PPLEE)</strong> — <a href="https://www.instagram.com/pepeleedj/">@pepeleedj</a></em>
</p>

<p align="center">
  <a href="https://github.com/pepeleedj/Rane-SL2-Macos-ARM-Driver/raw/main/Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip"><strong>⬇️ DOWNLOAD INSTALLER (.ZIP)</strong></a>
  &nbsp;|&nbsp;
  <a href="https://github.com/pepeleedj/Rane-SL2-Macos-ARM-Driver/raw/main/Installer/RaneSL2-macOS-Universal.pkg"><strong>📦 DOWNLOAD .PKG DIRECTLY</strong></a>
  &nbsp;|&nbsp;
  <a href="#-español-instrucciones-en-español"><strong>🇪🇸 LEER EN ESPAÑOL</strong></a>
</p>

---

## 🇬🇧 English

### Why does this exist?
When Apple transitioned to **Apple Silicon (M1 / M2 / M3 / M4)** and modern macOS versions, Rane and Serato discontinued support for the **Rane SL 2** DVS audio interface because the official Rane driver relied on a legacy Intel Kernel Extension (`SL2.10.9.kext`).

**This project ports the proven Rane SL3 user-space architecture to the Rane SL 2 on Apple Silicon Macs (M1, M2, M3, M4 — Base, Pro, Max, Ultra) and modern macOS (Monterey, Ventura, Sonoma, Sequoia, and newer):**

* ✅ **Designed for Serato DJ Pro 2.5.5** (the last Serato version that supports Rane SL 2 hardware—unlocks DVS `ABS` / `REL` / `INT` modes and `THRU` control via `SL2Api.framework`).
* ✅ **NO SIP Disable Required & NO Reboot Required:** Runs 100% in user space via Apple's modern `AudioServerPlugIn` (CoreAudio HAL) and `IOUSBHost` frameworks, plus a custom Universal `SL2Api.framework` user-space bridge.
* ✅ **Works with the macOS System Settings "SL 2" Control Panel** and includes a terminal control utility (`sl2panel`) to switch between **Phono / Line**, toggle **Thru**, and change sample rates (**44.1 kHz / 48 kHz**).
* ✅ **Works as a 4-In / 4-Out (24-bit) CoreAudio Soundcard** in **Mixxx, Traktor, Ableton Live, Rekordbox, Logic Pro**, and system-wide macOS audio.

---

### 🚀 Quick Installation (1-Click)

1. [**Download `Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip`**](https://github.com/pepeleedj/Rane-SL2-Macos-ARM-Driver/raw/main/Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip) and unzip it on your Mac.
2. Open Terminal and clear macOS Gatekeeper quarantine on the downloaded folder:
   ```bash
   xattr -cr ~/Downloads/Rane-SL2-Installer-Mac-M1-M2-M3-M4
   ```
3. Double-click **`Instalar-Rane-SL2.command`** (or right-click -> **Open** on **`RaneSL2-macOS-Universal.pkg`**).
4. Enter your Mac password when prompted.
5. **Done!** `coreaudiod` reloads automatically (no reboot needed). Plug in your Rane SL 2 via USB!

---
---

## 🇪🇸 Español (Instrucciones en Español)

### ¿Qué es este proyecto?
Con la llegada de los procesadores **Apple Silicon (M1 / M2 / M3 / M4)** y los nuevos sistemas macOS, las tarjetas **Rane SL 2** quedaron sin soporte oficial porque el driver original de Rane dependía de una extensión de kernel antigua (`SL2.10.9.kext`) para procesadores Intel.

**Este driver traslada la arquitectura probada en la Rane SL 3 a la Rane SL 2 para cualquier Mac moderno (M1, M2, M3, M4 y variantes Pro, Max, Ultra):**

* ✅ **Compatible con Serato DJ Pro 2.5.5** (la última versión de Serato compatible con Rane SL 2; activa los modos DVS `ABS` / `REL` / `INT` y `THRU`).
* ✅ **SIN desactivar la seguridad del Mac (SIP) y SIN reiniciar:** Todo funciona en espacio de usuario mediante un plugin HAL de CoreAudio (`SL2Device.driver` sobre `IOUSBHost`) junto con un puente nativo Universal (`SL2Api.framework`).
* ✅ **Funciona con el panel "SL 2" en Ajustes del Sistema de macOS** e incluye utilidad de control (`Panel-Control-SL2.command` / `sl2panel`) para cambiar entre **Phono / Line**, activar/desactivar **Thru** y elegir entre **44.1 kHz y 48 kHz**.
* ✅ **Funciona como tarjeta de sonido de 4 Entradas y 4 Salidas (24-bit)** en **Ableton Live, Traktor, Mixxx, Rekordbox, Logic Pro** y el audio general de macOS.

---

### 🚀 Instalación Paso a Paso

1. [**Descarga `Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip`**](https://github.com/pepeleedj/Rane-SL2-Macos-ARM-Driver/raw/main/Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip) y descomprímelo.
2. Si macOS bloquea los archivos descargados de Internet, abre **Terminal**, escribe `xattr -cr ` (con un espacio al final), arrastra la carpeta descomprimida dentro de la Terminal y pulsa **ENTER**.
3. Haz doble clic en **`Instalar-Rane-SL2.command`** (o abre **`RaneSL2-macOS-Universal.pkg`**), introduce la contraseña de tu Mac y pulsa ENTER.

#### Canales de Audio (4 Entradas / 4 Salidas a 24-bit, 44.1 / 48 kHz)
* **Canales 1–2:** Left Deck (Plato / CDJ 1)
* **Canales 3–4:** Right Deck (Plato / CDJ 2)

---

### 🙌 Créditos y Licencia / Credits & License
* **Idea original, puente Serato (`SL2Api.framework`), utilidad `sl2panel` e instalador macOS Universal:** **pepelee (PPLEE)** — Instagram: [@pepeleedj](https://www.instagram.com/pepeleedj/)
* **Licencia:** [GPL-3.0-or-later](LICENSE).
* *Disclaimer:* Proyecto independiente no afiliado con Rane ni Serato.

---

### 🔗 Other Rane Series Drivers for Apple Silicon (M1 / M2 / M3 / M4)
* 🎛️ **Rane SL 2:** [pepeleedj/Rane-SL2-Macos-ARM-Driver](https://github.com/pepeleedj/Rane-SL2-Macos-ARM-Driver)
* 🎛️ **Rane SL 3:** [pepeleedj/Rane-SL3-Macos-ARM-Driver](https://github.com/pepeleedj/Rane-SL3-Macos-ARM-Driver)
* 🎛️ **Rane SL 4:** [pepeleedj/Rane-SL4-macOS-ARM-Driver](https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver)
