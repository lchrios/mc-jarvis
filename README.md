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
* Módulo `notifier`: manda las alertas al Chat Box y al altavoz, con límite de
  ritmo para que una alerta que oscila no inunde el chat.

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

### El mapa de la base

El plano vive en su **propia pantalla** (botón `MAP`, o como vista fija de un
display): cajas que colocas tú y tuberías que se trazan solas.

```
+---------------+   +----------------+   +---------------+
|    POWER      |   |  CENTRAL HUB   |   |    STORAGE    |
|   NO DEVICE   |==>|     ONLINE     |<==|     LOCAL     |
+---------------+   +----------------+   +---------------+
                             ^
                             |
                    +----------------+
                    |   DEMO FARM    |
                    |    STOPPED     |
                    +----------------+
```

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

Primera fase completa y ejecutable. Pendiente (fase dos): integraciones reales
con ME Bridge, Powah, Player/Environment Detector y Chat Box, nodos rednet
distribuidos, histórico de métricas y automatizaciones por umbral y horario.
