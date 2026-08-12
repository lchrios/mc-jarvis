--- Rednet settings.
--
-- Leave `enabled = false` while everything runs on one computer. When remote
-- nodes appear, enable it on every node, give each a unique hostname and keep
-- the protocol identical across the base.

return {
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
}
