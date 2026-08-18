# Crear un módulo

> Objetivo: añadir un sistema nuevo a la base **sin tocar el núcleo**.

Un módulo es un fichero Lua en `src/modules/` que devuelve una tabla. El registro
(`src/modules/registry.lua`) se encarga del ciclo de vida, del polling, del
estado, de las acciones y de aislar sus fallos.

---

## 1. Ejemplo completo: `mob_farm`

`src/modules/mob_farm.lua`

```lua
--- Granja de mobs: mide el ritmo de salida y controla el spawner por redstone.

local util = require("core.util")

local farm = {}

-- Identidad -----------------------------------------------------------------
farm.id = "mob_farm"
farm.name = "Mob Farm"
farm.icon = "M"
farm.description = "Granja de mobs de la sala norte"
farm.pollInterval = 2          -- segundos entre poll(); por defecto 2

-- Periféricos que necesita ---------------------------------------------------
-- El registro da de alta estos alias en el Peripheral Manager. Los no opcionales
-- que falten dejan el módulo en `unavailable` en lugar de romper nada.
farm.peripherals = {
    { alias = "mobFarmOutput", type = "minecraft:barrel", optional = false },
    { alias = "mobFarmSwitch", type = "redstoneIntegrator", optional = true },
}

-- Ciclo de vida --------------------------------------------------------------

--- Se llama una vez, tras resolver los periféricos.
function farm.setup(self, ctx)
    self.ctx = ctx                    -- guarda el contexto: lo necesitarás
    self.settings = ctx.config.get("modules.settings.mob_farm", {})
    self.itemsPerMinute = 0
    self.lastCount = nil
    self.running = true

    -- Reaccionar a eventos en lugar de sondear agresivamente.
    ctx.bus.on("power.low", function(payload)
        if payload.critical then farm.setRunning(self, false) end
    end, { owner = "module:mob_farm" })
end

--- Opcional: arranque explícito, tras setup de todos los módulos.
function farm.start(self) end

--- Se llama cada `pollInterval` segundos. Aquí se leen los periféricos.
function farm.poll(self)
    local output = self.ctx.adapters.forAlias("mobFarmOutput", "inventory")
    if not output then return end

    local total = output.totalItems()
    if self.lastCount then
        self.itemsPerMinute = (total - self.lastCount) * (60 / farm.pollInterval)
    end
    self.lastCount = total
    self.buffer = output.fillLevel()

    self.ctx.alerts.toggle(self.buffer > 0.9, {
        id = "mob_farm.buffer_full",
        source = farm.id,
        severity = "warning",
        message = "El buffer de la granja de mobs está lleno",
    })
end

--- Opcional: limpieza al parar o descargar el módulo.
function farm.stop(self)
    if self.ctx then self.ctx.alerts.clear("mob_farm.buffer_full") end
end

-- Lo que ve la UI ------------------------------------------------------------

--- @return status, textoOpcional
function farm.status(self)
    if not self.running then return "stopped", "PARADA" end
    if (self.buffer or 0) > 0.9 then return "warning", "ATASCADA" end
    return "running", "EN MARCHA"
end

--- Métricas de la pantalla de detalle.
function farm.metrics(self)
    return {
        { id = "rate",   label = "Items/min", value = self.itemsPerMinute or 0 },
        { id = "buffer", label = "Buffer",    kind = "percent", value = self.buffer or 0 },
    }
end

--- Contenido del tile del dashboard (opcional).
function farm.tile(self)
    return {
        lines = { math.floor(self.itemsPerMinute or 0) .. " it/min" },
        gauge = self.buffer,
    }
end

--- Botones de la pantalla de detalle.
function farm.setRunning(self, running)
    self.running = running
    local switch = self.ctx.peripherals.get("mobFarmSwitch")
    if switch then switch.call("setOutput", "top", running) end
    self.ctx.bus.emit("farm.status_changed", { id = farm.id, status = running and "running" or "stopped" })
end

function farm.actions(self)
    return {
        { id = "start", label = "ARRANCAR", enabled = not self.running,
          run = function() farm.setRunning(self, true) end },
        { id = "stop",  label = "PARAR", style = "danger", enabled = self.running,
          confirm = "¿Parar la granja de mobs?",
          run = function() farm.setRunning(self, false) end },
    }
end

return farm
```

