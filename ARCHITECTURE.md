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

Selecciona archivos `.efi` del directorio `EFI/Linux` en la ESP. Para cada uno calcula SHA256: si ya existe un respaldo identico en el destino, lo salta; si cambio, lo copia y escribe su `.sha256`. Antes de copiar, limpia archivos `.sha256` huerfanos y rotaciones `.bak` (cuyo UKI ya no existe en la ESP). Verifica que la particion sea la ESP real mediante PARTTYPE GUID (`c12a7328-f81f-11d2-ba4b-00a0c93ec93b`) para evitar confusion con USBs.

**Purga de UKIs obsoletos (v3.3, `PRUNE_OLD_UKIS=true`):** antes de copiar, el hook calcula el conjunto de UKIs "vigentes" (`compute_current_ukis`): con layout `kernel-install` solo conserva el UKI del kernel en ejecucion (`uname -r`) y elimina del respaldo (vivo y dentro del snapshot) los `.efi` obsoletos (versiones anteriores y el preset clasico `arch-linux.efi`). Sin `kernel-install` conserva todos los UKIs presentes. Esto evita que snapshots acumulen UKIs de kernels viejos que luego serian devueltos a la ESP al restaurar.

### Cobertura de escenarios

| Escenario | Comportamiento |
|---|---|
| Normal (snapshot periodico) | Copia solo UKIs cambiados a `uki-backup/` (vivo y dentro del snapshot). El snapshot contiene modulos + UKI consistentes. |
| Sin cambios entre snapshots | Omite copia (SHA256 match). Cero I/O innecesario. |
| ESP montada en `/boot`, `/efi` o `/boot/efi` | Detecta dinamicamente con `findmnt -t vfat` + `EFI/Linux`. |
| Sin UKIs en ESP | Log WARN y sale con 0 (no bloquea el snapshot). |
| `TS_SNAPSHOT_PATH` no exportado o layout desconocido | Copia solo al sistema vivo y emite WARN (compatibilidad hacia atras). |

---

## Restore Hook (`90-restore-uki`)

Se ejecuta **despues** de restaurar un snapshot. Recupera los UKIs de `uki-backup/` (que estan dentro del snapshot restaurado) y los escribe de vuelta en la ESP, asegurando que coincidan con los modulos del kernel recien restaurados.

Por cada UKI respaldado verifica su checksum SHA256 contra el `.sha256` acompanante. Si coincide el checksum y ya existe un UKI identico en el destino, lo salta. Si no, copia atomicamente: escribe a un archivo temporal con `mktemp`, verifica, luego `mv`. Verifica espacio disponible en ESP (min. 50MB). Usa `trap cleanup EXIT` para restaurar el modo RO original o desmontar la ESP si el script aborta a mitad (checksum falla, cp falla, signal).

**Pruning (v3.2):** tras la copia, si `PRUNE_UKIS=true` (default), sincroniza la particion de arranque con el snapshot: elimina todo `.efi` del directorio `EFI/Linux` que **no exista** en el respaldo (y las rotaciones `.bak`). Es imprescindible con el layout `kernel-install` (`layout=uki`), donde conviven multiples UKIs versionados (`<machine-id>-<kver>.efi`): si quedara un UKI de un kernel mas nuevo cuyo `usr/lib/modules` ya no existe en el root restaurado, el arranque fallaria (mismatch kernel/modulos).

### Cobertura de escenarios

| Escenario | Comportamiento |
|---|---|
| **Normal**: restauracion desde el sistema arrancado | ESP ya montada en `/boot` o `/efi`. Restaura solo UKIs distintos. |
| **Falla tras actualizacion de kernel**: el usuario restaura un snapshot anterior para revertir | El hook coloca en la ESP los UKIs de la version anterior (los que estaban en el snapshot). Al reiniciar, kernel + modulos + UKI estan sincronizados. |
| **Peor caso: sistema no arranca** (kernel corrupto, UKI danado, Secure Boot falla) | El usuario arranca desde un Live USB, monta su particion Btrfs, hace chroot, ejecuta Timeshift restore. El hook detecta el chroot con `detect_chroot()` (compatible con systemd, OpenRC, runit), resuelve la ESP con `findmnt -t vfat` (requiere que este montada en el chroot) y restaura los UKIs. El usuario sale del chroot, reinicia y el sistema arranca con la version anterior. |
| **ESP montada RO** | Detecta `findmnt -O ro`, remonta RW, restaura; el trap EXIT devuelve a RO. |
| **Layout kernel-install** (`layout=uki`, v3.2) | El backup captura todos los UKIs versionados (`EFI/Linux/<machine-id>-<kver>.efi`). El restore copia los del snapshot y **elimina los obsoletos** (los que no estan en el respaldo), dejando la ESP identica al snapshot. |
| **Restauracion de un snapshot viejo** | Si en la ESP habia UKIs de kernels mas nuevos (cuyos modulos ya no existen en el root restaurado), el prune los elimina. Evita el fallo "unknown filesystem type" en boot. |

---

## Diagrama de flujo restore

```
Restore Timeshift
       |
       v
detect_chroot()  [v3.0: fallback sin systemd-detect-virt]
  +- namespaces PID diferentes? -> IN_CHROOT=true
  +- /.dockerenv existe?        -> IN_CHROOT=true
  +- /proc/1/cgroup container?  -> IN_CHROOT=true
       |
       v
resolve_esp_mount()
  +- ?/boot montado?   -> si -> TARGET_MNT=/boot
  +- ?/efi montado?    -> si -> TARGET_MNT=/efi
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
        Verifica backup_ukis, SHA256, espacio
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

---

## Resumen

Los scripts convierten un punto ciego de Timeshift (la ESP fuera de los snapshots) en un proceso automatizado y seguro. En uso normal son invisibles; en una reversion de kernel aseguran que el UKI coincida con los modulos; y en el peor caso (sistema inservible) permiten restaurar desde Live USB con deteccion y montaje automatico de la particion EFI.
