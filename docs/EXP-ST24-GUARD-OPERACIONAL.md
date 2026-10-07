# EXP-ST24: Guard operacional de tres estados

Fecha: 2026-10-07 · Derivado de ST23 (`b0967ac9`, no desplegado) · Decisión: ADR-0010

## Que se queria demostrar

ST23 cerro la investigacion de consola (ISSUE-003) y dejo un guard fijo de 240 s, sin
desarme. Ese guard era justo lo que impedia trabajar: cuatro minutos no dan una sesion de
diagnostico real. ST24 convierte ese entorno ya estable en una sesion segura y larga,
sin tocar pmOS, OpenRC, Wi-Fi, graficos ni particionado.

## Artefactos

```
ruby-init.c sha256  8afed53bfb8cfe54e4c7df2c9ec488bff7a5d0c2740ceb3a06a5614467494231
build id            ST24-rootfs-v5-df7a037
boot-st24.img       d8eb48c45b56e6b4fc6f494ac1ca565abd4f193a9ec90626f4ec1038cfba8276
ruby-rootfs-v5      e6181f2cce7d0ebcf2bd6416d1acdc31aa51a639e906fc4c42cfb6c458f39197
```

`build-manifest-st24.json` declara `derived_from: {experiment: ST23, artifact: b0967ac9,
deployed: false}`. ST24 **no** reutiliza la identificacion de ST23: el codigo del parser
es el mismo, pero el comportamiento del guard cambia, y el build id tiene que reflejarlo.

## Escritura verificada

```
lpdump            slot activo termina en sector 7763392, nuestro rango empieza en 8388608 -> OK
write-rootfs.sh   WRITE_PREFIX_VERIFIED   (primer MiB, mitad, ultimo MiB; magic 53ef a 4 GiB+1024+0x38)
verify-rootfs-full.sh  FULL_IMAGE_VERIFIED  (512 MiB, sha identico)
flash boot_a      Writing 'boot_a' OKAY
set_active a      OKAY
```

## Resultados

### Gate A: transicion automatica — PASS

```
ST24_GUARD_STARTED  state_initial=DIAGNOSTIC timeout_diagnostic=240s
                    timeout_work_session=1800s poll=10s
GUARD_TRANSITION    diagnostic->work_session
GUARD_STATE=WORK_SESSION  GUARD_TIMEOUT=1800s  work_deadline_T=1800.1
```

Los diez gates internos quedaron en PASS (`guard-gates.txt` -> `RESULT=PASS`): rootfs
escribible, proc/sys/devpts montados, build id correcto, cleanup completado,
`readers_after_cleanup == 0`, shell creado, `readers_after_shell == 1`, console gate PASS.

### Gate B: no reinicio a los 240 s — PASS

A los 06:39:57 el uptime era de 170 s; a las 06:41:10 era de ~283 s y el movil seguia en
nuestro kernel, con el gadget USB presente y sin fastboot. El plazo DIAGNOSTIC no disparo
el reboot porque hubo transicion.

### Gate C: consola estable prolongada — PASS

`ST24-C1-BASELINE` integro; `date` -> `Wed Oct  7 11:43:29 UTC 2026`;
`/proc/uptime` -> 354.75 / 365.30 / 381.81 s (crece: el reloj Monotónico esta vivo);
`ps` -> `PID 1 … init --rootfs` mas los hilos del kernel; dos lineas largas sin trocear;
`st24-session.txt` persistido en el rootfs a las 06:45.

Un residuo `daeWed` aparecio una sola vez, en la linea inmediatamente posterior a un
`^C`+`[6n` emitido por el host: es artefacto de `acm.py`, no corrupcion del movil.

### Gate D: desarme con token valido — PASS

```
GUARD_DISARM_REQUEST
GUARD_TOKEN_VALID
GUARD_DISARMED
GUARD_STATE=DISARMED  timeout=desactivado  canal de control sigue activo
```

### Gate E: token invalido rechazado — PASS

```
GUARD_TOKEN_INVALID reason=token_no_coincide
  esperado=54ed58ac-3fd8-44c0-ae9a-7ce95a078268
  recibido=invalid-tokenn
```

Probado dos veces, con dos cadenas distintas. El guard seguia contando y el fichero de
peticion se consumio siempre.

