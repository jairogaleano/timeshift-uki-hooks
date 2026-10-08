# Changelog

Todas las versiones significativas de este proyecto. Formato basado en [Keep a Changelog](https://keepachangelog.com/).

---

## [No publicado]

### Fixed
- **El restore hook restauraba los UKIs del sistema vivo, no los del snapshot, en un restore Btrfs in-system** (bug real encontrado en la verificación en Debian 13). En el restore Btrfs de la propia máquina **Timeshift no chrootea**: ejecuta el restore-hook en el sistema *vivo* (el root que se descarta al reiniciar) y exporta `TS_SNAPSHOT_PATH` con la ruta del snapshot que se restaura. El hook leía `/etc/timeshift/uki-backup`, que a esa altura es **el respaldo del estado actual** (el que desaparece), no el del snapshot restaurado: si el kernel cambió entre el snapshot y el restore, la ESP quedaba con el UKI nuevo sobre un root restaurado (viejo) → **no arrancaba**. Corregido: cuando `TS_SNAPSHOT_PATH` apunta a un sistema, `BACKUP_DIR` se resuelve al respaldo autocontenido del snapshot (`$TS_SNAPSHOT_PATH/@/etc/timeshift/uki-backup` o `$TS_SNAPSHOT_PATH/localhost/etc/…`); sin `TS_SNAPSHOT_PATH` (restore rsync con chroot sobre el árbol restaurado, o uso manual) se mantiene `/etc/timeshift/uki-backup`, que en ese flujo ya es el del snapshot.
- **El backup hook no reconocía el layout rsync de Timeshift.** Timeshift guarda el árbol del snapshot en `<snapshot>/localhost/`, pero la detección buscaba `$TS_SNAPSHOT_PATH/etc` → los snapshots rsync emitían el WARN "no contiene un sistema reconocible" y **no quedaban autocontenidos**. Corregido a `$TS_SNAPSHOT_PATH/localhost/etc` (verificado contra `src/Core/Main.vala`: `path_combine(snapshot_path, "localhost")`).

### Documented
- **Verificación 2026-10-08: Debian 13 (VM KVM) — ciclo completo Btrfs funcionando.** Timeshift 26.09 (fork linuxmint) en `btrfs_mode` con layout `@`/`@home` + `@var_log`/`@var_cache_apt`: snapshot → UKIs dentro del snapshot → `timeshift --restore --skip-grub` desde el sistema en marcha → pre-restore snapshot → raíz nueva a partir del snapshot → arranque correcto. De las 4 condiciones de la limitación multi-distribución quedan cubiertas arranque y layout `EFI/Linux`; **abiertas** disparo automático (solo manual fuera de Arch) y Secure Boot firmado con las claves de esa máquina. La tabla de plataformas y la sección "Limitación conocida" del README se actualizan en consecuencia.
- ⚠️ **Limitacion conocida: el soporte multi-distribucion no esta verificado en hardware real.** El "soporte universal" introducido en v3.0 se limita, en la practica, a `install.sh` (que detecta seis gestores de paquetes) y al empaquetado: **los dos hooks no tocan ninguna distro**, son bash + `util-linux` + `coreutils` y los ejecuta Timeshift via `run-parts`. Ese es el alcance real, y conviene decirlo sin ambiguedad: que `install.sh` funcione con `apt` o `dnf` **no demuestra** que los hooks funcionen ahi. **Solo Arch Linux se ha probado en una maquina real**, en un ciclo completo (snapshot -> UKIs dentro del snapshot -> restauracion -> arranque); en el resto no se ha ejecutado ni un ciclo completo de backup/restore. Lo que falta verificar por distro son cuatro cosas: (1) que el sistema **arranque** tras restaurar, no solo que el script termine sin error; (2) **que algo dispare los hooks**, ya que el unico automatismo documentado (`00-timeshift-autosnap.hook`) es un hook de **pacman** y fuera de Arch los hooks quedan instalados pero nadie los invoca; (3) que `kernel-install` use el layout `EFI/Linux` del que dependen los nombres `<machine-id>-<kver>.efi`; y (4) firmar el UKI restaurado con las claves de Secure Boot de esa maquina. Documentado en el README, seccion "Plataformas Soportadas", con la nota adicional de que el acoplamiento real del proyecto es con el **gestor de arranque** (systemd-boot), no con una distribucion.
- La tabla de plataformas pasa de "Probado / Sin probar" a "Verificado en hardware real / Sin verificar", para que el estado no se lea como una opinion. Se aclara que la CI corre en `ubuntu-latest` y que **no cuenta como verificacion**: los hooks se ejecutan en un chroot simulado sobre un arbol de ficheros, nunca contra una ESP real ni un arranque real.
- `ARCHITECTURE.md` tiene una seccion "Portabilidad y estado de su verificacion" que separa lo que es independiente de la distro (hooks, rutas de hooks de Timeshift upstream, `/usr/lib/modules/<kver>`) de lo que no lo es (`install.sh`, empaquetado, el disparo de los hooks).

### Changed
- Documentación: el README (§Solución) corrige la ruta rsync a `localhost/etc/timeshift/uki-backup/`.
- La seccion "Integracion con pacman" advierte explicitamente de que el automatismo es especifico de Arch, y enlaza a la limitacion. Sin cambios de codigo.

---

## [3.6] - 2026-10-05

### Fixed
- ⚠️ **El restore hook elegia la particion de arranque equivocada** (bug, no solo fragilidad). `resolve_esp_mount()` devovia el **primer mountpoint** de `/boot`, `/efi`, `/boot/efi` sin comprobar nada, y el destino se creaba con `mkdir -p`. Con dos vfat montadas y solo una con UKIs (el layout de dual-boot), si la particion correcta no estaba montada el hook caia en la otra, **creaba `EFI/Linux` ahi** y escribia los UKIs en la particion equivocada; con `PRUNE_UKIS=true` ademas borraba de ella los `.efi` que no estuvieran en el respaldo. El `mkdir -p` hacia que el error quedara "confirmado" para siempre. Afectaba sobre todo al chroot desde Live USB. **Corregido**: una particion solo es candidata si esta montada y tiene el directorio `EFI/Linux`, y si no hay ninguna el hook **aborta con un error explicito** en vez de adivinar. El `mkdir -p` desaparece: el destino ya no se inventa.
- **Los dos hooks puedan dejar de apuntar a la misma particion.** El backup hook ya exigia que `EFI/Linux` existiera; el restore no. Ahora los dos aplican exactamente la misma regla (`is_boot_partition_dir`), asi que no pueden discrepar.
- **Checksum del UKI con formato `sha256sum` abortaba la restauracion.** Se comparaba el **fichero entero** contra el hash pelado, asi que un `.sha256` con formato `<hash>  <nombre>` (el de `sha256sum X > X.sha256`, o sea el que produce `sha256sum -c`) fallaba siempre y el hook salia con error aunque el hash fuese correcto. Ahora se lee el primer campo, con lo que se aceptan ambos formatos. El backup hook sigue escribiendo el hash pelado, que es el formato que se documenta.
- **El fallback que monta particiones aceptaba cualquiera que se montara bien.** Se reintenta la resolucion y solo se usa lo que `resolve_esp_mount()` acepte; antes se aceptaba el primer mountpoint sin validar, que es justo el bug corregido.

### Added
- **`tests/boot-partition.sh`**: cobertura automatica del restore hook, que hasta v3.5 no tenia ninguna. Levanta un namespace de usuario y un chroot minimo donde `/boot` y `/efi` se montan o se dejan como directorios planos, de modo que se ejercita el codigo de produccion tal cual (sin seams ni variables que solo usen los tests). Cubre 9 casos: los cuatro layouts de particion con UKIs en `/boot` y/o `/efi`, los dos escenarios de dual-boot donde la particion de los UKIs esta sin montar (que son los que fallaban antes), el caso "ninguna sirve" (abortar sin crear nada), y tres de checksum (formato `sha256sum` aceptado, corrupto abortado, UKI sin kernel instalado tambien restaurado). `tests/smoke.sh` lo invoca, asi que `./tests/smoke.sh` sigue siendo la entrada unica.
- **Comprobacion de namespaces de usuario en CI**: Ubuntu 24.04+ restrict con AppArmor `apparmor_restrict_unprivileged_userns`; la CI lo desactiva y falla de forma explicita si aun asi no se pueden crear, en vez de saltarse el test en silencio.

### Changed
- El PARTTYPE (ESP `c12a7328` / XBOOTLDR `bc13c2ff`) se exige **solo** al buscar fuera de las rutas estandar, que es donde cabe confundirse con un USB. En `/boot`, `/efi` y `/boot/efi` basta con que la particion este montada y tenga `EFI/Linux`.
- **Documentacion**: la seccion "Deteccion de la particion de arranque" del README pasa de describir la limitacion a describir la regla vigente, con la tabla de criterios de ambos hooks y que hacer si el hook aborta. `ARCHITECTURE.md` actualizado. La limitacion documentada en v3.5 como "preexistente, no corregida" queda resuelta.
- Version bump a v3.6 en scripts, `install.sh` y documentacion.

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
- ⚠️ **Limitacion conocida, preexistente: el restore hook no valida la particion de arranque que elige.** `resolve_esp_mount()` devuelve el primer mountpoint de `/boot`, `/efi`, `/boot/efi` sin comprobar que contenga `EFI/Linux` ni que sea ESP/XBOOTLDR, y como el destino se crea con `mkdir -p`, una mala eleccion deja los UKIs en la particion equivocada (con `PRUNE_UKIS=true` borra ademas los `.efi` que no esten en el respaldo). Se manifiesta solo con **dos vfat montadas y una sola con UKIs** (dual-boot), y sobre todo en el chroot desde Live USB. El backup hook **si** comprueba que el directorio exista, asi que los dos hooks pueden apuntar a particiones distintas. Documentado en el README ("Deteccion de la particion de arranque", con comandos para verificar y evitarlo) y en la tabla de escenarios de `ARCHITECTURE.md`. **No corregido en v3.5** (cambia el criterio de seleccion: habria que exigir `EFI/Linux` o PARTTYPE valido en el camino rapido). **Resuelto en v3.6.**

### Notes
- ~~El restore hook **no tiene cobertura automatica**: su logica exige una ESP real montada. En CI solo se valida con `bash -n` y ShellCheck.~~ **Resuelto en v3.6**: `tests/boot-partition.sh` cubre su resolucion de particion y la verificacion de checksums con un namespace de usuario + chroot.
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
