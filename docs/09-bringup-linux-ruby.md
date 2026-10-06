# 09 — Bring-up de Linux sobre el ruby: consola USB, mapa de super, y el camino a pmOS

Registro fiel de lo que se construyó y probó contra el **Xiaomi Redmi Note 12 Pro 5G**
(`ruby`, MT6877V) los días 6–7 de octubre de 2026.

Documento técnico completo: `criollojoel10/ruby-postmarket-build` →
`docs/23-estado-bringup.md` y `docs/24-workflows-acciones.md`.

---

## 1. Punto de partida

El móvil corría `lineage_rubyx-userdebug 16` con kernel **6.6.127-4k-ged71a8f07b9c**.
Ese árbol **no está publicado en ningún repositorio** — se buscó a fondo y no aparece
(`gh search code '"6.6.127-4k"'` → 0 resultados; las 10 branches del repo de la ROM siguen
en 4.19.325). Así que no había de dónde sacar un kernel ni un árbol de fuentes.

Lo que **sí** había: un `boot.img` público en `RubyxLabs/releases@rubyx-20261001` cuyo
**device tree es byte-idéntico al que corre en el móvil** (`a7a4b405…`, 179139 B).

Estrategia: usar el kernel del propio ROM como plataforma, y meter un rootfs de pmOS debajo.

---

## 2. Lo que se consiguió

| Hito | Cómo se verificó |
|---|---|
| **Consola bidireccional por USB ACM** | `work/st7-console.log`: `uname` → `Linux 6.6.127-4k-ged71a8f07b9c-dirty`; `ls /bin` → busybox + ~43 symlinks; `echo SHELL_VIVA: $0` → `sh` |
| **boot.img reproducible en CI** | run `37516502209`, 32 s, sha `c1f91104…`, 9/9 comprobaciones OK |
| **Rootfs escrito en UFS y verificado** | sha del primer MiB leído del móvil = sha del host |
| **Auto-recuperación** | el PID 1 hace `reboot -f bootloader` a los 900 s, o a los 120 s si pierde USB ⇒ nunca se dejó el móvil inaccesible |

---

## 3. El mecanismo de la consola — el hallazgo que lo desbloqueó todo

El bootloader MTK (LK) concatena tres fuentes de línea de órdenes:

```
[ bootargs de LK ] + [ chosen/bootargs del DT ] + [ cmdline del header v2 ]
```

Lo que va en el header **gana**, porque se concatena al final. Eso es lo que permite
inyectar `console=` propio pese a que el DT del ROM traiga el suyo.

Pero lo que de verdad dio la consola fue otro detalle: **`/dev/ttyGS0` no lo crea
devtmpfs** en el kernel del ROM. El gadget USB enumeraba, el host veía `/dev/ttyACM0`,
y circulate **cero bytes**. Crear el nodo a mano leyendo `major:minor` de
`/sys/class/tty/ttyGS0/dev` lo resolvió.

Ese mismo detalle está en el port de referencia del Note 11 Pro (mismo SoC MT6877), que
funciona. **La lección: cuando algo no funciona, el port que sí funciona tiene la respuesta.**

---

## 4. El mapa de `super` — el único sitio donde cabe un rootfs

```
super = /dev/block/sdc61   9.126.805.504 B (8,50 GiB)
slot _b (activo)  termina en 3,70 GiB
slot _a (roto)     termina en 6,61 GiB
```

Rango elegido y validado con la herramienta del port de referencia:

```
offset 4.294.967.296 (4 GiB), longitud 1.610.612.736 (1,5 GiB)
→ no overlap with the active slot
→ inactive-slot overlap: system_ext_a, product_a-cow, vendor_a   (slot _a: roto)
```

**Advertencia operativa**: `virtual_ab_device` está activo ⇒ **una OTA puede escribir en el
espacio libre y pisar el rootfs.** Mantener las actualizaciones apagadas mientras el rootfs
viva ahí.

**Por qué el rootfs tiene que ir a UFS y no a la partición `boot`:**

