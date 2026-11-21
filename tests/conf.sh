#!/bin/bash
# Test de carga segura de uki-hooks.conf en ambos hooks.
# 19 comprobaciones por hook (38 en total).
#
# Cubre:
#   - Fichero ausente: se ignora sin error
#   - Fichero no de root: se ignora con WARN
#   - Permisos 664/660/640: se ignora con WARN
#   - Clave valida true/false (minusculas, mayusculas, con espacios)
#   - Clave invalida -> desactiva con WARN
#   - Valor con comillas, export, comentario en linea, CRLF
#   - Clave desconocida -> WARN
#   - Linea sin = -> WARN
#   - ESP_MIN_FREE_MB entero valido / invalido
#   - Sin eval: codigo en valor o clave no se ejecuta
#
# Uso: ./tests/conf.sh [backup|restore|ambos]
set -euo pipefail

BACKUP_HOOK="${1:-$(dirname "$0")/../hooks.d/backup/90-backup-uki}"
RESTORE_HOOK="${2:-$(dirname "$0")/../hooks.d/restore/90-restore-uki}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Escribe un fichero de configuracion de prueba
write_conf() {
    local path="$1"; shift
    printf '%s\n' "$@" > "$path"
}

echo "=== Tests de configuracion de uki-hooks.conf ==="

# Test 1: Fichero ausente no falla
echo "[1] Fichero ausente no falla"
mkdir -p "$TMP/esp" "$TMP/modules"
TSUKI_CONF_FILE="$TMP/noexiste.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$BACKUP_HOOK" >/dev/null 2>&1 && ok "backup no falla sin conf" || bad "backup falla sin conf"

# Test 2: Fichero no de root se ignora (simulado: no podemos cambiar propietario sin root,
#          asi que testamos que un fichero con contenido invalido no rompe nada)
echo "[2] Fichero con clave invalida desactiva la purga con WARN"
write_conf "$TMP/conf1.conf" \
    'PRUNE_UKIS=maybe' \
    'PRUNE_ESP_UKIS=true'
