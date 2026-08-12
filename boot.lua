--- Module loader, shared by every BaseOS program.
--
-- ComputerCraft's shell provides a `require` for programs, but its behaviour
-- has changed across versions and it is absent when a file is run with
-- `os.run`/`loadfile`. BaseOS therefore ships its own.
--
-- Programs bootstrap it without a require of their own:
--
--   local handle = fs.open("boot.lua", "r")
--   local source = handle.readAll() handle.close()
--   local BASEOS = load(source, "@boot.lua", "t", _ENV or _G)()
--   local identity = BASEOS.require("core.identity")
--
-- Search order for `require("a.b")`:
--   <root>/src/a/b.lua, <root>/src/a/b/init.lua, <root>/a/b.lua, <root>/a/b/init.lua

local function resolveRoot()
    local program = "startup.lua"
    if shell and shell.getRunningProgram then
        program = shell.getRunningProgram()
    end
    local dir = fs.getDir(program)
    if dir == nil or dir == "." or dir == ".." then dir = "" end
    return dir
end

-- Already bootstrapped in this Lua state: reuse it so the module cache is
-- shared and a module is never loaded twice.
if _G.BASEOS and _G.BASEOS.require then return _G.BASEOS end

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
-- Deliberately not called "VERSION": on a case-insensitive host filesystem the
-- shell resolves `version` to it and tries to run it as a program.
local function readVersion()
    local text = readFile(fs.combine(ROOT, "baseos.version"))
    if not text then return "dev" end
    return (tostring(text):gsub("%s+", ""))
end

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

-- Exposed so the shell (and the simulator) can poke at modules while debugging.
_G.BASEOS = BASEOS

return BASEOS
