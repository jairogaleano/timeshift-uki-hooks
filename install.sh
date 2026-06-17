#!/bin/bash
#
# Timeshift UKI Hooks - Instalador v2.1
#

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Por favor, ejecuta como root (sudo ./install.sh)"
  exit 1
fi

echo "Instalando Timeshift UKI Hooks v2.2..."

# Crear directorios si no existen
mkdir -p /etc/timeshift/backup-hooks.d
mkdir -p /etc/timeshift/restore-hooks.d

# Limpiar versiones anteriores (incluyendo archivos con sufijos de versión)
echo "Limpiando instalaciones previas y experimentos de nombres..."
rm -f /etc/timeshift/backup-hooks.d/90-backup-uki*
rm -f /etc/timeshift/restore-hooks.d/90-restore-uki*

# Copiar scripts con nombres estándar
echo "Copiando scripts..."
cp hooks.d/backup/90-backup-uki /etc/timeshift/backup-hooks.d/
cp hooks.d/restore/90-restore-uki /etc/timeshift/restore-hooks.d/

# Aplicar permisos
echo "Aplicando permisos de ejecución..."
chmod +x /etc/timeshift/backup-hooks.d/90-backup-uki
chmod +x /etc/timeshift/restore-hooks.d/90-restore-uki

echo "Instalación/Actualización a v2.2 completada correctamente."
echo "Los hooks han sido instalados con nombres estándar para compatibilidad con run-parts."
