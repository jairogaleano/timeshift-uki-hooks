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
SNAP_BTRFS="$TMP/snap-btrfs/@"   # layout Btrfs: <snap>/@/etc/...
SNAP_RSYNC="$TMP/snap-rsync"     # layout rsync: <snap>/etc/...

mkdir -p "$ESP" "$BACKUP" "$SNAP_BTRFS/etc" "$SNAP_RSYNC/etc"
: > "$LOG"

printf 'UKI-CURRENT' > "$ESP/${MID}-${KVER_CUR}.efi"
printf 'UKI-OLD'     > "$ESP/${MID}-${KVER_OLD}.efi"
printf 'UKI-GONE'    > "$ESP/${MID}-${KVER_GONE}.efi"
printf 'UKI-ROT'     > "$ESP/${MID}-${KVER_OLD}.bak.efi"   # rotacion vieja
printf 'CLASIC'      > "$ESP/arch-linux.efi"               # preset clasico (legacy)

CUR_EFI="${MID}-${KVER_CUR}.efi"

run_backup() {
    export TSUKI_UKI_DIR="$ESP" \
           TSUKI_BACKUP_DIR="$BACKUP" \
           TSUKI_LOG_FILE="$LOG" \
           TS_SNAPSHOT_PATH="$1"
    "$HOOK"
}

# --- Ejecutada 1: purga de obsoletos + respaldo en vivo y en snapshot -------

run_backup "$SNAP_BTRFS"

echo "[1/5] purga de UKIs de kernels desinstalados en la ESP"
assert_file "$ESP/${CUR_EFI}"        # el kernel en ejecucion nunca se toca
assert_no_file "$ESP/${MID}-${KVER_OLD}.efi"
assert_no_file "$ESP/${MID}-${KVER_GONE}.efi"
assert_no_file "$ESP/${MID}-${KVER_OLD}.bak.efi"
assert_file "$ESP/arch-linux.efi"    # preset clasico: sin version, no se decide nada
assert_log "kernel ${KVER_GONE} no instalado"
assert_log "Purgados 2 UKI(s) obsoletos"

echo "[2/5] respaldo solo con el UKI vigente (sistema vivo)"
assert_file "$BACKUP/${CUR_EFI}"
assert_file "$BACKUP/${CUR_EFI}.sha256"
assert_no_file "$BACKUP/${MID}-${KVER_OLD}.efi"
assert_no_file "$BACKUP/${MID}-${KVER_GONE}.efi"
assert_no_file "$BACKUP/arch-linux.efi"   # legacy en layouts kernel-install

# El .sha256 debe coincidir con el contenido real del UKI copiado
expected_sha="$(printf 'UKI-CURRENT' | sha256sum | awk '{print $1}')"
[ "$(cat "$BACKUP/${CUR_EFI}.sha256")" = "$expected_sha" ] \
    || fail "el .sha256 no coincide con el UKI copiado"

echo "[3/5] snapshot autocontenido (layout Btrfs: <snap>/@/etc/...)"
SNAP_BACKUP="$SNAP_BTRFS/etc/timeshift/uki-backup"
assert_file "$SNAP_BACKUP/${CUR_EFI}"
assert_file "$SNAP_BACKUP/${CUR_EFI}.sha256"

# --- Ejecutada 2: idempotencia (sin cambios => sin escrituras) --------------

# En una segunda ejecucion, sin cambios en la ESP ni en el respaldo, el hook no
# debe copiar ni podar nada: solo registrar "Sin cambios" en los dos destinos.
: > "$LOG"
run_backup "$SNAP_BTRFS"
echo "[4/5] segunda ejecucion idempotente"
assert_log "Sin cambios"
if grep -qE "Respaldo exitoso|Pruned UKI de la particion" "$LOG"; then
    fail "la segunda ejecucion volvio a copiar o podar (no es idempotente)"
fi

# --- Layout rsync: los UKIs tambien se escriben dentro del snapshot --------

rm -rf "$SNAP_RSYNC"
mkdir -p "$SNAP_RSYNC/etc"
run_backup "$SNAP_RSYNC"
echo "[5/5] snapshot autocontenido (layout rsync: <snap>/etc/...)"
assert_file "$SNAP_RSYNC/etc/timeshift/uki-backup/${CUR_EFI}"

# --- El restore hook al menos tiene que ser bash valido --------------------

bash -n "$RESTORE_HOOK"

echo ""
echo "OK: smoke test del backup hook correcto (log: $LOG)"