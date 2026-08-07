# Changelog

Todas las versiones significativas de este proyecto. Formato basado en [Keep a Changelog](https://keepachangelog.com/).

---

## [3.2] - 2026-08-06

### Added
- **Pruning de UKIs obsoletos** en `90-restore-uki`: tras restaurar, elimina de la partición de arranque los `.efi` que no existen en el snapshot restaurado (sync ESP ↔ snapshot). Esencial con layout `kernel-install` (`layout=uki`), donde conviven múltiples UKIs versionados (`<machine-id>-<kver>.efi`). Configurable con `PRUNE_UKIS=true/false`.

### Changed
- Versión bump a v3.2 en scripts, `install.sh`, PKGBUILD y documentación.
- Documentación del layout `kernel-install` y su integración con pacman.

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
