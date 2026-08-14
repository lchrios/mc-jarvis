# BaseOS

Sistema modular de administración, monitorización y automatización para una base
de Minecraft, escrito en Lua para **ComputerCraft: Tweaked** (All The Mods 10).

No es un script: es una plataforma con núcleo pequeño, módulos enchufables,
adaptadores por mod y una UI táctil pensada para monitores de CC.

```
+----------------------------------------------------------------------------+
| BASE CONTROL                                                          18:34 |
+----------------------------------------------------------------------------+
| +----------------+ +----------------+ +----------------+                   |
| |    STORAGE     | |  CENTRAL HUB   | |     POWER      |                   |
| |    NETWORK     | |     ONLINE     | |       OK       |                   |
| |  12.4k items   | |     ID 7       | |    842k FE     |                   |
| |      73%       | |    2h 14m      | |      82%       |                   |
| +----------------+ +----------------+ +----------------+                   |
| +----------------+ +----------------+ +----------------+                   |
| |   DEMO FARM    | |  ALL MODULES   | |     ALERTS     |                   |
| |    RUNNING     | |                | |                |                   |
| |   124 it/min   | |                | |                |                   |
| +----------------+ +----------------+ +----------------+                   |
+----------------------------------------------------------------------------+
| Status: ONLINE  Power: 82%  Alerts: 0  Modules: 4                          |
+----------------------------------------------------------------------------+
```

## Instalación en Minecraft

Necesitas un **Advanced Computer** y un **Advanced Monitor** (los normales no
generan eventos táctiles). Tamaño de monitor **mínimo recomendado: 3x2 bloques**
(~57x24 caracteres a escala 0.5). Un 2x2 o menor se rechaza con un aviso en
pantalla en lugar de dibujar algo ilegible. Con el ordenador abierto:

```
wget https://raw.githubusercontent.com/lchrios/mc-jarvis/main/installer.lua installer
installer
reboot
```

## Mantenerlo actualizado

`installer` solo trae el updater y hace la primera instalación. A partir de ahí
la herramienta es **`updater`**:

```
updater
```

Compara el repositorio con lo que tienes instalado y, si hay algo nuevo, enseña
qué ficheros cambian y **pregunta antes de tocar nada**. Descarga solo lo que
cambió, no el proyecto entero.

| Comando | Qué hace |
| --- | --- |
| `updater` | Comprueba y pregunta antes de aplicar |
| `updater check` | Solo informa, no cambia nada |
| `updater -y` | Aplica sin preguntar |
| `updater force` | Re-descarga todo, aunque no haya cambiado |
| `updater dev` | Trabaja contra otra rama o etiqueta |
| `version` | Qué tienes instalado, sin tocar la red |
| `scan` | Qué periféricos ve el ordenador y qué puede leer de ellos |
| `probe` | Llama a los métodos de Advanced Peripherals y enseña qué responde |

Tu `config/` y tu `data/` **no** se sobrescriben nunca. La versión instalada, la
rama y el commit se ven en el tile **CENTRAL HUB**.

Alternativa sin HTTP: copiar el repositorio a
`saves/<mundo>/computercraft/computer/<id>/` con `startup.lua` en la raíz.

No hace falta configurar nada para el primer arranque: con `config/` vacío
BaseOS arranca igual usando los valores por defecto, y sin monitor cae a la
terminal del ordenador.

## Varios ordenadores: master y nodos

Cada ordenador tiene un **rol**, que se elige una vez y se guarda en
`data/node.dat`. El updater nunca lo toca, así que no se vuelve a preguntar.

```
setup
```

```
  1) Master         Touch UI, aggregates every node
  2) Power node     Reads energy storage, reports to the master
  3) Storage node   Reads item storage, reports to the master
  4) Farm node      Runs farm instances from config/modules.lua
  5) Custom node    Modules come from config/modules.lua
```

