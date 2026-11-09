#!/usr/bin/env bash
set -Eeuo pipefail

# Minecraft-Server-Installer fuer Ubuntu
info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FEHLER] %s\n' "$*" >&2; exit 1; }
section() { printf '\n========== %s ==========\n' "$*"; }
confirm() {
    local answer
    while true; do
        read -r -p "$1 [J/n]: " answer
        case "${answer^^}" in
            ''|J|JA|Y|YES) return 0 ;;
            N|NEIN|NO) return 1 ;;
            *) warn 'Bitte J oder N eingeben.' ;;
        esac
    done
}
cleanup_download() { [[ -z "${DOWNLOAD_TMP:-}" ]] || rm -f -- "$DOWNLOAD_TMP"; }
trap cleanup_download EXIT

section 'Minecraft-Server-Installer'
confirm 'Installation vorbereiten?' || { info 'Installation abgebrochen.'; exit 0; }
[[ $EUID -ne 0 ]] || fail 'Bitte als normaler Benutzer ausfuehren, nicht mit sudo.'
command -v sudo >/dev/null || fail 'sudo fehlt.'
sudo -v || fail 'sudo-Berechtigung erforderlich.'
MC_USER="$(id -un)"
MC_GROUP="$(id -gn)"
MC_HOME="$HOME"

section 'Systempruefung'
[[ -r /etc/os-release ]] || fail '/etc/os-release fehlt.'
# shellcheck disable=SC1091
source /etc/os-release
if [[ "$ID" != ubuntu ]]; then
    warn "Erkanntes System: ${PRETTY_NAME:-unbekannt}. Automatische Paketinstallation ist fuer Ubuntu vorgesehen."
    confirm 'Trotzdem fortfahren?' || exit 0
fi

section 'Abhaengigkeiten'
if ! java -version 2>&1 | head -n 1 | grep -Eq 'version "25([.+"]|$)|openjdk 25([.+ ]|$)'; then
    [[ "$ID" == ubuntu ]] || fail 'Java 25 bitte manuell installieren.'
    info 'Installiere Java 25 ...'
    sudo apt-get update -qq
    sudo apt-get install -y openjdk-25-jre-headless || fail 'Java 25 konnte nicht installiert werden.'
fi
ok "Java: $(java -version 2>&1 | head -n 1)"

NEEDED_PACKAGES=()
for command_name in curl wget unzip screen openssl python3 timeout; do
    command -v "$command_name" >/dev/null || NEEDED_PACKAGES+=("$command_name")
