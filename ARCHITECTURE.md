# Arquitectura de Timeshift UKI Hooks

## Alcance de los scripts

Son dos hooks que integran UKIs (Unified Kernel Images) con el sistema de snapshots Btrfs de Timeshift. Resuelven un problema de desajuste: Timeshift protege `/` pero la particion **ESP** (donde estan los UKIs `.efi`) queda fuera de los snapshots.

---

## Backup Hook (`90-backup-uki`)

Timeshift ejecuta los backup hooks **despues** de crear el snapshot (`run_post_backup_hooks`), exportando `TS_SNAPSHOT_PATH`. Como el snapshot Btrfs es un punto en el tiempo (reflink), el hook escribe los UKIs en **dos destinos**:

1. `/etc/timeshift/uki-backup/` — sistema vivo (fallback/consulta rapida).
2. `$TS_SNAPSHOT_PATH/.../uki-backup/` — **dentro del snapshot recien creado**, dejandolo autocontenido:
   - Layout Btrfs: `$TS_SNAPSHOT_PATH/@/etc/timeshift/uki-backup/`.
   - Layout rsync: `$TS_SNAPSHOT_PATH/etc/timeshift/uki-backup/`.

Esto garantiza que cada snapshot viaje con los UKIs que coinciden con sus modulos del kernel, sin depender del snapshot anterior.

Selecciona archivos `.efi` del directorio `EFI/Linux` en la ESP. Para cada uno calcula SHA256: si ya existe un respaldo identico en el destino, lo salta; si cambio, lo copia y escribe su `.sha256`. Antes de copiar, limpia archivos `.sha256` huerfanos y rotaciones `.bak` (cuyo UKI ya no existe en la ESP). Verifica que la particion sea la ESP real mediante PARTTYPE GUID (`c12a7328-f81f-11d2-ba4b-00a0c93ec93b`, o `bc13c2ff-...` para XBOOTLDR) para evitar confusion con USBs.

**Purga de UKIs obsoletos (v3.3, `PRUNE_OLD_UKIS=true`):** antes de copiar, el hook calcula el conjunto de UKIs "vigentes" (`compute_current_ukis`): con layout `kernel-install` solo conserva el UKI del kernel en ejecucion (`uname -r`) y elimina del respaldo (vivo y dentro del snapshot) los `.efi` obsoletos (versiones anteriores y el preset clasico `arch-linux.efi`). Sin `kernel-install` conserva todos los UKIs presentes. Esto evita que snapshots acumulen UKIs de kernels viejos que luego serian devueltos a la ESP al restaurar.

**Purga de la particion de arranque (v3.5, `PRUNE_ESP_UKIS=true`):** `prune_esp_stale_ukis` se ejecuta **antes** de inventariar la ESP y elimina los UKIs versionados `<machine-id>-<kver>.efi` cuyo kernel no esta instalado (`kernel_is_installed`: no existe `/usr/lib/modules/<kver>` y no es `uname -r`). Necesario porque `kernel-install` **nunca** borra los UKIs de kernels desinstalados: con autodeteccion de systemd-boot cada UKI superviviente es una entrada mas del menu de arranque. Guardas de seguridad:

- nunca borra el UKI del kernel en ejecucion;
- nunca borra UKIs de kernels instalados aunque no esten en ejecucion (`linux-lts`, `linux-zen`, ...);
- solo toca nombres con version: el preset clasico `arch-linux.efi` se deja intacto porque sin version en el nombre no hay nada que decidir;
- si la ESP no contiene ningun UKI versionado, no hace nada (no hay layout `kernel-install`).

A diferencia de `prune_stale_ukis` (que opera sobre el destino), esta purga opera sobre **el origen**: por eso `PRUNE_OLD_UKIS` y `PRUNE_ESP_UKIS` son independientes.

### Rutas parametrizables (v3.5)

`BACKUP_DIR`, `LOG_FILE` y el directorio de UKIs se pueden fijar por entorno (`TSUKI_BACKUP_DIR`, `TSUKI_LOG_FILE`, `TSUKI_UKI_DIR`). En produccion no se usan; existen para que `tests/smoke.sh` y la CI ejecuten el hook de verdad contra un arbol temporal sin tocar el sistema.

### Cobertura de escenarios

