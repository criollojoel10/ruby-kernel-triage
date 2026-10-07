# ADR-0010: Guard operacional de tres estados con token BOOT_ID

Fecha: 2026-10-07 · Experimento: ST24 · Deriva de: ST23 (`b0967ac9`, no desplegado)

## Contexto

ST23_closed la investigacion de consola: el parser de PPID era el bug (ISSUE-003) y
corregido dio la transicion 3 → 0 → 1 lectores con consola limpia. Su guard era fijo
(240 s, sin desarme) porque mezclar la validacion de la consola con el control
operacional del guard haria imposible atribuir un fallo a uno o a otro.

ST24 convierte ese entorno estable en una sesion suficientemente segura y larga para
empezar pmOS real. No toca pmOS, OpenRC, Wi-Fi, graficos ni particionado.

## La maquina de estados

```
DIAGNOSTIC (240 s)
   | gates internos: todos PASS
   v
WORK_SESSION (1800 s desde la TRANSICION, no desde el arranque)
   | token BOOT_ID valido en /run/ruby-boot/disarm
   v
DISARMED (sin plazo, proceso vivo, canal de control activo)
```

Desde cualquier estado, un fallo acaba igual:

```
fallo → snapshot → syncfs → sync → reboot bootloader
```

Nunca se marca el slot como exitoso ni se toca `misc`.

## Decisiones

### El plazo de WORK_SESSION se cuenta desde la transicion

`work_deadline = transition_monotonic + 1800`. Contarlo desde el arranque haria que el
tiempo real de trabajo fuese 1800 menos lo que se tardo en arrancar y llegar a stage 2.

### 1800 s, no tiempo ilimitado

Con un plazo infinito, un fallo silencioso deja el movil inaccesible hasta que alguien
tenga un cable. 1800 s son treinta minutos de trabajo comodo y un techo acotado.

### El desarme exige el boot_id, no la mera existencia

```sh
cat /proc/sys/kernel/random/boot_id > /run/ruby-boot/disarm
```

El guard valida: `lstat` dice fichero regular, tamano en (0, 96], lectura con
`O_NOFOLLOW`, sin salto final, y comparacion EXACTA con el boot_id actual. El fichero se
borra siempre tras inspeccionarlo. Un archivo vacio, residual de un arranque anterior o
creado por accidente se rechaza con `GUARD_TOKEN_INVALID` y el guard sigue contando.

Se usa `/run/ruby-boot/` y no `/tmp/go-bootloader`: el control de ciclo de vida pertenece
al estado de ejecucion del sistema, no a ficheros temporales genericos.

### reboot-bootloader es una peticion SEPARADA

Desarmar y volver a fastboot son dos intenciones distintas, asi que son dos ficheros.
Comprobado en ST24 que se pueden usar los dos en el MISMO arranque, porque el proceso
guard no muere al desarmarse: pasa a `DISARMED` sin plazo y sigue atendiendo
`reboot-bootloader`. Es preferible a matar el guard, que obligaria a probar el desarme
y el regreso voluntario en arranques distintos, con `slot-retry-count:a` como recurso
limitado.

### El inventario de consola se corrigio semanticamente

ST22 y ST23 clasificaban por el PATH textual de `readlink(fd/0)`. `/dev/console` y
`/dev/ttyGS0` son dos nombres del mismo dispositivo, asi que PID 1 contaba como lector y
el resultado quedaba infravalorado en 1. Documentarlo como "infravalora en 1" era
describir el sintoma en vez de arreglarlo.

ST24 compara `major`/`minor` del descriptor (`st_rdev`) y separa dos conceptos:

| campo | significado | PID 1 |
|---|---|---|
| `CONSOLE_FD_OWNERS` | procesos con algun fd sobre el rdev de la consola | entra, tiene descriptor |
| `INTERACTIVE_READERS` | los que ADEMAS leen de la entrada | excluido explicitamente |
| `STAGE2_SHELL_READERS` | de esos, los que son el shell de stage 2 | — |

Tener stdin abierto no es estar leyendo en un bucle. El gate exige
`INTERACTIVE_READERS == 1` y `STAGE2_SHELL_READERS == 1`, con el PID del shell pasado
explicitamente (`g_stage2_pid`), no deducido por el nombre del proceso.

### El guard sondea cada 10 s en WORK_SESSION

El gate de consola solo mira el instante de la transicion. Una regresion en la que
apareciera otro getty o shell DESPUES pasaria el gate inicial. Cada 10 s el guard
comprueba lectores, existencia del shell de stage 2 y que /proc siga legible; si el
recuento cambia, registra `GUARD_FAILURE=tty_reader_count_changed` con esperado y
observado, y vuelve a fastboot.

### DIAGNOSTIC con gates fallidos sigue esperando

Si un gate falla: `GUARD_TRANSITION_DENIED` + `GUARD_FAILURE=<gate>`, el estado sigue
siendo DIAGNOSTIC y se respeta el plazo de 240 s. NO se vuelve a fastboot de inmediato:
hay que dar tiempo a que la caja negra se lea desde Android B.

## Un bug propio que el script de build cazó

La primera versión tenía:

```c
int transitioned = 0;
while (!transitioned) { ... }
if (guard_verify_gates(gates) != 0) { ... } else { /* transicion */ }
```

`transitioned` nunca se asignaba, luego `while(!transitioned)` era `while(1)` y todo el
bloque de transición era inalcanzable. El compilador lo eliminó como código muerto y las
cadenas `GUARD_TRANSITION_DIAGNOSTIC_TO_WORK_SESSION`, `GUARD_STATE=WORK_SESSION` y
`WORK_SESSION_TIMEOUT` desaparecieron del binario.

Lo caza `smoke/build-st24.sh`, que hace `strings` sobre el binario y ABORTA si falta la
transicion. Es la misma disciplina que docs/10-doble-artefacto.md: **verificar que el artefacto
contiene lo que el fuente dice**, y mas fuerte todavia cuando el compilador puede
optimizar en nuestra contra.

Consecuencia practica: ademas de mirar el fuente, hay que mirar el binario.

## Fuera de alcance en ST24

`pmos.noroot` (rescate condicional), OpenRC, pmOS real, Wi-Fi, Bluetooth, simpledrm,
watchdog como servicio, cambios de particion, cambios de distribucion.

## Nota de trazabilidad

ST24 se deriva de la **segunda** compilacion de ST23 (`b0967ac9`, la que lleva
`diag_append`), NO de la que se ejecuto en el movil. No reutiliza su identificacion:
aunque el codigo corregido sea el mismo, el build id cambia a
`ST24-rootfs-v5-<commit>` porque el comportamiento cambia (guard de tres estados).

`mke2fs -d` graba timestamps, asi que dos construcciones del mismo fuente dan hashes
distintos. El hash integral identifica el artefacto desde fuera
(`work/ruby-rootfs-v5.ext4.sha256`, `build-manifest-st24.json`, `SHA256SUMS.st24`,
`evidence/installations/`); el build id identifica el contenido desde dentro
(`identity.txt`).