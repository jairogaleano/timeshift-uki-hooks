#!/usr/bin/env bash
#
# Test de resolucion de la particion de arranque (restore hook, v3.6).
#
# QUE TESTEA
# ----------
# resolve_esp_mount() aceptaba el PRIMER mountpoint de /boot, /efi, /boot/efi
# sin comprobar nada. Con dos vfat montadas (el layout de dual-boot) y la
# particion que tiene los UKIs sin montar, elegia la otra; y como el destino se
# creaba con `mkdir -p`, los UKIs acababan ahi y el error quedaba "confirmado"
# para siempre. Con PRUNE_UKIS=true ademas se borraban los .efi que no
# estuvieran en el respaldo de esa particion.
#
# Desde v3.6 una particion solo es candidata si esta montada y tiene el
# directorio EFI/Linux (que es donde kernel-install deja los UKIs). Si no hay
# ninguna, el hook aborta en vez de adivinar.
#
# COMO LO TESTEA
# --------------
# Con un namespace de usuario se levanta un chroot minimo (bind mounts de
# /usr, /dev, /sys y /proc) donde /boot y /efi se manipulan a voluntad:
# montarlas o dejarlas como directorios planos, y poner los UKIs en una u
# otra. Asi se ejercita el codigo de produccion tal cual, sin variables de
# entorno ni seams que solo usen los tests; los unicos overrides son
# TSUKI_BACKUP_DIR y TSUKI_LOG_FILE, que ya existen para esto.
#
# Hace falta el chroot porque en el namespace no se puede DESMONTAR el /boot
# real (los montajes heredados van bloqueados), de modo que "particion de los
# UKIs sin montar" no se puede simular de otra forma.
#
# Si las user namespaces no estan habilitadas, el test FALLA en vez de
# saltarse en silencio: un test que se salta solo no es cobertura.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
RESTORE_HOOK="$ROOT/hooks.d/restore/90-restore-uki"

# Re-ejecutarse dentro de un namespace de usuario con montajes privados y su
# propio /proc (necesario para que mountpoint y findmnt sean fiables).
if [ "${TSUKI_TEST_NS:-}" != "1" ]; then
    if ! unshare -r -m -p -f --mount-proc true 2>/dev/null; then
        echo "FALLO: no se pueden crear namespaces de usuario con /proc propio." >&2
        echo "       El test de particion de arranque no puede ejecutarse." >&2
        exit 1
    fi
    exec unshare -r -m -p -f --mount-proc env TSUKI_TEST_NS=1 bash "$0" "$@"
fi

MID="$(cat /etc/machine-id)"
KVER="$(uname -r)"
CUR_EFI="${MID}-${KVER}.efi"

TMP="$(mktemp -d)"
R="$TMP/root"
LOG="$R/tmp/restore.log"
cleanup() {
    umount "$R/boot" "$R/efi" 2>/dev/null || true
    umount -R "$R" 2>/dev/null || true
    chmod -R u+w "$TMP" 2>/dev/null || true
    rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
    echo "  FALLO: $*" >&2
    echo "  --- log del hook ---" >&2
    sed 's/^/  | /' "$LOG" >&2 2>/dev/null || echo "  | (sin log)" >&2
    exit 1
}

# --- chroot minimo ---------------------------------------------------------
build_chroot() {
    mkdir -p "$R"/usr "$R"/dev "$R"/sys "$R"/boot "$R"/efi \
             "$R"/etc "$R"/proc "$R"/tmp "$R"/backup \
             "$R"/hooks.d/restore
    ln -s usr/bin "$R/bin"
    ln -s usr/lib "$R/lib"
    ln -s usr/lib "$R/lib64"
    ln -s usr/sbin "$R/sbin"
    mount --rbind /usr  "$R/usr"
    mount --rbind /dev  "$R/dev"
    mount --rbind /sys  "$R/sys"
    mount --rbind /proc "$R/proc"
    cp /etc/machine-id "$R/etc/machine-id"
    cp /etc/nsswitch.conf "$R/etc/" 2>/dev/null || true
    # fstab vacio: el hook no debe poder montar nada por su cuenta. Asi el
    # unico camino valido para el destino es EFI/Linux, nunca un mkdir.
    : > "$R/etc/fstab"
    cp "$RESTORE_HOOK" "$R/hooks.d/restore/90-restore-uki"
    chmod +x "$R/hooks.d/restore/90-restore-uki"
}

# --- Escenarios ------------------------------------------------------------
# Un UKI en el arbol de la particion indicada.
put_uki() {
    mkdir -p "$1/EFI/Linux"
    printf 'UKI' > "$1/EFI/Linux/$CUR_EFI"
}

