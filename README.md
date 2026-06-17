# Timeshift UKI Hooks v2.2

Sistema de hooks para **Timeshift** que respalda y restaura imágenes **UKI (Unified Kernel Images)** en sistemas con **Btrfs + Secure Boot**.

## 📋 Tabla de Contenidos

- [Concepto](#concepto)
- [¿Por qué es necesario?](#por-qué-es-necesario)
- [Cómo funciona](#cómo-funciona)
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Novedades en v2.2](#novedades-en-v21)
- [Seguridad](#seguridad)
- [Depuración](#depuración)
- [Licencia](#licencia)

---

## 🔍 Concepto

En sistemas Arch Linux con **systemd-boot** y **Secure Boot**, las imágenes UKI (ficheros `.efi`) residen en la partición **EFI System Partition (ESP)**.

**El problema**: Timeshift protege la raíz (`/`), pero la partición ESP queda fuera. Si restauras un snapshot antiguo, el kernel en `/` (módulos) y el UKI en la ESP (kernel binario) no coincidirán, impidiendo el arranque o el funcionamiento de módulos.

---

## 🎯 Solución

Este proyecto sincroniza los UKIs con los snapshots de Btrfs mediante hooks:

1. **Backup Hook** (`/etc/timeshift/backup-hooks.d/90-backup-uki`)
   - Se ejecuta **antes** de crear el snapshot.
   - Respalda los UKIs en `/etc/timeshift/uki-backup/` (dentro del snapshot).
   - **Inteligente**: Solo copia si detecta cambios (vía SHA256).

2. **Restore Hook** (`/etc/timeshift/restore-hooks.d/90-restore-uki`)
   - Se ejecuta **después** de restaurar.
   - Devuelve los UKIs a la partición ESP.
   - **Inteligente**: Salta archivos que ya son idénticos.

---

## 📦 Instalación

Hemos simplificado la instalación con un script dedicado:

```bash
git clone https://github.com/jairogaleano/timeshift-uki-hooks-v2.git
cd timeshift-uki-hooks-v2
sudo chmod +x install.sh
sudo ./install.sh
```

El instalador se encarga de:
1. Crear los directorios de hooks.
2. Limpiar versiones anteriores.
3. Instalar los scripts con nombres canónicos para compatibilidad con `run-parts`.
4. Aplicar permisos de ejecución.

---

## ✨ Novedades en v2.2

- **Fix crítico**: Variable `expected_sha` inicializada correctamente para evitar `unbound variable` en restore hook.
- **Seguridad**: Uso de `mktemp` en vez de `$$` para archivos temporales en restore hook.
- **Skip condicional**: La comparación de checksums en restore salta archivos solo cuando SHA256 está disponible.
- **Limpieza**: Eliminada variable `skipped_count` sin uso y redirección redundante en restore hook.

---

## 🔒 Seguridad

- ✅ **Integridad**: Verificación SHA256 obligatoria antes de restaurar.
- ✅ **Atomicidad**: Uso de copias temporales y `mv` para evitar archivos corruptos.
- ✅ **Secure Boot**: No modifica firmas; solo preserva los binarios ya firmados.

---

## 🔧 Depuración

Ver logs en tiempo real:
```bash
tail -f /var/log/timeshift.log
```

---

## 📄 Licencia

Este software está bajo la licencia **GNU General Public License v3.0**.

**Contribuciones**: Proyecto mantenido por Jairo Galeano.