done
if ((${#NEEDED_PACKAGES[@]})); then
    [[ "$ID" == ubuntu ]] || fail "Fehlende Programme: ${NEEDED_PACKAGES[*]}"
    info "Installiere: ${NEEDED_PACKAGES[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${NEEDED_PACKAGES[@]}" || fail 'Paketinstallation fehlgeschlagen.'
fi
if ! command -v mcrcon >/dev/null; then
    [[ "$ID" == ubuntu ]] || fail 'mcrcon bitte manuell installieren.'
    info 'Installiere mcrcon aus dem offiziellen GitHub-Release ...'
    sudo apt-get install -y build-essential tar
    MCRCON_VERSION="$(curl -fsSL https://api.github.com/repos/Tiiffi/mcrcon/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')" || fail 'mcrcon-Release nicht abrufbar.'
    [[ "$MCRCON_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Unerwartete mcrcon-Version.'
    MCRCON_TMP="$(mktemp -d)" || fail 'Temp-Verzeichnis konnte nicht erstellt werden.'
    curl -fLsS --retry 3 "https://github.com/Tiiffi/mcrcon/archive/refs/tags/${MCRCON_VERSION}.tar.gz" -o "$MCRCON_TMP/source.tar.gz" || fail 'mcrcon-Download fehlgeschlagen.'
    tar -xzf "$MCRCON_TMP/source.tar.gz" -C "$MCRCON_TMP" --strip-components=1 || fail 'mcrcon-Archiv ungueltig.'
    make -C "$MCRCON_TMP" || fail 'mcrcon-Kompilierung fehlgeschlagen.'
    sudo install -m 755 "$MCRCON_TMP/mcrcon" /usr/local/bin/mcrcon || fail 'mcrcon-Installation fehlgeschlagen.'
    rm -rf "$MCRCON_TMP"
fi
ok 'Java, RCON und Screen sind verfuegbar.'

section 'Minecraft-EULA'
info 'EULA: https://www.minecraft.net/en-us/eula'
confirm 'Minecraft-EULA akzeptieren?' || { info 'Installation abgebrochen.'; exit 0; }

section 'Server-Konfiguration'
printf 'Installationsart: [A] Aktuelle Vanilla-Version / [L] Eigene direkte JAR-URL\n'
while true; do
    read -r -p 'Auswahl [A/L]: ' answer
    case "${answer^^}" in
        A) INSTALL_TYPE=auto; break ;;
        L) INSTALL_TYPE=link; break ;;
        *) warn 'Bitte A oder L eingeben.' ;;
    esac
done
JAR_DL_URL=''
if [[ "$INSTALL_TYPE" == auto ]]; then
    info 'Ermittle die aktuelle Vanilla-Release-Version ...'
    VERSION_MANIFEST="$(curl -fsSL --retry 3 https://piston-meta.mojang.com/mc/game/version_manifest_v2.json)" || fail 'Versionsliste nicht abrufbar.'
    VERSION_URL="$(printf '%s' "$VERSION_MANIFEST" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d["latest"]["release"]; print(next(x["url"] for x in d["versions"] if x["id"]==v))')" || fail 'Vanilla-Version nicht gefunden.'
    MC_VERSION="$(printf '%s' "$VERSION_MANIFEST" | python3 -c 'import json,sys; print(json.load(sys.stdin)["latest"]["release"])')"
    VERSION_JSON="$(curl -fsSL --retry 3 "$VERSION_URL")" || fail 'Versionsdetails nicht abrufbar.'
    JAR_DL_URL="$(printf '%s' "$VERSION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["downloads"]["server"]["url"])')" || fail 'Server-Download nicht gefunden.'
    JAR_SHA1="$(printf '%s' "$VERSION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["downloads"]["server"]["sha1"])')"
    ok "Vanilla-Version: $MC_VERSION"