### Gate F: regreso voluntario desde DISARMED — PASS

```
GUARD_REBOOT_REQUEST
GUARD_REBOOT_TOKEN_VALID
GUARD_LAST_STATE=DISARMED
GUARD_FINAL owners=1 interactive_readers=1 stage2_readers=1 pid1_owned=0
SYNC_HECHO, reboot a bootloader desde el estado DISARMED
```

El guard **no muere al desarmarse**: pasa a `DISARMED` sin plazo y sigue atendiendo
`reboot-bootloader`. Eso permitio probar desarme y regreso voluntario en el mismo
arranque, que era la opcion recomendada.

## Inventario de consola: el defecto, corregido

ST22 y ST23 clasificaban por el path textual de `readlink(fd/0)`. `/dev/console` y
`/dev/ttyGS0` son dos nombres del mismo dispositivo, asi que PID 1 contaba como lector y
el resultado quedaba infravalorado en 1. Documentarlo como "infravalora en 1" era
describir el sintoma en vez de arreglarlo.

ST24 compara `major`/`minor` del descriptor (`st_rdev`) y separa tres cosas:

```
console-census.txt   CONSOLE_FD_OWNERS=1 INTERACTIVE_READERS=1 STAGE2_SHELL_READERS=0
                     PID1_OWNED=0 SCAN_FAILED=0 rdev=478:0
guard (final)        owners=1 interactive_readers=1 stage2_readers=1 pid1_owned=0
```

`PID1_OWNED=0` confirma que en este kernel `/dev/console` **no** es el mismo dispositivo
que `ttyGS0`: son rdev distintos. Tener stdin abierto no es estar leyendo en un bucle, y
el gate exige un unico lector interactivo que ademas sea el shell de stage 2.

El `STAGE2_SHELL_READERS=0` del censo inicial no es un fallo: el censo se escribe antes
de bifurcar el shell. El `GUARD_FINAL`, escrito despues, ya da `stage2_readers=1`.

## Un bug propio que el script de build cazó

La primera version tenia:

```c
int transitioned = 0;
while (!transitioned) { ... }
if (guard_verify_gates(gates) != 0) { ... } else { /* transicion */ }
```

`transitioned` nunca se asignaba, luego `while(!transitioned)` era `while(1)` y todo el
bloque de transicion era inalcanzable. El compilador lo elimino como codigo muerto y las
cadenas `GUARD_TRANSITION_DIAGNOSTIC_TO_WORK_SESSION`, `GUARD_STATE=WORK_SESSION` y
`WORK_SESSION_TIMEOUT` desaparecieron del binario. Sin el script de build habriamos
desplegado una imagen sin transicion, y el fallo se habria blamed al runtime.

Lo caza `smoke/build-st24.sh`, que hace `strings` sobre el binario y ABORTA si falta la
transicion. Consecuencia practica: **ademas de mirar el fuente, hay que mirar el binario**,
sobre todo cuando el compilador puede optimizar en nuestra contra.

## Estado del slot A

```
current-slot: a | slot-retry-count:a: 5 | slot-successful:a: no | slot-unbootable:a: no
slot-retry-count:b: 1 | slot-successful:b: yes
```

Un arranque que llega a WORK_SESSION y vuelve voluntariamente **no consume intentos**. Confirma
lo medido antes: lo que repone los intentos es arrancar el slot A y volver, no `set_active`.
El slot A **no** se marco como exitoso, a proposito.

## Recuperacion

`fastboot set_active b` + `reboot` -> Android en `_b`, `adb root` operativo,
`sys.boot_completed=1`.

La limitacion del entorno Android sigue igual: `toybox losetup -o/-S` devuelve I/O error al
montar. La ruta de inspeccion aceptada es `adb shell dd if=/dev/block/sdc61 … bs=1M
skip=4096 count=512` + `adb pull` + `debugfs` en el host. No se gasta tiempo en corregir
`losetup` de Android.

## Que queda

La siguiente frontera es **PMOS-M0**, no otro ST: reemplazar el rootfs de humo por
postmarketOS `ui=none` con OpenRC como PID 1, USB gadget, getty y SSH, sin interfaz
grafica. Para eso ST24 era necesario: ya se puede trabajar treinta minutos, con retorno
voluntario a fastboot a voluntad y diagnostico persistente.