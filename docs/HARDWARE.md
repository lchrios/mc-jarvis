# Qué montar en el mundo

Guía de bloques, cableado y configuración para probar BaseOS por etapas. Cada
etapa funciona por sí sola: monta la 1, compruébala, y solo entonces sigue.

> Lo marcado con **(sin verificar en juego)** funciona en el simulador pero
> todavía no se ha probado dentro de Minecraft.

---

## Materiales por rol

| Rol | Ordenador | Monitor | Modem | Por qué |
| --- | --- | --- | --- | --- |
| **Master** | **Advanced** Computer | **Advanced**, 3x2 mínimo | Solo si hay nodos | El táctil y el color solo existen en los Advanced |
| **Nodo** | Computer normal | Ninguno | Sí | Es headless: ni dibuja ni recibe toques |
| **Display** | **Advanced** Computer | **Advanced**, 3x2 mínimo | Sí | Solo muestra; recibe todo por red |

Los monitores **normales no generan eventos táctiles**: con uno de esos la UI se
dibuja pero no responde. Un nodo, en cambio, no necesita gastar oro: un Computer
normal vale.

---

## Etapa 1 — Un solo ordenador

Lo mínimo que prueba casi todo: UI, módulos, granjas, alertas, histórico.

**Bloques**

1. Advanced Computer.
2. Advanced Monitor de **3x2 bloques o más**, pegado al ordenador.
3. Un cofre o barril cualquiera, también pegado al ordenador.

**Comandos**

```
wget https://raw.githubusercontent.com/lchrios/mc-jarvis/main/installer.lua installer
installer
```

El instalador pregunta el rol al terminar: elige **Master**, dale nombre y deja
que reinicie.

**Comprobar**

```
scan
```

Debe listar el monitor y el cofre. Si el cofre sale con `INV`, el módulo de
almacenamiento ya lo está leyendo.

En el monitor: toca **ALERTS** arriba (abre las alertas), una fila de sistema
(abre su detalle), y **MAP** abajo (abre el plano).

---

## Etapa 2 — Energía

El módulo `power` lee **los periféricos conectados al ordenador donde corre**.
No hay que configurar nada: los descubre solos.

**Bloques**

1. Un **Wired Modem** pegado a la cara de cada bloque de energía.
2. **Networking Cable** uniéndolos hasta el ordenador.
3. Un **Wired Modem** también en el ordenador.
4. **Click derecho en cada modem de un bloque de energía.** Se pone rojo y el
   chat dice su nombre (`powah:energy_cell_nitro_0`). Sin ese click, el bloque no
   existe para el ordenador.

> El modem del *ordenador* es su conexión a la red de cable; el de un *bloque* es
> lo que lo publica. Solo los segundos hay que activarlos con click derecho.

**Comprobar**

```
scan energy
```

- Sale con `ENERGY x / y FE` → el módulo `power` ya lo está midiendo.
- Sale pero sin `ENERGY` → está conectado pero no expone energía; `scan <nombre>`
  y pásame la lista de métodos.
- No sale → falta activar su modem, o ese bloque no es periférico de CC.

---

## Etapa 3 — Una granja real

**Bloques**

1. El cofre o barril **donde cae la producción**, con Wired Modem activado y
   cable hasta el ordenador.
2. Opcional, para poder arrancarla y pararla: una línea de redstone desde una
   cara del ordenador hasta el control de la granja.

**Configuración** — `config/modules.lua`:

```lua
instances = {
    {
        id = "mob_farm",
        template = "farm",
        name = "Mob Farm",
        icon = "M",
        settings = {
            output  = { type = "minecraft:barrel" },
            control = { kind = "redstone", side = "back" },
            targetRate = 120,
        },
    },
},
```

`side` es la cara del **ordenador** de la que sale la señal. Si la granja va al
revés (funciona con la señal apagada), añade `invert = true`.

> Apunta `output` al buffer **antes** de que las tuberías se lo lleven. El ritmo
> se mide por lo que se acumula entre dos lecturas: si algo lo vacía al instante,
> saldrá bajo.