| Escenario | Comportamiento |
|---|---|
| Normal (snapshot periodico) | Copia solo UKIs cambiados a `uki-backup/` (vivo y dentro del snapshot). El snapshot contiene modulos + UKI consistentes. |
| Sin cambios entre snapshots | Omite copia (SHA256 match). Cero I/O innecesario. |
| ESP montada en `/boot`, `/efi` o `/boot/efi` | Detecta dinamicamente con `findmnt -t vfat` + `EFI/Linux`. |
| Sin UKIs en ESP | Log WARN y sale con 0 (no bloquea el snapshot). |
| `TS_SNAPSHOT_PATH` no exportado o layout desconocido | Copia solo al sistema vivo y emite WARN (compatibilidad hacia atras). |
| UKIs de kernels desinstalados en la ESP | Se purgan antes de inventariar (`PRUNE_ESP_UKIS`). Log `Pruned UKI de la particion de arranque (kernel <kver> no instalado)`. |
| ESP solo con el preset clasico (`arch-linux.efi`) | No hay UKIs versionados: la purga no hace nada. |
| UKI de un kernel instalado pero no en ejecucion | Se conserva (p. ej. `linux-lts` recien instalado sin reiniciar). |

---

## Restore Hook (`90-restore-uki`)

Se ejecuta **despues** de restaurar un snapshot. Recupera los UKIs de `uki-backup/` (que estan dentro del snapshot restaurado) y los escribe de vuelta en la ESP, asegurando que coincidan con los modulos del kernel recien restaurados.

Por cada UKI respaldado verifica su checksum SHA256 contra el `.sha256` acompanante. Si coincide el checksum y ya existe un UKI identico en el destino, lo salta. Si no, copia atomicamente: escribe a un archivo temporal con `mktemp`, verifica, luego `mv`. Verifica el espacio disponible en ESP calculando en tiempo de ejecucion lo que hace falta: `ESP_MIN_FREE_MB` (20 MB de margen) mas el tamano real de los UKIs a restaurar (v3.5; hasta v3.4 era un umbral fijo de 50 MB, menor que un UKI tipico, por lo que el aviso no podia dispararse). Usa `trap cleanup EXIT` para restaurar el modo RO original o desmontar la ESP si el script aborta a mitad (checksum falla, cp falla, signal).

**Pruning (v3.2):** tras la copia, si `PRUNE_UKIS=true` (default), sincroniza la particion de arranque con el snapshot: elimina todo `.efi` del directorio `EFI/Linux` que **no exista** en el respaldo (y las rotaciones `.bak`). Es imprescindible con el layout `kernel-install` (`layout=uki`), donde conviven multiples UKIs versionados (`<machine-id>-<kver>.efi`): si quedara un UKI de un kernel mas nuevo cuyo `usr/lib/modules` ya no existe en el root restaurado, el arranque fallaria (mismatch kernel/modulos).

### Cobertura de escenarios

| Escenario | Comportamiento |
|---|---|
| **Normal**: restauracion desde el sistema arrancado | ESP ya montada en `/boot` o `/efi`. Restaura solo UKIs distintos. |
| **Falla tras actualizacion de kernel**: el usuario restaura un snapshot anterior para revertir | El hook coloca en la ESP los UKIs de la version anterior (los que estaban en el snapshot). Al reiniciar, kernel + modulos + UKI estan sincronizados. |
| **Peor caso: sistema no arranca** (kernel corrupto, UKI danado, Secure Boot falla) | El usuario arranca desde un Live USB, monta su particion Btrfs, hace chroot, ejecuta Timeshift restore. El hook detecta el chroot con `detect_chroot()` (solo para registrarlo en el log: las rutas `/boot`, `/efi` y `/boot/efi` ya se resuelven dentro del chroot, no hay nada que ajustar), resuelve la ESP con `findmnt -t vfat` (requiere que este montada en el chroot) y restaura los UKIs. El usuario sale del chroot, reinicia y el sistema arranca con la version anterior. |
| **ESP montada RO** | Detecta `findmnt -O ro`, remonta RW, restaura; el trap EXIT devuelve a RO. |
| **Layout kernel-install** (`layout=uki`, v3.2) | El backup captura **solo el UKI del kernel en ejecucion** (`EFI/Linux/<machine-id>-<kver>.efi` con `kver == uname -r`, v3.3) y purga de la ESP los de kernels ya desinstalados (v3.5). El restore copia los del snapshot y **elimina los obsoletos** (los que no estan en el respaldo), dejando la ESP identica al snapshot. |
| **Restauracion de un snapshot viejo** | Si en la ESP habia UKIs de kernels mas nuevos (cuyos modulos ya no existen en el root restaurado), el prune los elimina. Evita el fallo "unknown filesystem type" en boot. |
| ⚠️ **Dos vfat montadas, solo una con UKIs (dual-boot)** | **Limitacion conocida.** `resolve_esp_mount()` devuelve el primer mountpoint de `/boot`, `/efi`, `/boot/efi` **sin** validar que tenga `EFI/Linux` ni que sea ESP/XBOOTLDR (el fallback si valida). Si la particion correcta no esta montada, cae en la otra vfat y, como el destino se crea con `mkdir -p`, **escribe los UKIs ahi**; con `PRUNE_UKIS=true` borra ademas los `.efi` que no esten en el respaldo. Afecta sobre todo al chroot desde Live USB. Detallado en el README. |

