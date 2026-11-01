-- Windrose+ terrain file guard
--
-- The HeightmapExporter C++ mod rewrites windrose_plus_data\terrain_v17.json every time
-- an export is triggered. An export taken before the world has loaded (the server still
-- in its lobby map) finds no landscape pieces and writes a near-empty file over a good
-- one; the heightmap files on disk stay, but nothing points to them any more, so every
-- tile rebuild after that fails with "No components with heightfield data".
--
-- So the last good terrain file is kept beside it (terrain_v17.good.json) before every
-- export, and an export that comes back empty is replaced by that copy. An empty export
-- can never be kept as the good copy.

local Terrain = {}

local TERRAIN = "terrain_v17.json"
local GOOD = "terrain_v17.good.json"

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    return raw
end

-- Written beside the target first, then moved over it (Windows cannot rename onto an
-- existing file, so the old one is removed just before).
local function writeReplace(path, text)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local ok = f:write(text)
    f:close()
    if not ok then os.remove(tmp); return false end
    os.remove(path)
    local moved = os.rename(tmp, path)
    if not moved then os.remove(tmp); return false end
    return true
end

-- A terrain file with at least one landscape piece that has height data. An export taken
-- in the lobby has none; the 74-byte file it leaves is treated as no terrain at all.
function Terrain.textLooksValid(raw)
    return raw ~= nil and #raw > 200 and raw:find('"h":1', 1, true) ~= nil
end

function Terrain.looksValid(path)
    return Terrain.textLooksValid(readAll(path))
end

function Terrain.path(dir) return dir .. "\\" .. TERRAIN end
function Terrain.goodPath(dir) return dir .. "\\" .. GOOD end

-- Before an export: keep the current terrain file as the good copy, if it is one.
-- Returns true when a good copy exists afterwards.
function Terrain.keepGood(dir)
    local raw = readAll(Terrain.path(dir))
    if Terrain.textLooksValid(raw) then
        if readAll(Terrain.goodPath(dir)) ~= raw then
            if not writeReplace(Terrain.goodPath(dir), raw) then return Terrain.looksValid(Terrain.goodPath(dir)) end
        end
        return true
    end
    return Terrain.looksValid(Terrain.goodPath(dir))
end

-- After an export (or at boot): if the terrain file is an empty export and a good copy
-- exists, put the good copy back. Returns true when it did.
function Terrain.restoreGood(dir)
    if Terrain.looksValid(Terrain.path(dir)) then return false end
    local good = readAll(Terrain.goodPath(dir))
    if not Terrain.textLooksValid(good) then return false end
    return writeReplace(Terrain.path(dir), good)
end

return Terrain