else
    warn 'Eigene JARs muessen direkt mit java -jar startbar sein; Forge/NeoForge-Installer sind nicht geeignet.'
    while true; do
        read -r -p 'Direkte HTTPS-Download-URL: ' JAR_DL_URL
        [[ "$JAR_DL_URL" == https://* ]] && break
        warn 'Bitte eine HTTPS-URL eingeben.'
    done
fi

while true; do
    read -r -p 'Maximaler RAM in GB [6, mindestens 4]: ' answer
    answer="${answer:-6}"
    if [[ "$answer" =~ ^[[:space:]]*([0-9]+)[[:space:]]*([Gg][Bb])?[[:space:]]*$ ]]; then
        RAM_MAX=$((10#${BASH_REMATCH[1]}))
        (( RAM_MAX >= 4 )) && break
    fi
    warn 'Bitte mindestens 4 GB angeben (z. B. 6 oder 6GB).'
done
if confirm 'Whitelist aktivieren?'; then WHITELIST=1; else WHITELIST=0; fi
OP_DEFINED=0
OP_FIRST=''
while true; do
    read -r -p 'Erster OP-Spieler (leer = ueberspringen): ' OP_FIRST
    [[ -z "$OP_FIRST" ]] && break
    if [[ "$OP_FIRST" =~ ^[A-Za-z0-9_]{3,16}$ ]]; then OP_DEFINED=1; break; fi
    warn 'Minecraft-Java-Spielernamen muessen 3-16 Zeichen (Buchstaben, Zahlen, _) enthalten.'
done

section 'Zusammenfassung'
info "Installation: $([[ "$INSTALL_TYPE" == auto ]] && printf 'Vanilla %s' "$MC_VERSION" || printf 'Eigene JAR-URL')"
info "RAM: ${RAM_MAX} GB | Whitelist: $([[ "$WHITELIST" == 1 ]] && echo 'an' || echo 'aus')"
info "OP-Spieler: ${OP_FIRST:-keiner}"
info 'Autostart: an | Shutdown: 5 Minuten ohne Spieler'
confirm 'Installation jetzt starten?' || { info 'Installation abgebrochen.'; exit 0; }

section 'Dateien einrichten'
SERVER_DIR="$MC_HOME/minecraft"
[[ ! -e "$SERVER_DIR" ]] || fail "Zielverzeichnis existiert bereits: $SERVER_DIR (keine vorhandenen Daten ueberschreiben)."
mkdir -p -- "$SERVER_DIR" || fail 'Serververzeichnis konnte nicht erstellt werden.'
SERVER_DIR="$(realpath "$SERVER_DIR")"
DOWNLOAD_TMP="$(mktemp)" || fail 'Temp-Datei konnte nicht erstellt werden.'
info 'Lade Server-JAR herunter ...'
curl -fLsS --retry 3 "$JAR_DL_URL" -o "$DOWNLOAD_TMP" || fail 'Download fehlgeschlagen.'
unzip -tq "$DOWNLOAD_TMP" >/dev/null 2>&1 || fail 'Download ist kein gueltiges JAR/ZIP-Archiv.'
if [[ "$INSTALL_TYPE" == auto ]]; then
    printf '%s  %s\n' "$JAR_SHA1" "$DOWNLOAD_TMP" | sha1sum -c --status || fail 'SHA1-Pruefung fehlgeschlagen.'
fi
mv -- "$DOWNLOAD_TMP" "$SERVER_DIR/server.jar"
DOWNLOAD_TMP=''
# Log4j2: Nur die haeufigen RCON-Verbindungsnachrichten ausblenden.
# Andere INFO-, WARN- und ERROR-Meldungen bleiben sichtbar.
cat > "$SERVER_DIR/log4j2.xml" <<'LOG4J_CONFIG'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration status="WARN">
  <Appenders>
    <Console name="Console" target="SYSTEM_OUT">
      <PatternLayout pattern="[%d{HH:mm:ss}] [%t/%level]: %msg%n"/>
      <RegexFilter regex=".*Thread RCON Client .* (started|shutting down).*" onMatch="DENY" onMismatch="NEUTRAL"/>
    </Console>
    <RollingRandomAccessFile name="File" fileName="logs/latest.log"
                             filePattern="logs/%d{yyyy-MM-dd}-%i.log.gz">
      <PatternLayout pattern="[%d{HH:mm:ss}] [%t/%level]: %msg%n"/>
      <RegexFilter regex=".*Thread RCON Client .* (started|shutting down).*" onMatch="DENY" onMismatch="NEUTRAL"/>
      <Policies>
        <TimeBasedTriggeringPolicy/>
        <OnStartupTriggeringPolicy/>
      </Policies>
      <DefaultRolloverStrategy max="7"/>
    </RollingRandomAccessFile>
  </Appenders>
  <Loggers>
    <Root level="info">
      <AppenderRef ref="Console"/>
      <AppenderRef ref="File"/>
    </Root>
  </Loggers>
</Configuration>
LOG4J_CONFIG
info 'Erzeuge Minecraft-Konfigurationsdateien ...'
(
    cd "$SERVER_DIR" || exit 1
    java -Dlog4j.configurationFile=log4j2.xml -Xms1G -Xmx"${RAM_MAX}G" -jar server.jar nogui
) > "$SERVER_DIR/initial.log" 2>&1 || true
[[ -f "$SERVER_DIR/server.properties" ]] || fail "server.properties wurde nicht erzeugt. Log: $SERVER_DIR/initial.log"
printf 'eula=true\n' > "$SERVER_DIR/eula.txt"

PROPERTIES_FILE="$SERVER_DIR/server.properties"
set_property() {
    local key="$1" value="$2" file="$PROPERTIES_FILE" tmp
    tmp="$(mktemp "$SERVER_DIR/.properties.XXXXXX")" || return 1
    awk -v k="$key" -v v="$value" '
        index($0,k"=")==1 { if (!found++) print k"="v; next }
        { print }
        END { if (!found) print k"="v }
    ' "$file" > "$tmp" && cat "$tmp" > "$file"
    local result=$?
    rm -f -- "$tmp"
    return "$result"
}
if [[ "$WHITELIST" == 1 ]]; then
    set_property white-list true
    set_property enforce-whitelist true
else
    set_property white-list false
    set_property enforce-whitelist false
fi
RCON_PORT=25575
RCON_PASSWORD="$(openssl rand -hex 24)" || fail 'RCON-Passwort konnte nicht erzeugt werden.'
set_property enable-rcon true
set_property rcon.port "$RCON_PORT"
set_property rcon.password "$RCON_PASSWORD"
(umask 077; printf '%s\n' "$RCON_PASSWORD" > "$SERVER_DIR/.rcon_password")
ok 'server.properties, Whitelist und RCON konfiguriert.'

rcon() { timeout 10 mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "$1"; }
if [[ "$OP_DEFINED" == 1 ]]; then
    section 'Ersten OP-Spieler einrichten'
    info 'Starte Server voruebergehend ...'
    (cd "$SERVER_DIR" && exec java -Dlog4j.configurationFile=log4j2.xml -Xms1G -Xmx"${RAM_MAX}G" -jar server.jar nogui) </dev/null > "$SERVER_DIR/first-start.log" 2>&1 &
    MC_PID=$!
    MC_READY=0
    for ((i=0; i<180; i++)); do
        if ! kill -0 "$MC_PID" 2>/dev/null; then
            wait "$MC_PID" || true
            fail "Serverstart fehlgeschlagen. Log: $SERVER_DIR/first-start.log"
        fi
        if rcon list >/dev/null 2>&1; then MC_READY=1; break; fi
        sleep 1
    done
    if (( ! MC_READY )); then
        kill "$MC_PID" 2>/dev/null || true
        wait "$MC_PID" 2>/dev/null || true
        fail "RCON nach 180 Sekunden nicht bereit. Log: $SERVER_DIR/first-start.log"
    fi
    MC_SETUP_ERROR=0
    if [[ "$WHITELIST" == 1 ]]; then
        result="$(rcon "whitelist add $OP_FIRST")" || MC_SETUP_ERROR=1
        info "Whitelist: $result"
        [[ "$result" == *"Added"* || "$result" == *"already"* ]] || MC_SETUP_ERROR=1
    fi
    result="$(rcon "op $OP_FIRST")" || MC_SETUP_ERROR=1
    info "OP: $result"
    [[ "$result" == *"Made"* || "$result" == *"already"* ]] || MC_SETUP_ERROR=1
    rcon 'save-all flush' >/dev/null || MC_SETUP_ERROR=1
    rcon stop >/dev/null || MC_SETUP_ERROR=1
    wait "$MC_PID" || MC_SETUP_ERROR=1
    (( MC_SETUP_ERROR == 0 )) || fail "OP-/Whitelist-Einrichtung fehlgeschlagen. Log: $SERVER_DIR/first-start.log"
    ok "Spieler $OP_FIRST eingerichtet."
fi

section 'Systemd und Screen'
# Ein eigener Service-Name vermeidet Kollisionen mit anderen Minecraft-Instanzen.
MC_SERVICE='minecraft.service'
IDLE_SERVICE='minecraft-idle.service'

cat > "$SERVER_DIR/run.sh" <<EOF
#!/usr/bin/env bash
cd "${SERVER_DIR}" || exit 1
exec java -Dlog4j.configurationFile=log4j2.xml -Xms1G -Xmx${RAM_MAX}G -jar server.jar nogui
EOF
cat > "$SERVER_DIR/stop.sh" <<'EOF'
#!/usr/bin/env bash
if ! screen -S minecraft -p 0 -X stuff "$(printf 'stop\r')"; then
    echo '[WARN] Keine aktive Minecraft-Screen-Session.' >&2
    exit 1
fi
for ((i=0; i<120; i++)); do
    screen -ls | grep -Eq '[.]minecraft[[:space:]]' || exit 0
    sleep 1
done
echo '[FEHLER] Server wurde nicht innerhalb von 120 Sekunden beendet.' >&2
exit 1
EOF
cat > "$SERVER_DIR/start.sh" <<'EOF'
#!/usr/bin/env bash
if ! systemctl is-active --quiet minecraft.service; then
    echo '[INFO] Starte Minecraft ...'
    sudo systemctl start minecraft.service || exit 1
fi
echo '[INFO] Verbinde mit der Konsole (Trennen: Strg+A, dann D).'
for ((i=0; i<60; i++)); do
    if screen -ls | grep -Eq '[.]minecraft[[:space:]]'; then
        exec screen -r minecraft
    fi
    sleep 1
done
echo '[FEHLER] Screen-Session nicht gefunden.' >&2
exit 1
EOF
chmod 750 "$SERVER_DIR/run.sh" "$SERVER_DIR/stop.sh"
chmod 755 "$SERVER_DIR/start.sh"

sudo tee "/etc/systemd/system/$MC_SERVICE" >/dev/null <<EOF
[Unit]
Description=Minecraft Server
Wants=network-online.target minecraft-idle.service
After=network-online.target

[Service]
Type=exec
User=$MC_USER
Group=$MC_GROUP
WorkingDirectory=$SERVER_DIR
ExecStart=/usr/bin/screen -D -m -S minecraft $SERVER_DIR/run.sh
ExecStop=$SERVER_DIR/stop.sh
Restart=on-failure
RestartSec=10
TimeoutStopSec=130
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF

# Watchdog als root, damit er die gesamte Maschine ausschalten kann.
# Passwort nur fuer root lesbar; RCON-Fehler fuehren nie zu einem Shutdown.
sudo tee /usr/local/bin/minecraft-idle.sh >/dev/null <<EOF
#!/usr/bin/env bash
set -u
SERVER_DIR="$SERVER_DIR"
RCON_PORT=$RCON_PORT
PASSWORD=\$(<"\$SERVER_DIR/.rcon_password") || exit 1
EMPTY_SINCE=0
while true; do
    RESPONSE=\$(timeout 5 mcrcon -H 127.0.0.1 -P "\$RCON_PORT" -p "\$PASSWORD" list 2>/dev/null)
    if [[ "\$RESPONSE" =~ There[[:space:]]are[[:space:]]([0-9]+)[[:space:]]of ]]; then
        PLAYERS="\${BASH_REMATCH[1]}"
        if (( PLAYERS > 0 )); then
            EMPTY_SINCE=0
        elif (( EMPTY_SINCE == 0 )); then
            EMPTY_SINCE=\$(date +%s)
        elif (( \$(date +%s) - EMPTY_SINCE >= 300 )); then
            echo '[INFO] Seit 5 Minuten keine Spieler online. Ubuntu wird heruntergefahren.'
            systemctl poweroff
            exit 0
        fi
    else
        EMPTY_SINCE=0
    fi
    sleep 30
done
EOF
sudo chmod 700 /usr/local/bin/minecraft-idle.sh
sudo tee "/etc/systemd/system/$IDLE_SERVICE" >/dev/null <<'EOF'
[Unit]
# Unabhaengig vom Minecraft-Lebenszyklus: bleibt bei Server-Restarts aktiv.
Description=Minecraft Idle Shutdown
After=minecraft.service

[Service]
Type=simple
ExecStart=/usr/local/bin/minecraft-idle.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload || fail 'systemd konnte nicht neu geladen werden.'
sudo systemctl enable "$MC_SERVICE" "$IDLE_SERVICE" >/dev/null || fail 'Services konnten nicht aktiviert werden.'
sudo systemctl start "$MC_SERVICE" || fail 'Minecraft-Service konnte nicht gestartet werden.'
sudo systemctl start "$IDLE_SERVICE" || fail 'Idle-Service konnte nicht gestartet werden.'

section 'Installation abgeschlossen'
ok "Serververzeichnis: $SERVER_DIR"
ok "Konsole: $SERVER_DIR/start.sh"
ok 'Autostart und Idle-Shutdown aktiviert (5 Minuten).'
info "Status: sudo systemctl status $MC_SERVICE $IDLE_SERVICE"
