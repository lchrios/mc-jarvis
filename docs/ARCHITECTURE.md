# Arquitectura de BaseOS

> Documentación en español; el código y sus comentarios están en inglés
> (convención habitual en Lua/CC:Tweaked).

BaseOS es una plataforma modular para administrar, monitorizar y automatizar una
base de Minecraft desde ComputerCraft: Tweaked. No es un programa único: es un
núcleo pequeño de servicios sobre el que se enchufan módulos.

---

## 1. Estructura de directorios

```
startup.lua              Arranque: carga boot.lua y entrega el control a core.app
boot.lua                 Cargador de módulos compartido por todos los programas
setup.lua                Elige el rol de este ordenador (master / nodo)
reset.lua                Reset de fábrica: borra config y datos locales
installer.lua            Trae updater.lua a un ordenador vacío y lo ejecuta
updater.lua              Comprueba GitHub, avisa y actualiza solo lo que cambió
version.lua              Imprime la versión instalada (sin red)
scan.lua                 Diagnóstico de periféricos (sin red, sin BaseOS)
probe.lua                Ejercita Advanced Peripherals y dice qué responde
baseos.version           Versión instalada (la leen startup.lua y el updater)
config/                  Configuración (sin código de lógica)
  system.lua             Nombre, logging, UI, intervalos
  peripherals.lua        Alias lógicos de periféricos
  layout.lua             Mapa/plano de la base (zonas del dashboard)
  modules.lua            Módulos activos y sus ajustes
  network.lua            Rednet (desactivado por defecto)
  theme.lua              Colores y caracteres de dibujo
src/
  core/
    app.lua              Ciclo de vida, bucle de eventos, apagado
    config.lua           Carga y fusión de configuración
    logger.lua           Logging con niveles (terminal + fichero)
    event_bus.lua        Publicación/suscripción interna
    scheduler.lua        Tareas periódicas (un único timer real)
    state.lua            Store central observable
    util.lua             Helpers puros (formato, tablas, tiempo)
    class.lua            Herencia mínima para componentes de UI
    identity.lua         Rol de este ordenador (data/node.dat)
  peripherals/
    manager.lua          Único dueño de la API `peripheral`
  adapters/
    registry.lua         Selección de adaptador por periférico
    base.lua             Helpers: probar métodos, llamadas protegidas
    inventory.lua        Inventarios genéricos
    energy.lua           Almacenamiento de energía genérico
    fluid.lua            Tanques genéricos
    speaker.lua          Altavoz (CC vanilla, verificado)
    ae2.lua              ME Bridge / RS Bridge (verificado contra AP 0.7.62b)
    powah.lua            Powah (extras sobre energy, sin verificar)
    advanced_peripherals.lua  Player Detector, Chat Box... (verificado)
  modules/
    registry.lua         Registro, ciclo de vida y snapshots de módulos
    system.lua           Info del ordenador (módulo de referencia)
    power.lua            Energía agregada
    storage.lua          Almacenamiento (red o inventarios)
    demo_farm.lua        Granja simulada para validar la UI
    presence.lua         Detección de jugadores y activación por proximidad
    notifier.lua         Alertas al chat y al altavoz
    farm.lua             Plantilla de granja real (instancias por config)
    remote.lua           Proxy de un módulo que corre en otro ordenador
  ui/
    renderer.lua         Primitivas de dibujo sobre monitor o terminal
    navigation.lua       Registro de pantallas, pila y cromo (header/footer)
    screen.lua           Clase base de pantalla
    component.lua        Clase base de componente
    theme.lua            Paleta semántica
    base_layout.lua      Zonas de configuración -> rectángulos
    base_links.lua       Trazado de las conexiones entre zonas
    components/          label, button, panel, progress_bar, list, modal,
                         pager, zone_tile
    screens/             dashboard, base_map, layout_editor, module_detail,
                         metric_detail,
                         module_list, alerts, peripherals, logs, nodes,
                         power_detail, display_view
  network/
    protocol.lua         Formato de mensaje (sobre + tipos)
    network.lua          Transporte rednet
    telemetry.lua        Push de métricas nodo -> master y acciones al revés
  services/
    activity.lua         Eventos recientes para el feed del dashboard
    layout_store.lua     Plano vigente: override de data/ o config/layout.lua
    alerts.lua           Alertas activas con severidad
    persistence.lua      Guardado/carga en `data/`
    snapshot.lua         Volcado periódico del estado a disco
data/                    Runtime: log, estado persistido (ignorado por git)
docs/                    Esta documentación
tools/simulator/         Ejecuta BaseOS fuera de Minecraft (desarrollo)
```