Después:

**`config/modules.lua`**

```lua
enabled = { "system", "power", "storage", "mob_farm" },
settings = {
    mob_farm = { targetRate = 120 },
},
```

**`config/layout.lua`** (opcional, para que aparezca en el plano)

```lua
{ id = "mob_farm", label = "MOB FARM", module = "mob_farm",
  col = 1, row = 4, colSpan = 4, rowSpan = 3 },
```

Reinicia el ordenador y ya está. No se ha tocado ni una línea del núcleo.

---

## 1.b Plantillas: muchas granjas, una implementación

Escribir un fichero por granja no escala. Si varias máquinas se comportan igual
y solo cambian sus periféricos y umbrales, usa una **plantilla**: un fichero que
exporta `create(instance)` en lugar de ser un módulo.

`src/modules/farm.lua` ya es una, y cubre el caso general "granja con un buffer
de salida y control por redstone". Añadir una granja real es solo configuración:

```lua
-- config/modules.lua
instances = {
    {
        id = "mob_farm",          -- id único; también el nombre de sus alias
        template = "farm",        -- src/modules/farm.lua
        name = "Mob Farm",
        icon = "M",
        pollInterval = 5,
        settings = {
            output  = { type = "minecraft:barrel" },     -- dónde cae la producción
            control = { kind = "redstone", side = "back" },
            bufferWarn = 0.90,
            bufferClear = 0.75,
            targetRate = 120,
        },
    },
}
```

La plantilla `farm` acepta:

| Ajuste | Qué hace |
| --- | --- |
| `output` | Matcher del contenedor de salida (`type`, `name`, `method`, `match`) |
| `control` | `{ kind = "none" }`, `{ kind = "redstone", side }` o `{ kind = "integrator", side, match }`; `invert = true` si la granja va con la señal apagada |
| `bufferWarn` / `bufferClear` | Umbrales con histéresis para la alerta de buffer lleno |
| `idleAfter` / `alertWhenIdle` | Segundos sin producir para marcarla `IDLE` |
| `targetRate` | Ritmo esperado, solo informativo |
| `countItems` | Contar solo estos items, p. ej. `{ "minecraft:oak_log" }` |
| `spawner` | `{ match = { name = "block_reader_0" } }`: un Block Reader mirando al spawner |

Cada instancia registra sus propios alias (`mob_farm.output`, `mob_farm.control`,
`mob_farm.spawner`), así que dos granjas nunca se pisan y una puede estar
`unavailable` sin afectar a la otra.

`spawner` es **opcional en los dos sentidos**: la granja funciona sin él, y si
el Block Reader se rompe la granja sigue midiendo su salida en vez de marcarse
como averiada. Lo que se saca de él —qué mob, cada cuánto, a qué distancia— va
en el NBT, que cambia entre versiones y entre mods; se mira donde lo pone cada
uno y lo que no aparece sencillamente no se enseña, en vez de adivinarlo.

**No hace falta editar este fichero para añadir una granja.** El panel las
escribe en `data/farms.dat`, sembrado desde estas instancias la primera vez —
ver la sección de granjas del README. En cuanto el editor guarda una vez, esa
lista manda sobre la de `config/modules.lua`.

> **Ojo con el ritmo**: se mide por lo que aparece en el buffer entre dos
> lecturas. Si una tubería lo vacía al instante, el ritmo saldrá bajo. Apunta
> `output` al buffer *antes* de la extracción. Los deltas negativos se ignoran,
> así que sacar items nunca se lee como producción negativa.

Para escribir tu propia plantilla, devuelve una tabla con `create(instance)` que
construya y devuelva una definición de módulo normal. El registro la reconoce
por tener `create` y la instancia por tener `template`.

## 2. Contrato del módulo

Todas las funciones reciben el propio módulo como primer parámetro (`self`), así
que puedes guardar estado en él con total libertad.

### Campos

