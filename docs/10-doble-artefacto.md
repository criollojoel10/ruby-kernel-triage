# 10 — El error que costó cinco experimentos: initramfs y rootfs son dos artefactos

El 6 de octubre de 2026, cinco experimentos consecutivos (ST16 a ST20) cambiaron el
initramfs del teléfono y **ninguno cambió el comportamiento** una vez que el arranque
llegaba al rootfs. La causa no estaba en el código, que era correcto desde el tercer
intento.

Este es el registro de lo que pasó, porque el error es fácil de repetir.

## Los dos artefactos

```
boot_a / initramfs              rootfs ext4 dentro de super
├── se actualiza con            ├── NO cambia al flashear boot_a
│   fastboot flash boot_a       │
└── ruby-init como /init        └── ruby-init como /sbin/init
                                    (persistido en el dispositivo)
```

El primer árbol se reescribe cada vez que flasheamos. El segundo se escribió **una vez**,
a las 14:26, y nunca se volvió a tocar.

## El síntoma

El kernel arrancaba, montaba el rootfs, ejecutaba `switch_root` correctamente — eso
funcionaba desde ST15 — y a partir de ahí la consola por USB se corrompía: cada comando
llegaba partido.

```
enviado:  ls /root
recibido: srts/ro            →  sh: srts/ro: not found

enviado:  echo CONSOLA-LIMPIA-MARKER-12345
recibido: echo CONOSLA-LIMPIA-MARKER-12345   →  sh: OSAM-AKR24: not found
```

## La pista que lo resolvió

Tres síntomas que no encajaban con el código fuente, que a esas alturas ya tenía todos los
arreglos:

1. `sh: can't set tty process group: Not a tty` salía **dos o tres veces** por comando.
   El código de stage2 abría **un solo** shell.
2. El `TICK` seguía **cada 5 segundos** aunque el código puesto `rescue_mode = 0` en
   stage2, lo que daría un TICK cada 60.
3. El texto de stage decía `STAGE2_ROOTFS`, una cadena presente en todas las versiones.

Los tres juntos eran imposibles con el binario recién compilado. La conclusión: **el
binario que estaba corriendo no era el que acabábamos de compilar**.

La comprobación que lo confirmó:

```sh
$ debugfs -R "dump /sbin/init /tmp/x" rootfs.ext4
$ strings /tmp/x | grep -E 'STAGE2_ROOTFS|--rootfs|kill_all_children|rescue_mode'
STAGE2_ROOTFS
```

Una sola cadena. Era el binario de ST8: sin `--rootfs`, sin limpieza de los shells del
rescate, tres shells, TICK cada 5 s. Exactamente lo observado.

## Por qué engaña

Un binario viejo produce el mismo síntoma que un bug nuevo. En este caso concreto:

- el código tenía el arreglo y aun así fallaba,
- el `strings` del binario local **sí** mostraba las cadenas nuevas,
- el flash había devuelto `OKAY`,
- el reinicio había funcionado.

Todo indicaba que la imagen era correcta. Lo único que faltaba era mirar **qué binario
ejecutaba el teléfono**, y ese no era el que acabábamos de construir.

## El arreglo

```sh
# 1. El rootfs se reescribe con el init actual
bash smoke/build-st.sh ST21          # construye los DOS artefactos
bash smoke/write-rootfs.sh work/ruby-rootfs-ST21.ext4

# 2. Solo después, el boot
fastboot flash boot_a work/boot-ST21.img
```

Y para que no vuelva a pasar, el binario se identifica solo:

```
RUBY_INIT_BUILD_ID=ST21-rootfs-v2-18b8515
PROTOCOL=st1:rescue+switch_root st2:rooted
BUILD_DATE=Oct  6 2026 20:27:45
```

`sbin/init --version` lo imprime, y el arranque lo anuncia **antes de tocar nada**. El
sha que lleva incrustado es **del código fuente**, no del binario: el del binario cambiaría
al recompilarlo, el del fuente es estable y se puede verificar contra el repositorio.

`smoke/build-st.sh` además aborta si el `/sbin/init` que hay **dentro** de la imagen del
rootfs no entiende `--rootfs`, si no trae la limpieza de stage2, si el build id no coincide
con el del boot, o si `e2fsck` no está limpio. Es la comprobación que faltaba.

## Cómo nombrar un experimento

No «ST20 flasheada», sino la combinación:

```
boot=ST21 + rootfs=v2
```

El comportamiento observado es el producto de los dos artefactos, y describirlos por
separado invita a volver a confundirlos.

## Dos reglas que van mas alla de este caso

**No asumir que flashear `boot_a` actualiza el rootfs.** Es el mismo error que
intentar arreglar un programa y recargar sólo la biblioteca.

**Cuando el comportamiento contradiga al código, sospechar del artefacto antes que de la
lógica.** Un binario viejo y un bug nuevo se ven igual desde fuera.

## Detalle técnico: exclusividad de la consola

El criterio correcto para «una sola sesión en la consola USB» no es contar procesos con
cualquier descriptor hacia `ttyGS0`, sino contar los que tienen **`fd 0` (entrada)**:

```sh
for p in /proc/[0-9]*; do
    for fd in 0 1 2; do
        t=$(readlink "$p/fd/$fd" 2>/dev/null)
        case "$t" in *ttyGS0*) echo "pid=${p##*/} fd=$fd";; esac
    done
done
```

Varios descriptores de **salida** hacia el puerto USB son normales: el PID 1 escribe sus
registros ahí y el shell escribe su salida. Eso no corrompe nada. Lo que corrompe son
**varios lectores** de la entrada.

Corolario útil: un TICK o cualquier escritura periódica al puerto corrompe lo que se
teclea. Un goteo de 60 bytes cada 5 s sobre un puerto a 115200 compartido parte las líneas
a mitad. Por eso el canal de diagnóstico y el de control no pueden ser el mismo, y el
latido necesita una vía aparte.

## Nota sobre este repositorio

Los registros de consola de esos experimentos están en `logs/2026-10-06-bringup/`,
pasados por `scripts/redact-logs.sh`. El número de serie del dispositivo aparece
sustituido por `<device-serial>` en `flash-st20.log`.

Documentación técnica completa: `criollojoel10/ruby-postmarket-build` →
`STATUS.md`, `docs/adr/ADR-0009-identidad-doble-artefacto.md`,
`docs/25-punto-de-reanudacion.md`.