El instalador lo lanza solo en un ordenador nuevo. En todos corre el mismo
`startup.lua`: el rol decide qué arranca.

| Rol | Qué hace |
| --- | --- |
| **Master** | UI táctil, agrega todo, manda acciones a los nodos |
| **Nodo** | Sin pantalla. Lee *sus* periféricos y publica su estado cada 3 s |
| **Display** | Un monitor en cualquier punto de la base, fijo en una vista |

**Los datos viven en el nodo.** El master nunca lee un periférico remoto:
escucha, guarda la última instantánea de cada nodo y la expone como un módulo
más — en el dashboard un módulo remoto se ve y se pulsa igual que uno local, y
sus botones se reenvían al nodo que los ejecuta. Si un nodo deja de reportar
15 s, sus módulos pasan a `OFFLINE`, se desactivan sus acciones y salta una
alerta, en vez de mostrar números viejos como si fueran de ahora.

Los nodos necesitan un **modem** (inalámbrico, o cableado con cable hasta el
master). La red se enciende sola en cuanto eliges rol con `setup`.

### Pantallas repartidas por la base

Un **display** es un ordenador con monitor y nada más: no controla, solo enseña.
`setup` te pregunta a qué vista lo fijas:

| Vista | Qué muestra |
| --- | --- |
| `BASE` | Todo lo que reporte |
| `POWER` | Solo energía |
| `STORAGE` | Solo almacenamiento |
| `FARMS` | Cualquier cosa tipo granja |
| `ALERTS` / `NODES` | La lista de alertas o la salud de los nodos |

Con un módulo lo enseña en grande con sus métricas y su gráfica; con varios, en
mosaico. Si lo tocas puedes navegar, y vuelve solo a su vista al cabo de un
minuto. Así pones una pantalla de energía en la sala del reactor y otra de
granjas en el granero, sin duplicar lógica.

### Histórico y tendencias

Cada métrica numérica se muestrea en una ventana rodante. Al tocar cualquier
métrica se abre su historia: valor actual, si sube o baja, mínimo, media, máximo
y una gráfica. El histórico se guarda con la instantánea, así que sobrevive a un
reinicio.

Además cada ordenador guarda una instantánea en disco cada 60 s, así que tras
un reinicio ve sus últimos valores conocidos de inmediato.

## Si juegas en un servidor con gente

Rednet es un medio público. Cualquiera puede poner un ordenador con modem,
escuchar el protocolo `baseos` y mandar lo que quiera — y por ahí viajan las
acciones remotas. **Pon un secreto en [config/network.lua](config/network.lua),
el mismo en todos los equipos de la base:**

```lua
secret = "lo que se te ocurra, cuanto mas largo mejor",
```

A partir de ahí cada mensaje va firmado y el que no cuadre se tira, con lo que
un desconocido no puede mandar órdenes a tus nodos. Se avisa en el log en cada
arranque mientras no lo pongas.

Lo que **no** hace: cifrar. Quien escuche sigue viendo el contenido de los
mensajes. Por eso el envío de copias de seguridad por red viene apagado.

En un mundo en solitario puedes dejarlo vacío y todo funciona igual que antes.

## Perfiles de seguridad

No todo el mundo debería poder parar una granja. `config/security.lua` protege
acciones por patrón (`"*.stop"`, `"power.*"`) y las asigna a perfiles.

**Lo que se puede saber, y lo que no:** el evento `monitor_touch` de
ComputerCraft trae solo `(lado, x, y)`. **No hay forma de saber quién tocó la
pantalla.** Por eso hay dos modos:

| Modo | Cómo identifica | Fuerza |
| --- | --- | --- |
| `session` | Clic derecho en el Player Detector: AP emite `playerClick` con tu nombre y abre una sesión corta | Identidad real |
| `proximity` | Basta con que un jugador autorizado esté en el radio | Débil: quien esté a su lado también acciona |