---

## 2. Cargador de módulos

CC:Tweaked expone `require` de forma distinta según versión y según cómo se
lance el programa. Por eso `startup.lua` implementa su propio cargador:

* `require("core.app")` busca, en orden:
  `src/core/app.lua`, `src/core/app/init.lua`, `core/app.lua`, `core/app/init.lua`
* Cada módulo recibe un entorno propio con `require`, `BASEOS` y herencia de
  `_G`, así que escribir una global por accidente no contamina el sistema.
* Los módulos se cachean; una dependencia circular lanza un error explícito.

`_G.BASEOS.loaded` queda accesible desde el shell para depurar en caliente.

---

## 3. Orden de arranque

`core.app.boot()` es deliberadamente secuencial:

1. **Config** — se leen `config/*.lua` y se fusionan sobre los valores por defecto.
2. **Logger** — nivel y destinos. Si la UI acaba usando la terminal del
   ordenador, el log deja de escribir ahí automáticamente.
3. **Persistencia + estado** — se crea `data/` y se inicializa el árbol de estado.
4. **Peripheral Manager** — escaneo y resolución de alias.
5. **Adapters** — se cargan y se les inyecta el manager.
6. **Display** — alias `mainMonitor` → cualquier monitor → terminal.
7. **UI** — tema, renderer, navegación y registro de pantallas.
8. **Módulos** — carga, `setup`, `start` y programación de sus `poll`.
9. **Red** — no-op salvo que `network.enabled = true`.
10. **Timers** — refresco de UI y arranque del scheduler.
11. **Primer frame**.

Si cualquier paso falla, `app.run` ejecuta `shutdown()` y propaga el error a
`startup.lua`, que restaura la terminal y lo imprime.

---

## 4. Flujo de eventos

```
        os.pullEventRaw()            (único punto en todo el proyecto)
                 |
         core.app.handleEvent
                 |
    +------------+--------------------------------+
    |            |                                |
 scheduler   event_bus.emit(nombre, ...)     enrutado de UI
 .onTimer         |                                |
              suscriptores                 navigation.handleTouch
              (módulos, manager,            navigation.onResize
               network, pantallas)
                 |
        navigation.dispatchEvent -> pantalla activa
                 |
        navigation.draw()  (solo si algo marcó "dirty")
```

Reglas:

* **Un único bucle.** Ningún módulo llama a `os.pullEvent` ni a `sleep`.
* **Un único timer real.** El scheduler mantiene un `os.startTimer` para la
  próxima tarea pendiente y lo rearma; los timers ajenos se ignoran.
* **Todo evento crudo de CC se republica en el bus con su propio nombre**
  (`monitor_touch`, `peripheral`, `rednet_message`, `chat`...), así que un
  módulo puede suscribirse sin tocar el bucle.
* Los eventos internos usan namespaces con punto:
  `power.low`, `module.status_changed`, `alert.raised`, `peripheral.attached`.
* Los comodines existen: `bus.on("alert.*", fn)`. Un handler comodín recibe el
  nombre del evento como primer argumento; uno exacto no.
* Los errores de un handler se registran y se descartan: nunca tumban el bus.

### Eventos publicados por el núcleo

| Evento | Payload |
| --- | --- |
| `peripheral.attached` / `peripheral.detached` | `{ name, types }` |
| `peripheral.alias_bound` / `peripheral.alias_lost` | `{ alias, name }` |
| `module.registered` / `module.unregistered` | `{ id, name }` |
| `module.status_changed` | `{ id, status, previous, text }` |
| `module.availability_changed` | `{ id, available, missing }` |
| `module.action` | `{ id, action }` |
| `alert.raised` / `alert.updated` / `alert.cleared` | la alerta completa |
| `state.changed` | `{ path, value, previous }` |
| `ui.navigated` | `{ name, params, depth }` |
| `network.message` y `network.message.<tipo>` | el mensaje |

---

## 5. Estado

Un único árbol observable en `core.state`:

```lua
state.set("modules.demo_farm.status", "running")
state.get("modules.demo_farm.status", "unknown")
state.watch("modules", function(path, value) ... end)
```

Contiene `system`, `modules`, `peripherals`, `network`, `alerts`, `ui`.
Es el sitio para datos compartidos entre subsistemas; los datos internos de un
módulo pueden vivir en el propio módulo. Las métricas efímeras **no** se
persisten.

---

## 6. Peripheral Manager

Es el único que llama a `peripheral.*`. Ofrece:

* Escaneo inicial, reacción a `peripheral` / `peripheral_detach` y reescaneo
  periódico (por si un modem cableado cambia sin avisar).
* **Alias lógicos** definidos en `config/peripherals.lua`. Un alias se resuelve
  por `type`, por `name` exacto, por presencia de un `method` o por una función
  `match`. Un periférico solo lo reclama un alias.
* **Búsqueda por capacidad**: `manager.findByMethod("list")` devuelve todo lo que
  se comporte como inventario, sin importar el mod.
* **Proxies seguros**: cualquier llamada va envuelta en `pcall`.

```lua
local monitor = manager.get("mainMonitor")     -- proxy o nil
local ok, err = monitor.call("setTextScale", 0.5)
local value    = monitor.getEnergy()           -- nil si falla o no existe
```

Arrancar un periférico de la pared no rompe nada: el alias queda sin ligar, se
emite `peripheral.alias_lost` y los módulos que lo requieren pasan a
`unavailable`.

---

## 7. Capa de adapters

Los módulos **no** conocen nombres de métodos de mods. Un adapter traduce la API
externa a estructuras internas.

```lua
local cells = ctx.adapters.allOfKind("energy")
for _, cell in ipairs(cells) do
    local reading = cell.read()   -- { stored, capacity, percentage, rate, unit }
end
```

Reglas de un adapter:

1. `matches(proxy)` decide si sabe manejar ese periférico.
2. `wrap(proxy)` devuelve una tabla de funciones con vocabulario de BaseOS.
3. Nunca se asume que un método existe: se prueba con `base.pick`, que acepta
   una lista de nombres candidatos (los mods los renombran entre versiones).
4. Devuelve `nil` en lugar de lanzar cuando algo no está disponible.

El registro prueba los adapters en orden, del más específico al más genérico:
`ae2 → powah → advanced_peripherals → inventory → energy → fluid`.

> Los adapters de AE2 y Powah están marcados como **no verificados en juego**.
> Antes de fiarse de sus lecturas hay que comprobar los nombres reales con
> `peripheral.getMethods(nombre)` y ajustar las listas de candidatos.

---

## 8. Módulos

Un módulo describe un sistema de la base. El registro le da ciclo de vida,
polling, estado, snapshots y acciones, y aísla sus fallos: todo callback corre
bajo `pcall`, y un módulo roto se marca `error` sin afectar al resto.

Ver **[MODULE_DEVELOPMENT.md](MODULE_DEVELOPMENT.md)** para el contrato completo.

Resumen del ciclo de vida:

```
require("modules.<id>")  ->  register  ->  setup(ctx)  ->  start()
                                             |
                                        poll() cada pollInterval
                                             |
                        status() / metrics() / tile() / actions()
                                             |
                                          stop()
```

Hay dos formas de declarar un módulo en `config/modules.lua`:

* `enabled = { "power", ... }` — un fichero, un módulo.
* `instances = { { id = "mob_farm", template = "farm", settings = {...} } }` —
  una **plantilla** (`src/modules/farm.lua`, que exporta `create(instance)`)
  instanciada tantas veces como haga falta. Es como se añaden granjas: solo
  configuración, sin código nuevo. Cada instancia registra sus propios alias de
  periférico (`mob_farm.output`), así que las granjas fallan de forma
  independiente.

---

## 9. UI

Separación estricta: **una granja no sabe cómo se dibuja un botón**. Los módulos
publican datos (`status`, `metrics`, `tile`, `actions`); las pantallas los pintan.

* **Renderer** — envuelve el monitor (o la terminal) en un `window` para
  componer el frame fuera de pantalla y volcarlo de golpe (sin parpadeo). Todas
  las primitivas recortan a los límites, así que un componente que se pase de su
  área no lanza excepciones. Helpers: `write`, `writeCentered`, `writeRight`,
  `fill`, `box`, `progress`, `badge`, `distribute`, `inset`.
* **Theme** — paleta semántica (`statusOk`, `headerBg`, `buttonDangerBg`...).
  Detecta monitores monocromos y cae a blanco y negro automáticamente.
* **Component** — rectángulo absoluto + `draw(renderer)` + `handleTouch(x, y)`.
  Componentes incluidos: `Label`, `Button`, `Panel`, `ProgressBar`, `List`,
  `Modal`, `ZoneTile`.
* **Screen** — página completa. Ciclo:
  `new → onMount → layout → update (cada frame) → draw → handleTouch → onUnmount`.
  `layout` reconstruye componentes (tras un resize o un cambio estructural);
  `update` solo refresca valores.