# setup <donde viven los UKIs> <que particiones estan montadas>
#   ukis_on:    boot | efi | both | none
#   mounted:    boot | efi | both | none
# Lo que NO esta montado simplemente no se ve desde dentro del chroot, que es
# justo lo que pasa cuando el usuario restaura desde un Live USB sin montar la
# particion de arranque.
setup() {
    umount "$R/boot" "$R/efi" 2>/dev/null || true
    rm -rf "$TMP/src-boot" "$TMP/src-efi" "${R:?}/boot" "${R:?}/efi"
    mkdir -p "$TMP/src-boot" "$TMP/src-efi" "$R/boot" "$R/efi"

    # Una particion sin UKIs tiene su arbol habitual pero NO EFI/Linux.
    # /efi lleva ademas el arbol de arranque de Windows.
    mkdir -p "$TMP/src-boot/EFI/BOOT" "$TMP/src-efi/EFI/Microsoft/Boot"

    case "$1" in
        boot) put_uki "$TMP/src-boot" ;;
        efi)  put_uki "$TMP/src-efi" ;;
        both) put_uki "$TMP/src-boot"; put_uki "$TMP/src-efi" ;;
        none) ;;
    esac

    case "$2" in
        boot) mount --bind "$TMP/src-boot" "$R/boot" ;;
        efi)  mount --bind "$TMP/src-efi"  "$R/efi" ;;
        both) mount --bind "$TMP/src-boot" "$R/boot"
              mount --bind "$TMP/src-efi"  "$R/efi" ;;
    esac
}

run_restore() {
    : > "$LOG"
    set +e
    chroot "$R" /bin/bash -c \
        "TSUKI_BACKUP_DIR=/backup TSUKI_LOG_FILE=/tmp/restore.log /hooks.d/restore/90-restore-uki" \
        >/dev/null 2>&1
    echo $?
    set -e
}

# El UKI de respaldo. El formato del .sha256 es el que escribe el backup hook
# (hash pelado, sin nombre); el formato `sha256sum` se prueba aparte en el
# caso F.
mkdir -p "$R/backup"
printf 'UKI' > "$R/backup/$CUR_EFI"
bare_sha="$(sha256sum "$R/backup/$CUR_EFI" | awk '{print $1}')"
printf '%s\n' "$bare_sha" > "$R/backup/$CUR_EFI.sha256"

build_chroot

# --- A: UKIs en /boot, /boot montada -> usa /boot --------------------------
setup boot boot
rc=$(run_restore)
[ "$rc" -eq 0 ] || fail "caso A: se esperaba exito, rc=$rc"
grep -q "Particion de arranque (UKIs) en: /boot" "$LOG" || fail "caso A: no eligio /boot"
[ -f "$TMP/src-boot/EFI/Linux/$CUR_EFI" ] || fail "caso A: el UKI no quedo en /boot"
[ ! -e "$TMP/src-efi/EFI/Linux" ] || fail "caso A: toco /efi, que no tiene UKIs"
echo "  A: UKIs en /boot, montada            -> usa /boot, no toca /efi"

# --- B: UKIs en /boot SIN montar, /efi montada (sin EFI/Linux) -------------
# Este es el bug. UKIs en la particion de arranque no montada, ESP de Windows
# montada: el hook NO puede elegir /efi ni fabricarse alli el directorio.
setup boot efi
rc=$(run_restore)
[ "$rc" -ne 0 ] || fail "caso B: deberia abortar, no restaurar en la particion equivocada"
grep -q "No se encontro la particion de arranque" "$LOG" \
    || fail "caso B: no dio el error de particion de arranque"
[ ! -e "$TMP/src-efi/EFI/Linux" ] \
    || fail "caso B: creo /efi/EFI/Linux en la particion equivocada (el bug)"
echo "  B: UKIs en /boot sin montar, /efi     -> ABORTA, ESP de Windows intacta"

# --- C: espejo de B: UKIs en /efi sin montar, /boot montada ---------------
# Al reves: /boot es la primera de la lista, asi que el bug de v3.5 lo sufria
# sin tan siquiera tener que mirar mas.
setup efi boot
rc=$(run_restore)
[ "$rc" -ne 0 ] || fail "caso C: deberia abortar, no restaurar en /boot"
[ ! -e "$TMP/src-boot/EFI/Linux" ] \
    || fail "caso C: creo /boot/EFI/Linux en la particion equivocada (el bug)"
