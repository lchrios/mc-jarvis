--- Minimal prototype based "class" helper.
--
-- Deliberately tiny: single inheritance, an `init` constructor and nothing
-- else. UI components are the only part of BaseOS that really benefits from
-- object orientation; everything else uses plain module tables.
--
--   local Base = class()
--   function Base:init(opts) self.opts = opts end
--
--   local Child = class(Base)
--   function Child:init(opts) Base.init(self, opts) end
--
--   local instance = Child.new({ ... })

local function class(base)
    local klass = {}
    klass.__index = klass
    klass.__base = base

    if base then
        setmetatable(klass, { __index = base })
    end

    --- Create an instance and run `init` if the class defines one.
    function klass.new(...)
        local instance = setmetatable({}, klass)
        if instance.init then
            instance:init(...)
        end
        return instance
    end

    --- True when `instance` derives from this class.
    function klass.isInstance(instance)
        local meta = getmetatable(instance)
        while meta do
            if meta == klass then return true end
            meta = meta.__base
        end
        return false
    end

    return klass
end

return class