---

## Etapa 4 — Un nodo remoto **(sin verificar en juego)**

**Bloques**

1. Computer (normal vale) donde esté la maquinaria.
2. **Ender Modem** en ese ordenador y otro en el master. Los Wireless Modem
   normales tienen alcance limitado; los Ender no, y cruzan dimensiones.
   *(También sirve un Wired Modem en cada ordenador unidos por cable.)*
3. Los periféricos de esa zona cableados **a ese nodo**, no al master.

**Comandos en el nodo**

```
wget https://raw.githubusercontent.com/lchrios/mc-jarvis/main/installer.lua installer
installer
```

Elige **Power node** (o Farm/Storage), dale un nombre único y reinicia. El nodo
no dibuja nada: su terminal muestra un resumen de texto.

**Comprobar**

- En el nodo: la línea `network:` debe decir `online as '<nombre>'`. Si dice
  `OFFLINE`, falta el modem.
- En el master: el contador **Nodes** aparece en el pie, y el botón `NODES`
  lista el nodo con su último contacto.
- Los módulos del nodo salen en el dashboard del master como si fueran locales,
  y sus botones se ejecutan en el nodo.

Si un nodo calla 15 s, sus módulos pasan a `OFFLINE` y salta una alerta. Eso es
lo esperado, no un fallo.

---

## Etapa 5 — Pantallas repartidas **(sin verificar en juego)**

**Bloques**

1. Advanced Computer + Advanced Monitor donde quieras la pantalla.
2. Ender Modem.

**Comandos**

```
installer
```

Elige **Display**, y luego a qué vista lo fijas: `POWER`, `FARMS`, `BASE MAP`,
`NODES`... Reinicia.

No hay que configurar nada más: recibe la telemetría por red. Mientras no llegue
nada dice que está esperando.

---

## El plano de la base

Solo en el master, `config/layout.lua`. Colocas las salas y declaras qué conecta
con qué; el recorrido de las tuberías se calcula solo:

```lua
zones = {
    { id = "reactor", label = "REACTOR", module = "power",
      col = 1, row = 1, colSpan = 4, rowSpan = 3,
      links = { { to = "almacen", kind = "energy" } } },

    { id = "almacen", label = "ALMACEN", module = "storage",
      col = 9, row = 1, colSpan = 4, rowSpan = 3 },

    { id = "granja", label = "MOB FARM", module = "mob_farm",
      col = 1, row = 4, colSpan = 4, rowSpan = 3,
      links = { { to = "almacen", kind = "items" } } },
}
```

Para un módulo que corre en un nodo, el id lleva el nombre del nodo delante:
`module = "power_node.power"`.

---

## Resumen de configuración

| Fichero | Dónde | Cuándo tocarlo |
| --- | --- | --- |
| `config/modules.lua` | En el equipo que ejecuta esa granja | Al añadir una granja real |
| `config/layout.lua` | Solo en el master | Al dibujar el plano |
| `config/peripherals.lua` | Donde esté el periférico | Solo si hay varios del mismo tipo y quieres fijar cuál |
| `config/network.lua` | Todos | Casi nunca: la red se enciende sola al elegir rol |

`data/` no se toca nunca a mano: ahí viven el rol, el log y las instantáneas.

---

## Si algo va mal

| Síntoma | Mirar |
| --- | --- |
| `MONITOR TOO SMALL` | El monitor es menor de 3x2 |
| La UI no responde al tacto | El monitor es normal, no Advanced |
| Un periférico no aparece | `scan`; ¿está activado su modem con click derecho? |
| Aparece pero no se lee | `scan <nombre>` y pásame los métodos |
| El nodo no llega al master | `network:` en su terminal; ¿modem en los dos equipos? |
| Un equipo quedó mal configurado | `setup` para cambiar el rol, `reset` para dejarlo limpio |

```
version          qué hay instalado
setup show       qué rol tiene este equipo
scan             qué periféricos ve
```
