#!/bin/bash
#
# Timeshift UKI Hooks - Instalador v3.4
# Soporte universal: Arch, Debian, Fedora, openSUSE, Void, Gentoo, etc.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$EUID" -ne 0 ]; then
  echo "Por favor, ejecuta como root (sudo ./install.sh)"
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
    if [[ ! " ${MISSING_PKGS[*]:-} " =~ " ${pkg} " ]]; then
      MISSING_PKGS+=("$pkg")
    fi
  fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
  echo "Faltan las siguientes dependencias: ${MISSING_DEPS[*]}"
  echo "Paquetes necesarios: ${MISSING_PKGS[*]}"
  read -rp "¿Deseas instalarlos ahora? [S/n] " answer
  answer="${answer:-S}"
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

echo "Instalando Timeshift UKI Hooks v3.4..."

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

echo "Instalacion/Actualizacion a v3.4 completada correctamente."
echo "Los hooks han sido instalados con nombres estandar para compatibilidad con run-parts."