Con `session`, pon el detector **junto al monitor** y funciona como una tarjeta
de acceso: lo tocas y el panel se desbloquea unos segundos.

Los **roles** llevan los permisos y los **usuarios** asignan jugador a rol:

```lua
protect = { "*.stop", "*.start" },
roles = {
    admin    = { label = "Admin",    allow = { "*" }, manage = true },
    operator = { label = "Operator", allow = { "*.start", "*.stop" } },
    viewer   = { label = "Viewer",   allow = {} },
},
users = { { player = "lchrios", role = "admin" } },
```

### Dar de alta gente desde el panel

Con seguridad activada aparece el botón **ACCESS** en el dashboard. Un rol con
`manage` puede registrar a otros de dos formas:

* **LISTEN** — el admin lo pulsa y la máquina queda a la escucha: el
  **siguiente** jugador que toque el detector queda capturado y la pantalla
  pregunta *"¿registro a fulano como operator?"* antes de nada. Los clics del
  propio admin se ignoran mientras escucha, para que no se registre a sí mismo.
* **TYPE** — teclado en pantalla, para alguien que no está delante. Un monitor
  no tiene teclado: `read()` solo existe en la terminal del ordenador.

Lo registrado desde el panel va a `data/security.dat`. Lo declarado en
`config/security.lua` es la semilla y **no se puede borrar desde la pantalla**:
esa es tu llave maestra.

Desactivado por defecto, y sin `protect` todo está permitido: una actualización
nunca debe dejarte fuera de tu propia base.

## Automatizaciones

Una regla **no es un temporizador**. Es una máquina de dos estados: entra cuando
se cumple `when`, y sale cuando se cumple `until_` **o** pasa `after`, lo que
ocurra primero.

```lua
{
    id     = "backpressure",
    when   = { metric = "mob_farm.buffer", op = ">=", value = 0.9 },
    do_    = "mob_farm.stop",
    until_ = { metric = "mob_farm.buffer", op = "<=", value = 0.3 },
    after  = "60s",
    then_  = "mob_farm.start",
}
```

Decir "párate 30 segundos" desperdicia producción si el buffer se vació a los
15, y reenciende contra un buffer lleno si no se vació. Con las dos salidas, se
arranca en cuanto de verdad se vació, y el tiempo es solo la red de seguridad.

Las condiciones miran métricas, estado, **tendencia** del histórico, hora del
mundo, jugadores conectados, alertas activas y nodos caídos; se combinan con
`all` / `any` / `none`.

**Si tocas el botón a mano, tú ganas.** La regla suelta el control y no vuelve a
intervenir hasta que su condición de entrada deje de cumplirse y vuelva a
cumplirse. Así no te pelea por el interruptor.

### El set base

BaseOS trae siete reglas hechas — granja atascada, energía crítica, base vacía,
celdas AE2 llenas, nodo caído, turno de noche y red de almacenamiento caída —
**todas apagadas**. Están ahí como punto de partida, no como comportamiento que
te aparece sin pedirlo. Una regla que apunte a un módulo que no tienes no hace
nada y lo avisa una vez en el log, no en cada ciclo.

> El updater **nunca pisa `config/`**, así que en una instalación que ya existía
> sigue estando tu `config/rules.lua` de antes. Para traerte el set base:
> `delete config/rules.lua` y luego `updater force`.

### Editarlas desde el panel

Botón **RULES** en el dashboard. La lista dice qué hace cada una ahora mismo:

| Estado | Significa |
| --- | --- |
| `off` | Apagada |
| `waiting` | Encendida, esperando su condición |
| `ACTING 12s` | Actuando, y le quedan 12s de `after` |
| `yielded` | Alguien tocó el botón a mano; espera a re-armarse |
| `ERROR` | La regla falló; el motivo está en el log |

`TURN ON`/`TURN OFF` la enciende o apaga, `EDIT` la abre, `NEW` crea una y
`RESET` tira todo lo editado y vuelve al fichero de config.

