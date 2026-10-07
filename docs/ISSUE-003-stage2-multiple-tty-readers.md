# ISSUE-003: Varios shells compiten por ttyGS0

Estado: **causa raíz identificada** en ST22 y **corregida** en ST23.

Impacto: la consola USB es bidireccional y fiable en el rescate (stage 1) pero
**ilegible e inutilizable en stage 2**. Cuatro experimentos consecutivos
(ST16, ST17, ST18, ST19, ST20) "arreglaron" el código sin cambiar nada.

## Síntomas

- Comandos troceados: `touch /tmp/x` llegaba como `ouh/m/t0cnoeo`.
- Varias apariciones de `sh: can't set tty process group: Not a tty`.
- El **eco** del prompt llegaba íntegro pero lo **ejecutado** salía partido.
  Eso descarta un problema de temporización del host: la línea llegaba
  completa a la disciplina de línea y se repartía al hacer `read()`.
- TICK cada 5 s dentro de stage 2, cuando el código dice 60 s.
- `stage=STAGE2_ROOTFS` con `period = 5` a la vez: imposible si el binario en
  ejecución fuera el esperado. Esa contradicción fue la pista.

## Evidencia ST22

Caja negra persistente en `/var/log/ruby-boot/` (dentro del rootfs de `super`):

```
3 lectores ANTES de la limpieza
3 lectores DESPUÉS      <- kill_all_children() no mató a NINGUNO
5 lectores tras crear el shell de stage 2
```

```
PID 360  PPID=1  SID=360  tty_nr=360  fd0=ttyGS0    sh   (rescate)
PID 361  PPID=1             fd0=/dev/console      sh   (rescate)
PID 362  PPID=1             fd0=/dev/ttyS0        sh   (rescate)
PID 409  PPID=1  SID=409  tty_nr=409  fd0=ttyGS0    sh   (stage 2)
PID 411  PPID=1  SID=409             fd0=ttyGS0      sh   (hijo del stage 2)
```

Los PIDs 360/361/362 son idénticos antes y después de la limpieza: **no se
mató a nadie**. Y el shell de stage 2 (409) consigue su propio `tty_nr` y su
`SID`, o sea que `TIOCSCTTY` va bien: **no es un problema de termios ni del
host**, son dos lectores compitiendo el `read()` sobre el mismo descriptor.

## Causa raíz

`kill_all_children()` leía el PPID en la posición equivocada:

```c
sp1 = strrchr(buf, ')');   /* buf = "360 (sh) S 1 360 360 ..." */
sp2 = sp1 + 1;
while (*sp2 == ' ') sp2++; /* -> "S 1 360 360 ..." */
if (atol(sp2) == (long)me) kill(pid, SIGKILL);
```

El formato de `/proc/<pid>/stat` es:

```
pid (comm) state ppid pgrp session ...
```

Justo después del último `)` está el **estado** (`S`, `R`, `D`…), no el PPID.
`atol("S 1 360 …")` devuelve **0**, la comparación contra `getpid()` (1) nunca
es cierta y la función mata un conjunto **vacío** sin devolver error alguno.

Que `atol()` fuera el problema y no `strtol()` es irrelevante: ambos devuelven
0 ante una cadena que no empieza por un dígito. El defecto es **leer el campo
equivocado**.

## Corrección

`smoke/init/ruby-init.c`, función `parse_stat_ppid()`:

1. localizar el **último** `)` (porque `comm` puede contener espacios y
   paréntesis);
2. avanzar espacios;
3. leer **un carácter** como `state`;
4. avanzar espacios;
5. convertir el token siguiente con `strtol()`;
6. validar que hubo conversión (`errno`, `end != p`);
7. comparar el PPID obtenido con `getpid()`.

No se usa `sp2 + 2`: eso presupone exactamente el espaciado `") S "` y falla
en cuanto cambia un espacio o el campo de estado.

## Por qué costó cuatro experimentos

1. **El síntoma era intermitente.** Las órdenes que caían en un hueco entre
   TICKs llegaban enteras, lo que hacía creer que el arreglo anterior funcionaba
   cuando en realidad sólo se mitigaba.
2. **No había forma de preguntar "¿cuántos hijos mataste?".** `kill()` devolviendo
   0 significa "señal entregada", no "proceso desaparecido"; y aquí ni siquiera
   se llamaba, así que el código era indistinguible del éxito.
3. **La prueba de exclusividad llegó tarde.** Durante ST16–ST21 se juzgó la
   consola mirándola, no contando lectores.
4. **Había dos artefactos** (initramfs y rootfs) y durante ST17–ST20 el
   binario ejecutado venía del rootfs, que seguía congelado en ST8. Ver
   `docs/10-doble-artefacto.md` en `ruby-kernel-triage`.

## Gate

ST23 pasa únicamente con esta transición:

```
readers_before_cleanup = 3
readers_after_cleanup  = 0
readers_after_shell    = 1
```

Dejarlo escrito como gate duro, no como observación: el shell de stage 2 **no
se crea** si quedan lectores, y el resultado se persiste en
`/var/log/ruby-boot/console-gate.txt` para poder leerlo desde Android B aunque
la consola siga inservible.

```c
int shell_allowed = (cr.tty_readers_after == 0);
```

Si no se cumple, se registra `STAGE2_SHELL_BLOCKED readers=<n>`, se escribe el
snapshot, se sincroniza y se deja actuar al guard, que devuelve el móvil a
fastboot con la evidencia. El fallo pasa a ser explícito.

## Lectura de la evidencia

El bucle de UFS con `losetup -o OFF -S SIZE` **da EIO** al montar con el
`losetup` de toybox, y `e2fsck` también falla. Lo que sí funciona:

```sh
adb shell 'dd if=/dev/block/sdc61 of=/data/local/tmp/x.ext4 bs=1M skip=4096 count=512'
adb pull /data/local/tmp/x.ext4
sudo debugfs -R 'cat /var/log/ruby-boot/console-gate.txt' x.ext4
```

`smoke/read-diag-logs.sh` automatiza esto.

## Evidencia relacionada

- `docs/experiments/EXP-ST22-TTY-READER-IDENTITY.md` — el experimento que lo destapó.
- `docs/experiments/EXP-ST23-TTY-EXCLUSIVITY.md` — el que demuestra la corrección.
- `evidence/diag/ST22/` — inventarios de descriptores y snapshots de procesos.