# Changelog

Todas las versiones significativas de este proyecto. Formato basado en [Keep a Changelog](https://keepachangelog.com/).

---

## [3.3] - 2026-08-13

### Added
- **`PRUNE_OLD_UKIS`** (backup hook): cada snapshot viaja **solo con el UKI del sistema actual** (`uname -r`). Con layout `kernel-install` el backup hook detecta los UKIs versionados (`<machine-id>-<kver>.efi`) y elimina del respaldo (vivo y dentro del snapshot) los `.efi` que no pertenecen al kernel en ejecución, incluyendo el preset clásico `arch-linux.efi` (legacy tras el cambio a kernel-install). Así, al restaurar se devuelve exactamente el UKI del momento de la snapshot. Configurable con `PRUNE_OLD_UKIS=true/false` (por defecto `true`).

### Fixed
- El backup hook era **aditivo**: solo añadía UKIs cambiados pero nunca purgaba los obsoletos, así que `uki-backup` acumulaba UKIs de kernels antiguos (y del preset clásico pre-kernel-install) que se incrustaban en cada snapshot y luego eran devueltos a la partición de arranque al restaurar.
- **Ruta del checksum en el restore hook**: buscaba `"<UKI>".sha256` (p. ej. `arch-linux.sha256`) pero el backup hook escribe `"<UKI>.efi.sha256"` (`arch-linux.efi.sha256`). El desajuste hacía que la verificación de integridad nunca se ejecutara (siempre caía en "continuando sin verificación") y que la optimización de "saltar si ya es idéntico" nunca se disparara. Corregido: `sha_file` ahora usa el nombre completo del UKI (`$uki_backup.sha256`).

### Changed
- Versión bump a v3.3 en scripts, PKGBUILD y documentación.

---

## [3.2] - 2026-08-06

### Added
- **Pruning de UKIs obsoletos** en `90-restore-uki`: tras restaurar, elimina de la partición de arranque los `.efi` que no existen en el snapshot restaurado (sync ESP ↔ snapshot). Esencial con layout `kernel-install` (`layout=uki`), donde conviven múltiples UKIs versionados (`<machine-id>-<kver>.efi`). Configurable con `PRUNE_UKIS=true/false`.

### Fixed
- **Snapshots autocontenidos (semántica de Timeshift)**: los backup hooks se ejecutan **después** de crear el snapshot (`run_post_backup_hooks`, con `TS_SNAPSHOT_PATH`), no antes. El backup hook ahora además de `/etc/timeshift/uki-backup/` escribe los UKIs **dentro del snapshot recién creado** (Btrfs: `$TS_SNAPSHOT_PATH/@/etc/timeshift/uki-backup/`, rsync: `$TS_SNAPSHOT_PATH/etc/timeshift/uki-backup/`). Sin esto cada snapshot quedaba con el respaldo del anterior (desfase de 1) y el prune de v3.2 podía borrar el UKI correcto de la ESP.
- Bug latente bajo `set -e`: `((contador++))` abortaba el hook (el post-incremento devuelve 0) → sustituido por `contador=$((contador + 1))` en los contadores del restore.

### Changed
- Versión bump a v3.2 en scripts, `install.sh`, PKGBUILD y documentación.
- Documentación del layout `kernel-install`, de la semántica post-snapshot de Timeshift y del doble destino del backup hook.

---

## [3.1] - 2026-07-28

### Fixed
- `is_esp_partition()` renombrada a `is_valid_boot_partition()` y ahora acepta tanto ESP (`c12a7328-...`) como XBOOTLDR (`bc13c2ff-...`). Sistemas con partición XBOOTLDR independiente (ej. dual-boot Windows + Arch) ya no son rechazados por el filtro PARTTYPE.

### Changed
- Versión bump a v3.1 en scripts, PKGBUILD y documentación.

---

## [3.0] - 2026-07-10

### Added
- Soporte multi-distribución en `install.sh` (pacman, apt, dnf, zypper, xbps, apk)
- Fallback para detección de chroot sin `systemd-detect-virt`
- Detección robusta de contenedores (namespaces PID, /.dockerenv, /proc/1/cgroup)
- Tabla de plataformas soportadas en README

### Changed
- `install.sh` reescrito con detección automática de gestor de paquetes
- Restore hook usa función `detect_chroot()` en vez de `systemd-detect-virt` directo

---

## [2.7] - 2026-07-10

### Added
- Función `is_esp_partition()` para verificar PARTTYPE de la partición
- GUID ESP: `c12a7328-f81f-11d2-ba4b-00a0c93ec93b`

### Fixed
- Evita confusión entre ESP y dispositivos USB FAT32

---

## [2.6] - 2026-07-10

### Added
- Filtrado de archivos `.bak` en ambos hooks
- Auto-limpieza de `.bak.*.efi` y `.bak.efi` en ESP y directorio de respaldo

### Fixed
- Glob `*.efi` capturaba archivos `.bak.*.efi` causando entradas inválidas en systemd-boot

---

## [2.5] - 2026-07-01

### Added
- Validación de existencia de `/EFI/Linux` antes de seleccionar partición vfat
- Optimización con `df --output=avail` para lectura de espacio más precisa
- Validación de dependencias en `install.sh`

---

## [2.4] - 2026-06-30

### Added
- Detección dinámica de ESP via `findmnt -t vfat`
- Soporte chroot/Live USB en restore hook
- Verificación de espacio mínimo (50MB) en ESP
- Limpieza de `.sha256` huérfanos
- Copia selectiva completa (SHA256 per-file)

---

## [2.3] - 2026-06-25

### Removed
- Rotación de backups (`.bak`) que acumulaba archivos sin límite
- Bloque duplicado de verificación de directorio (código muerto)

### Fixed
- `SCRIPT_DIR` para rutas absolutas en `install.sh`

---

## [2.2] - 2026-06-24

### Fixed
- Variable `expected_sha` inicializada correctamente (evita `unbound variable`)
- Uso de `mktemp` en vez de `$$` para archivos temporales
- Skip condicional en comparación de checksums

### Removed
- Variable `skipped_count` sin uso
- Redirección redundante

---

## [2.1] - 2026-06-23

### Added
- Versión inicial con rotación de backups
- Soporte básico para ESP en `/boot`, `/efi`, `/boot/efi`