---

## Diagrama de flujo restore

```
Restore Timeshift
       |
       v
detect_chroot()  [v3.0: fallback sin systemd-detect-virt]
  +- namespaces PID diferentes? -> log INFO (no cambia ninguna ruta)
  +- /.dockerenv existe?        -> log INFO
  +- /proc/1/cgroup container?  -> log INFO
       |
       v
resolve_esp_mount()
  +- ?/boot montado?   -> si -> TARGET_MNT=/boot   [⚠️ SIN validar: no comprueba
  +- ?/efi montado?    -> si -> TARGET_MNT=/efi       EFI/Linux ni PARTTYPE aqui]
  +- ?findmnt vfat?    -> si -> is_valid_boot_partition()? -> si -> TARGET_MNT=resultado
  +- NO -> intenta montar /boot /efi /boot/efi
             |
             v
        ?sigues sin TARGET_MNT?
             |
             v
        ERROR "No se pudo detectar ni montar la particion EFI"
        exit 1
             |
             v
        findmnt -O ro TARGET_MNT
        +- si -> remount,rw ; WAS_RO=true
             |
             v
        Verifica backup_ukis, SHA256 y espacio
        (necesario = ESP_MIN_FREE_MB + tamano de los UKIs a restaurar) [v3.5]
             |
             v
        Por cada UKI: cp atomico a EFI/Linux/
             |
             v
        PRUNE_UKIS?  [v3.2]
        +- true  -> elimina .efi de EFI/Linux no presentes en el respaldo
        +- false -> conserva los UKIs no respaldados
             |
             v
        exit 0
             |
             v
        trap EXIT (cleanup)
        +- ?WAS_RO? -> remount,ro
        +- ?ESP_MOUNTED_BY_US? -> umount
```

## Diagrama de flujo backup (v3.5)

```
     Snapshot Btrfs creado por Timeshift (TS_SNAPSHOT_PATH ya exportado)
            |
            v
     detect_uki_dir()   [TSUKI_UKI_DIR tiene prioridad, solo para tests]
  +- /boot/EFI/Linux -> ?/efi/EFI/Linux -> ?/boot/efi/EFI/Linux
  +- NO -> findmnt -t vfat + is_valid_boot_partition() (ESP o XBOOTLDR)
  +- nada -> WARN y exit 0
            |
            v
     Limpia .bak de la ESP
            |
            v
     prune_esp_stale_ukis()   [PRUNE_ESP_UKIS, v3.5]
  +- ?hay UKIs versionados? -> no -> no hace nada
  +- si -> por cada <machine-id>-<kver>.efi:
         ?kver == uname -r             -> conserva (kernel en ejecucion)
         ?existe /usr/lib/modules/kver -> conserva (kernel instalado)
         resto                         -> rm (kernel ya desinstalado)
            |
            v
     Inventario de la ESP (uki_files)
            |
            v
     compute_current_ukis()   [PRUNE_OLD_UKIS, v3.3]
  +- solo los versionados con kver == uname -r; el preset clasico se descarta
  +- si no queda ninguno -> fallback: no purgar nada ni dejar el snapshot vacio
            |
            v
     copy_ukis(/etc/timeshift/uki-backup)        [purga obsoletos]
     copy_ukis($TS_SNAPSHOT_PATH/.../uki-backup)  [skip_prune]
```

---

## Resumen

Los scripts convierten un punto ciego de Timeshift (la ESP fuera de los snapshots) en un proceso automatizado y seguro. En uso normal son invisibles; en una reversion de kernel aseguran que el UKI coincida con los modulos; y en el peor caso (sistema inservible) permiten restaurar desde Live USB con deteccion y montaje automatico de la particion EFI.
