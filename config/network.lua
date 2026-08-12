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
}