El editor enseña los cinco campos como frases, no como Lua:

```
WHEN     demo_farm.buffer >= 0.9
DO       demo_farm.stop
UNTIL    demo_farm.buffer <= 0.3
AFTER    60s
THEN     demo_farm.start
```

Tocas un campo y te va preguntando: módulo → métrica → comparación → valor. Solo
salen los módulos cargados y las métricas que existen, así que no hay forma de
escribir un nombre mal. El valor se teclea en el mismo teclado en pantalla de la
pantalla de accesos. `AFTER` es una lista de duraciones, y se puede dejar sin
poner: entonces la regla solo sale por su condición.

Nada se guarda hasta `SAVE`, y al salir con cambios sin guardar te pregunta.

Lo editado va a `data/rules.dat` y manda sobre `config/rules.lua`, que **no se
toca nunca** — igual que el plano del editor. `RESET` borra el override y el
fichero vuelve a mandar. El motor recoge los cambios al momento: no hace falta
reiniciar el ordenador para que una regla recién encendida empiece a actuar.

## Avisos por chat

El Chat Box es la única parte de BaseOS que te encuentra a ti en vez de esperar
a que mires el monitor. Por eso lo que dice tiene que ser lo que tú quieres oír:
el módulo `notifier` sabe **cómo** llegarte (Chat Box, altavoz, límite de
ritmo), y el catálogo decide **qué** merece la pena decir.

Pantalla `ALERTS` → botón **NOTIFY**. Una fila por tema, y a la derecha lo que
lleva hecho:

```
 Alerts                                                          4 said
 Player arrives                                                  2 said
 Node goes silent                                                    on
 Module fails                                                        on
 Farm starts or stops                                               off
 Access denied                                                   1/3 said
```

`1/3 said` significa que pasó tres veces y solo una llegó al chat: el resto lo
frenó el límite de ritmo. `ANNOUNCE` / `MUTE` enciende o apaga el seleccionado,
`TEST` manda una línea de prueba por el camino real, y `RESET` vuelve al fichero.

Los 17 temas, y cómo vienen de fábrica:

| Encendidos | Apagados |
| --- | --- |
| Alertas (avisos y críticos) | Un jugador se va de una zona |
| **Un jugador entra en una zona** | Se pierde un peer de rednet |
| **Un nodo deja de reportar** | Un módulo se recupera |
| Un módulo se cae | Aparece o desaparece un periférico |
| Lo que una regla quiere decir (`say`) | Una regla entra, sale o cede |
| Alguien intentó algo sin permiso | Una granja arranca o para |
| Alguien recibió acceso al panel | Alguien se identifica en el detector |

Cada tema escucha un evento **real** de BaseOS; no hay ninguno inventado. Los
apagados no es que sean inútiles: es que hablan mucho, y una base que narra cada
periférico que redescubre es una base que nadie lee.

Lo que enciendas en la pantalla se guarda en `data/notifications.dat` y manda
sobre [config/notifications.lua](config/notifications.lua), que no se toca
nunca. El cambio es inmediato, sin reiniciar.

> Un detalle que esto arregla de paso: la acción `say` de una regla, que estaba
> documentada desde el principio, **no tenía a nadie escuchando**. Ahora sale por
> el chat como el tema `rule_message`.

## Copias de seguridad

`updater` devuelve los programas; lo que no se puede volver a descargar es lo
que hace que un ordenador sea *ese* ordenador: su `config/`, su rol, el plano
del editor y los usuarios registrados. Eso es lo que guarda `backup`.

| Comando | Qué hace |
| --- | --- |
| `backup` | Guarda en un disquete (Disk Drive + Floppy) |
| `backup local` | Copia en el propio ordenador |
| `backup show` | Qué contiene el disquete, sin restaurar |
| `backup restore` | Restaura desde el disquete |
| `backup pull` | Pide su configuración al master por rednet |
| `backup list` | En un master: de qué nodos guarda copia |

