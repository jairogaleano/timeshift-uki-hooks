#!/usr/bin/env bash
#
# Smoke test del backup hook contra un arbol de pruebas.
#
# No toca el sistema real: el hook respeta las variables de entorno
# TSUKI_UKI_DIR / TSUKI_BACKUP_DIR / TSUKI_LOG_FILE / TSUKI_SNAPSHOT_PATH,
# asi que aqui se ejecutan enteramente sobre un directorio temporal.
#
# Uso: ./tests/smoke.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
HOOK="$ROOT/hooks.d/backup/90-backup-uki"
RESTORE_HOOK="$ROOT/hooks.d/restore/90-restore-uki"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# machine-id con el formato que usa kernel-install (<32 hex>-<kver>.efi)
MID="0123456789abcdef0123456789abcdef"
KVER_CUR="$(uname -r)"      # kernel en ejecucion: SIEMPRE se conserva
KVER_OLD="0.0.1-fake-old"    # no instalado: se poda de la ESP y del respaldo
KVER_GONE="0.0.2-fake-gone"  # idem

fail() { echo "FALLO: $*" >&2; exit 1; }
assert_file() { [ -f "$1" ] || fail "se esperaba el fichero $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "no se esperaba el fichero $1"; }
assert_log() { grep -qF "$1" "$LOG" || fail "el log no contiene: $1"; }

# --- Arbol de pruebas -------------------------------------------------------

ESP="$TMP/esp/EFI/Linux"
BACKUP="$TMP/backup"
LOG="$TMP/timeshift.log"
SNAP_BTRFS="$TMP/snap-btrfs"     # layout Btrfs: <snap>/@/etc/... (TS_SNAPSHOT_PATH = raiz del snapshot)
SNAP_RSYNC="$TMP/snap-rsync"     # layout rsync: <snap>/localhost/etc/...

mkdir -p "$ESP" "$BACKUP" "$SNAP_BTRFS/@/etc" "$SNAP_RSYNC/localhost/etc"
: > "$LOG"

printf 'UKI-CURRENT' > "$ESP/${MID}-${KVER_CUR}.efi"
printf 'UKI-OLD'     > "$ESP/${MID}-${KVER_OLD}.efi"
printf 'UKI-GONE'    > "$ESP/${MID}-${KVER_GONE}.efi"
printf 'UKI-ROT'     > "$ESP/${MID}-${KVER_OLD}.bak.efi"   # rotacion vieja
printf 'CLASIC'      > "$ESP/arch-linux.efi"               # preset clasico (legacy)

CUR_EFI="${MID}-${KVER_CUR}.efi"

run_backup_to() {
    export TSUKI_UKI_DIR="$1" \
           TSUKI_BACKUP_DIR="$2" \
           TSUKI_LOG_FILE="$LOG" \
           TS_SNAPSHOT_PATH="$3"
    # El hook escribe cada mensaje a stdout Y al fichero de log. Aqui solo
    # interesa el fichero (assert_log lo lee de $LOG), asi que se silencia
    # stdout: sin esto el caso de la lista grande vuelca ~1400 lineas.
    "$HOOK" > /dev/null
}

run_backup() {
    run_backup_to "$ESP" "$BACKUP" "$1"
}

# --- Ejecutada 1: purga de obsoletos + respaldo en vivo y en snapshot -------

run_backup "$SNAP_BTRFS"

echo "[1/7] purga de UKIs de kernels desinstalados en la ESP"
assert_file "$ESP/${CUR_EFI}"        # el kernel en ejecucion nunca se toca
assert_no_file "$ESP/${MID}-${KVER_OLD}.efi"
assert_no_file "$ESP/${MID}-${KVER_GONE}.efi"
assert_no_file "$ESP/${MID}-${KVER_OLD}.bak.efi"
assert_file "$ESP/arch-linux.efi"    # preset clasico: sin version, no se decide nada
assert_log "kernel ${KVER_GONE} no instalado"
assert_log "Purgados 2 UKI(s) obsoletos"

echo "[2/7] respaldo solo con el UKI vigente (sistema vivo)"
assert_file "$BACKUP/${CUR_EFI}"
assert_file "$BACKUP/${CUR_EFI}.sha256"
assert_no_file "$BACKUP/${MID}-${KVER_OLD}.efi"
assert_no_file "$BACKUP/${MID}-${KVER_GONE}.efi"
assert_no_file "$BACKUP/arch-linux.efi"   # legacy en layouts kernel-install

# El .sha256 debe coincidir con el contenido real del UKI copiado
expected_sha="$(printf 'UKI-CURRENT' | sha256sum | awk '{print $1}')"
[ "$(cat "$BACKUP/${CUR_EFI}.sha256")" = "$expected_sha" ] \
    || fail "el .sha256 no coincide con el UKI copiado"

echo "[3/7] snapshot autocontenido (layout Btrfs: <snap>/@/etc/...)"
SNAP_BACKUP="$SNAP_BTRFS/@/etc/timeshift/uki-backup"
assert_file "$SNAP_BACKUP/${CUR_EFI}"
assert_file "$SNAP_BACKUP/${CUR_EFI}.sha256"

# --- Ejecutada 2: idempotencia (sin cambios => sin escrituras) --------------

# En una segunda ejecucion, sin cambios en la ESP ni en el respaldo, el hook no
# debe copiar ni podar nada: solo registrar "Sin cambios" en los dos destinos.
: > "$LOG"
run_backup "$SNAP_BTRFS"
echo "[4/7] segunda ejecucion idempotente"
assert_log "Sin cambios"
if grep -qE "Respaldo exitoso|Pruned UKI de la particion" "$LOG"; then
    fail "la segunda ejecucion volvio a copiar o podar (no es idempotente)"
fi

# --- Layout rsync: los UKIs tambien se escriben dentro del snapshot --------

rm -rf "$SNAP_RSYNC"
mkdir -p "$SNAP_RSYNC/localhost/etc"
run_backup "$SNAP_RSYNC"
echo "[5/7] snapshot autocontenido (layout rsync: <snap>/localhost/etc/...)"
assert_file "$SNAP_RSYNC/localhost/etc/timeshift/uki-backup/${CUR_EFI}"

# --- Regresion: lista grande de UKIs vigentes (SIGPIPE en printf|grep) ------
# El prune del respaldo comprobaba la pertenencia con
#   printf '%s\n' "${current_uki_names[@]}" | grep -qx "$base"
# En cuanto la lista supera el buffer de tuberia (64 KiB), grep sale al primer
# match y printf muere con SIGPIPE; con `set -o pipefail` la tuberia devuelve
# 141, el `!` lo interpreta como "no esta en el conjunto" y el hook BORRA un
# UKI vigente. Un nombre versionado mide ~50 B, asi que hacen falta >1300 UKIs
# del kernel actual para reproducirlo. Se generan con machine-id "f..." para
# que ordenen DESPUES del UKI real: el match sale en la primera linea y el
# SIGPIPE es seguro (con el orden inverso seria una carrera).
BIG_N=1400
for i in $(seq 1 "$BIG_N"); do
    printf -v big_efi 'f%031x-%s.efi' "$i" "$KVER_CUR"
    printf 'UKI-BIG' > "$ESP/$big_efi"
done
: > "$LOG"
# TS_SNAPSHOT_PATH inexistente: el hook solo emite un WARN y se salta la
# segunda copia. El prune que se prueba es el del respaldo vivo ($BACKUP_DIR),
# asi que no hace falta duplicar 1400 ficheros dentro del snapshot.
run_backup "$TMP/snap-invalido"        # 1a pasada: copia los 1400 al respaldo
echo "[6/7] lista grande de UKIs vigentes: no se poda ninguno (SIGPIPE)"
assert_file "$BACKUP/${CUR_EFI}"
if grep -q "Pruned UKI obsoleto" "$LOG"; then
    fail "el prune borro UKIs que debia conservar (¿SIGPIPE en la tuberia?)"
fi

# La purga actua sobre el DESTINO, no sobre la ESP: con el respaldo ya poblado,
# la segunda pasada recorre los 1401 UKIs y comprueba pertenencia en cada uno.
# Es ahi donde `printf | grep -qx` mataba printf por SIGPIPE y borraba en masa
# (medido: 1083 de 1401 con el idioma antiguo, el UKI vigente incluido).
: > "$LOG"
run_backup "$TMP/snap-invalido"
assert_file "$BACKUP/${CUR_EFI}"
if grep -q "Pruned UKI obsoleto" "$LOG"; then
    fail "el prune borro UKIs en la segunda pasada (¿SIGPIPE en la tuberia?)"
fi
assert_log "Sin cambios"

# --- Guarda: no dejar la particion de arranque sin UKIs versionados ---------
# Chroot de Live USB: el kernel en ejecucion es el del USB, asi que ningun UKI
# de la ESP tiene su kernel "instalado" y la purga se los llevaria TODOS. La
# guarda de supervivientes lo detecta (el borrado no dejaria ningun UKI
# versionado) y no poda nada: mejor UKIs obsoletos que quedarse sin arranque.
ESP_GUARD="$TMP/esp-guard/EFI/Linux"
BACKUP_GUARD="$TMP/backup-guard"
mkdir -p "$ESP_GUARD" "$BACKUP_GUARD"
printf 'UKI-OLD'  > "$ESP_GUARD/${MID}-${KVER_OLD}.efi"
printf 'UKI-GONE' > "$ESP_GUARD/${MID}-${KVER_GONE}.efi"
: > "$LOG"
run_backup_to "$ESP_GUARD" "$BACKUP_GUARD" "$TMP/snap-invalido"
echo "[7/7] sin UKI del kernel en ejecucion: la guarda impide vaciar la ESP"
assert_file "$ESP_GUARD/${MID}-${KVER_OLD}.efi"
assert_file "$ESP_GUARD/${MID}-${KVER_GONE}.efi"
assert_log "sin ningun UKI versionado; no se poda nada"
if grep -qE "Pruned UKI de la particion|Purgados [0-9]+ UKI" "$LOG"; then
    fail "la guarda de supervivientes no impidio la purga"
fi

# --- El restore hook al menos tiene que ser bash valido --------------------

bash -n "$RESTORE_HOOK"

# --- Resolucion de la particion de arranque (namespace + bind mounts) ------
# Vive en su propio fichero porque necesita un namespace de usuario con
# montajes privados sobre /boot y /efi. Ver tests/boot-partition.sh.
echo ""
echo "--- resolucion de la particion de arranque ---"
"$SCRIPT_DIR/boot-partition.sh"

echo ""
echo "OK: smoke test correcto (backup hook + particion de arranque)"