# Timeshift UKI Hooks v3.2

Sistema de hooks para **Timeshift** que respalda y restaura imágenes **UKI (Unified Kernel Images)** en sistemas con **Btrfs + Secure Boot**. Compatible con múltiples distribuciones Linux.

## 📋 Tabla de Contenidos

- [Concepto](#concepto)
- [Solución](#solución)
- [Plataformas Soportadas](#plataformas-soportadas)
- [Instalación](#instalación)
- [Desinstalación](#desinstalación)
- [Uso](#uso)
- [Integración con pacman](#integración-con-pacman-timeshift-autosnap)
- [Soporte de kernel-install](#soporte-de-kernel-install)
- [Seguridad](#seguridad)
- [Depuración e Integración de Logs](#depuración-e-integración-de-logs)
- [Changelog](#changelog)
- [Licencia](#licencia)

---

## 🔍 Concepto

En sistemas Linux con **systemd-boot** y **Secure Boot**, las imágenes UKI (ficheros `.efi`) residen en la partición **EFI System Partition (ESP)**.

**El problema**: Timeshift protege la raíz (`/`), pero la partición ESP queda fuera. Si restauras un snapshot antiguo, el kernel en `/` (módulos) y el UKI en la ESP (kernel binario) no coincidirán, impidiendo el arranque o el funcionamiento de módulos.

> **Nota**: Este proyecto es específico para **systemd-boot**. Si usas GRUB, no necesitas estos hooks porque GRUB gestiona los kernels de forma diferente.

---

## 🎯 Solución

Este proyecto sincroniza los UKIs con los snapshots de Btrfs mediante hooks:

1. **Backup Hook** (`/etc/timeshift/backup-hooks.d/90-backup-uki`)
   - Timeshift lo ejecuta **después** de crear el snapshot (`run_post_backup_hooks`) y le exporta `TS_SNAPSHOT_PATH`
   - Detecta dinámicamente la ESP (verifica PARTTYPE para evitar USBs)
   - Respalda UKIs en `/etc/timeshift/uki-backup/`
   - Escribe los UKIs **dentro del snapshot recién creado** vía `TS_SNAPSHOT_PATH` (Btrfs: `@/etc/timeshift/uki-backup/`, rsync: `etc/timeshift/uki-backup/`), dejándolo **autocontenido**
   - **Selectivo**: solo copia UKIs que cambiaron (comparación SHA256 per-file)
   - **Purga UKIs obsoletos** (`PRUNE_OLD_UKIS=true`): cada snapshot viaja solo con el UKI del kernel actual (`uname -r`); elimina versiones anteriores y el preset clásico `arch-linux.efi` en máquinas con `kernel-install`
   - Limpia archivos `.bak` y `.sha256` huérfanos automáticamente

2. **Restore Hook** (`/etc/timeshift/restore-hooks.d/90-restore-uki`)
   - Se ejecuta **después** de restaurar
   - Detecta y monta la ESP dinámicamente (incluso en entornos chroot/Live USB)
   - Verifica espacio disponible antes de copiar
   - Devuelve los UKIs a la ESP con copia atómica (`mktemp + mv`)
   - **Inteligente**: salta archivos que ya son idénticos

---

## 🖥️ Plataformas Soportadas

| Distribución | Estado | Notas |
|-------------|--------|-------|
| Arch Linux / Manjaro / EndeavourOS | ✅ Completo | Soporte nativo con pacman |
| Debian / Ubuntu / Linux Mint / Pop!_OS | ✅ Completo | Instalación vía apt |
| Fedora | ✅ Completo | Instalación vía dnf |
| openSUSE | ✅ Completo | Instalación vía zypper |
| Void Linux | ✅ Completo | Instalación vía xbps |
| Alpine Linux | ✅ Completo | Instalación vía apk |
| Gentoo | ✅ Completo | Herramientas estándar GNU |
| Otros (con systemd) | ✅ Compatible | Requiere util-linux y coreutils |

**Init systems soportados:** systemd, OpenRC, runit, sysvinit

---

## 📦 Instalación

### Instalación rápida

```bash
git clone https://github.com/jairogaleano/timeshift-uki-hooks.git
cd timeshift-uki-hooks
sudo ./install.sh
```

### Qué hace el instalador

1. Detecta tu distribución y gestor de paquetes.
2. Verifica e instalar dependencias faltantes automáticamente (`util-linux`, `coreutils`).
3. Crea los directorios de hooks en `/etc/timeshift/`.
4. Limpia versiones anteriores.
5. Instala los scripts con nombres canónicos para compatibilidad con `run-parts`.
6. Aplica permisos de ejecución.

### Requisitos previos

- **Timeshift** instalado y configurado
- **Btrfs** como sistema de archivos raíz
- **systemd-boot** como gestor de arranque
- **Secure Boot** habilitado (opcional pero recomendado)

---

## 🗑️ Desinstalación

### Opción automática (recomendado)

```bash
sudo rm -f /etc/timeshift/backup-hooks.d/90-backup-uki
sudo rm -f /etc/timeshift/restore-hooks.d/90-restore-uki
sudo rm -rf /etc/timeshift/uki-backup/
```

### Verificar desinstalación

```bash
ls /etc/timeshift/backup-hooks.d/
ls /etc/timeshift/restore-hooks.d/
# No deben mostrar archivos 90-backup-uki ni 90-restore-uki
```

> **Nota**: Los directorios `/etc/timeshift/backup-hooks.d/` y `/etc/timeshift/restore-hooks.d/` pueden quedarse vacíos. Timeshift los ignora si están vacíos.

---

## 🚀 Uso

### Cómo funciona en la práctica

Una vez instalados, los hooks se ejecutan **automáticamente**:

1. **Al crear un snapshot** (manual o programado):
   - Timeshift crea el snapshot y luego ejecuta `90-backup-uki` (`run_post_backup_hooks`)
   - El hook escribe los UKIs en `/etc/timeshift/uki-backup/` y **dentro del snapshot recién creado** (vía `TS_SNAPSHOT_PATH`)
   - El snapshot queda autocontenido: UKIs y módulos del kernel coincidentes

2. **Al restaurar un snapshot**:
   - Timeshift ejecuta `90-restore-uki` después de restaurar
   - Los UKIs se devuelven a la ESP
   - El sistema queda consistente y arrancable

### Integración con pacman (`timeshift-autosnap`)

En Arch Linux, el hook `00-timeshift-autosnap.hook` (incluido en el paquete `timeshift`) crea un snapshot automáticamente antes de cada actualización de paquetes. Nuestros hooks se ejecutan dentro de ese ciclo:

```
sudo pacman -Syu
  └─ 00-timeshift-autosnap.hook (pre-transacción)
       └─ timeshift-autosnap
            └─ timeshift --create
                 ├─ Snapshot creado
                 └─ 90-backup-uki (después del snapshot)
                      ├─ Copia UKIs de ESP → /etc/timeshift/uki-backup/
                      └─ Copia UKIs de ESP → snapshot (TS_SNAPSHOT_PATH)
```

**Configuración** (`/etc/timeshift-autosnap.conf`):

| Parámetro | Valor por defecto | Descripción |
|-----------|-------------------|-------------|
| `skipAutosnap` | `false` | Saltar la creación automática de snapshots |
| `deleteSnapshots` | `true` | Eliminar snapshots antiguos automáticamente |
| `maxSnapshots` | `3` | Cantidad máxima de snapshots a conservar |
| `minHoursBetweenSnapshots` | `18` | Horas mínimas entre snapshots consecutivos |

**Restaurar un snapshot** (el restore hook se ejecuta automáticamente):

```bash
sudo timeshift --restore
```

Los UKIs se devuelven a la ESP y el sistema queda consistente y arrancable.

### Comandos útiles

```bash
# Ver logs en tiempo real
tail -f /var/log/timeshift.log

# Verificar que los hooks están instalados
ls -la /etc/timeshift/backup-hooks.d/90-backup-uki
ls -la /etc/timeshift/restore-hooks.d/90-restore-uki

# Verificar respaldo actual
ls -la /etc/timeshift/uki-backup/

# Verificar ESP montada
findmnt -t vfat
```

### Ejemplo de flujo completo

**Flujo automático (con `timeshift-autosnap`):**

```bash
# pacman crea el snapshot automáticamente antes de actualizar
sudo pacman -Syu
# 1. timeshift-autosnap hook se ejecuta (pre-transacción)
# 2. Se crea el snapshot
# 3. 90-backup-uki escribe los UKIs dentro del snapshot (autocontenido)
# 4. Se instalan las actualizaciones

# Si algo sale mal después de la actualización:
sudo timeshift --restore
# 5. 90-restore-uki devuelve los UKIs de ese snapshot a la ESP
# 6. Reiniciar
```

**Flujo manual:**

```bash
# 1. Crear snapshot (el hook se ejecuta automáticamente)
sudo timeshift --create --comments "Antes de actualizar kernel"

# 2. Actualizar sistema
sudo pacman -Syu

# 3. Si algo sale mal, restaurar
sudo timeshift --restore

# 4. El hook restaura los UKIs automáticamente
# 5. Reiniciar y verificar que todo funciona
```

---

## 🧩 Soporte de kernel-install

Desde **v3.2** los hooks soportan de forma completa la arquitectura `kernel-install` de systemd, además de los presets clásicos de mkinitcpio.

### Layout `kernel-install`

Con `kernel-install` (layout `uki`, configurado en `/etc/kernel/install.conf`) los UKIs se generan con **nombres versionados** y se instalan en `$BOOT/EFI/Linux/`:

```
$BOOT/EFI/Linux/<machine-id>-<kernel-version>.efi
```

Ejemplo (Arch + Secure Boot):

```
/boot/EFI/Linux/c2224fefe655409688eccb14500b0429-7.1.6-arch1-1.efi
```

Como coexisten **múltiples versiones de kernel a la vez**, al restaurar un snapshot antiguo es crítico que la partición de arranque quede exactamente igual que cuando se tomó ese snapshot:

- El **backup hook** (v3.3) respalda **solo el UKI vigente** — el del kernel actualmente en ejecución (`uname -r`) — y lo escribe **dentro del snapshot recién creado** (vía `TS_SNAPSHOT_PATH`), dejando cada snapshot autocontenido. Con `PRUNE_OLD_UKIS=true` (por defecto) además **purga del respaldo** los `.efi` que no corresponden al kernel actual: versiones anteriores de UKIs kernel-install y el preset clásico `arch-linux.efi` (legacy tras el cambio a kernel-install). Así cada snapshot viaja solo con su UKI y al restaurar se devuelve exactamente el del momento de la snapshot.
- El **restore hook** (v3.2) hace **sync inverso**: además de copiar los UKIs del snapshot, **elimina de la partición de arranque cualquier `.efi` que no esté en el snapshot** (`PRUNE_UKIS=true`). Si quedara un UKI de un kernel más nuevo (cuyos módulos ya no existen en el root restaurado), el sistema fallaría al arrancar — exactamente el problema de "unknown filesystem type" tras una actualización.

Para desactivar la limpieza:
- Restore: edita `/etc/timeshift/restore-hooks.d/90-restore-uki` y pon `PRUNE_UKIS=false`.
- Backup: edita `/etc/timeshift/backup-hooks.d/90-backup-uki` y pon `PRUNE_OLD_UKIS=false` (conserva todos los UKIs versionados acumulados).

> **XBOOTLDR**: en sistemas con `/boot` en una partición XBOOTLDR independiente (ej. dual-boot Windows + Arch), los hooks la detectan y validan por su GUID (`bc13c2ff-...`) igual que la ESP.

### Regeneración del UKI tras actualizar el kernel

`kernel-install` **no regenera el UKI solo** con un `pacman -Syu`: necesita su propio hook de pacman. Si usas `kernel-install` como generador:

```bash
# Opción A: hook de kernel-install para pacman (AUR), enmascarando los de mkinitcpio
yay -S pacman-hook-kernel-install
sudo ln -s /dev/null /etc/pacman.d/hooks/60-mkinitcpio-remove.hook
sudo ln -s /dev/null /etc/pacman.d/hooks/90-mkinitcpio-install.hook

# Opción B: regenerar manualmente tras cada actualización de kernel
sudo kernel-install --boot-path=/boot --esp-path=/efi add \
  "$(cat /usr/lib/modules/*/version | head -1)" /boot/vmlinuz-linux
```

> **Alternativa simple**: el preset de mkinitcpio con `default_uki=` (p. ej. `/boot/EFI/Linux/arch-linux.efi`) sigue siendo el camino documentado y **se regenera solo** en cada `pacman -Syu`. Los hooks funcionan igual en ambos casos.

---

## 🔒 Seguridad

- ✅ **Integridad**: Verificación SHA256 obligatoria antes de restaurar.
- ✅ **Atomicidad**: Uso de copias temporales y `mv` para evitar archivos corruptos.
- ✅ **Secure Boot**: No modifica firmas; solo preserva los binarios ya firmados.
- ✅ **Detección de ESP**: Verifica PARTTYPE para no confundir con USBs.

---

## 🔧 Depuración e Integración de Logs

Este proyecto se integra directamente con el sistema de registros de **Timeshift** para facilitar el mantenimiento y la visibilidad:

- **Logs Unificados**: Los mensajes de los hooks se inyectan en `/var/log/timeshift.log`. Esto permite ver en un solo lugar tanto las acciones de Timeshift como el estado de la sincronización de los UKIs.
- **Rotación Automática**: Timeshift gestiona internamente la limpieza y rotación de estos logs (manteniendo las últimas sesiones). Al integrarse aquí, los registros de este proyecto se depuran automáticamente, evitando el crecimiento indefinido de archivos en `/var/log`.

### Solución de problemas

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| "No se pudo detectar la ESP" | USB conectado o ESP no montada | Desconectar USB o montar ESP manualmente |
| "Checksum falló" | UKI corrupto en respaldo | Verificar integridad del SSD con SMART |
| "Espacio insuficiente" | ESP casi llena | Limpiar kernels viejos de `/boot/EFI/Linux/` |
| Hooks no se ejecutan | Permisos incorrectos | `chmod +x /etc/timeshift/*-hooks.d/90-*-uki` |

---

## 📄 Changelog

Para el historial completo de cambios, ver [CHANGELOG.md](CHANGELOG.md).

### v3.3 (Última versión)
- **`PRUNE_OLD_UKIS` (backup hook)**: cada snapshot viaja **solo con el UKI del sistema actual** (`uname -r`). Con layout `kernel-install` se eliminan del respaldo los `.efi` obsoletos (versiones anteriores y el preset clásico `arch-linux.efi` legacy), evitando que UKIs de kernels viejos se acumulen en las snapshots y sean devueltos a la partición de arranque al restaurar. Configurable con `PRUNE_OLD_UKIS`.

### v3.2
- **Soporte completo de `kernel-install`**: pruning de UKIs obsoletos en el restore hook (sync ESP ↔ snapshot), esencial con UKIs versionados (`<machine-id>-<kver>.efi`). Configurable con `PRUNE_UKIS`.
- Documentación del layout `kernel-install` y su integración con pacman.

### v3.1
- **Fix**: `is_esp_partition()` renombrada a `is_valid_boot_partition()`. Ahora acepta tanto ESP (`c12a7328-...`) como XBOOTLDR (`bc13c2ff-...`). Sistemas con partición XBOOTLDR independiente (dual-boot) ya no son rechazados.

### v3.0
- **Soporte multi-distribución**: `install.sh` detecta automáticamente el gestor de paquetes (pacman, apt, dnf, zypper, xbps, apk).
- **Fallback para chroot**: El restore hook detecta entornos chroot sin depender de `systemd-detect-virt`.
- **Detección robusta de contenedores**: Namespaces PID, `/.dockerenv`, `/proc/1/cgroup`.

### v2.7
- **Detección de ESP por PARTTYPE**: Verifica GUID `c12a7328-f81f-11d2-ba4b-00a0c93ec93b` para evitar confusión con USBs.

### v2.6
- **Filtrado de archivos `.bak`**: Limpieza automática de rotaciones viejas.

---

## 📄 Licencia

Este software está bajo la licencia **GNU General Public License v3.0**.

**Contribuciones**: Proyecto mantenido por Jairo Galeano.