echo "  C: UKIs en /efi sin montar, /boot     -> ABORTA, /boot intacto"

# --- D: UKIs en /efi, /efi montada -> usa /efi ----------------------------
setup efi efi
rc=$(run_restore)
[ "$rc" -eq 0 ] || fail "caso D: se esperaba exito, rc=$rc"
grep -q "Particion de arranque (UKIs) en: /efi" "$LOG" || fail "caso D: no eligio /efi"
[ -f "$TMP/src-efi/EFI/Linux/$CUR_EFI" ] || fail "caso D: el UKI no quedo en /efi"
[ ! -e "$TMP/src-boot/EFI/Linux" ] || fail "caso D: toco /boot, que no tiene UKIs"
echo "  D: UKIs en /efi, montada              -> usa /efi, no toca /boot"

# --- E: UKIs en las dos, /boot montada -> preferencia de /boot -------------
setup both boot
rc=$(run_restore)
[ "$rc" -eq 0 ] || fail "caso E: se esperaba exito, rc=$rc"
grep -q "Particion de arranque (UKIs) en: /boot" "$LOG" || fail "caso E: deberia preferir /boot"
echo "  E: UKIs en ambas, /boot montada       -> prefiere /boot"

# --- F: ninguna particion tiene EFI/Linux -> ABORTA, no adivina ------------
setup none none
rc=$(run_restore)
[ "$rc" -ne 0 ] || fail "caso F: deberia abortar, no restaurar en ninguna parte"
grep -q "No se encontro la particion de arranque" "$LOG" \
    || fail "caso F: no dio el error de particion de arranque"
[ ! -e "$TMP/src-boot/EFI/Linux" ] || fail "caso F: creo /boot/EFI/Linux (no deberia)"
[ ! -e "$TMP/src-efi/EFI/Linux" ]  || fail "caso F: creo /efi/EFI/Linux (no deberia)"
echo "  F: ninguna particion sirve           -> ABORTA sin crear nada"

# --- G: UKIs de un kernel no instalado no se restauran de mas -------------
# Solo hay un UKI en el respaldo y es el vigente: nada mas que copiar.
setup boot boot
printf 'UKI-VIEJO' > "$R/backup/obsoleto-1.0.efi"
old_sha="$(sha256sum "$R/backup/obsoleto-1.0.efi" | awk '{print $1}')"
printf '%s\n' "$old_sha" > "$R/backup/obsoleto-1.0.efi.sha256"
rc=$(run_restore)
[ "$rc" -eq 0 ] || fail "caso G: se esperaba exito, rc=$rc"
[ -f "$TMP/src-boot/EFI/Linux/obsoleto-1.0.efi" ] \
    || fail "caso G: no restauro un UKI que si estaba en el respaldo"
rm -f "$R/backup/obsoleto-1.0.efi" "$R/backup/obsoleto-1.0.efi.sha256"
echo "  G: UKI con kernel desconocido         -> tambien se restaura"

# --- H: .sha256 en formato `sha256sum` ("hash  nombre") --------------------
# El backup hook escribe solo el hash, pero un .sha256 hecho a mano con
# `sha256sum UKI > UKI.sha256` (o cualquier tooling que use ese formato) trae
# el nombre pegado. Antes de v3.6 el hook comparaba el fichero entero contra
# el hash pelado, con lo que ese formato hacia fallar la verificacion y ABORTAR
# la restauracion con un hash perfectamente correcto.
setup boot boot
printf '%s  %s\n' "$bare_sha" "$CUR_EFI" > "$R/backup/$CUR_EFI.sha256"
rc=$(run_restore)
[ "$rc" -eq 0 ] \
    || fail "caso H: un .sha256 en formato sha256sum deberia aceptarse, rc=$rc"
grep -q "Checksum verificado para $CUR_EFI" "$LOG" \
    || fail "caso H: no verifico el checksum (hash correcto, formato sha256sum)"
echo "  H: .sha256 formato 'sha256sum'       -> se acepta y verifica"

# --- I: .sha256 corrupto -> ABORTA, no restaura basura ---------------------
setup boot boot
printf '%064d\n' 0 > "$R/backup/$CUR_EFI.sha256"
rc=$(run_restore)
[ "$rc" -ne 0 ] || fail "caso I: deberia abortar con checksum incorrecto"
grep -q "Checksum fallo para $CUR_EFI" "$LOG" \
    || fail "caso I: no reporto el fallo de checksum"
echo "  I: .sha256 corrupto                  -> ABORTA en vez de restaurar basura"

echo "  OK: 9/9 casos (6 de particion de arranque + 3 de checksum)"