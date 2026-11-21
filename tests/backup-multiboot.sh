#!/bin/bash
# Test del backup hook: UKIs de otra instalacion, purga del snapshot y .sha256 reparable.
set -euo pipefail
HOOK="${1:-$(dirname "$0")/../hooks.d/backup/90-backup-uki}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ME=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

run() {
  TSUKI_UKI_DIR="$T/esp" TSUKI_BACKUP_DIR="$T/backup" TSUKI_LOG_FILE="$T/log" \
  TSUKI_LOCK_FILE="$T/lock" TSUKI_MACHINE_ID="$ME" TSUKI_KVER="2.0" \
  TSUKI_MODULES_DIR="$T/modules" TS_SNAPSHOT_PATH="${SNAP:-}" bash "$HOOK" >/dev/null
}
mkdir -p "$T/esp" "$T/modules/2.0" "$T/snap/@/etc/timeshift/uki-backup"
echo cur  > "$T/esp/$ME-2.0.efi"
echo old  > "$T/esp/$ME-1.0.efi"      # propio, kernel desinstalado
echo oth  > "$T/esp/$OTHER-9.9.efi"   # otra instalacion
echo leg  > "$T/esp/arch-linux.efi"

echo "[1] UKI de otra instalacion no se borra"
SNAP="$T/snap" run
check "UKI ajeno sigue en la ESP"            '[ -f "$T/esp/$OTHER-9.9.efi" ]'
check "UKI propio obsoleto purgado de la ESP" '[ ! -f "$T/esp/$ME-1.0.efi" ]'
check "UKI vigente intacto"                  '[ -f "$T/esp/$ME-2.0.efi" ]'
check "UKI ajeno NO entra en el respaldo"    '[ ! -f "$T/backup/$OTHER-9.9.efi" ]'
check "respaldo tiene el vigente + sha256"   '[ -f "$T/backup/$ME-2.0.efi.sha256" ]'

echo "[2] el snapshot se purga siempre (antes: skip_prune)"
echo stale > "$T/snap/@/etc/timeshift/uki-backup/$ME-0.5.efi"
echo x     > "$T/snap/@/etc/timeshift/uki-backup/$ME-0.5.efi.sha256"
SNAP="$T/snap" run
check "UKI viejo del snapshot purgado"       '[ ! -f "$T/snap/@/etc/timeshift/uki-backup/$ME-0.5.efi" ]'
check "snapshot contiene el vigente"         '[ -f "$T/snap/@/etc/timeshift/uki-backup/$ME-2.0.efi" ]'

echo "[3] .sha256 ausente o erroneo se repara aunque el UKI sea identico"
rm -f "$T/backup/$ME-2.0.efi.sha256"
SNAP="$T/snap" run
check "sha256 recreado"                      '[ -s "$T/backup/$ME-2.0.efi.sha256" ]'
echo deadbeef > "$T/snap/@/etc/timeshift/uki-backup/$ME-2.0.efi.sha256"
SNAP="$T/snap" run
# shellcheck disable=SC2034  # usada dentro de eval en check()
want=$(sha256sum "$T/esp/$ME-2.0.efi" | awk '{print $1}')
check "sha256 erroneo corregido"             '[ "$(cat "$T/snap/@/etc/timeshift/uki-backup/$ME-2.0.efi.sha256")" = "$want" ]'

echo "[4] sin machine-id no se poda"
echo old2 > "$T/esp/$ME-1.1.efi"
TSUKI_MACHINE_ID="" TSUKI_UKI_DIR="$T/esp" TSUKI_BACKUP_DIR="$T/backup" TSUKI_LOG_FILE="$T/log" \
  TSUKI_LOCK_FILE="$T/lock" TSUKI_KVER=2.0 TSUKI_MODULES_DIR="$T/modules" bash -c "
  sed 's#/etc/machine-id#/nonexistent#' '$HOOK' > '$T/h.sh'; bash '$T/h.sh' >/dev/null" || true
check "nada borrado sin machine-id"          '[ -f "$T/esp/$ME-1.1.efi" ]'
check "sin temporales huerfanos"             '! ls "$T"/backup/.tmp_* >/dev/null 2>&1'

echo; echo "Resultado: $pass ok, $fail fallos"; [ "$fail" -eq 0 ]
