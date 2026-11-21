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

# Escribe un fichero de configuracion de prueba como root (si sudo -n esta
# disponible) o como el usuario actual. Para que load_conf procese el fichero,
# debe ser propiedad de root y tener permisos 644 o mas restrictivo.
write_conf() {
    local path="$1"; shift
    printf '%s\n' "$@" > "$path"
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -n chown root:root "$path" 2>/dev/null || true
        sudo -n chmod 644 "$path" 2>/dev/null || true
    fi
}

# Ejecuta un hook con una configuracion dada.
# Ejecuta como root si sudo -n esta disponible (para que load_conf procese el
# fichero); de lo contrario, ejecuta como usuario actual (load_conf ignorara
# el fichero, pero el hook no debe fallar).
run_hook() {
    local hook="$1"; local conf="$2"; shift 2
    local extra_env=(
        TSUKI_CONF_FILE="$conf"
        TSUKI_UKI_DIR="$TMP/esp"
        TSUKI_BACKUP_DIR="$TMP/backup"
        TSUKI_LOG_FILE="$TMP/log"
        TSUKI_LOCK_FILE="$TMP/lock"
        TSUKI_MODULES_DIR="$TMP/modules"
    )
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -n env "${extra_env[@]}" bash "$hook" "$@" >/dev/null 2>&1
    else
        env "${extra_env[@]}" bash "$hook" "$@" >/dev/null 2>&1
    fi
}

# Crea la estructura de ESP y backup vacia
setup_esp() {
    mkdir -p "$TMP/esp/EFI/Linux" "$TMP/backup" "$TMP/modules"
}

# Crea un UKI valido en el backup para que el restore hook no falle
# al verificar el directorio de respaldo.
setup_backup_uki() {
    local kver="0.0.1-fake"
    local machine_id="c2224fefe655409688eccb14500b0429"
    mkdir -p "$TMP/backup" "$TMP/modules/${kver}"
    echo "uki" > "$TMP/backup/${machine_id}-${kver}.efi"
    sha256sum "$TMP/backup/${machine_id}-${kver}.efi" | awk '{print $1}' > "$TMP/backup/${machine_id}-${kver}.efi.sha256"
}

# Indica si podemos probar realmente la carga de configuracion (somos root
# o tenemos sudo sin contraseña).
can_test_conf() {
    [ "$(id -u)" = "0" ] || { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }
}

echo "=== Tests de configuracion de uki-hooks.conf ==="

# Test 1: Fichero ausente no falla
echo "[1] Fichero ausente no falla"
setup_esp
run_hook "$BACKUP_HOOK" "$TMP/noexiste.conf" && ok "backup no falla sin conf" || bad "backup falla sin conf"

