--- Speaker adapter.
--
-- Vanilla CC:Tweaked, not Advanced Peripherals, so this one is safe to rely on:
-- `playSound` and `playNote` have been stable for a long time.

local base = require("adapters.base")

local speaker = {}

speaker.id = "speaker"
speaker.label = "Speaker"

--- Sounds used for alerts, worst first. Vanilla sound ids.
speaker.TONES = {
    critical = { sound = "minecraft:block.note_block.didgeridoo", pitch = 0.5, repeats = 3 },
    warning = { sound = "minecraft:block.note_block.bell", pitch = 1.0, repeats = 2 },
    info = { sound = "minecraft:block.note_block.pling", pitch = 1.5, repeats = 1 },
    ok = { sound = "minecraft:block.note_block.chime", pitch = 1.8, repeats = 1 },
}

function speaker.matches(proxy)
    return base.has(proxy, "playSound") or base.has(proxy, "playNote")
end

function speaker.wrap(proxy)
    local self = { proxy = proxy, kind = "speaker" }

    function self.name() return proxy.name and proxy.name() or "?" end

    --- Play a raw sound. Returns true when the speaker accepted it.
    function self.play(sound, volume, pitch)
        return base.call(proxy, "playSound", sound, volume or 1, pitch or 1) ~= nil
    end

    function self.note(instrument, volume, pitch)
        return base.call(proxy, "playNote", instrument or "harp", volume or 1, pitch or 1) ~= nil
    end

    --- Play the tone for an alert severity.
    -- Repeats are deliberately not looped here: a speaker can only queue a few
    -- sounds per tick, and a blocking loop would stall the event loop.
    function self.alert(severity)
        local tone = speaker.TONES[severity] or speaker.TONES.info
        return self.play(tone.sound, 1, tone.pitch)
    end

    return self
end

return speaker
