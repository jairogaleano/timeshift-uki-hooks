#!/bin/bash
#
# Timeshift UKI Hooks - Instalador v3.5
# Soporte universal: Arch, Debian, Fedora, openSUSE, Void, Gentoo, etc.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Version unica del repositorio (ver tambien .github/workflows/ci.yml, que
# comprueba que todos los ficheros la declaran coherente).
VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "desconocida")"

if [ "$EUID" -ne 0 ]; then
  echo "Por favor, ejecuta como root (pkexec ./install.sh o sudo ./install.sh)"
  exit 1
fi

# --- Deteccion de gestor de paquetes ---

detect_pkg_manager() {
  if command -v pacman &>/dev/null; then
    echo "pacman"
  elif command -v apt-get &>/dev/null; then
    echo "apt"
  elif command -v dnf &>/dev/null; then
    echo "dnf"
  elif command -v zypper &>/dev/null; then
    echo "zypper"
  elif command -v xbps-install &>/dev/null; then
    echo "xbps"
  elif command -v apk &>/dev/null; then
    echo "apk"
  else
    echo "unknown"
  fi
}

install_packages() {
  local pkgs=("$@")
  local mgr
  mgr=$(detect_pkg_manager)
  case "$mgr" in
    pacman) pacman -S --noconfirm "${pkgs[@]}" ;;
    apt)    apt-get update -qq && apt-get install -y "${pkgs[@]}" ;;
    dnf)    dnf install -y "${pkgs[@]}" ;;
    zypper) zypper install -y "${pkgs[@]}" ;;
    xbps)   xbps-install -y "${pkgs[@]}" ;;
    apk)    apk add --no-cache "${pkgs[@]}" ;;
    *)
      echo "Error: No se detecto un gestor de paquetes compatible."
      echo "Instala manualmente: ${pkgs[*]}"
      return 1
      ;;
  esac
}

# --- Verificacion de dependencias ---

echo "Verificando dependencias del sistema..."

# Herramienta -> Paquete (nombres en la mayoria de distros)
# findmnt/lsblk/mountpoint -> util-linux
# sha256sum/df -> coreutils
declare -A DEP_PKG=(
  ["findmnt"]="util-linux"
  ["lsblk"]="util-linux"
  ["mountpoint"]="util-linux"
  ["sha256sum"]="coreutils"
  ["df"]="coreutils"
)

MISSING_DEPS=()
MISSING_PKGS=()

for dep in "${!DEP_PKG[@]}"; do
  if ! command -v "$dep" &>/dev/null; then
    MISSING_DEPS+=("$dep")
    pkg="${DEP_PKG[$dep]}"
    if [[ " ${MISSING_PKGS[*]:-} " != *" ${pkg} "* ]]; then
      MISSING_PKGS+=("$pkg")
    fi
  fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
  echo "Faltan las siguientes dependencias: ${MISSING_DEPS[*]}"
  echo "Paquetes necesarios: ${MISSING_PKGS[*]}"
  # Non-interactive: instalar automaticamente si no hay terminal (pkexec, cron, etc.)
  if [ -t 0 ] && [ -t 1 ]; then
    read -rp "¿Deseas instalarlos ahora? [S/n] " answer
    answer="${answer:-S}"
  else
    answer="S"
  fi
  if [[ "$answer" =~ ^[Ss]$ ]]; then
    echo "Instalando paquetes..."
    install_packages "${MISSING_PKGS[@]}"
    echo "Paquetes instalados correctamente."
  else
    echo "Instalacion cancelada. Por favor, instala manualmente: ${MISSING_PKGS[*]}"
    exit 1
  fi
fi
echo "Todas las dependencias encontradas."

# --- Comprobaciones previas (avisos, no abortan) ---

echo "Comprobando el entorno..."

if ! command -v timeshift &>/dev/null; then
  echo "AVISO: 'timeshift' no esta instalado. Los hooks quedaran inactivos hasta que lo instales."
else
  echo "  timeshift: $(command -v timeshift)"
fi

# Los hooks solo hacen algo si existe un directorio EFI/Linux en una particion
# vfat. Se avisa para que un fallo posterior no se confunda con un bug.
esp_found=false
while read -r mnt; do
    if [ -d "$mnt/EFI/Linux" ]; then
        esp_found=true
        break
    fi
done < <(findmnt -rno TARGET -t vfat 2>/dev/null || true)
if [ "$esp_found" != true ]; then
  echo "AVISO: no se encuentra ningun directorio EFI/Linux en las particiones vfat montadas."
  echo "       Revisa que la ESP este montada (p. ej. /boot o /efi)."
fi

# Si los hooks actuales pertenecen a un paquete, install.sh los sobreescribe
# fuera del gestor de paquetes: la metadata del paquete quedara mintiendo
# (pacman -Qkk marcara los ficheros como alterados). Se avisa y se indica la
# via recomendada.
for hook_path in /etc/timeshift/backup-hooks.d/90-backup-uki \
                 /etc/timeshift/restore-hooks.d/90-restore-uki; do
  [ -f "$hook_path" ] || continue
  owner=""
  if command -v pacman &>/dev/null; then
    owner=$(pacman -Qo "$hook_path" 2>/dev/null | awk '{print $5}' || true)
  elif command -v dpkg &>/dev/null; then
    owner=$(dpkg -S "$hook_path" 2>/dev/null | cut -d: -f1 || true)
  elif command -v rpm &>/dev/null; then
    owner=$(rpm -qf "$hook_path" 2>/dev/null || true)
  fi
  if [ -n "$owner" ]; then
    echo "AVISO: $hook_path pertenece al paquete '$owner'."
    echo "       install.sh lo va a sobreescribir fuera del gestor de paquetes."
    echo "       Recomendado: actualiza ese paquete en vez de usar install.sh."
  fi
done

echo "Instalando Timeshift UKI Hooks v${VERSION}..."

# Crear directorios si no existen
mkdir -p /etc/timeshift/backup-hooks.d
mkdir -p /etc/timeshift/restore-hooks.d

# Limpiar versiones anteriores (incluyendo archivos con sufijos de version)
echo "Limpiando instalaciones previas..."
rm -f /etc/timeshift/backup-hooks.d/90-backup-uki*
rm -f /etc/timeshift/restore-hooks.d/90-restore-uki*

# Copiar scripts con nombres estandar
echo "Copiando scripts..."
cp "$SCRIPT_DIR/hooks.d/backup/90-backup-uki" /etc/timeshift/backup-hooks.d/
cp "$SCRIPT_DIR/hooks.d/restore/90-restore-uki" /etc/timeshift/restore-hooks.d/

# Aplicar permisos
echo "Aplicando permisos de ejecucion..."
chmod +x /etc/timeshift/backup-hooks.d/90-backup-uki
chmod +x /etc/timeshift/restore-hooks.d/90-restore-uki

echo "Instalacion/Actualizacion a v${VERSION} completada correctamente."
echo "Los hooks han sido instalados con nombres estandar para compatibilidad con run-parts."
echo ""
echo "Si no los instalas con el paquete (AUR: timeshift-uki-hooks-git), recuerda que"
echo "install.sh deja los ficheros fuera del gestor de paquetes: una actualizacion"
echo "del paquete o una restauracion pueden volver a sobrescribirlos."