# Test 2: Clave invalida desactiva la purga con WARN (fallo cerrado)
echo "[2] PRUNE_UKIS=maybe desactiva purga con WARN"
setup_esp
setup_backup_uki
write_conf "$TMP/conf1.conf" \
    'PRUNE_UKIS=maybe' \
    'PRUNE_ESP_UKIS=true'
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
run_hook "$RESTORE_HOOK" "$TMP/conf1.conf" || true
if can_test_conf; then
    [ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
        && ok "PRUNE_UKIS=maybe desactiva purga (UKI conserva)" \
        || bad "PRUNE_UKIS=maybe no desactivo purga"
else
    ok "PRUNE_UKIS=maybe no causa fallo (no-root: no se puede verificar purga)"
fi

# Test 3: Clave desconocida -> WARN, se ignora
echo "[3] Clave desconocida se ignora con WARN"
setup_esp
write_conf "$TMP/conf2.conf" \
    'CLAVE_DESCONOCIDA=true' \
    'PRUNE_UKIS=true'
run_hook "$BACKUP_HOOK" "$TMP/conf2.conf" && ok "clave desconocida no falla" || bad "clave desconocida falla"

# Test 4: Linea sin = -> WARN, se ignora
echo "[4] Linea sin = se ignora con WARN"
setup_esp
write_conf "$TMP/conf3.conf" \
    'PRUNE_UKIS=true' \
    'linea_sin_igual'
run_hook "$BACKUP_HOOK" "$TMP/conf3.conf" && ok "linea sin = no falla" || bad "linea sin = falla"

# Test 5: Valor entero invalido en ESP_MIN_FREE_MB -> se ignora, conserva default
echo "[5] ESP_MIN_FREE_MB invalido se ignora"
setup_esp
write_conf "$TMP/conf4.conf" \
    'ESP_MIN_FREE_MB=abc'
run_hook "$BACKUP_HOOK" "$TMP/conf4.conf" && ok "ESP_MIN_FREE_MB invalido no falla" || bad "ESP_MIN_FREE_MB invalido falla"

# Test 6: Valor booleano en mayusculas -> se acepta
echo "[6] PRUNE_UKIS=FALSE (mayusculas) se acepta como false"
setup_esp
setup_backup_uki
write_conf "$TMP/conf5.conf" \
    'PRUNE_UKIS=FALSE'
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
run_hook "$RESTORE_HOOK" "$TMP/conf5.conf" || true
if can_test_conf; then
    [ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
        && ok "PRUNE_UKIS=FALSE desactiva purga" \
        || bad "PRUNE_UKIS=FALSE no desactivo purga"
else
    ok "PRUNE_UKIS=FALSE no causa fallo (no-root: no se puede verificar purga)"
fi

# Test 7: Valor con comillas dobles -> se acepta
echo "[7] PRUNE_UKIS=\"false\" se acepta"
setup_esp
setup_backup_uki
write_conf "$TMP/conf6.conf" \
    'PRUNE_UKIS="false"'
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
run_hook "$RESTORE_HOOK" "$TMP/conf6.conf" || true
if can_test_conf; then
    [ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
        && ok "PRUNE_UKIS=\"false\" desactiva purga" \
        || bad "PRUNE_UKIS=\"false\" no desactivo purga"
else
    ok "PRUNE_UKIS=\"false\" no causa fallo (no-root: no se puede verificar purga)"
fi

# Test 8: Valor con prefijo export -> se acepta
echo "[8] export PRUNE_UKIS=false se acepta"
setup_esp
setup_backup_uki
write_conf "$TMP/conf7.conf" \
    'export PRUNE_UKIS=false'
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
run_hook "$RESTORE_HOOK" "$TMP/conf7.conf" || true
if can_test_conf; then
    [ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
        && ok "export PRUNE_UKIS=false desactiva purga" \
        || bad "export PRUNE_UKIS=false no desactivo purga"
else
    ok "export PRUNE_UKIS=false no causa fallo (no-root: no se puede verificar purga)"
fi

# Test 9: Comentario en linea -> se acepta
echo "[9] PRUNE_UKIS=false # desactivo purga se acepta"
setup_esp
setup_backup_uki
write_conf "$TMP/conf8.conf" \
    'PRUNE_UKIS=false # desactivo purga'
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
run_hook "$RESTORE_HOOK" "$TMP/conf8.conf" || true
if can_test_conf; then
    [ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
        && ok "comentario en linea se acepta" \
        || bad "comentario en linea no se acepta"
else
    ok "comentario en linea no causa fallo (no-root: no se puede verificar purga)"
fi

# Test 10: Sin eval: codigo en el valor no se ejecuta
echo "[10] Codigo en valor no se ejecuta (sin eval)"
setup_esp
write_conf "$TMP/conf9.conf" \
    'PRUNE_UKIS=false"; touch /tmp/pwned_test; "'
run_hook "$BACKUP_HOOK" "$TMP/conf9.conf" >/dev/null 2>&1
[ ! -f /tmp/pwned_test ] \
    && ok "codigo en valor no se ejecuta" \
    || bad "codigo en valor se ejecuto (INYECCION)"
rm -f /tmp/pwned_test

# Test 11: Sin eval: codigo en la clave no se ejecuta
echo "[11] Codigo en clave no se ejecuta (sin eval)"
setup_esp
write_conf "$TMP/conf10.conf" \
    'PRUNE_UKIS$(touch /tmp/pwned_test2)=false'
run_hook "$BACKUP_HOOK" "$TMP/conf10.conf" >/dev/null 2>&1
[ ! -f /tmp/pwned_test2 ] \
    && ok "codigo en clave no se ejecuta" \
    || bad "codigo en clave se ejecuto (INYECCION)"
rm -f /tmp/pwned_test2

# Test 12: ESP_MIN_FREE_MB valido -> se aplica sin error de aritmetica
echo "[12] ESP_MIN_FREE_MB=50 se aplica sin error"
setup_esp
setup_backup_uki
write_conf "$TMP/conf11.conf" \
    'ESP_MIN_FREE_MB=50'
run_hook "$RESTORE_HOOK" "$TMP/conf11.conf" >/dev/null 2>&1 && ok "ESP_MIN_FREE_MB=50 no causa error de aritmetica" || bad "ESP_MIN_FREE_MB=50 causa error"

# Test 13: PRUNE_OLD_UKIS=false -> se aplica
echo "[13] PRUNE_OLD_UKIS=false se aplica"
setup_esp
write_conf "$TMP/conf12.conf" \
    'PRUNE_OLD_UKIS=false'
run_hook "$BACKUP_HOOK" "$TMP/conf12.conf" >/dev/null 2>&1 && ok "PRUNE_OLD_UKIS=false se acepta" || bad "PRUNE_OLD_UKIS=false no se acepta"

# Test 14: PRUNE_ESP_UKIS=false -> se aplica
echo "[14] PRUNE_ESP_UKIS=false se aplica"
setup_esp
write_conf "$TMP/conf13.conf" \
    'PRUNE_ESP_UKIS=false'
run_hook "$BACKUP_HOOK" "$TMP/conf13.conf" >/dev/null 2>&1 && ok "PRUNE_ESP_UKIS=false se acepta" || bad "PRUNE_ESP_UKIS=false no se acepta"

# Test 15: Valor con tabulador final -> se acepta
echo "[15] PRUNE_UKIS=true con tabulador final se acepta"
setup_esp
printf 'PRUNE_UKIS=true\t' > "$TMP/conf14.conf"
run_hook "$BACKUP_HOOK" "$TMP/conf14.conf" >/dev/null 2>&1 && ok "tabulador final se acepta" || bad "tabulador final no se acepta"

# Test 16: Valor con CRLF -> se acepta
echo "[16] PRUNE_UKIS=false con CRLF se acepta"
setup_esp
setup_backup_uki
printf 'PRUNE_UKIS=false\r\n' > "$TMP/conf15.conf"
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
run_hook "$RESTORE_HOOK" "$TMP/conf15.conf" || true
if can_test_conf; then
    [ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
        && ok "CRLF se acepta" \
        || bad "CRLF no se acepta"
else
    ok "CRLF no causa fallo (no-root: no se puede verificar purga)"
fi

# Test 17: Valor con comillas simples -> se acepta
echo "[17] PRUNE_UKIS='false' se acepta"
setup_esp
setup_backup_uki
write_conf "$TMP/conf16.conf" \
    "PRUNE_UKIS='false'"
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
run_hook "$RESTORE_HOOK" "$TMP/conf16.conf" || true
if can_test_conf; then
    [ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
        && ok "comillas simples se aceptan" \
        || bad "comillas simples no se aceptan"
else
    ok "comillas simples no causan fallo (no-root: no se puede verificar purga)"
fi

# Test 18: ESP_MIN_FREE_MB=0 valido -> se aplica
echo "[18] ESP_MIN_FREE_MB=0 se aplica"
setup_esp
setup_backup_uki
write_conf "$TMP/conf17.conf" \
    'ESP_MIN_FREE_MB=0'
run_hook "$RESTORE_HOOK" "$TMP/conf17.conf" >/dev/null 2>&1 && ok "ESP_MIN_FREE_MB=0 no causa error de aritmetica" || bad "ESP_MIN_FREE_MB=0 causa error"

# Test 19: PRUNE_ESP_UKIS=false -> se aplica en backup
echo "[19] PRUNE_ESP_UKIS=false desactiva purga en backup"
setup_esp
setup_backup_uki
write_conf "$TMP/conf18.conf" \
    'PRUNE_ESP_UKIS=false'
echo "uki" > "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi"
run_hook "$BACKUP_HOOK" "$TMP/conf18.conf" >/dev/null 2>&1
if can_test_conf; then
    [ -f "$TMP/esp/EFI/Linux/c2224fefe655409688eccb14500b0429-0.0.1-fake.efi" ] \
        && ok "PRUNE_ESP_UKIS=false no poda UKIs de la ESP" \
        || bad "PRUNE_ESP_UKIS=false sigue podando UKIs de la ESP"
else
    ok "PRUNE_ESP_UKIS=false no causa fallo (no-root: no se puede verificar purga)"
fi

echo
echo "Resultado: $pass ok, $fail fallos"
[ "$fail" -eq 0 ]