Los logs y las instantáneas quedan fuera a propósito: se regeneran solos.

**Los nodos pueden mandar su copia al master** cada 5 minutos. Si un nodo se
destruye: pones un ordenador nuevo, `installer`, `setup` con **el mismo
nombre**, `backup pull` y `reboot`. El master le devuelve su config y el nombre
que acabas de darle no se pisa.

Viene **apagado** (`backup.share` en [config/network.lua](config/network.lua)):
ese archivo lleva `data/security.dat` — tu lista de usuarios — y rednet no
cifra. Enciéndelo si te fías de quien pueda estar escuchando. Cuando está
encendido va **dirigido al master**, no en broadcast.

Para el master en cambio hace falta un disquete — nadie guarda su copia.

## Rescatar un equipo

| Comando | Qué hace |
| --- | --- |
| `setup` | Cambiar el rol; pregunta si borrar la config del rol anterior |
| `setup show` | Ver el rol actual |
| `reset` | Borra `config/` y `data/` (rol incluido). Pide escribir `RESET` |
| `reset --keep-setup` | Igual, pero conserva el rol |
| `reset --data` | Solo datos de runtime (logs, caché) |

`reset` nunca toca los ficheros del programa: después, `updater force` restaura
la config por defecto.

## Qué hay ya funcionando

* Arranque completo con cargador de módulos propio, logger, configuración,
  event bus, scheduler, store de estado y persistencia.
* Peripheral Manager con alias lógicos, detección de conexión/desconexión y
  llamadas protegidas.
* UI para monitor táctil: dashboard con el plano de la base, tiles clicables,
  pantalla de detalle genérica, lista de módulos, alertas, periféricos y logs.
  Se adapta a cualquier tamaño de monitor y a monitores monocromos.
* Módulos: `system`, `power`, `storage` y `demo_farm` (granja simulada para
  probar la UI sin depender de máquinas reales).
* Plantilla `farm`: granjas reales declaradas solo con configuración — lee el
  cofre de salida, mide items/min, avisa cuando el buffer se llena y arranca o
  para la granja por redstone o Redstone Integrator.
* Adaptadores genéricos (inventarios, energía, fluidos) y esqueletos para AE2,
  Powah y Advanced Peripherals. Los de AP y los bridges están verificados contra
  los `@LuaFunction` del jar de AdvancedPeripherals 0.7.62b.
* Servicio de alertas con severidades y capa de red rednet lista pero apagada.
* Módulo `presence`: puertas y mecanismos que se encienden al acercarse un
  jugador, con radio, filtro por jugador, retardo de cierre y control manual.
* Módulo `notifier` + catálogo de avisos: 17 cosas que pasan en la base, cada
  una se enciende o se apaga desde la pantalla, con límite de ritmo para que
  nada inunde el chat.
* Motor de reglas con salida por condición **o** por tiempo, set base de siete
  reglas apagadas y editor en pantalla para encenderlas y ajustarlas sin tocar
  ficheros.

## Configuración

Todo vive en `config/`, sin lógica:

| Fichero | Para qué |
| --- | --- |
| `system.lua` | Nombre, logging, intervalos, opciones de UI |
| `peripherals.lua` | Alias lógicos de periféricos |
| `layout.lua` | Plano de la base: zonas del dashboard |
| `modules.lua` | Módulos activos y sus ajustes |
| `network.lua` | Rednet (desactivado por defecto) |
| `theme.lua` | Colores y caracteres de dibujo |

Mover una sala del plano, renombrar una zona o añadir una habitación es editar
`config/layout.lua`. Nada más.

### El dashboard

La pantalla principal no es una rejilla de cajas iguales: es un panel de mando
con cifras arriba, sistemas en vivo, lo que acaba de pasar, y acciones abajo.

