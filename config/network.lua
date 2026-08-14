--- Rednet settings.
--
-- Leave `enabled = false` while everything runs on one computer. When remote
-- nodes appear, enable it on every node, give each a unique hostname and keep
-- the protocol identical across the base.

return {
    -- Se enciende sola en cuanto ejecutas `setup` y eliges un rol: un ordenador
    -- con rol elegido forma parte de una base con varios equipos. Ponla a true
    -- para forzarla, o a false para apagarla aunque haya rol.
    enabled = false,

    -- Rednet protocol name. Must match on every node.
    protocol = "baseos",

    -- Node name other computers address. Defaults to the computer label.
    hostname = nil,

    -- ----------------------------------------------------------------------
    -- SECRETO COMPARTIDO
    --
    -- Rednet es un medio público: cualquiera puede poner un ordenador con
    -- modem, escuchar este protocolo y mandar lo que quiera — incluido
    -- "para las granjas". Con un secreto, cada mensaje va firmado y los que no
    -- cuadran se tiran.
    --
    -- **Pon la misma cadena en TODOS los equipos de la base.** Invéntate algo
    -- largo; no se escribe en ningún sitio ni viaja por la red.
    --
    -- Vacío = sin firma, como hasta ahora. Vale para un mundo en solitario;
    -- en un servidor con gente, ponlo.
    --
    -- OJO: esto firma, NO cifra. Quien escuche sigue viendo el contenido de
    -- los mensajes. Por eso `backup.share` de abajo viene apagado.
    -- ----------------------------------------------------------------------
    secret = "",
    authWindow = 30,          -- segundos que un mensaje sigue siendo válido

    -- Open every attached modem (wired and wireless).
    openAllModems = true,
    modemSide = nil,          -- pin a side instead, e.g. "back"

    heartbeatInterval = 10,   -- seconds between heartbeat broadcasts
    peerTimeout = 30,         -- seconds before a silent peer counts as lost

    -- Métricas en vivo entre nodos y master.
    telemetry = {
        -- Cada cuántos segundos publica un nodo su estado. Bajarlo da datos
        -- más frescos a cambio de más tráfico.
        publishInterval = 3,
        -- Silencio tras el cual el master da un nodo por caído y levanta alerta.
        staleAfter = 15,
    },

    -- Copia de la config de cada nodo en el master, para poder reconstruir un
    -- equipo destruido sin disquete (`backup pull`).
    backup = {
        -- Apagado por defecto: ese archivo lleva `data/security.dat`, o sea tu
        -- lista de usuarios, y rednet no cifra. Enciéndelo si te fías de quien
        -- pueda estar escuchando, y pon `secret` arriba en cualquier caso.
        share = false,
        interval = 300,
    },
}
