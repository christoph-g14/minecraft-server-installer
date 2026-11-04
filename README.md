# Minecraft-Server-Installer (Ubuntu)

Ein Bash-Skript, das einen Minecraft-Java-Server auf Ubuntu einrichtet, beim Systemstart automatisch startet und die Maschine nach etwa **5 Minuten ohne Spieler** herunterfährt.

## Voraussetzungen

- Ubuntu mit Internetzugang und ausreichend Arbeitsspeicher (**mindestens 4 GB für die Serverkonfiguration**).
- Ein **normaler Benutzer mit `sudo`-Rechten**. Das Installationsskript **nicht mit `sudo` starten**.
- Java 25 und weitere benötigte Programme werden bei Bedarf installiert (unter Ubuntu). Die gewünschte Server-JAR muss mit `java -jar` direkt startbar sein.

## Installation

1. `install.sh` auf den Ubuntu-Rechner übertragen.
2. Im Verzeichnis mit der Datei ausführen:

   ```bash
   chmod +x install.sh
   ./install.sh
   ```

3. Den Anweisungen folgen: Minecraft-EULA akzeptieren, **aktuelle Vanilla-Version** oder **direkte HTTPS-URL einer eigenen JAR** wählen, RAM (Standard **6 GB**, mindestens **4 GB**), Whitelist und optional einen ersten OP-Spieler festlegen.
4. Die Zusammenfassung bestätigen. Der Installer legt den Server unter `~/minecraft` an und richtet die Dienste ein.

**Hinweis:** Das Verzeichnis `~/minecraft` darf vor der Installation noch nicht existieren. Forge-/NeoForge-Installer und Server mit besonderen Startbefehlen werden nicht automatisch unterstützt.

## Server bedienen

| Aktion | Befehl |
| --- | --- |
| Serverkonsole öffnen / Server starten | `~/minecraft/start.sh` |
| Konsole verlassen, ohne Server zu stoppen | **Strg+A**, danach **D** |
| Server starten | `sudo systemctl start minecraft.service` |
| Server stoppen | `sudo systemctl stop minecraft.service` |
| Server neu starten | `sudo systemctl restart minecraft.service` |
| Status prüfen | `sudo systemctl status minecraft.service minecraft-idle.service` |
| Server-Logs ansehen | `sudo journalctl -u minecraft.service -f` |
| Inaktivitätsabschaltung deaktivieren | `sudo systemctl disable --now minecraft-idle.service` |
| Inaktivitätsabschaltung wieder aktivieren | `sudo systemctl enable --now minecraft-idle.service` |

Der Minecraft-Server läuft unter **dem Benutzer, der den Installer gestartet hat**, in einer `screen`-Session. `start.sh` bitte ebenfalls als diesen Benutzer ausführen.

## Automatisches Herunterfahren

Der Dienst `minecraft-idle.service` fragt die Spielerzahl über **RCON** ab. Ist etwa **5 Minuten lang niemand online**, fährt er **den gesamten Ubuntu-Rechner** herunter. Bei RCON-Fehlern wird kein Shutdown ausgelöst. Nach einem Neustart beginnt die Überwachung erneut; auch ein frisch gestarteter, leerer Server kann daher heruntergefahren werden.

**Achtung:** Das Skript bietet **keinen automatischen Wiederstart der ausgeschalteten Maschine**, wenn ein Spieler beitreten möchte. Dafür wäre eine separate Wake-on-LAN- oder Hosting-Lösung nötig.

## Dateien und Sicherheit

- `~/minecraft/server.properties` – Servereinstellungen
- `~/minecraft/server.jar` – Serverdatei
- `~/minecraft/.rcon_password` – vertrauliches RCON-Passwort (nicht veröffentlichen)
- `~/minecraft/run.sh`, `stop.sh`, `start.sh` – Bedienungsskripte
- `~/minecraft/initial.log`, ggf. `first-start.log` – Protokolle der Einrichtung

RCON wird auf Port **25575** aktiviert. Diesen Port **nicht öffentlich freigeben**. Für Verbindungen von außen muss der Minecraft-Spielport (standardmäßig **25565/TCP**) passend zur Firewall-/Router-Konfiguration erreichbar sein.

## Fehlerbehebung

Bei Installationsfehlern die angezeigte Fehlermeldung und die genannten Logdateien prüfen. Bei Problemen nach der Installation helfen:

```bash
sudo systemctl status minecraft.service minecraft-idle.service
sudo journalctl -u minecraft.service -u minecraft-idle.service -n 100 --no-pager
```

**Stand:** Dokumentation für `install.sh`. Die Einrichtung wurde nicht auf jeder Ubuntu- und Minecraft-Version getestet.
