--- Mapa de la base: qué zonas aparecen, dónde, y qué conecta con qué.
--
-- mode = "grid" (por defecto)
--   Las zonas se colocan sobre una rejilla virtual y escalan a cualquier
--   monitor. Usa col/row (empezando en 1) y colSpan/rowSpan.
--
-- mode = "absolute"
--   Coordenadas de carácter (x/y/width/height) dentro del área de contenido.
--
-- Campos de una zona:
--   id        identificador único
--   label     texto del tile
--   module    id del módulo al que se enlaza (muestra su estado en vivo)
--   screen    abre esta pantalla en vez de la vista de detalle del módulo
--   icon      uno o dos caracteres delante del texto
--   color     nombre de color de ui/theme.lua para el fondo
--   links     conexiones que salen de esta zona (ver abajo)
--
-- CONEXIONES
--   links = { "almacen" }                              línea simple
--   links = { { to = "almacen", kind = "energy" } }    con etiqueta de tipo
--   links = { { to = "almacen", metric = "flow" } }    el estado sale de esa métrica
--
-- El trazado se calcula solo: mueves una zona y la tubería la sigue. El color
-- indica el estado del flujo:
--   verde  el origen está funcionando
--   gris   el origen está parado o en reposo
--   rojo   alguno de los dos extremos está caído o no disponible
--
-- Declarar el enlace en un solo lado basta; hacerlo en los dos no lo duplica.

return {
    mode = "grid",

    -- Separación entre tiles. "auto" usa 1 en monitores pequeños y 2 en los
    -- grandes, y ensancha cuando hay tuberías para que quepa la línea.
    gap = "auto",

    -- Tope de tamaño de celda. Sin esto, un monitor alto no enseña más base:
    -- enseña las mismas salas infladas, con el nombre flotando en medio. Al
    -- llegar al tope el plano se centra en vez de estirarse.
    cell = { maxCellWidth = 8, maxCellHeight = 3 },

    grid = { columns = 12, rows = 9 },

    -- ----------------------------------------------------------------------
    -- PLANO DE EJEMPLO
    --
    -- Salas de tamaños distintos a propósito: un plano se lee por la forma,
    -- no por el texto de dentro. Esto NO es tu base — es un punto de partida
    -- para que edites desde MAP -> EDIT, que guarda en `data/layout.dat` y no
    -- toca este fichero.
    --
    -- Si un `module` no existe en este ordenador, la sala sale en gris. No
    -- pasa nada: bórrala desde el editor o cambia el id por el tuyo.
    --
    -- Nombres cortos a propósito: en un monitor de 3x2 una sala son ~8
    -- caracteres por dentro, y un nombre largo sale cortado. Si tu monitor es
    -- grande puedes alargarlos sin problema.
    -- ----------------------------------------------------------------------
    zones = {
        ---------------------------------------------------------------- arriba
        {
            id = "reactor",
            label = "REACTOR",
            module = "power",
            col = 1, row = 1, colSpan = 3, rowSpan = 4,
            links = {
                { to = "hub", kind = "energy" },
            },
        },
        {
            id = "baterias",
            label = "BATERIAS",
            col = 1, row = 5, colSpan = 3, rowSpan = 2,
            links = {
                { to = "reactor", kind = "energy" },
            },
        },

        --------------------------------------------------------------- centro
        {
            id = "hub",
            label = "CONTROL",
            module = "system",
            col = 5, row = 2, colSpan = 4, rowSpan = 4,
            links = {
                { to = "almacen", kind = "items" },
            },
        },

        -------------------------------------------------------------- derecha
        {
            id = "almacen",
            label = "ALMACEN",
            module = "storage",
            col = 10, row = 1, colSpan = 3, rowSpan = 6,
        },

        ---------------------------------------------------------------- abajo
        {
            id = "granja_mobs",
            label = "MOB FARM",
            module = "demo_farm",
            col = 1, row = 8, colSpan = 4, rowSpan = 2,
            links = {
                { to = "almacen", kind = "items" },
            },
        },
        {
            id = "granja_cultivos",
            label = "CULTIVOS",
            col = 6, row = 8, colSpan = 3, rowSpan = 2,
            links = {
                { to = "almacen", kind = "items" },
            },
        },
        {
            id = "taller",
            label = "TALLER",
            screen = "module_list",
            col = 10, row = 8, colSpan = 3, rowSpan = 2,
        },
    },
}
