# Changelog

Todas las versiones significativas de este proyecto. Formato basado en [Keep a Changelog](https://keepachangelog.com/).

---

## [3.5] - 2026-10-05

### Added
- **`PRUNE_ESP_UKIS` (backup hook)**: purga de la **particion de arranque** los UKIs versionados `<machine-id>-<kver>.efi` cuyo kernel ya no esta instalado (`kernel_is_installed`: no existe `/usr/lib/modules/<kver>` y no es `uname -r`). Se ejecuta antes de inventariar la ESP. `kernel-install` nunca borra los UKIs de kernels desinstalados, de modo que `/boot/EFI/Linux` acumulaba UKIs muertos que, con autodeteccion de systemd-boot, aparecian como entradas extra en el menu de arranque. Guardas: nunca borra el UKI del kernel en ejecucion, ni los de kernels instalados no ejecutados (`linux-lts`, `linux-zen`), ni el preset clasico `arch-linux.efi` (sin version no hay nada que decidir); y no hace nada si la ESP no tiene UKIs versionados. Configurable con `PRUNE_ESP_UKIS=true/false` (por defecto `true`).
- **Rutas parametrizables por entorno** en ambos hooks: `TSUKI_BACKUP_DIR`, `TSUKI_LOG_FILE` y `TSUKI_UKI_DIR`. En produccion no se usan; permiten ejecutar los hooks contra un arbol de pruebas sin tocar el sistema real.
- **`VERSION`**: version unica del repositorio.
- **CI** (`.github/workflows/ci.yml`): `bash -n` de los cuatro scripts, ShellCheck en nivel `warning` sin excepciones, comprobacion de coherencia de version contra `VERSION` y smoke test del backup hook.
- **`tests/smoke.sh`**: smoke test que ejecuta el backup hook de verdad contra un arbol temporal y verifica la purga de la ESP, el respaldo selectivo con su `.sha256`, los dos layouts de snapshot (Btrfs y rsync) y la idempotencia de una segunda ejecucion.
- **`install.sh`**: comprobaciones previas (Timeshift instalado, `EFI/Linux` presente en alguna vfat) y aviso si los hooks actuales pertenecen a un paquete, con la recomendacion de actualizar ese paquete en su lugar.

### Fixed
- **Espacio de la ESP calculado en tiempo de ejecucion** (restore hook): el umbral era fijo (`MIN_ESP_SPACE_MB=50`), menor que un UKI tipico (~75 MB), por lo que el aviso de "poco espacio" no podia dispararse cuando realmente no cabia. Ahora se calcula como `ESP_MIN_FREE_MB` (20) + el tamano real de los UKIs a restaurar.
- **Los hooks de git no eran ejecutables** (`100644`): un clon recien hecho no permitia ejecutarlos directamente. Ahora `100755`.
- **`install.sh`**: el aviso de dependencias fallaba en modo no interactivo por una comparacion `=~` con comillas en el lado derecho; se cambio por un patron glob literal.
- **`IN_CHROOT` estaba asignado pero nunca se usaba** (restore hook): el log decia "ajustando rutas de montaje" pero el hook no ajustaba ninguna. Se elimino la variable y el mensaje se corrige.

### Changed
- **Documentacion**: titulo del README sincronizado con la version real (llevaba en `v3.2` con el codigo en `v3.4`), tabla de plataformas ajustada a lo real (Arch probado; el resto "sin probar"), `ARCHITECTURE.md` y README alineados con el comportamiento real de `PRUNE_OLD_UKIS` y de la purga de la ESP, y nueva seccion de Configuracion con todas las variables.
- Version bump a v3.5 en scripts, `install.sh` y documentacion.

### Documented
- ⚠️ **Limitacion conocida, preexistente: el restore hook no valida la particion de arranque que elige.** `resolve_esp_mount()` devuelve el primer mountpoint de `/boot`, `/efi`, `/boot/efi` sin comprobar que contenga `EFI/Linux` ni que sea ESP/XBOOTLDR, y como el destino se crea con `mkdir -p`, una mala eleccion deja los UKIs en la particion equivocada (con `PRUNE_UKIS=true` borra ademas los `.efi` que no esten en el respaldo). Se manifiesta solo con **dos vfat montadas y una sola con UKIs** (dual-boot), y sobre todo en el chroot desde Live USB. El backup hook **si** comprueba que el directorio exista, asi que los dos hooks pueden apuntar a particiones distintas. Documentado en el README ("Deteccion de la particion de arranque", con comandos para verificar y evitarlo) y en la tabla de escenarios de `ARCHITECTURE.md`. **No corregido en v3.5** (cambia el criterio de seleccion: habria que exigir `EFI/Linux` o PARTTYPE valido en el camino rapido).

### Notes
- El restore hook **no tiene cobertura automatica**: su logica exige una ESP real montada. En CI solo se valida con `bash -n` y ShellCheck.
- Los UKIs se conservan dentro de cada snapshot, asi que el directorio de respaldo ocupa ~75 MB adicionales por snapshot (Btrfs no deduplica entre subvolumenes).

---

## [3.4] - 2026-08-25

### Added
- **`trap cleanup EXIT`** en el restore hook: si el script aborta a mitad (checksum falla, cp falla, signal), el trap restaura el modo RO de la ESP y la desmonta si fue montada manualmente. Antes, un aborto deixaba la ESP montada RW o colgada.
- **`skip_prune`** en `copy_ukis()`: la segunda llamada (snapshot) omite la purge de obsoletos ya que el destino fue purgeado en la primera llamada (sistema vivo). Evita I/O innecesario.

### Fixed
- Restore hook: eliminados bloques manuales de cleanup (`mount -o remount,ro`) en cada ruta de error — el trap EXIT los maneja de forma centralizada y segura.

### Changed
- `ARCHITECTURE.md` sincronizado con el codigo real: el diagrama de flujo del restore hook ya no atribuia al hook una busqueda de ESP por PARTTYPE GUID como propio paso de decision. (La funcion `is_valid_boot_partition()` **si** existe en el restore hook, pero se aplica dentro de `resolve_esp_mount()`, no como etapa separada.)
- Version bump a v3.4.

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
