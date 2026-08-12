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
    -- grandes; pon un número para fijarla.
    gap = "auto",

    grid = { columns = 12, rows = 6 },

    zones = {
        {
            id = "storage",
            label = "STORAGE",
            module = "storage",
            col = 1, row = 1, colSpan = 4, rowSpan = 3,
        },
        {
            id = "hub",
            label = "CENTRAL HUB",
            module = "system",
            col = 5, row = 1, colSpan = 4, rowSpan = 3,
            links = {
                { to = "storage", kind = "items" },
            },
        },
        {
            id = "power",
            label = "POWER",
            module = "power",
            col = 9, row = 1, colSpan = 4, rowSpan = 3,
            links = {
                { to = "hub", kind = "energy" },
            },
        },
        {
            id = "farm_demo",
            label = "DEMO FARM",
            module = "demo_farm",
            col = 1, row = 4, colSpan = 4, rowSpan = 3,
            links = {
                { to = "storage", kind = "items" },
            },
        },
        {
            id = "modules",
            label = "ALL MODULES",
            screen = "module_list",
            col = 5, row = 4, colSpan = 4, rowSpan = 3,
        },
        {
            id = "alerts",
            label = "ALERTS",
            screen = "alerts",
            col = 9, row = 4, colSpan = 4, rowSpan = 3,
        },
    },
}