```
 ALERTS              MODULES
 0                   4

 SYSTEMS                            ACTIVITY
 * System      ONLINE   ID 7           12s Mob Farm -> BACKED UP
 * Power       OK       [####--] 82%   1m  node farm_node went silent
 * Storage     NETWORK  12.4k items
 * Mob Farm    BACKED UP[#####-] 91%

     MAP        NODES      ALERTS     DEVICES      LOGS
```

Las cifras de arriba son navegables (tocar **ALERTS** abre las alertas), cada
sistema abre su detalle, y la barra inferior lleva a las pantallas que se usan a
diario. En monitores estrechos el feed de actividad se retira antes que nada
esencial.

### Dispositivos, y cómo se encuentran solos

Botón `DEVICES`: un árbol con todo lo que ve este equipo. Cada fila se despliega
y dice qué tipos reporta, cuántos métodos tiene, qué alias lo reclamó y qué sabe
leer BaseOS de él — o, si no sabe leer nada, te lo dice para que corras
`scan <nombre>`.

Un **modem** también sale aquí, y dice lo que hace falta saber: si es wireless o
de cable, si rednet está abierto **en él** (no solo que exista), y cuántos
periféricos alcanza su cable. Para saber si hay alguien más en la red, la
primera línea de `NODES`.

**No hay que reiniciar para que aparezca un bloque nuevo.** Conectar o
desconectar llega como evento y se atiende al instante; lo demás lo recoge el
repaso periódico:

| Pasa esto | Se detecta así |
| --- | --- |
| Activas el modem de un bloque | En el siguiente repaso, segundos |
| Se descarga el chunk de una máquina | Se comprueba presencia, no solo el listado |
| Rompes una celda y pones otra mayor | Se releen tipos y métodos: mismo nombre, otro bloque |
| Una máquina deja de responder | La primera llamada que falla la da de baja |
| Acabas de poner algo y no esperas | Botón `RESCAN NOW` |

**La cadencia se adapta al equipo.** Mientras falte algo que este ordenador
espera, mira cada pocos segundos y la cabecera lo dice (`MISSING mainCell`);
cuando está todo, espacia el repaso. Y cada nodo vigila lo suyo: en
[config/peripherals.lua](config/peripherals.lua), `byRole` afina el intervalo
por perfil — un nodo de energía vive de sus periféricos, una pantalla no tiene
nada que descubrir.

```lua
rescan = { interval = 30, degradedInterval = 5, deepEvery = 4, minGap = 1 },
byRole = {
    power   = { rescan = { interval = 15, degradedInterval = 3 } },
    display = { rescan = { interval = 120, degradedInterval = 15 } },
},
```

### El mapa de la base

El plano vive en su **propia pantalla** (botón `MAP`, o como vista fija de un
display): salas que colocas tú y tuberías que se trazan solas. **No es el
dashboard otra vez** — un plano se lee por la forma, así que las salas tienen
tamaños distintos y dentro llevan poca cosa: el nombre y una palabra de estado.
El detalle está a un toque.

```
 +---------------+                                           +---------------+
 |               |                                           |               |
 |    REACTOR    |         +----------------------+          |               |
 |   NO DEVICE   |====+    |                      |          |               |
 |               |    |    |       CONTROL        |          |               |
 |               |    ====>|        ONLINE        |====+     |    ALMACEN    |
 +---------------+         |                      |=========>|   NO DEVICE   |
         ^                 |                      |    |     |               |
         |                 +----------------------+    |     |               |
 +---------------+                        |            |     |               |
 |   BATERIAS    |                        |            |     |               |
 +---------------+                        |            |     +---------------+
                                          |            |
 +---------------------+          +---------------+    |     +---------------+
 |      MOB FARM       |==========|   CULTIVOS    |====+     |    TALLER     |
 +---------------------+          +---------------+          +---------------+
```