```
boot_b = 128 MiB
  kernel 6.6 del ROM ......... 21,2 MB
  DTB ........................  0,2 MB
  presupuesto de ramdisk ...... ~20,3 MB
rootfs de pmOS ............... 659 MB
```

No cabe ni con el presupuesto ampliado (~112 MB). **Aritmética, no preferencia.**

---

## 5. Diez cosas que fallaron por el camino

Cada una costó un ciclo completo de flasheado. Están documentadas porque se repiten:

| # | Qué pasó | Por qué |
|---|---|---|
| 1 | 0 bytes por USB, gadget enumerado | `/dev/ttyGS0` no lo crea devtmpfs → `mknod` manual |
| 2 | `execve` → `ENOENT` | el cpio no declaraba `bin/`; el kernel no crea dirs intermedios |
| 3 | gadget no enumeraba | layout anidado `acm.usb0/GS0`; el plano `acm.GS0` es el que funciona |
| 4 | escrituras perdidas | `O_NONBLOCK` las descartaba |
| 5 | mensajes tapados | `stage_set()` guardaba un puntero al stack, no una copia → concatenación exponencial |
| 6 | consola con basura | `/dev/ttyACM0` del host tiene ECHO; leerlo devuelve cada byte al móvil |
| 7 | `EAGAIN` en el cliente | `O_NONBLOCK` con un móvil que genera mucho |
| 8 | payload +16 bytes | buffer de cabecera mal dimensionado en el ensamblador |
| 9 | campos v2 corrupts | offsets de la cola en hex inventado (`0x460` en vez de `0x660`) |
| 10 | `struct.error` en el build | `os_version` como string donde se esperaba un `u32` |

La 5 y la 6 son las más caras: ambas **funcionaban pero no se veían**, que es peor que
fallar.

---

## 6. Estado del hardware que se confirmó

- **No hay eMMC.** `dmesg | grep -c mmc` = 0. `sda`/`sdb`/`sdc` son los **3 LUN del UFS**.
  El nodo `mmc0` existe en el DT pero no enumera nada. ⇒ **el port no necesita eMMC.**
- **El táctil es FT3680** (`focaltech,3680-spi`, spi3). El `goodix` que aparece en los
  logs del triage es el **sensor de huella**, no el táctil.
- **El panel es `m16_42_0d_0a_dsc_vdo`** con DSC, y la config del kernel **sí trae**
  `CONFIG_DRM_PANEL_M16_42_0D_0A_DSC_VDO`. Pero el nodo del DT usa el framework LCM
  custom de MTK (`mediatek,dsi0`), no el `mediatek-drm` de mainline ⇒ **el DRM nunca hace
  probe y no hay framebuffer** (`/dev/fb*` no existe). De ahí que la pantalla se quede en
  el logo de MI.
- **El Wi-Fi no está en el kernel.** No existe `CONFIG_WLAN_VENDOR_MTK`; el driver MTK
  vive en `vendor_dlkm` como `.ko` firmados. Como es el mismo kernel y la misma clave,
  **se pueden cargar tal cual** — es trabajo pendiente, no un bloqueo.

---

## 7. Cómo no perder el móvil

```bash
adb reboot bootloader
fastboot flash boot_b rom/boot_b.img     # sha 4bd8b755…
```

El `boot_b` original está respaldado antes del primer flasheo. El init de rescate se
auto-recibe a los 900 s. El rootfs tiene handshake (`/etc/pmos-ruby-root`): si no está,
no hay `switch_root`, así que un `super` corrupto no deja al móvil dentro de un árbol vacío.

**El slot `a` está roto de fábrica** (bootloop con la imagen Android original,
`bootreason=lk_crash`): su `dtbo` y sus `vbmeta*` no corresponden a los del `boot`.
Todo va a `boot_b`.

---

## 8. Referencia canónica

**`Nxages/redmi-note-11-pro-postmarketos-server`** — Redmi Note 11 Pro, mismo SoC MT6877,
mismo bootloader, y **funcionando**. Cuando haya duda entre dos opciones, se copia su
código. Es la fuente de: loop-mount de ext4 en `super`, `switch_root`, watchdog,
validación del rango antes de escribir, y el patrón de consola de rescate.