| Campo | Tipo | Obligatorio | Descripción |
| --- | --- | --- | --- |
| `id` | string | sí | Identificador único; debe coincidir con el nombre del fichero |
| `name` | string | no | Nombre legible (por defecto, el `id`) |
| `icon` | string | no | Uno o dos caracteres para el tile |
| `description` | string | no | Texto de ayuda |
| `pollInterval` | number | no | Segundos entre `poll()`; por defecto `system.modules.defaultPollInterval` |
| `peripherals` | lista | no | Requisitos, ver abajo |

### Requisitos de periférico

```lua
{ alias = "meBridge", type = "meBridge", optional = false }
{ alias = "farmChest", name = "minecraft:barrel_3" }
{ alias = "anyTank", method = "tanks" }
{ alias = "raro", match = function(proxy, device) return ... end }
```

`alias` es el nombre por el que pedirás el periférico. Los `optional = false` que
falten marcan el módulo `unavailable` automáticamente, y vuelve solo cuando el
periférico reaparece.

### Callbacks

| Función | Cuándo | Devuelve |
| --- | --- | --- |
| `setup(self, ctx)` | una vez al arrancar | — |
| `start(self)` | tras el `setup` de todos | — |
| `poll(self)` | cada `pollInterval` | — |
| `stop(self)` | al apagar o descargar | — |
| `status(self)` | tras cada poll y acción | `status[, texto]` |
| `metrics(self)` | al pintar el detalle | lista de métricas |
| `tile(self)` | al pintar el dashboard | `{ lines = {...}, gauge = 0..1 }` |
| `detail(self)` | al construir la instantánea | desglose por dispositivo |
| `actions(self)` | al pintar el detalle | lista de acciones |
| `detailScreen(params)` | si quieres pantalla propia | una `Screen` |

Valores de `status` que la UI colorea: `running`/`ok`/`online` (verde),
`warning`/`degraded`/`starting` (naranja), `error`/`fault`/`offline` (rojo),
`stopped`/`idle`/`paused` (gris claro), cualquier otro (gris).

### Métricas

```lua
{ id = "rate", label = "Items/min", value = 124 }                  -- número
{ id = "buf",  label = "Buffer", kind = "percent", value = 0.73 }  -- barra
{ id = "pwr",  label = "Consumo", value = 12400, unit = "FE/t" }
{ id = "up",   label = "Tiempo", value = 3600,
  format = function(v) return util.formatDuration(v) end }
```

Las de tipo `percent` se pintan como barra de progreso; el resto como fila
`etiqueta ......... valor`. También se acepta un mapa simple
(`{ Temperatura = 812 }`), que se ordena alfabéticamente.

### Desglose por dispositivo

`metrics` da los totales; `detail` da las cosas que se sumaron para llegar a
ellos. Un módulo que agrega periféricos (celdas, barriles, tanques) lo devuelve
y se lo lleva de gratis: la pantalla
[`ui/screens/device_breakdown.lua`](../src/ui/screens/device_breakdown.lua) lo
pinta con scroll, y una fila tocada abre sus `fields`.

```lua
function mi_modulo.detail(self)
    return {
        columns = { "CHARGE", "STORED" },     -- cabeceras de las dos columnas
        rows = {
            {
                id = "powah:energy_cell_0",
                name = "powah:energy_cell_0",
                percent = 0.78,               -- pinta la fila de color
                value = "1.5M",               -- columna derecha, ya formateada
                status = "running",           -- opcional, manda sobre percent
                fields = {                    -- lo que sale al tocarla
                    { label = "Stored", value = "1.5M FE" },
                    { label = "Capacity", value = "2.0M FE" },
                },
            },
        },
    }
end

function mi_modulo.detailScreen(params)
    return require("ui.screens.device_breakdown").new(params)
end
```

**Solo cadenas y números.** El desglose viaja dentro de la instantánea que un
nodo manda al master, y por rednet no cruza una función: formatea en el
ordenador que tiene los periféricos delante, que además es el único que sabe de
qué unidades habla. Por lo mismo, calcúlalo en `poll` y guárdalo en `self`; que
`detail` solo dé forma a lo que ya se leyó.

### Acciones

```lua
{ id = "stop", label = "PARAR", style = "danger", enabled = true,
  confirm = "¿Seguro?",           -- true o texto: abre un diálogo
  run = function(self) ... end }
```

Estilos: `default`, `primary`, `danger`, `ghost`. Las acciones se desactivan
solas si el módulo está `unavailable`.

