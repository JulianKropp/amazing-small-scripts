# NVIDIA-Treiber-Installation (Debian)

**Ziel:** Bereitstellung einer deterministischen Schritt-für-Schritt-Anleitung für einen AI-Agenten zur Installation eines NVIDIA-Grafiktreibers (`.run`-Datei) aus dem lokalen `Downloads`-Verzeichnis.

---

## Schritt 1: GPU-Hardware verifizieren
Der Agent muss zunächst sicherstellen, dass eine NVIDIA-GPU physisch vorhanden ist und vom System erkannt wird, bevor Änderungen am System vorgenommen werden.

```bash
# pciutils installieren (falls nicht vorhanden)
sudo apt-get update
sudo apt-get -y install pciutils

# Prüfe auf NVIDIA VGA-Controller
lspci | grep -i "nvidia"
```
> **Logik für den Agenten:** Wenn die Ausgabe des letzten Befehls leer ist, brich den Prozess ab und melde dem Benutzer, dass keine NVIDIA-Hardware erkannt wurde.

## Schritt 2: Nouveau-Treiber deaktivieren (Blacklisting)
Der quelloffene `nouveau`-Treiber blockiert die Installation der proprietären NVIDIA-Treiber. Er muss zwingend deaktiviert werden.

```bash
# 1. Erstelle die Blacklist-Konfiguration
cat <<EOF | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
EOF

# 2. Kernel-Modesetting deaktivieren
echo options nouveau modeset=0 | sudo tee -a /etc/modprobe.d/nouveau-kms.conf

# 3. Initramfs aktualisieren
sudo update-initramfs -u
```

## Schritt 3: GRUB-Konfiguration patchen
Um `nouveau` bereits beim Systemstart auf Kernel-Ebene zu blockieren, muss der Bootloader aktualisiert werden.

```bash
# 1. Erstelle ein Backup der aktuellen GRUB-Konfiguration
sudo cp /etc/default/grub /etc/default/grub.bak

# 2. Füge Nouveau-Blacklist-Parameter zur GRUB_CMDLINE_LINUX Variablen hinzu
sudo sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 rd.driver.blacklist=grub.nouveau rcutree.rcu_idle_gp_delay=1"/' /etc/default/grub

# 3. GRUB aktualisieren (Hinweis: Unter Debian ist update-grub oft der Standard-Alias)
sudo update-grub
# Fallback, falls update-grub fehlt: sudo grub2-mkconfig -o /boot/grub/grub.cfg
```

## Schritt 4: Abhängigkeiten & Voraussetzungen installieren
Für die Kompilierung des Kernel-Moduls durch den NVIDIA-Installer werden spezifische Tools benötigt.

```bash
sudo apt-get -y install linux-headers-$(uname -r) make gcc acpid dkms
```

## Schritt 5: X-Server (Display Manager) stoppen
Die Installation schlägt fehl, wenn ein grafischer X-Server läuft. Der Agent muss die UI stoppen.

```bash
# Identifiziere den laufenden Display-Manager und stoppe ihn. 
# Beispiel für den häufigen lightdm (Gilt analog für gdm3 oder sddm):
sudo systemctl stop lightdm

# Wechsle in den Multi-User-Target-Modus (Runlevel 3 - reines Terminal)
sudo init 3
```

## Schritt 6: Treiber aus dem Downloads-Ordner installieren
Der Agent führt nun die `.run`-Datei aus, die der Benutzer im Downloads-Ordner abgelegt hat.

```bash
# Wechsle in das Verzeichnis
cd ~/Downloads

# Finde die .run-Datei und mache sie ausführbar
chmod +x ./NVIDIA-Linux-*.run

# Führe die Installation aus.
# Agenten-Logik für Kernel-Signatur-Prüfung (verhindert Fehler bei aktivierten Signatur-Checks):
grep CONFIG_MODULE_SIG=y /boot/config-$(uname -r) && \
grep "CONFIG_MODULE_SIG_FORCE is not set" /boot/config-$(uname -r) && \
sudo ./NVIDIA-Linux-*.run -e || \
sudo ./NVIDIA-Linux-*.run
```

**Anweisungen für den Installer-Dialog (TUI):**
* **Sign the Kernel Module:** Bestätigen ("Generate a new key pair").
* **GLVND / OpenGL:** Akzeptieren / Installieren.
* **Update X config:** **NEIN (NO)**. *Wichtig: Der Agent darf den Installer die X-Konfiguration am Ende nicht überschreiben lassen.*
* *Fehler-Log:* Im Falle eines Abbruchs findet der Agent das Log unter `/var/log/nvidia-installer.log`.

## Schritt 7: Installation verifizieren und Neustart
Nach Abschluss des Installationsskripts muss das System neu gestartet werden.

```bash
# Vorab-Test (kann fehlschlagen, wenn der Neustart zwingend erforderlich ist)
nvidia-smi

# Server neu starten, um den X-Server und den neuen Kernel-Treiber sauber zu laden
sudo reboot now
```

---

## 🛠️ Troubleshooting-Wissensbasis für den Agenten

* **Szenario A:** *Tainted Kernel Fehler*
    * **Ursache:** Der Installer bricht ab, weil der Treiber nicht signiert ist.
    * **Lösung:** Installer im Expert-Modus starten (`sudo ./NVIDIA-Linux-*.run -e`) und beim Prompt die Erstellung eines neuen Schlüsselpaares ("Generate a new key pair") erzwingen.
* **Szenario B:** *Kernel-Header Mismatch (Installer stoppt nach Lizenz)*
    * **Ursache:** Diskrepanz zwischen Entwicklungs-Headern und aktivem System-Kernel.
    * **Lösung:** `sudo apt-get update && sudo apt-get install linux-headers-$(uname -r)` gefolgt von einem sofortigen `reboot`.
* **Szenario C:** *Failed to initialize NVML: GPU access blocked...*
    * **Ursache:** Konflikt durch ältere, parallele Treiberinstallationen.
    * **Lösung:** Führe `dpkg --list | grep -E "cuda|nvidia"` aus und bereinige veraltete Paket-Leichen via `apt-get purge`.
