#!/bin/bash
# Test del restore hook en user+mount namespace (sin ESP real ni privilegios).
# Cubre: UKIs de otra instalacion, y chequeo de espacio sin nada que copiar.
set -euo pipefail
HOOK="$(readlink -f "${1:-$(dirname "$0")/../hooks.d/restore/90-restore-uki}")"
if [ -z "${TSUKI_IN_NS:-}" ]; then
  exec env TSUKI_IN_NS=1 unshare -r -m -p -f bash "$(readlink -f "$0")" "$HOOK"
fi
ME=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; OTHER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
T=$(mktemp -d); pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
mkdir -p /boot; mount -t tmpfs -o size=40m tmpfs /boot   # ESP simulada (40 MB)
mkdir -p /boot/EFI/Linux "$T/backup" "$T/modules/2.0"
echo new > "$T/backup/$ME-2.0.efi"
sha256sum "$T/backup/$ME-2.0.efi" | awk '{print $1}' > "$T/backup/$ME-2.0.efi.sha256"
run() { TSUKI_BACKUP_DIR="$T/backup" TSUKI_MODULES_DIR="$T/modules" TSUKI_MACHINE_ID="$ME" \
        TSUKI_LOG_FILE="$T/log" TSUKI_LOCK_FILE="$T/lock" bash "$HOOK" >"$T/out" 2>&1; }

echo "[1] UKI de otra instalacion en la ESP compartida"
echo oth > /boot/EFI/Linux/$OTHER-9.9.efi
echo old > /boot/EFI/Linux/$ME-1.0.efi          # propio sin modulos
if run; then ok "restore termina con exito"; else bad "restore fallo: $(tail -3 "$T/out")"; fi
check "UKI ajeno intacto"        '[ -f /boot/EFI/Linux/$OTHER-9.9.efi ]'
check "UKI propio restaurado"    '[ -f /boot/EFI/Linux/$ME-2.0.efi ]'
check "UKI propio obsoleto podado" '[ ! -f /boot/EFI/Linux/$ME-1.0.efi ]'

echo "[2] ~5 MB libres (< margen de 20) y todo identico: no debe abortar"
dd if=/dev/zero of=/boot/filler bs=1M count=34 status=none
if run; then ok "sin escrituras pendientes no exige margen"; else bad "abortó: $(grep ERROR "$T/out" | head -2)"; fi

echo "[3] ESP completamente llena (0 MB) y UKI nuevo por copiar: debe abortar"
rm -f /boot/EFI/Linux/$ME-2.0.efi
dd if=/dev/zero of=/boot/filler2 bs=64k status=none 2>/dev/null || true
if run; then bad "debia abortar por espacio"; else check "aborta por espacio insuficiente" 'grep -q "Espacio insuficiente" "$T/out"'; fi

echo; echo "Resultado: $pass ok, $fail fallos"; [ "$fail" -eq 0 ]