---

## 3. El contexto (`ctx`)

Lo recibes en `setup` y conviene guardarlo en `self.ctx`.

| Campo | Para qué |
| --- | --- |
| `ctx.config` | `ctx.config.get("modules.settings.mi_modulo.umbral", 0.5)` |
| `ctx.logger` | `local log = ctx.logger.scoped("mob_farm")` |
| `ctx.bus` | `ctx.bus.on(...)`, `ctx.bus.emit(...)` |
| `ctx.state` | estado compartido entre subsistemas |
| `ctx.scheduler` | tareas extra: `ctx.scheduler.every(30, fn, { owner = "module:mob_farm" })` |
| `ctx.peripherals` | `ctx.peripherals.get("alias")`, `findByType`, `findByMethod` |
| `ctx.adapters` | `forAlias(alias, adapterId)`, `allOfKind(adapterId)` |
| `ctx.alerts` | `raise`, `clear`, `toggle` |
| `ctx.persistence` | `save(nombre, tabla)`, `load(nombre, defecto)` |
| `ctx.network` | `send`, `broadcast`, `registerHandler` |
| `ctx.navigation` | `push("logs", {})` para abrir una pantalla |
| `ctx.modules` | el propio registro (otros módulos) |
| `ctx.util` | helpers de formato |

Si registras suscripciones o tareas, usa siempre
`{ owner = "module:<tu_id>" }`: el registro las limpia sola al descargar el
módulo.

---

## 4. Reglas

1. **No llames a `peripheral.*` directamente.** Declara un requisito y usa
   `ctx.peripherals` o, mejor, un adapter.
2. **No llames a `sleep()` ni a `os.pullEvent()`.** Usa `pollInterval`,
   `ctx.scheduler` o el bus.
3. **No asumas que un método de un mod existe.** Si el adapter no lo cubre,
   añádelo al adapter, no al módulo.
4. **No dibujes.** Publica `metrics`/`tile`/`actions` y deja que la UI decida.
5. **Usa histéresis en las alertas** (levantar al 90%, limpiar al 80%), o
   inundarás el log.
6. **Mantén `poll` barato.** Se ejecuta cada pocos segundos, en el mismo hilo que
   la UI.

---

## 5. Cuando el mod aún no está verificado

Si vas a integrar un mod cuyos métodos no has comprobado en juego:

1. En el ordenador, mira lo que hay de verdad:

   ```lua
   lua> peripheral.getNames()
   lua> peripheral.getType("meBridge_0")
   lua> peripheral.getMethods("meBridge_0")
   ```

2. Añade o corrige el adapter en `src/adapters/`, usando listas de candidatos:

   ```lua
   local STORED = { "getEnergy", "getEnergyStored", "getStoredEnergy" }
   local value = base.callAny(proxy, STORED)
   ```

3. Solo entonces escribe el módulo contra el adapter.

Mientras tanto, un módulo simulado (como `demo_farm`) permite construir y probar
toda la UI sin depender de la máquina real.

---

## 6. Pantalla de detalle propia

La pantalla genérica suele bastar. Si necesitas algo específico:

```lua
function farm.detailScreen(params)
    local class = require("core.class")
    local Screen = require("ui.screen")
    local Label = require("ui.components.label")

    local MobFarmScreen = class(Screen)

    function MobFarmScreen:init(p)
        Screen.init(self, p)
        self.title = "Mob Farm"
    end

    function MobFarmScreen:onLayout(x, y, w, h)
        local label = Label.new({ text = "Vista propia", fg = "accent" })
        label:setBounds(x + 1, y + 1, w - 2, 1)
        self:add(label)
    end

    return MobFarmScreen.new(params)
end
```

La navegación la usa automáticamente al abrir `module_detail` para ese módulo, y
cae a la genérica si falla.

---

## 7. Probarlo sin entrar a Minecraft

```bash
cd tools/simulator
npm install
node run.js
```

El simulador ejecuta los ficheros reales del proyecto en un Lua 5.4 con la API
de CC:Tweaked mockeada, imprime capturas del monitor y falla si aparece algún
`[ERROR]` en el log. Ver [tools/simulator/README.md](../tools/simulator/README.md).