Eso es lo que trae [config/layout.lua](config/layout.lua) de fábrica. **No es tu
base**: es un punto de partida con salas de distintos tamaños para que lo edites
desde `MAP` → `EDIT`. Una sala cuyo módulo no exista en ese ordenador sale en
gris; bórrala o cámbiale el id.

> Un monitor más alto **no infla las salas**. El plano tiene un tamaño en el que
> se lee bien (`cell` en el config) y a partir de ahí se centra en vez de
> estirarse — antes, cuanto más grande el monitor, más grandes las cajas y más
> perdido el nombre en medio.

Declaras la conexión, no el recorrido:

```lua
{ id = "power", label = "POWER", module = "power",
  col = 1, row = 1, colSpan = 4, rowSpan = 3,
  links = { { to = "hub", kind = "energy" } } },
```

Mueves la zona y la tubería la sigue. El color dice qué pasa: **verde** fluyendo,
**gris** parado, **rojo** algún extremo caído. Así un nodo que se cae se ve en el
plano, no solo en su tile.

### Editor del plano

No hace falta editar ficheros: en el mapa, botón **EDIT**.

```
+-- EDIT LAYOUT ---------------------------------------------+
| MODULES      + STORAGE ----+  + CENTRAL HUB -+  + POWER --+ |
| * System     |             |  |              |  |         | |
| * Power      |             |  |=1            |  |=1       | |
| * Storage    +-------------+  +--------------+  +---------+ |
|   Demo Farm                                                 |
+-------------------------------------------------------------+
| Selected: hub                                               |
|   MOVE     <     v     ^     >                              |
|         ADD        DEL       SAVE       EXIT                |
+-------------------------------------------------------------+
```

A la izquierda, todos los módulos detectados; `*` marca los que ya están en el
plano. Un modo con cuatro flechas en vez de veinte botones, para que los targets
sigan siendo grandes en un 3x2:

| Modo | Las flechas hacen |
| --- | --- |
| `MOVE` | Desplazan la zona por la rejilla |
| `SIZE` | La agrandan o encogen |
| `LINK` | Tocas dos zonas y crea (o quita) la tubería entre ellas |

`ADD` mete en el plano un módulo detectado que aún no esté; `DEL` lo saca y
limpia las tuberías que apuntaban a él. Nada se escribe hasta pulsar `SAVE`.

Lo que guardas va a **`data/layout.dat`**, no a `config/layout.lua`: tu fichero y
tus comentarios quedan intactos, y el override manda mientras exista. `reset` lo
borra y vuelves al de config.

## Documentación

* [docs/HARDWARE.md](docs/HARDWARE.md) — qué bloques montar y cómo cablearlos,
  por etapas, con la configuración de cada una.
* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — estructura, flujo de eventos,
  UI, adapters, peripheral manager, red.
* [docs/MODULE_DEVELOPMENT.md](docs/MODULE_DEVELOPMENT.md) — cómo añadir un
  módulo nuevo sin tocar el núcleo.
* [tools/simulator/README.md](tools/simulator/README.md) — ejecutar BaseOS fuera
  de Minecraft para probar cambios.

## Desarrollo

```bash
cd tools/simulator
npm install
node run.js                            # recorre el dashboard y vuelca capturas
node run.js scenarios/resilience.lua   # sin monitor + alerta forzada
```

El simulador ejecuta los ficheros reales del proyecto sobre un Lua 5.4 con la
API de CC:Tweaked mockeada. Falla si el log contiene algún `[ERROR]`.

## Estado

Primera fase completa y ejecutable, con histórico de métricas, nodos rednet,
perfiles de seguridad, copias de seguridad y automatizaciones editables desde el
panel.

Lo que sigue sin verificarse **dentro del juego** son las integraciones reales
con ME Bridge, Powah y Chat Box, y el rednet entre dos ordenadores (etapas 4 y 5
de `docs/HARDWARE.md`). Los adaptadores están escritos contra los métodos reales
de los jars, pero eso no es lo mismo que haberlo visto funcionar.