* **Navigation** — registro de pantallas por nombre, pila de navegación y cromo
  persistente: cabecera con `< BACK`, título y reloj; pie con estado, alertas y
  número de módulos. Las pantallas solo reciben el rectángulo intermedio, ya
  descontado el margen (`system.ui.paddingX/paddingY`).

Nada asume una resolución fija. El tamaño se lee del dispositivo y se recalcula
en `monitor_resize` / `term_resize`. Adaptaciones automáticas:

| Situación | Comportamiento |
| --- | --- |
| Ancho < 40 o alto útil < 14 | Se elimina el margen: cada fila cuenta más |
| Área pequeña (lado menor < 34) | Separación entre tiles de 1 carácter |
| Área grande | Separación de 2 (`layout.gap = "auto"`) |
| Tile más alto que su contenido | El contenido se centra verticalmente |
| Tile de menos de 4 filas | Se omite la línea de estado |
| Lista más larga que su alto | Aparece un paginador `^ UP / n-m / DOWN v` con botones de 3 filas |
| Métricas que no caben en el detalle | Se paginan con el mismo control; ninguna se pierde |
| Menor que `system.ui.minWidth/minHeight` (45x18) | Se muestra "MONITOR TOO SMALL" con el tamaño real y el necesario |

Tamaño recomendado: monitor de **3x2 bloques o mayor** (~57x24 caracteres).

### Conexiones del mapa

Una zona declara con qué conecta; **dónde va la línea lo calcula el sistema**,
así que mover una sala en `config/layout.lua` nunca obliga a redibujar tuberías.

```lua
{ id = "power", module = "power", col = 1, row = 1, colSpan = 4, rowSpan = 3,
  links = { { to = "hub", kind = "energy" } } }
```

* `ui/base_links.lua` enruta en ortogonal: sale por el borde de una caja, cruza
  por un punto medio y entra por el borde de la otra, con una punta de flecha en
  el destino. Es una función pura: entra la lista de rectángulos ya colocados,
  sale una lista de celdas.
* `ui/components/link_layer.lua` las pinta **antes** que los tiles, de modo que
  los extremos quedan tapados por los bordes de las cajas.
* Declarar el enlace desde los dos lados no lo duplica.
* El color sale del estado de los dos extremos, sin configuración extra:

| Estado | Cuándo | Color |
| --- | --- | --- |
| `active` | el módulo origen está funcionando | verde |
| `idle` | el origen está parado o en reposo | gris |
| `broken` | algún extremo no está disponible o dio error | rojo |
| `unknown` | todavía no hay datos | gris oscuro |

  Un enlace puede además nombrar una métrica del origen (`metric = "flow"`) para
  distinguir "encendido" de "moviendo algo de verdad".
* Cuando el layout declara enlaces, la separación entre tiles crece sola: con un
  hueco de un carácter solo cabría la punta de flecha, no la línea.

### Mapa de la base

`config/layout.lua` declara zonas. En modo `grid` (por defecto) se colocan sobre
una rejilla virtual y escalan a cualquier monitor; en modo `absolute` se usan
coordenadas de carácter. Una zona puede apuntar a un `module` (muestra su estado
en vivo) o directamente a un `screen` (atajo). Reorganizar la base es editar ese
fichero: no hay código que tocar.

---

## 10. Alertas

Una alerta es una **condición**, no una línea de log: volver a levantar el mismo
`id` actualiza la existente en lugar de duplicarla.

```lua
ctx.alerts.raise({ id = "power.low", source = "power",
                   severity = "warning", message = "Energía por debajo del 25%" })
ctx.alerts.clear("power.low")
ctx.alerts.toggle(condicion, { id = ..., ... })   -- levanta o limpia
```

Severidades: `info`, `warning`, `critical`. El servicio no conoce periféricos:
Chat Box, altavoces o rednet se enganchan suscribiéndose a `alert.raised`.

**Usa histéresis.** Un valor oscilando en el umbral levanta y limpia la alerta en
cada poll e inunda el log. `modules/demo_farm.lua` y `modules/power.lua`
muestran el patrón (levantar al 90%, limpiar al 80%).

---

## 10.b Identidad y roles

Cada ordenador guarda qué es en `data/node.dat`, fuera de todo lo que el updater
toca. Lo escribe `setup.lua`, lo borra `reset.lua` y nadie más.

```lua
{ role = "master", profile = "master", name = "mainframe",
  modules = { "system", "power", "storage" } }
```

