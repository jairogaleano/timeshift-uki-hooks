# Timeshift UKI Hooks

Este proyecto proporciona un sistema de automatización para respaldar y restaurar imágenes **UKI (Unified Kernel Images)** utilizando los hooks de **Timeshift**.

## Problema
Las instalaciones de Linux que utilizan **Btrfs** con snapshots (vía Timeshift) normalmente solo protegen la partición raíz (`/`). Sin embargo, en sistemas modernos con **Secure Boot** y **UKIs**, el ejecutable de arranque reside en la partición **EFI (ESP)**, que suele ser FAT32 y queda fuera del snapshot.

Si restauras un snapshot antiguo de la raíz pero mantienes el UKI nuevo en la partición EFI, el sistema puede fallar debido a la incompatibilidad entre el kernel/módulos restaurados y el binario de arranque.

## Solución
Este conjunto de scripts vincula atómicamente la UKI con el snapshot de Btrfs:

1.  **Backup Hook:** Justo antes de crear el snapshot, copia la UKI actual a `/etc/timeshift/uki-backup/`. Como esta carpeta está en la raíz, se incluye dentro del snapshot de Btrfs.
2.  **Restore Hook:** Inmediatamente después de una restauración, Timeshift ejecuta este script que toma la UKI guardada en el snapshot y la devuelve a la partición EFI física.

## Estructura de Archivos
- `hooks.d/backup/90-backup-uki`: Script de respaldo.
- `hooks.d/restore/90-restore-uki`: Script de restauración automática.

## Instalación

### 1. Requisitos
- Sistema con Btrfs y Timeshift.
- Uso de UKIs (ubicados en `/boot/EFI/Linux` o `/efi/EFI/Linux`).
- `timeshift-autosnap` (recomendado para automatización en actualizaciones).

### 2. Copiar los scripts
Copia los scripts a las carpetas correspondientes de Timeshift (crea las carpetas si no existen):

```bash
sudo mkdir -p /etc/timeshift/backup-hooks.d
sudo mkdir -p /etc/timeshift/restore-hooks.d

sudo cp hooks.d/backup/90-backup-uki /etc/timeshift/backup-hooks.d/
sudo cp hooks.d/restore/90-restore-uki /etc/timeshift/restore-hooks.d/

sudo chmod +x /etc/timeshift/backup-hooks.d/90-backup-uki
sudo chmod +x /etc/timeshift/restore-hooks.d/90-restore-uki
```

## Funcionamiento Detallado

### Ciclo de Actualización (Backup)
Cuando ejecutas una actualización (ej: `pacman -Syu`), `timeshift-autosnap` dispara la creación de un snapshot. Timeshift detecta el script en `backup-hooks.d` y lo ejecuta **antes** de congelar el subvolumen. El script guarda una copia idéntica del UKI funcional dentro de `/etc`.

### Ciclo de Recuperación (Restore)
Si el sistema falla y decides restaurar un snapshot anterior:
1.  Timeshift reemplaza los archivos de la raíz.
2.  La carpeta `/etc/timeshift/uki-backup` recupera la versión del UKI que funcionaba en ese momento.
3.  Timeshift ejecuta el hook de `restore-hooks.d`.
4.  El script monta la partición EFI (si no lo está), la pone en modo lectura-escritura, copia el UKI restaurado y vuelve a poner la partición en modo seguro.

## Autor
Desarrollado para el entorno de trabajo de **Jairo Galeano** (ASROCK/ThinkPad) para garantizar la integridad del arranque en sistemas Arch Linux con Secure Boot.
