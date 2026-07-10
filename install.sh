#!/bin/bash
#
# Timeshift UKI Hooks - Instalador v2.7
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$EUID" -ne 0 ]; then
  echo "Por favor, ejecuta como root (sudo ./install.sh)"
  exit 1
fi

echo "Verificando dependencias del sistema..."
# findmnt y lsblk → util-linux, sha256sum y df → coreutils, mountpoint → util-linux
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
  if ! command -v "$dep" >/dev/null 2>&1; then
    MISSING_DEPS+=("$dep")
    pkg="${DEP_PKG[$dep]}"
    # Evitar duplicados en la lista de paquetes
    if [[ ! " ${MISSING_PKGS[*]:-} " =~ " ${pkg} " ]]; then
      MISSING_PKGS+=("$pkg")
    fi
  fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
  echo "Faltan las siguientes dependencias: ${MISSING_DEPS[*]}"
  echo "Paquetes necesarios: ${MISSING_PKGS[*]}"
  read -rp "¿Deseas instalarlos ahora con pacman? [S/n] " answer
  answer="${answer:-S}"
  if [[ "$answer" =~ ^[Ss]$ ]]; then
    echo "Instalando paquetes..."
    pacman -S --noconfirm "${MISSING_PKGS[@]}"
    echo "Paquetes instalados correctamente."
  else
    echo "Instalación cancelada. Por favor, instala manualmente: ${MISSING_PKGS[*]}"
    exit 1
  fi
fi
echo "Todas las dependencias encontradas."

echo "Instalando Timeshift UKI Hooks v2.7..."

# Crear directorios si no existen
mkdir -p /etc/timeshift/backup-hooks.d
mkdir -p /etc/timeshift/restore-hooks.d

# Limpiar versiones anteriores (incluyendo archivos con sufijos de versión)
echo "Limpiando instalaciones previas y experimentos de nombres..."
rm -f /etc/timeshift/backup-hooks.d/90-backup-uki*
rm -f /etc/timeshift/restore-hooks.d/90-restore-uki*

# Copiar scripts con nombres estándar
echo "Copiando scripts..."
cp "$SCRIPT_DIR/hooks.d/backup/90-backup-uki" /etc/timeshift/backup-hooks.d/
cp "$SCRIPT_DIR/hooks.d/restore/90-restore-uki" /etc/timeshift/restore-hooks.d/

# Aplicar permisos
echo "Aplicando permisos de ejecución..."
chmod +x /etc/timeshift/backup-hooks.d/90-backup-uki
chmod +x /etc/timeshift/restore-hooks.d/90-restore-uki

echo "Instalacion/Actualizacion a v2.7 completada correctamente."
echo "Los hooks han sido instalados con nombres estándar para compatibilidad con run-parts."
