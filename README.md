# Timeshift UKI Hooks v3.6

Sistema de hooks para **Timeshift** que respalda y restaura imágenes **UKI (Unified Kernel Images)** en sistemas con **Btrfs + Secure Boot**.

## 📋 Tabla de Contenidos

- [Concepto](#concepto)
- [Solución](#solución)
- [Plataformas Soportadas](#plataformas-soportadas)
- [Instalación](#instalación)
- [Desinstalación](#desinstalación)
- [Uso](#uso)
- [Integración con pacman](#integración-con-pacman-timeshift-autosnap)
- [Soporte de kernel-install](#soporte-de-kernel-install)
- [Configuración](#configuración)
- [Detección de la partición de arranque](#-detección-de-la-partición-de-arranque)
- [Seguridad](#seguridad)
- [Depuración e Integración de Logs](#depuración-e-integración-de-logs)
- [Desarrollo y CI](#desarrollo-y-ci)
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
   - **Purga la partición de arranque** (`PRUNE_ESP_UKIS=true`, v3.5): elimina los UKIs versionados cuyo kernel ya no está instalado. `kernel-install` **no** poda, así que sin esto `/boot/EFI/Linux` acumula UKIs de kernels desinstalados y cada uno se convierte en una entrada más del menú de arranque de systemd-boot
   - Limpia archivos `.bak` y `.sha256` huérfanos automáticamente

2. **Restore Hook** (`/etc/timeshift/restore-hooks.d/90-restore-uki`)
   - Se ejecuta **después** de restaurar
   - Detecta y monta la ESP dinámicamente (incluso en entornos chroot/Live USB)
   - Verifica espacio disponible antes de copiar
   - Devuelve los UKIs a la ESP con copia atómica (`mktemp + mv`)
   - **Verifica integridad**: calcula el SHA256 de cada UKI respaldado y lo compara con el checksum guardado (`<UKI>.efi.sha256`); aborta si no coincide
   - **Inteligente**: salta archivos que ya son idénticos en el destino (evita escrituras innecesarias a la ESP)

---

## 🖥️ Plataformas Soportadas

| Distribución | Estado | Notas |
|-------------|--------|-------|
| Arch Linux / Manjaro / EndeavourOS | ✅ Verificado en hardware real | Incluye paquete AUR (`timeshift-uki-hooks-git`) |
| Debian / Ubuntu / Linux Mint / Pop!_OS | ⚠️ Sin verificar | `install.sh` detecta apt e instala dependencias; el resto del proyecto es shell estándar |
| Fedora | ⚠️ Sin verificar | Ídem con dnf |
| openSUSE | ⚠️ Sin verificar | Ídem con zypper |
| Void Linux | ⚠️ Sin verificar | Ídem con xbps |
| Alpine Linux | ⚠️ Sin verificar | Ídem con apk (requiere bash) |
| Gentoo y otros con systemd | ⚠️ Sin verificar | Herramientas estándar GNU (`util-linux`, `coreutils`) |

**Qué es realmente portable**: los hooks solo usan bash + `util-linux` (`findmnt`, `lsblk`, `mountpoint`) + `coreutils` (`sha256sum`, `stat`, `df`). Lo específico de cada distribución se reduce a `install.sh` (que detecta el gestor de paquetes) y al empaquetado: **el núcleo —los dos hooks— no toca ningún gestor de paquetes ni ningún init system**, porque los ejecuta Timeshift vía `run-parts`. La CI cubre la lógica de ambos hooks (el backup contra un árbol temporal, el restore con namespaces + chroot), pero nunca una ESP real de verdad. Y lo que no se ha verificado en otras distribuciones es la integración completa, que es la parte específica de cada sistema (ver la limitación siguiente).

### Limitación conocida: el soporte multi-distribución no está verificado en hardware real

> ⚠️ **Esta es una limitación abierta, no un problema conocido con solución.** Que `install.sh` sepa manejar seis gestores de paquetes **no demuestra** que los hooks funcionen en esas distribuciones. **Solo Arch Linux se ha probado en una máquina real, de principio a fin**: snapshot → UKIs dentro del snapshot → restauración → arranque correcto. En el resto no se ha ejecutado ni un ciclo completo de backup/restore.

Para levantar esta limitación, una distribución debe cumplir **las cuatro** condiciones:

1. **Que el sistema arranque después de restaurar**, no solo que el script termine sin error. Un restore correcto en el log puede dejar en la ESP un UKI que no arranca; es el fallo que no se vería en una prueba de scripts.
2. **Que algo dispare los hooks.** El único automatismo documentado es `00-timeshift-autosnap.hook`, un hook de **pacman** ([Integración con pacman](#integración-con-pacman-timeshift-autosnap)). Fuera de Arch no hay equivalente documentado, así que los hooks quedan instalados pero **nadie los invoca**. Un `timeshift --create` manual sí los ejecuta; lo que falta es el disparo automático previo a una actualización de paquetes.
3. **`kernel-install` con layout `EFI/Linux`.** La lógica de purga asume UKIs con nombre `<machine-id>-<kver>.efi`; ese es el layout de `kernel-install` en todas las distribuciones, pero casi solo Arch lo usa por defecto.
4. **Secure Boot con las claves de esa máquina**: firmar el UKI restaurado contra las claves de `db` (shim + MOK en Debian/Fedora, `sbctl` en Arch).

Lo que **sí** es independiente de la distribución, y por eso no es descartable que funcione tal cual: las rutas `/etc/timeshift/*-hooks.d/` son las del propio Timeshift upstream, y `/usr/lib/modules/<kver>` es igual en Arch, Fedora, Debian 12+, openSUSE y Void.

> El acoplamiento real del proyecto no es a una distribución, sino al **gestor de arranque**: presupone UKIs en `EFI/Linux` sobre vfat, es decir **systemd-boot**. Con GRUB no hay UKIs que respaldar en ninguna distribución.

**Init systems:** los hooks no dependen del init system (los ejecuta Timeshift vía `run-parts`); el restore hook está pensado para funcionar también desde un chroot en un Live USB.

---

## 📦 Instalación

### Opción A: paquete AUR (recomendada en Arch)

```bash
yay -S timeshift-uki-hooks-git
```

Mantiene los hooks bajo propiedad de pacman: los actualiza con el sistema y no se descuadran.

### Opción B: instalador

```bash
git clone https://github.com/jairogaleano/timeshift-uki-hooks.git
cd timeshift-uki-hooks
sudo ./install.sh
```

> `install.sh` deja los ficheros **fuera del gestor de paquetes**. Si ya tienes el paquete AUR instalado, no lo mezcles: o actualizas el paquete, o no usas el instalador. De lo contrario, `pacman -Qkk` marcará los hooks como alterados y una actualización del paquete los sobrescribirá sin avisar.

### Qué hace el instalador

1. Detecta tu distribución y gestor de paquetes.
2. Verifica e instala dependencias faltantes (`util-linux`, `coreutils`).
3. **Comprueba el entorno**: avisa si Timeshift no está instalado, si no hay ningún `EFI/Linux` en las vfat montadas, o si los hooks actuales pertenecen a un paquete.
4. Crea los directorios de hooks en `/etc/timeshift/`.
5. Limpia versiones anteriores.
6. Instala los scripts con nombres canónicos para compatibilidad con `run-parts`.
7. Aplica permisos de ejecución.

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

> ⚠️ Este automatismo es **específico de Arch**: `00-timeshift-autosnap.hook` es un hook de pacman y no tiene equivalente documentado en otras distribuciones. Fuera de Arch los hooks sí se ejecutan con `timeshift --create` y `timeshift --restore` manuales, pero nada los dispara antes de actualizar el sistema. Ver [la limitación conocida](#limitación-conocida-el-soporte-multi-distribución-no-está-verificado-en-hardware-real).

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
- El **backup hook** (v3.5) purga además la **propia partición de arranque**: `kernel-install` no borra los UKIs de kernels que se desinstalan, así que `/boot/EFI/Linux` se llenaba de UKIs muertos que, con autodetección de systemd-boot, aparecían como entradas extra en el menú de arranque. Con `PRUNE_ESP_UKIS=true` (por defecto) se eliminan los UKIs versionados `<machine-id>-<kver>.efi` cuyo kernel ya no tiene `/usr/lib/modules/<kver>`. Nunca toca el UKI del kernel en ejecución, ni los de kernels instalados que no estén en ejecución, ni el preset clásico `arch-linux.efi` (sin versión en el nombre no hay nada que decidir).
- El **restore hook** (v3.3) hace **sync inverso**: además de copiar los UKIs del snapshot, **elimina de la partición de arranque cualquier `.efi` que no esté en el snapshot** (`PRUNE_UKIS=true`). Si quedara un UKI de un kernel más nuevo (cuyos módulos ya no existen en el root restaurado), el sistema fallaría al arrancar — exactamente el problema de "unknown filesystem type" tras una actualización.

> **Nota sobre el nombre del kernel**: `uname -r` es el kernel **en ejecución**, no el instalado. Si actualizas el kernel y no reinicias, una segunda transacción de pacman creará un snapshot cuyo UKI de respaldo es el del kernel antiguo. El UKI nuevo no se pierde (está en la ESP y se regenera con `kernel-install`), pero ese snapshot no lo incluye.

Para desactivar la limpieza:
- Restore: edita `/etc/timeshift/restore-hooks.d/90-restore-uki` y pon `PRUNE_UKIS=false`.
- Backup (respaldo): edita `/etc/timeshift/backup-hooks.d/90-backup-uki` y pon `PRUNE_OLD_UKIS=false` (conserva todos los UKIs versionados acumulados en `uki-backup/`).
- Backup (ESP): pon `PRUNE_ESP_UKIS=false` (conserva en `/boot/EFI/Linux` los UKIs de kernels desinstalados).

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

## ⚙️ Configuración

Ambos hooks se configuran editando las constantes de la cabecera de cada script.

| Variable | Hook | Por defecto | Efecto |
|---|---|---|---|
| `PRUNE_OLD_UKIS` | backup | `true` | Purga del respaldo los UKIs que no son del kernel en ejecución |
| `PRUNE_ESP_UKIS` | backup | `true` | Purga de la partición de arranque los UKIs cuyo kernel ya no está instalado |
| `PRUNE_UKIS` | restore | `true` | Sincroniza la partición de arranque con el snapshot restaurado (elimina los UKIs que no están en él) |
| `ESP_MIN_FREE_MB` | restore | `20` | Margen libre que se quiere dejar en la ESP tras restaurar |

El espacio necesario se calcula en tiempo de ejecución como `ESP_MIN_FREE_MB` + el tamaño de los UKIs a restaurar. Hasta v3.4 era un umbral fijo de 50 MB, menor que un UKI típico (~75 MB), por lo que el aviso de "poco espacio" no podía dispararse cuando realmente no cabía.

Variables de entorno (para pruebas; no hace falta tocarlas en producción):

| Variable | Por defecto | Para qué |
|---|---|---|
| `TSUKI_UKI_DIR` | detección automática | Fuerza el directorio de UKIs de origen |
| `TSUKI_BACKUP_DIR` | `/etc/timeshift/uki-backup` | Fuerza el directorio de respaldo |
| `TSUKI_LOG_FILE` | `/var/log/timeshift.log` | Fuerza el archivo de log |

`TS_SNAPSHOT_PATH` lo exporta Timeshift; el hook también lo acepta a mano.

---

## 📍 Detección de la partición de arranque

Ambos hooks tienen que decidir en qué partición están los UKIs. **No hay variable de configuración para eso**: se detecta sola, y conviene entender cómo, porque es la misma regla en los dos hooks desde v3.6.

Una partición es **candidata** si está **montada** y tiene el directorio `EFI/Linux`. La presencia de ese directorio es la evidencia: es donde `kernel-install` deja los UKIs, así que existe en la partición correcta y no en la otra.

| | Backup hook | Restore hook |
|---|---|---|
| Rutas estándar (`/boot`, `/efi`, `/boot/efi`) | primera montada con `EFI/Linux` | primera montada con `EFI/Linux` |
| Otras vfat montadas | `EFI/Linux` + PARTTYPE ESP/XBOOTLDR | `EFI/Linux` + PARTTYPE ESP/XBOOTLDR |
| Crea el directorio si falta | no | no |

El **PARTTYPE** (ESP `c12a7328` o XBOOTLDR `bc13c2ff`) solo se exige cuando hay que buscar **fuera** de las rutas estándar, que es donde cabe confundirse con un USB. En las rutas estándar basta con `EFI/Linux`.

Si **ninguna** partición candidata, los hooks lo dicen y **no escriben nada**. En el restore significa que la restauración no se lleva a cabo; **no** significa que los UKIs acaben en una partición cualquiera.

### Por qué no se acepta «el primer mountpoint que aparezca»

Hasta v3.5 el restore hook aceptaba el primer punto de montaje de `/boot`, `/efi`, `/boot/efi` **sin comprobar nada**, y creaba el destino con `mkdir -p`. En una máquina con **una sola** partición de arranque eso es inofensivo, pero en el layout habitual de dual-boot era un bug:

```
p1  ESP     c12a7328  → /efi    ← Windows (o el bootloader), SIN UKIs
p5  XBOOTLDR bc13c2ff → /boot   ← los UKIs de Linux aquí
```

Si `/boot` **no** estaba montado, el hook caía en `/efi`, creaba `/efi/EFI/Linux` y escribía ahí los UKIs. Los UKIs reales de `/boot` no se restauraban y, con `PRUNE_UKIS=true`, además se borraba de esa partición los `.efi` que no estuvieran en el respaldo. El error se **persistía**, porque el `mkdir -p` dejaba el directorio ya creado para la siguiente ejecución.

> **El caso más probable era el chroot de un Live USB** (el "peor caso" que describe [ARCHITECTURE.md](ARCHITECTURE.md)): ahí es fácil montar `/efi` por costumbre y olvidar `/boot`.

**Cómo comprobar tu máquina:**

```bash
# La partición de los UKIs es la única vfat con un EFI/Linux con contenido
findmnt -t vfat -o TARGET,SOURCE
sudo ls -d /boot/EFI/Linux /efi/EFI/Linux 2>&1   # solo debe existir el correcto
```

Los UKIs en uso son los que tienen el nombre `<machine-id>-<uname -r>.efi` (compruébalo con `uname -r`).

Si el hook aborta con `No se encontro la particion de arranque`, casi siempre es que la partición de los UKIs no está montada: móntala y vuelve a lanzar el restore. Si está realmente vacía, crea el directorio a mano (`mkdir -p <mnt>/EFI/Linux`); el hook no lo hace por ti precisamente para no dejar UKIs donde no había ninguno.

---

## 🔒 Seguridad

- ✅ **Integridad**: Verificación SHA256 obligatoria antes de restaurar.
- ✅ **Atomicidad**: Uso de copias temporales y `mv` para evitar archivos corruptos.
- ✅ **Secure Boot**: No modifica firmas; solo preserva los binarios ya firmados.
- ✅ **Detección de ESP**: Verifica PARTTYPE para no confundir con USBs.

### Verificación de integridad (checksums)

El backup hook escribe junto a cada UKI un archivo de checksum con el nombre **completo del UKI** más el sufijo `.sha256` (p. ej. `arch-linux.efi.sha256`, `c2224fef-...-7.1.8-arch1-3.efi.sha256`). Contiene únicamente el hash SHA-256 en hex (sin nombres de archivo):

```bash
sha256sum /boot/EFI/Linux/c2224fef-*-7.1.8-arch1-3.efi | awk '{print $1}'
# se guarda en /etc/timeshift/uki-backup/<mismo-nombre>.efi.sha256
```

El restore hook, antes de copiar, calcula el SHA-256 de cada UKI respaldado y lo compara con su `.sha256`:
- Si **coincide** → restaura (o salta si el destino ya es idéntico, evitando escrituras innecesarias a la ESP).
- Si **no coincide** → aborta con `ERROR: Checksum falló` (posible corrupción del respaldo).
- Si **falta** el `.sha256` → avisa con `WARN` y continúa sin verificación (no bloquea la restauración).

Los `.sha256` huérfanos (sin su UKI asociado) se limpian automáticamente en cada ejecución del hook.

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
| "Espacio insuficiente" | ESP casi llena | Con v3.5 el aviso calcula el espacio real que hace falta; si aparece, `PRUNE_ESP_UKIS` ya habrá liberado los UKIs de kernels desinstalados |
| Hooks no se ejecutan | Permisos incorrectos | `chmod +x /etc/timeshift/*-hooks.d/90-*-uki` |
| Tras restaurar, el sistema no arranca o el UKI no está donde debería | El restore hook eligió otra vfat montada (dual-boot) | Ver [Detección de la partición de arranque](#-detección-de-la-partición-de-arranque) |
| El menú de arranque ofrece kernels viejos | UKIs acumulados en la ESP | Con v3.5 se purgan solos en el siguiente snapshot; para hacerlo ya: `rm` manual de `/boot/EFI/Linux/<machine-id>-<kver>.efi` de kernels ya desinstalados |

> Si tu ESP se monta con `dmask=0077` (opción habitual de `systemd-fstab-generator` en vfat), los UKIs quedan en `700` y **solo root puede leerlos**, también dentro de `/etc/timeshift/uki-backup/`. No afecta a los hooks (se ejecutan como root), pero impide comprobarlos a mano con tu usuario normal.

---

## 🧪 Desarrollo y CI

Cada `push` a `main` ejecuta [`.github/workflows/ci.yml`](.github/workflows/ci.yml), que comprueba:

1. **Sintaxis**: `bash -n` sobre `install.sh`, ambos hooks y los dos tests.
2. **ShellCheck** en nivel `warning` (sin excepciones: el nivel está limpio).
3. **Coherencia de versión**: `VERSION` es la única fuente de verdad y la CI falla si `README.md`, `CHANGELOG.md`, ambos hooks o `install.sh` no la declaran igual. Antes la versión se escribía a mano en cada fichero y ya había derivado (el título del README se quedó en v3.2 mientras el código iba por v3.4).
4. **Tests**: [`tests/smoke.sh`](tests/smoke.sh) (backup hook) + [`tests/boot-partition.sh`](tests/boot-partition.sh) (restore hook), que es el que invoca al primero.

```bash
./tests/smoke.sh          # ejecuta los dos
```

**`tests/smoke.sh`** ejecuta el backup hook de verdad contra un árbol temporal (`mktemp -d`) usando las variables `TSUKI_*`, sin tocar el sistema. Comprueba la purga de la ESP, el respaldo selectivo con su `.sha256`, los dos layouts de snapshot (Btrfs y rsync) y la idempotencia de una segunda ejecución.

**`tests/boot-partition.sh`** cubre el restore hook, que hasta v3.5 no tenía ninguna cobertura. La clave es que **no necesita una ESP real ni privilegios**: se re-ejecuta dentro de un namespace de usuario (`unshare -r -m -p -f`) y levanta un chroot mínimo con *bind mounts* de `/usr`, `/dev`, `/sys` y `/proc`. Dentro, `/boot` y `/efi` se pueden montar o dejar como directorios planos, así que se ejercita el código de producción tal cual, sin variables de entorno ni *seams* que solo usen los tests. Cubre 9 casos: los cuatro *layouts* de partición con UKIs en `/boot` y/o `/efi`, los dos escenarios de dual-boot con la partición de los UKIs **sin montar** (justo los que fallaban antes del fix), el caso "ninguna sirve" y tres de verificación de checksum.

Si las *user namespaces* estuvieran deshabilitadas, el test **falla** en lugar de saltarse en silencio: un test que se salta solo no es cobertura.

> ⚠️ **La CI corre en `ubuntu-latest` y eso no verifica ninguna distro.** Es el único entorno donde el proyecto se ejecuta de forma automatizada, y no es el de producción: los hooks corren dentro de un *chroot* simulado, sobre un árbol de ficheros, nunca contra una ESP de verdad ni contra un arranque real. La CI no cuenta como verificación en hardware (ver [la limitación conocida](#limitación-conocida-el-soporte-multi-distribución-no-está-verificado-en-hardware-real)); de hecho, los dos fallos que corrigió el `chroot` de `boot-partition.sh` eran **típicos de Ubuntu** (`/lib64` como directorio real en vez de symlink, y `awk` desapareciendo al no existir `/etc/alternatives`).

---

## 📄 Changelog

Para el historial completo de cambios, ver [CHANGELOG.md](CHANGELOG.md).

### v3.6 (Última versión)
- **El restore hook elegía la partición de arranque equivocada** (bug, no solo fragilidad). Aceptaba el **primer mountpoint** de `/boot`, `/efi`, `/boot/efi` sin comprobar nada y creaba el destino con `mkdir -p`. Con dos vfat montadas y solo una con UKIs (dual-boot), si la partición correcta no estaba montada, escribía los UKIs en la otra y —con `PRUNE_UKIS=true`— además borraba de ella los `.efi` que no estuvieran en el respaldo. El `mkdir -p` hacía que el error quedara "confirmado". Ahora una partición solo es candidata si está montada y tiene `EFI/Linux`, y si no hay ninguna el hook **aborta con un error claro** en vez de adivinar. Era justo lo que documentamos como limitación en v3.5.
- **Los dos hooks ya no pueden apuntar a particiones distintas**: ambos aplican la misma regla (`is_boot_partition_dir`).
- **Un `.sha256` con formato `sha256sum` abortaba la restauración**: se comparaba el fichero entero contra el hash pelado, así que un `.sha256` con formato `<hash>  <nombre>` fallaba siempre aunque el hash fuese correcto. Ahora se aceptan ambos formatos.
- **El fallback que monta particiones ya no acepta la primera que se monte bien**: se reintenta la resolución y solo se usa lo que la validación acepte.
- **El restore hook por fin tiene cobertura automática** ([`tests/boot-partition.sh`](tests/boot-partition.sh), 9 casos): namespace de usuario + chroot mínimo con *bind mounts*, sin necesitar una ESP real ni privilegios. Simula los cuatro *layouts* de partición y los dos escenarios de dual-boot que fallaban antes.

### v3.5
- **`PRUNE_ESP_UKIS` (backup hook)**: purga de la partición de arranque los UKIs versionados cuyo kernel ya no está instalado. `kernel-install` no los borra nunca, así que `/boot/EFI/Linux` acumulaba UKIs de kernels desinstalados que, con autodetección de systemd-boot, se colgaban como entradas extra en el menú de arranque.
- **Espacio de la ESP calculado en tiempo de ejecución** (restore hook): antes era un umbral fijo de 50 MB, menor que un UKI típico (~75 MB), así que el aviso de "poco espacio" no podía dispararse. Ahora es `ESP_MIN_FREE_MB` (20) + el tamaño de los UKIs a restaurar.
- **Hooks parametrizables por entorno** (`TSUKI_UKI_DIR`, `TSUKI_BACKUP_DIR`, `TSUKI_LOG_FILE`): permiten ejecutar el backup hook contra un árbol de pruebas sin tocar el sistema.
- **CI** (`.github/workflows/ci.yml`): `bash -n`, ShellCheck sin excepciones, coherencia de versión contra `VERSION` y smoke test del backup hook (`tests/smoke.sh`). Antes el repositorio no tenía ninguna verificación automática.
- **`VERSION`**: fichero único de versión; la CI obliga a que todos los ficheros lo declaren igual.
- **Los hooks de git eran `644`** (no ejecutables en un clon recién hecho). Ahora son `755`.
- **Restauración**: los UKIs se conservan dentro de cada snapshot, así que el directorio de respaldo ocupa ~75 MB adicionales por snapshot (Btrfs no deduplica entre subvolúmenes).
- **Correcciones de documentación**: título del README sincronizado con la versión real, tabla de plataformas ajustada a lo que está probado, `ARCHITECTURE.md` y este README alineados con `PRUNE_OLD_UKIS`, y eliminas dos afirmaciones que no se correspondían con el código (la detección de ESP por PARTTYPE sí existe en el restore hook, y `IN_CHROOT` nunca se usó para ajustar rutas).
- **`install.sh`**: comprueba que Timeshift esté instalado y que exista un `EFI/Linux` en alguna vfat, y avisa si los hooks actuales pertenecen a un paquete (su uso deja los ficheros fuera del gestor de paquetes y hace que `pacman -Qkk` los marque como alterados).

### v3.4
- **`trap cleanup EXIT`** en el restore hook: si el script aborta a mitad (checksum falla, cp falla, signal), el trap restaura el modo RO de la ESP y la desmonta si fue montada manualmente. Evita que la ESP quede montada RW o colgada.
- **`skip_prune`** en `copy_ukis()`: la segunda llamada (snapshot) omite la purge de obsoletos, evitando I/O innecesario.

### v3.3
- **`PRUNE_OLD_UKIS` (backup hook)**: cada snapshot viaja **solo con el UKI del sistema actual** (`uname -r`). Con layout `kernel-install` se eliminan del respaldo los `.efi` obsoletos (versiones anteriores y el preset clásico `arch-linux.efi` legacy), evitando que UKIs de kernels viejos se acumulen en las snapshots y sean devueltos a la partición de arranque al restaurar. Configurable con `PRUNE_OLD_UKIS`.
- **Fix en el restore hook**: la ruta del checksum apuntaba a `"<UKI>".sha256` en lugar de `"<UKI>.efi.sha256"`, por lo que la verificación de integridad y el "salto si idéntico" nunca se ejecutaban. Corregido.

---

## 📄 Licencia

Este software está bajo la licencia **GNU General Public License v3.0**.

**Contribuciones**: Proyecto mantenido por Jairo Galeano.
