--- Qué se anuncia por el chat.
--
-- El módulo `notifier` sabe CÓMO llegar al jugador (Chat Box, altavoz, límite
-- de ritmo). Esto decide QUÉ merece la pena decir.
--
-- Cada tema escucha un evento real de BaseOS y lo convierte en una línea de
-- chat. Se encienden y se apagan desde la pantalla NOTIFY (botón en ALERTS),
-- y lo que elijas ahí manda sobre este fichero.
--
-- Los temas que no aparezcan aquí usan su valor por defecto del catálogo
-- (`src/services/notifications.lua`). Poner uno a `false` lo calla.

return {
    topics = {
        -- --------------------------------------------------------------
        -- ENCENDIDOS DE FÁBRICA
        -- --------------------------------------------------------------
        alerts          = true,   -- avisos y críticos, según se levantan
        player_arrived  = true,   -- alguien entra en una zona con detector
        node_offline    = true,   -- otro ordenador dejó de reportar
        module_error    = true,   -- un sistema se cae
        rule_message    = true,   -- lo que una regla con `say` quiere decir
        access_denied   = true,   -- alguien intentó algo sin permiso
        user_added      = true,   -- alguien recibió acceso al panel

        -- --------------------------------------------------------------
        -- APAGADOS: útiles, pero hablan mucho
        -- --------------------------------------------------------------
        player_left     = false,
        peer_lost       = false,
        module_recovered = false,
        device_lost     = false,
        device_found    = false,
        rule_fired      = false,
        rule_done       = false,
        rule_yielded    = false,
        farm_toggled    = false,
        session_opened  = false,
    },
}
