--- BaseOS bootstrap.
--
-- ComputerCraft's shell provides a `require` for programs, but its behaviour has
-- changed across versions and it is not available when a file is run with
-- `os.run`/`dofile`. BaseOS therefore ships its own tiny module loader so the
-- rest of the project can use plain `require("core.app")` style imports no
-- matter how it was started.
--
-- Search order for `require("a.b")`:
--   <root>/src/a/b.lua
--   <root>/src/a/b/init.lua
--   <root>/a/b.lua
--   <root>/a/b/init.lua

local function resolveRoot()
    local program = "startup.lua"
    if shell and shell.getRunningProgram then
        program = shell.getRunningProgram()
    end
    local dir = fs.getDir(program)
    if dir == nil or dir == "." or dir == ".." then dir = "" end
    return dir
end

local ROOT = resolveRoot()

local SEARCH_PATTERNS = {
    "src/?.lua",
    "src/?/init.lua",
    "?.lua",
    "?/init.lua",
}

local baseEnv = _ENV or _G
local loaded = {}
local loading = {}
local bosRequire

local function findModuleFile(name)
    local relative = name:gsub("%.", "/")
    for _, pattern in ipairs(SEARCH_PATTERNS) do
        local candidate = fs.combine(ROOT, (pattern:gsub("%?", relative)))
        if fs.exists(candidate) and not fs.isDir(candidate) then
            return candidate
        end
    end
    return nil
end

local function readFile(path)
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local contents = handle.readAll()
    handle.close()
    return contents
end

--- Installed version, from the file the updater keeps in sync.
-- Deliberately not called "VERSION": on a case-insensitive host filesystem
-- the shell resolves `version` to it and tries to run it as a program.
local function readVersion()
    local path = fs.combine(ROOT, "baseos.version")
    if not fs.exists(path) then return "dev" end
    local handle = fs.open(path, "r")
    if not handle then return "dev" end
    local text = handle.readAll()
    handle.close()
    return (tostring(text):gsub("%s+", ""))
end

--- The BaseOS handle injected into every module environment.
local BASEOS = {
    root = ROOT,
    version = readVersion(),
    loaded = loaded,
}

bosRequire = function(name)
    if type(name) ~= "string" then
        error("require expects a module name (string)", 2)
    end

    local cached = loaded[name]
    if cached ~= nil then return cached end

    if loading[name] then
        error("circular require detected while loading '" .. name .. "'", 2)
    end

    local path = findModuleFile(name)
    if not path then
        error("module '" .. name .. "' not found (root: '" .. ROOT .. "')", 2)
    end

    local source = readFile(path)
    if not source then
        error("unable to read module file '" .. path .. "'", 2)
    end

    local env = setmetatable({
        require = bosRequire,
        BASEOS = BASEOS,
        __MODULE__ = name,
        __FILE__ = path,
    }, { __index = baseEnv })
    env._ENV = env

    local chunk, err = load(source, "@" .. path, "t", env)
    if not chunk then
        error("syntax error in '" .. path .. "': " .. tostring(err), 2)
    end

    loading[name] = true
    local ok, result = pcall(chunk)
    loading[name] = nil

    if not ok then
        error("error loading '" .. name .. "': " .. tostring(result), 0)
    end

    if result == nil then result = true end
    loaded[name] = result
    return result
end

BASEOS.require = bosRequire

-- Expose the loader globally so a user can poke at modules from the shell
-- (`lua` prompt) while debugging without re-bootstrapping.
_G.BASEOS = BASEOS

local ok, err = pcall(function()
    local app = bosRequire("core.app")
    return app.run({ root = ROOT, require = bosRequire, version = BASEOS.version })
end)

if not ok then
    -- Make sure a crashed UI never leaves the user with a redirected terminal.
    if term and term.native then
        pcall(term.redirect, term.native())
    end
    if term and term.setBackgroundColor then
        pcall(term.setBackgroundColor, colors.black)
        pcall(term.setTextColor, colors.red)
    end
    print("")
    print("BaseOS stopped with an error:")
    print(tostring(err))
    if term and term.setTextColor then pcall(term.setTextColor, colors.white) end
end