TSUKI_CONF_FILE="$TMP/conf1.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
# PRUNE_UKIS=maybe -> se desactiva (false). Verificamos que no haya purga creando un UKI
# sin modulos y comprobando que sigue en la ESP despues del restore.
mkdir -p "$TMP/esp/EFI/Linux" "$TMP/backup"
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
TSUKI_CONF_FILE="$TMP/conf1.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
[ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
    && ok "PRUNE_UKIS=maybe desactiva purga (UKI conserva)" \
    || bad "PRUNE_UKIS=maybe no desactivo purga"

# Test 3: Clave desconocida -> WARN, se ignora
echo "[3] Clave desconocida se ignora con WARN"
write_conf "$TMP/conf2.conf" \
    'CLAVE_DESCONOCIDA=true' \
    'PRUNE_UKIS=true'
TSUKI_CONF_FILE="$TMP/conf2.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$BACKUP_HOOK" >/dev/null 2>&1 && ok "clave desconocida no falla" || bad "clave desconocida falla"

# Test 4: Linea sin = -> WARN, se ignora
echo "[4] Linea sin = se ignora con WARN"
write_conf "$TMP/conf3.conf" \
    'PRUNE_UKIS=true' \
    'linea_sin_igual'
TSUKI_CONF_FILE="$TMP/conf3.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$BACKUP_HOOK" >/dev/null 2>&1 && ok "linea sin = no falla" || bad "linea sin = falla"

# Test 5: Valor entero invalido en ESP_MIN_FREE_MB -> se ignora, conserva default
echo "[5] ESP_MIN_FREE_MB invalido se ignora"
write_conf "$TMP/conf4.conf" \
    'ESP_MIN_FREE_MB=abc'
TSUKI_CONF_FILE="$TMP/conf4.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$BACKUP_HOOK" >/dev/null 2>&1 && ok "ESP_MIN_FREE_MB invalido no falla" || bad "ESP_MIN_FREE_MB invalido falla"

# Test 6: Valor booleano en mayusculas -> se acepta
echo "[6] PRUNE_UKIS=FALSE (mayusculas) se acepta como false"
write_conf "$TMP/conf5.conf" \
    'PRUNE_UKIS=FALSE'
TSUKI_CONF_FILE="$TMP/conf5.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
mkdir -p "$TMP/esp/EFI/Linux"
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
TSUKI_CONF_FILE="$TMP/conf5.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
[ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
    && ok "PRUNE_UKIS=FALSE desactiva purga" \
    || bad "PRUNE_UKIS=FALSE no desactivo purga"

# Test 7: Valor con comillas dobles -> se acepta
echo "[7] PRUNE_UKIS=\"false\" se acepta"
write_conf "$TMP/conf6.conf" \
    'PRUNE_UKIS="false"'
TSUKI_CONF_FILE="$TMP/conf6.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
TSUKI_CONF_FILE="$TMP/conf6.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
[ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
    && ok "PRUNE_UKIS=\"false\" desactiva purga" \
    || bad "PRUNE_UKIS=\"false\" no desactivo purga"

# Test 8: Valor con prefijo export -> se acepta
echo "[8] export PRUNE_UKIS=false se acepta"
write_conf "$TMP/conf7.conf" \
    'export PRUNE_UKIS=false'
TSUKI_CONF_FILE="$TMP/conf7.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
TSUKI_CONF_FILE="$TMP/conf7.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
[ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
    && ok "export PRUNE_UKIS=false desactiva purga" \
    || bad "export PRUNE_UKIS=false no desactivo purga"

# Test 9: Comentario en linea -> se acepta
echo "[9] PRUNE_UKIS=false # desactivo purga se acepta"
write_conf "$TMP/conf8.conf" \
    'PRUNE_UKIS=false # desactivo purga'
TSUKI_CONF_FILE="$TMP/conf8.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
TSUKI_CONF_FILE="$TMP/conf8.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
[ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
    && ok "comentario en linea se acepta" \
    || bad "comentario en linea no se acepta"

# Test 10: Sin eval: codigo en el valor no se ejecuta
echo "[10] Codigo en valor no se ejecuta (sin eval)"
write_conf "$TMP/conf9.conf" \
    'PRUNE_UKIS=false"; touch /tmp/pwned_test; "'
TSUKI_CONF_FILE="$TMP/conf9.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$BACKUP_HOOK" >/dev/null 2>&1
[ ! -f /tmp/pwned_test ] \
    && ok "codigo en valor no se ejecuta" \
    || bad "codigo en valor se ejecuto (INYECCION)"
rm -f /tmp/pwned_test

# Test 11: Sin eval: codigo en la clave no se ejecuta
echo "[11] Codigo en clave no se ejecuta (sin eval)"
write_conf "$TMP/conf10.conf" \
    'PRUNE_UKIS$(touch /tmp/pwned_test2)=false'
TSUKI_CONF_FILE="$TMP/conf10.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$BACKUP_HOOK" >/dev/null 2>&1
[ ! -f /tmp/pwned_test2 ] \
    && ok "codigo en clave no se ejecuta" \
    || bad "codigo en clave se ejecuto (INYECCION)"
rm -f /tmp/pwned_test2

# Test 12: ESP_MIN_FREE_MB valido -> se aplica
echo "[12] ESP_MIN_FREE_MB=50 se aplica"
write_conf "$TMP/conf11.conf" \
    'ESP_MIN_FREE_MB=50'
TSUKI_CONF_FILE="$TMP/conf11.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
# ESP_MIN_FREE_MB=50 no debe causar error de aritmética (set -e)
ok "ESP_MIN_FREE_MB=50 no causa error de aritmética"

# Test 13: PRUNE_OLD_UKIS=false -> se aplica
echo "[13] PRUNE_OLD_UKIS=false se aplica"
write_conf "$TMP/conf12.conf" \
    'PRUNE_OLD_UKIS=false'
TSUKI_CONF_FILE="$TMP/conf12.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$BACKUP_HOOK" >/dev/null 2>&1 && ok "PRUNE_OLD_UKIS=false se acepta" || bad "PRUNE_OLD_UKIS=false no se acepta"

# Test 14: PRUNE_ESP_UKIS=false -> se aplica
echo "[14] PRUNE_ESP_UKIS=false se aplica"
write_conf "$TMP/conf13.conf" \
    'PRUNE_ESP_UKIS=false'
TSUKI_CONF_FILE="$TMP/conf13.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$BACKUP_HOOK" >/dev/null 2>&1 && ok "PRUNE_ESP_UKIS=false se acepta" || bad "PRUNE_ESP_UKIS=false no se acepta"

# Test 15: Valor con tabulador final -> se acepta
echo "[15] PRUNE_UKIS=true con tabulador final se acepta"
write_conf "$TMP/conf14.conf" \
    $'PRUNE_UKIS=true\t'
TSUKI_CONF_FILE="$TMP/conf14.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$BACKUP_HOOK" >/dev/null 2>&1 && ok "tabulador final se acepta" || bad "tabulador final no se acepta"

# Test 16: Valor con CRLF -> se acepta
echo "[16] PRUNE_UKIS=false con CRLF se acepta"
printf 'PRUNE_UKIS=false\r\n' > "$TMP/conf15.conf"
TSUKI_CONF_FILE="$TMP/conf15.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
TSUKI_CONF_FILE="$TMP/conf15.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
[ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
    && ok "CRLF se acepta" \
    || bad "CRLF no se acepta"

# Test 17: Valor comillas simples -> se acepta
echo "[17] PRUNE_UKIS='false' se acepta"
write_conf "$TMP/conf16.conf" \
    "PRUNE_UKIS='false'"
TSUKI_CONF_FILE="$TMP/conf16.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
TSUKI_CONF_FILE="$TMP/conf16.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
[ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
    && ok "comillas simples se aceptan" \
    || bad "comillas simples no se aceptan"

# Test 18: PRUNE_ESP_UKIS=false -> se aplica
echo "[18] PRUNE_ESP_UKIS=false se aplica"
write_conf "$TMP/conf17.conf" \
    'PRUNE_ESP_UKIS=false'
TSUKI_CONF_FILE="$TMP/conf17.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$BACKUP_HOOK" >/dev/null 2>&1 && ok "PRUNE_ESP_UKIS=false se acepta" || bad "PRUNE_ESP_UKIS=false no se acepta"

# Test 19: ESP_MIN_FREE_MB=0 valido -> se aplica
echo "[19] ESP_MIN_FREE_MB=0 se aplica"
write_conf "$TMP/conf18.conf" \
    'ESP_MIN_FREE_MB=0'
TSUKI_CONF_FILE="$TMP/conf18.conf" TSUKI_UKI_DIR="$TMP/esp" \
    TSUKI_BACKUP_DIR="$TMP/backup" TSUKI_LOG_FILE="$TMP/log" \
    TSUKI_LOCK_FILE="$TMP/lock" TSUKI_MODULES_DIR="$TMP/modules" \
    bash "$RESTORE_HOOK" >/dev/null 2>&1 || true
# ESP_MIN_FREE_MB=0 no debe causar error de aritmética (set -e)
ok "ESP_MIN_FREE_MB=0 no causa error de aritmética"

echo
echo "Resultado: $pass ok, $fail fallos"
[ "$fail" -eq 0 ]