* `core.identity` lee y escribe el fichero y define los perfiles del asistente.
* `core.app` se ramifica en el arranque: un **master** monta display, tema,
  navegación y pantallas; un **nodo** se salta todo eso (`uiActive = false`),
  no enruta toques y pinta un resumen de texto en su terminal.
* Los módulos que carga salen de `identity.modules`, con `config/modules.lua`
  como respaldo. Las instancias de plantilla (granjas) se añaden siempre.
* Un ordenador sin identidad se asume **master**, así que una instalación de un
  solo equipo sigue funcionando igual que antes de que existieran los roles.
* `ctx.hasUI` le dice a un módulo si hay pantallas: sin él, un nodo ofrecería al
  master acciones que abren vistas y fallarían al llegar.

## 10.c Telemetría

Los datos son del nodo. El master **nunca** lee un periférico remoto.

```
NODO                                    MASTER
  poll local de sus periféricos
  cada publishInterval (3 s):
    broadcast metrics.update  ───────>  guarda en state.nodes.<nodo>
                                        registra un módulo proxy por cada
                                        módulo reportado (modules.remote)
                                        el dashboard lo trata como local
  ejecuta la acción         <───────    command.execute (al pulsar un botón)
    responde command.result ───────>
  publica al recibir        <───────    state.request (master recién arrancado)
```

* Es **push**, no polling: el nodo emite solo. `state.request` existe únicamente
  para que un master recién arrancado no espere al siguiente tick.
* `modules.remote` es una plantilla: su `metrics`, `status` y `tile` salen de la
  última instantánea en `core.state`, y sus acciones se reenvían por rednet.
* Si un nodo calla más de `staleAfter` (15 s), se marca offline, sus módulos
  pasan a `OFFLINE`, sus acciones se desactivan y se levanta una alerta.
* `services.snapshot` vuelca a `data/snapshot.dat` cada 60 s y restaura al
  arrancar, marcando siempre lo restaurado como no vivo.

## 11. Red

Desactivada por defecto. Con `network.enabled = true` cada nodo abre sus modems,
se registra en rednet con su hostname y habla el sobre de `network/protocol.lua`:

```lua
{ version = 1, id = 42, source = "power_node", target = "master",
  type = "metrics.update", timestamp = 1712345678901, payload = { ... } }
```

API: `network.send(destino, tipo, payload)`, `network.broadcast(tipo, payload)`,
`network.registerHandler(tipo, fn)`, `network.reply(mensaje, tipo, payload)`.
Además cada mensaje se republica en el bus como `network.message.<tipo>`.

Hay latidos periódicos y detección de nodos caídos (`network.peer_lost`). Ningún
módulo toca `rednet` directamente, así que mover un módulo a otro ordenador no
obliga a reescribirlo.

---

## 12. Errores y degradación

* Todo lo que cruza la frontera con un mod va bajo `pcall`.
* Falta un periférico requerido → el módulo pasa a `unavailable`, su tile se
  pinta en gris y la pantalla de detalle explica qué falta. El resto sigue.
* Un módulo que lanza excepciones se marca `error`; si su tarea de poll falla 5
  veces seguidas, el scheduler la desactiva y lo registra.
* Un fallo al dibujar una pantalla se registra y se muestra en pantalla en lugar
  de tumbar el bucle.

---

## 13. Despliegue y actualizaciones

`installer.lua` es solo un arranque: descarga `updater.lua` y lo ejecuta. Toda
la lógica vive en el updater, así que la ruta de instalación y la de
actualización no pueden divergir.

Cómo detecta el updater si hay algo nuevo:

1. Pide `GET /repos/<repo>/git/trees/<ref>?recursive=1`, que devuelve un SHA del
   contenido completo del repositorio y otro por fichero.
2. Compara ese SHA raíz con el de la última instalación, guardado en
   `data/install.dat`. Iguales significa idénticos: una sola petición basta.
3. Si difieren, compara los SHA por fichero para saber exactamente cuáles
   cambiaron, los enseña y pregunta. Solo descarga esos.

Reglas: `config/` se escribe únicamente si no existe, `data/` no se toca nunca,
y solo se borran ficheros bajo `src/` cuando desaparecen del repositorio. Usar
la API del árbol en lugar de un manifiesto escrito a mano significa que un
módulo nuevo se recoge solo.

## 14. Cómo crear un módulo nuevo

Ver **[MODULE_DEVELOPMENT.md](MODULE_DEVELOPMENT.md)**. En una línea: crear
`src/modules/<id>.lua`, añadir el id a `config/modules.lua` y, si se quiere en el
plano, una zona en `config/layout.lua`. No se toca el núcleo.
