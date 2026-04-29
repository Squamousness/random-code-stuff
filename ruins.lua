-- ruins.lua

local PLASTCRETE_TOKEN      = "INORGANIC:PLASTCRETE_ID_NULL"
local SUPERSTRUCTURE_TOKEN  = "INORGANIC:SUPERSTRUCTURE_ID_NULL"
local INITIAL_DELAY_TICKS   = 120
local SCAN_INTERVAL_TICKS = 150
local SCAN_RADIUS         = 96

-- Maximum wall height (in tiles) per biome
local BIOME_MAX_HEIGHT = {
    [df.biome_type.DESERT_SAND]                     = 10,
    [df.biome_type.SHRUBLAND_TEMPERATE]             = 20,
    [df.biome_type.SHRUBLAND_TROPICAL]              = 20,
    [df.biome_type.SAVANNA_TEMPERATE]               = 30,
    [df.biome_type.SAVANNA_TROPICAL]                = 30,
    [df.biome_type.DESERT_BADLAND]                  = 20,
    [df.biome_type.DESERT_ROCK]                     = 40,
    [df.biome_type.FOREST_TAIGA]                    = 40,
    [df.biome_type.FOREST_TEMPERATE_CONIFER]        = 40,
    [df.biome_type.FOREST_TEMPERATE_BROADLEAF]      = 40,
    [df.biome_type.FOREST_TROPICAL_CONIFER]         = 40,
    [df.biome_type.FOREST_TROPICAL_DRY_BROADLEAF]   = 40,
    [df.biome_type.FOREST_TROPICAL_MOIST_BROADLEAF] = 40,
    [df.biome_type.MOUNTAIN]                        = 40,
    [df.biome_type.SUBTERRANEAN_WATER]              = 20,
    [df.biome_type.SUBTERRANEAN_CHASM]              = 20,
    [df.biome_type.SUBTERRANEAN_LAVA]               = 20,
    -- Wetlands: maybe if i add them
    -- [df.biome_type.SWAMP_TEMPERATE_FRESHWATER]   = X,
    -- [df.biome_type.SWAMP_TEMPERATE_SALTWATER]    = X,
    -- [df.biome_type.MARSH_TEMPERATE_FRESHWATER]   = X,
    -- [df.biome_type.MARSH_TEMPERATE_SALTWATER]    = X,
    -- [df.biome_type.SWAMP_TROPICAL_FRESHWATER]    = X,
    -- [df.biome_type.SWAMP_TROPICAL_SALTWATER]     = X,
    -- [df.biome_type.SWAMP_MANGROVE]               = X,
    -- [df.biome_type.MARSH_TROPICAL_FRESHWATER]    = X,
    -- [df.biome_type.MARSH_TROPICAL_SALTWATER]     = X,
}
local DEFAULT_MAX_HEIGHT = 5   -- fallback for biomes not listed above
local STAIR_PROB         = 2   -- % chance a wall tower becomes an up-down staircase column
local FORT_PROB          = 10  -- % chance a wall tower in a SUPERSTRUCTURE biome becomes a fortification

local NO_WALL_SPANS       = false -- set true to skip horizontal wall span generation
local NO_FLOOR_SPANS      = false -- set true to skip floor slab span generation
local NO_CATWALK_SPANS    = false -- set true to skip catwalk span generation

local MAX_SPAN            = 12  -- max tiles a span extends from a tower
local SPAN_WALL_GAP_PROB  = 20  -- % chance a wall span step terminates the span
local SPAN_WALL_FORT_PROB = 15  -- % chance a non-gap wall span step uses a fortification tile
local SPAN_SIDE_PROB      = 50  -- % chance a perpendicular side tile is attempted (floor spans)
local SPAN_SIDE_GAP_PROB  = 25  -- % chance an attempted side tile is a gap

-- Biomes whose constructions use SUPERSTRUCTURE_ID_NULL instead of PLASTCRETE_ID_NULL but the colors make it bad to use
local SUPERSTRUCTURE_BIOMES = {
    [df.biome_type.FOREST_TAIGA]                    = true,
    [df.biome_type.FOREST_TEMPERATE_CONIFER]        = true,
    [df.biome_type.FOREST_TEMPERATE_BROADLEAF]      = true,
    [df.biome_type.FOREST_TROPICAL_CONIFER]         = true,
    [df.biome_type.FOREST_TROPICAL_DRY_BROADLEAF]   = true,
    [df.biome_type.FOREST_TROPICAL_MOIST_BROADLEAF] = true,
}

-- Wall tiles in these biomes are degraded to floors but it doesnt get used rn
local FLOOR_ONLY_BIOMES = {
}


local FLOOR_PLANT_IDS = { TILE1=true, TILE2=true, TILE3=true, TILE4=true, TILE5=true, TILE6=true }
local WALL_PLANT_IDS  = { CONCRETE=true, CONCRETE2=true, CONCRETE3=true }

local PLASTCRETE_MAT_TYPE
local PLASTCRETE_MAT_INDEX
local SUPERSTRUCTURE_MAT_TYPE
local SUPERSTRUCTURE_MAT_INDEX

-- Single pass over all tiletypes to find every constant at once (~65K iterations vs ~458K).
local CONSTRUCTED_FLOOR_TT       = nil
local CONSTRUCTED_RAMP_TT        = nil
local constructed_wall_by_suffix = {}
local constructed_wall_all_set   = {}
local CONSTRUCTED_PILLAR_TT      = nil
local CONSTRUCTED_STAIR_UD_TT    = nil
local CONSTRUCTED_STAIR_UP_TT    = nil
local CONSTRUCTED_STAIR_DOWN_TT  = nil
local CONSTRUCTED_FORTIFICATION_TT = nil
local SOIL_FLOOR_TT              = nil

do
    local constr       = df.tiletype_material.CONSTRUCTION
    local sh_updown    = df.tiletype_shape and df.tiletype_shape.STAIR_UPDOWN
    local sh_up        = df.tiletype_shape and df.tiletype_shape.STAIR_UP
    local sh_down      = df.tiletype_shape and df.tiletype_shape.STAIR_DOWN
    local first        = df.tiletype._first_item
    local last         = df.tiletype._last_item
    for i = first, last do
        local name  = df.tiletype[i]
        local attrs = df.tiletype.attrs[i]
        if name then
            local s = tostring(name)
            if s == "SoilFloor1" then SOIL_FLOOR_TT = i end
            if attrs and attrs.material == constr then
                local shape = attrs.shape
                if not CONSTRUCTED_FLOOR_TT and s == "ConstructedFloor" then
                    CONSTRUCTED_FLOOR_TT = i
                elseif not CONSTRUCTED_RAMP_TT and s:find("^ConstructedRamp") then
                    CONSTRUCTED_RAMP_TT = i
                elseif not CONSTRUCTED_PILLAR_TT and s == "ConstructedPillar" then
                    CONSTRUCTED_PILLAR_TT = i
                elseif not CONSTRUCTED_FORTIFICATION_TT and s == "ConstructedFortification" then
                    CONSTRUCTED_FORTIFICATION_TT = i
                elseif not CONSTRUCTED_STAIR_UD_TT then
                    if (sh_updown and shape == sh_updown) then
                        CONSTRUCTED_STAIR_UD_TT = i
                    else
                        local sl = s:lower()
                        if sl:find("stair") and (sl:find("updown") or sl:find("ud")
                           or (sl:find("up") and sl:find("down"))) then
                            CONSTRUCTED_STAIR_UD_TT = i
                        end
                    end
                end
                if not CONSTRUCTED_STAIR_UP_TT then
                    if (sh_up and shape == sh_up) or s == "ConstructedStairUp" then
                        CONSTRUCTED_STAIR_UP_TT = i
                    end
                end
                if not CONSTRUCTED_STAIR_DOWN_TT then
                    if (sh_down and shape == sh_down) or s == "ConstructedStairDown" then
                        CONSTRUCTED_STAIR_DOWN_TT = i
                    end
                end
                local raw = s:match("^ConstructedWall([LRUD0-9]*)$")
                if raw ~= nil then
                    constructed_wall_all_set[i] = true
                    local sfx = raw:gsub("%d+", "")
                    if not constructed_wall_by_suffix[sfx] or not raw:find("%d") then
                        constructed_wall_by_suffix[sfx] = i
                    end
                end
            end
        end
    end
end

local CONSTRUCTED_WALL_TT = constructed_wall_by_suffix["LRUD"]
    or constructed_wall_by_suffix[""]

-- All ConstructedWall/Pillar tiletypes; used for fast neighbour checks.
local CONSTRUCTED_WALL_SET = constructed_wall_all_set
if CONSTRUCTED_PILLAR_TT then CONSTRUCTED_WALL_SET[CONSTRUCTED_PILLAR_TT] = true end

local function original_tile_for(tt)
    local attrs = df.tiletype.attrs[tt]
    if attrs then
        local m = attrs.material
        if m == df.tiletype_material.GRASS_DARK or m == df.tiletype_material.GRASS_LIGHT then
            return SOIL_FLOOR_TT or tt
        end
    end
    return tt
end

local function wall_tt(suffix)
    local tt = constructed_wall_by_suffix[suffix]
    if tt then return tt end
    return CONSTRUCTED_PILLAR_TT or CONSTRUCTED_WALL_TT
end

-- plant_type index → "floor" or "wall"; populated on first use.
local plant_role_cache = nil

local S = rawget(_G, "__ruins_state")
if not S then
    S = {
        watcher_enabled     = false,
        watcher_gen         = 0,
        scan_gen            = 0,
        init_gen            = 0,
        processed_blocks    = {},
        last_site_id        = nil,
        biome_height_cache  = {},
        biome_mat_cache     = {},
        biome_floor_cache   = {},
        debug               = false,
        last_scan_x         = nil,
        last_scan_y         = nil,
        existing            = nil,   -- nil = needs rebuild from global list
    }
    _G.__ruins_state = S
end

local function log(msg)  print("[ruins] " .. msg) end
local function dlog(fn) if S.debug then log("DIAG: " .. fn()) end end

local function find_materials()
    local info = dfhack.matinfo.find(PLASTCRETE_TOKEN)
    if not info then
        log(PLASTCRETE_TOKEN .. " not found in raws — ruins conversion disabled")
        return false
    end
    PLASTCRETE_MAT_TYPE  = info.type
    PLASTCRETE_MAT_INDEX = info.index
    local sinfo = dfhack.matinfo.find(SUPERSTRUCTURE_TOKEN)
    if sinfo then
        SUPERSTRUCTURE_MAT_TYPE  = sinfo.type
        SUPERSTRUCTURE_MAT_INDEX = sinfo.index
    else
        log(SUPERSTRUCTURE_TOKEN .. " not found — mountain/forest ruins will use plastcrete")
        SUPERSTRUCTURE_MAT_TYPE  = PLASTCRETE_MAT_TYPE
        SUPERSTRUCTURE_MAT_INDEX = PLASTCRETE_MAT_INDEX
    end
    return true
end

local function build_plant_cache()
    plant_role_cache = {}
    local all = df.global.world.raws.plants.all
    local floors, walls = 0, 0
    for i = 0, #all - 1 do
        local id = tostring(all[i].id or "")
        if FLOOR_PLANT_IDS[id] then
            plant_role_cache[i] = "floor"
            floors = floors + 1
        elseif WALL_PLANT_IDS[id] then
            plant_role_cache[i] = "wall"
            walls = walls + 1
        end
    end
    dlog(function() return ("plant cache built: floor_species=%d wall_species=%d"):format(floors, walls) end)
end

-- Integer key: z*16384^2 + y*16384 + x. Safe as a Lua double up to 2^53.
local function key_xyz(x, y, z)
    return (z * 16384 + y) * 16384 + x
end

-- Builds a table of block-origin → block for O(1) lookups without C++ calls.
local function make_block_map(block_list)
    local m = {}
    for _, block in ipairs(block_list) do
        local p = block.map_pos
        m[(p.z * 16384 + p.y) * 16384 + p.x] = block
    end
    return m
end

local function block_from_map(bmap, wx, wy, wz)
    local bx = wx - wx % 16
    local by = wy - wy % 16
    return bmap[(wz * 16384 + by) * 16384 + bx]
end

local function is_player_map()
    if dfhack.world.isFortressMode and dfhack.world.isFortressMode() then return true end
    if dfhack.world.getCurrentSite then
        local site = dfhack.world.getCurrentSite()
        return site ~= nil and site.type == df.world_site_type.PlayerFortress
    end
    return false
end

--[[ Keys in world.buildings.other for worldgen road civzones. Player-built roads are in
ANY_ROAD; worldgen dirt roads only appear as ZONE_ROAD_* civzones, not as RoadDirt buildings. ]]
local ROAD_OTHER_KEYS = {
    "ZONE_ROAD_CENTER",
    "ZONE_ROAD_EXIT_NORTH",
    "ZONE_ROAD_EXIT_SOUTH",
    "ZONE_ROAD_EXIT_EAST",
    "ZONE_ROAD_EXIT_WEST",
}

-- Returns a road_set hash and a flat road_tiles list. block_map is used for BFS lookups.
local function build_road_set(block_map)
    local road_set   = {}
    local road_tiles = {}   -- flat: {x1,y1,z1, x2,y2,z2, ...}
    local bother     = df.global.world.buildings.other
    -- flat arrays avoid per-tile table allocation
    local qx, qy, qz = {}, {}, {}
    local qi, qn = 1, 0

    local function enqueue(x, y, z)
        qn = qn + 1; qx[qn] = x; qy[qn] = y; qz[qn] = z
        local n = #road_tiles
        road_tiles[n+1] = x; road_tiles[n+2] = y; road_tiles[n+3] = z
    end

    local function seed(b)
        if not b or not b.x1 then return end
        for rx = b.x1, b.x2 do
            for ry = b.y1, b.y2 do
                local k = key_xyz(rx, ry, b.z)
                if not road_set[k] then
                    road_set[k] = true
                    enqueue(rx, ry, b.z)
                end
            end
        end
    end

    for _, key in ipairs(ROAD_OTHER_KEYS) do
        local vec = bother[key]
        if vec then for _, b in ipairs(vec) do seed(b) end end
    end
    local any_road = bother.ANY_ROAD
    if any_road then for _, b in ipairs(any_road) do seed(b) end end

    -- BFS through adjacent no_grow tiles using block_map to avoid C++ calls.
    local dx = {-1, 1,  0, 0}
    local dy = { 0, 0, -1, 1}
    while qi <= qn do
        local x, y, z = qx[qi], qy[qi], qz[qi]; qi = qi + 1
        local lx, ly = x % 16, y % 16
        for d = 1, 4 do
            local nx, ny = x + dx[d], y + dy[d]
            local k = key_xyz(nx, ny, z)
            if not road_set[k] then
                local block = block_map and block_from_map(block_map, nx, ny, z)
                              or dfhack.maps.getTileBlock(nx, ny, z)
                if block then
                    local occ = block.occupancy[nx % 16][ny % 16]
                    if occ.no_grow and occ.building == 0 then
                        road_set[k] = true
                        enqueue(nx, ny, z)
                    end
                end
            end
        end
        -- ramp tile: also expand upward
        local cur_block = block_map and block_from_map(block_map, x, y, z)
                          or dfhack.maps.getTileBlock(x, y, z)
        if cur_block then
            local cur_attrs = df.tiletype.attrs[cur_block.tiletype[lx][ly]]
            local cur_shape = cur_attrs and df.tiletype_shape.attrs[cur_attrs.shape]
            if cur_shape and cur_shape.basic_shape == df.tiletype_shape_basic.Ramp then
                local k_up = key_xyz(x, y, z + 1)
                if not road_set[k_up] then
                    local block_up = block_map and block_from_map(block_map, x, y, z + 1)
                                     or dfhack.maps.getTileBlock(x, y, z + 1)
                    if block_up then
                        local occ_up = block_up.occupancy[lx][ly]
                        if occ_up.no_grow and occ_up.building == 0 then
                            road_set[k_up] = true
                            enqueue(x, y, z + 1)
                        end
                    end
                end
            end
        end
        -- ramp below: also expand downward
        local k_dn = key_xyz(x, y, z - 1)
        if not road_set[k_dn] then
            local block_dn = block_map and block_from_map(block_map, x, y, z - 1)
                             or dfhack.maps.getTileBlock(x, y, z - 1)
            if block_dn then
                local dn_attrs = df.tiletype.attrs[block_dn.tiletype[lx][ly]]
                local dn_shape = dn_attrs and df.tiletype_shape.attrs[dn_attrs.shape]
                if dn_shape and dn_shape.basic_shape == df.tiletype_shape_basic.Ramp then
                    local occ_dn = block_dn.occupancy[lx][ly]
                    if occ_dn.no_grow and occ_dn.building == 0 then
                        road_set[k_dn] = true
                        enqueue(x, y, z - 1)
                    end
                end
            end
        end
    end

    dlog(function() return ("road_set built: %d tiles"):format(#road_tiles / 3) end)
    return road_set, road_tiles
end


--[[ Returns the cached set of existing construction positions, rebuilding from the global
list only on first call or site change. Stale entries from demolished constructions are
harmless since their grass events are already zeroed. ]]
local function get_existing_set()
    if S.existing then return S.existing end
    local existing = {}
    local constructions = df.global.world.event.constructions
    for i = 0, #constructions - 1 do
        local c = constructions[i]
        existing[key_xyz(c.pos.x, c.pos.y, c.pos.z)] = true
    end
    S.existing = existing
    return existing
end

-- Deterministic per-position hash returning 0–99.
local function hash_percent(x, y, z)
    local mod = 2147483647
    local h   = 1234567
    h = (h * 1103515245 + x + 12345) % mod
    h = (h * 1103515245 + y + 12345) % mod
    h = (h * 1103515245 + z + 12345) % mod
    return h % 100
end

-- Returns the max wall height for the biome at (wx,wy,wz). Cached by region.
local function get_biome_max_height(wx, wy, wz)
    local rx, ry = dfhack.maps.getTileBiomeRgn(wx, wy, wz)
    local ck     = rx .. "," .. ry
    if S.biome_height_cache[ck] then return S.biome_height_cache[ck] end
    local btype  = dfhack.maps.getBiomeType(rx, ry)
    local max_h  = BIOME_MAX_HEIGHT[btype] or DEFAULT_MAX_HEIGHT
    S.biome_height_cache[ck] = max_h
    return max_h
end

-- Returns (mat_type, mat_index) for the construction material at (wx,wy,wz).
local function get_biome_mat(wx, wy, wz)
    -- getTileBiomeRgn returns the surface region even underground, so force superstructure here.
    local block = dfhack.maps.getTileBlock(wx, wy, wz)
    if block and block.designation[wx % 16][wy % 16].subterranean then
        return SUPERSTRUCTURE_MAT_TYPE, SUPERSTRUCTURE_MAT_INDEX
    end

    local rx, ry = dfhack.maps.getTileBiomeRgn(wx, wy, wz)
    local ck     = rx .. "," .. ry
    if S.biome_mat_cache[ck] then
        local m = S.biome_mat_cache[ck]
        return m[1], m[2]
    end
    local btype = dfhack.maps.getBiomeType(rx, ry)
    local mt, mi
    if SUPERSTRUCTURE_BIOMES[btype] then
        mt, mi = SUPERSTRUCTURE_MAT_TYPE, SUPERSTRUCTURE_MAT_INDEX
    else
        mt, mi = PLASTCRETE_MAT_TYPE, PLASTCRETE_MAT_INDEX
    end
    S.biome_mat_cache[ck] = { mt, mi }
    return mt, mi
end

-- True if walls at should be degraded to floors
local function is_floor_only_biome(wx, wy, wz)
    local rx, ry = dfhack.maps.getTileBiomeRgn(wx, wy, wz)
    local ck     = rx .. "," .. ry
    if S.biome_floor_cache[ck] ~= nil then return S.biome_floor_cache[ck] end
    local btype  = dfhack.maps.getBiomeType(rx, ry)
    local result = FLOOR_ONLY_BIOMES[btype] or false
    S.biome_floor_cache[ck] = result
    return result
end

local function has_adjacent_door(wx, wy, wz)
    local dirs = {{-1,0},{1,0},{0,-1},{0,1}}
    for _, d in ipairs(dirs) do
        local bld = dfhack.buildings.findAtTile(wx + d[1], wy + d[2], wz)
        if bld and bld:getType() == df.building_type.Door then return true end
    end
    return false
end

--[[ Returns the target height (1..max_h) for the tower at (wx,wy,wz). x,y are offset so
this hash is decorrelated from the stair/fort rolls. A z offset of 5000 would look
independent but 5000 % 100 == 0, making it useless, hence the x,y offsets. ]]
local function get_tower_height(wx, wy, wz, max_h)
    local roll = hash_percent(wx + 31337, wy + 271, wz)
    return 1 + math.floor(roll * max_h / 100)
end

-- True if the CONCRETE tile at (wx,wy,wz) will have an upper wall at z+tier.
local function will_have_tier(wx, wy, wz, wall_set, tier)
    if not wall_set[key_xyz(wx, wy, wz)] then return false end
    local max_h = get_biome_max_height(wx, wy, wz)
    if tier > max_h - 1 then return false end
    return get_tower_height(wx, wy, wz, max_h) > tier
end

-- Collects positions of all CONCRETE grass tiles from a block list.
local function collect_wall_positions(block_list)
    local wall_set = {}
    for _, block in ipairs(block_list) do
        for _, ev in ipairs(block.block_events) do
            if getmetatable(ev) == "block_square_event_grassst"
               and plant_role_cache[ev.plant_index] == "wall" then
                for lx = 0, 15 do
                    for ly = 0, 15 do
                        if ev.amount[lx][ly] > 0 then
                            wall_set[key_xyz(
                                block.map_pos.x + lx,
                                block.map_pos.y + ly,
                                block.map_pos.z)] = true
                        end
                    end
                end
            end
        end
    end
    return wall_set
end

-- True if the tile is either an unconverted CONCRETE grass tile or an already-placed ConstructedWall.
local function is_wall_neighbour(wx, wy, wz, wall_set)
    if wall_set[key_xyz(wx, wy, wz)] then return true end
    local block = dfhack.maps.getTileBlock(wx, wy, wz)
    if block then
        return CONSTRUCTED_WALL_SET[block.tiletype[wx % 16][wy % 16]] or false
    end
    return false
end

local function wall_suffix(wx, wy, wz, wall_set)
    local s = ""
    if is_wall_neighbour(wx - 1, wy,     wz, wall_set) then s = s .. "L" end
    if is_wall_neighbour(wx + 1, wy,     wz, wall_set) then s = s .. "R" end
    if is_wall_neighbour(wx,     wy - 1, wz, wall_set) then s = s .. "U" end
    if is_wall_neighbour(wx,     wy + 1, wz, wall_set) then s = s .. "D" end
    return s
end

--[[ Wall suffix for an upper tier. Checks which neighbours will also have that tier via
hash, falling back to already-placed ConstructedWall tiles at the same z level. ]]
local function upper_wall_suffix(wx, wy, wz, wall_set, tier)
    local zt = wz + tier
    local function has_upper(nx, ny)
        if will_have_tier(nx, ny, wz, wall_set, tier) then return true end
        local block = dfhack.maps.getTileBlock(nx, ny, zt)
        return block and (CONSTRUCTED_WALL_SET[block.tiletype[nx % 16][ny % 16]] or false)
    end
    local s = ""
    if has_upper(wx - 1, wy    ) then s = s .. "L" end
    if has_upper(wx + 1, wy    ) then s = s .. "R" end
    if has_upper(wx,     wy - 1) then s = s .. "U" end
    if has_upper(wx,     wy + 1) then s = s .. "D" end
    return s
end

-- Zeros grass events at a tile so a demolished construction won't be re-converted.
local function zero_grass_at(block, lx, ly)
    for _, ev in ipairs(block.block_events) do
        if getmetatable(ev) == "block_square_event_grassst" then
            ev.amount[lx][ly] = 0
        end
    end
end

--[[ Inserts a wall construction at (wx,wy,wz). Returns true on success. If override_tt
is set, applies it directly instead of computing a wall suffix. ]]
local function insert_upper_wall(wx, wy, wz, existing, wall_set, tier, mat_type, mat_index, override_tt)
    local k = key_xyz(wx, wy, wz)
    if existing[k] then return false end
    local block = dfhack.maps.getTileBlock(wx, wy, wz)
    if not block then return false end
    local lx, ly = wx % 16, wy % 16
    local attrs = df.tiletype.attrs[block.tiletype[lx][ly]]
    if not attrs or attrs.material ~= df.tiletype_material.AIR then return false end

    local c = df.construction:new()
    c.pos.x     = wx
    c.pos.y     = wy
    c.pos.z     = wz
    c.mat_type  = mat_type
    c.mat_index = mat_index
    c.item_type = df.item_type.BLOCKS
    c.original_tile = original_tile_for(block.tiletype[lx][ly])
    c.flags.no_build_item = true

    if not dfhack.constructions.insert(c) then return false end

    existing[k] = true
    if override_tt then
        block.tiletype[lx][ly] = override_tt
    else
        local suffix = upper_wall_suffix(wx, wy, wz - tier, wall_set, tier)
        local tt = wall_tt(suffix)
        if tt then block.tiletype[lx][ly] = tt end
    end
    zero_grass_at(block, lx, ly)
    return true
end

-- Places a floor tile directly above a wall tower, matching vanilla DF behaviour.
local function insert_cap_floor(wx, wy, wz, existing, mat_type, mat_index)
    local k = key_xyz(wx, wy, wz)
    if existing[k] then return end
    local block = dfhack.maps.getTileBlock(wx, wy, wz)
    if not block then return end
    local lx, ly = wx % 16, wy % 16
    local attrs  = df.tiletype.attrs[block.tiletype[lx][ly]]
    if not attrs or attrs.material ~= df.tiletype_material.AIR then return end
    local c = df.construction:new()
    c.pos.x     = wx
    c.pos.y     = wy
    c.pos.z     = wz
    c.mat_type  = mat_type
    c.mat_index = mat_index
    c.item_type = df.item_type.BLOCKS
    c.original_tile = original_tile_for(block.tiletype[lx][ly])
    c.flags.no_build_item = true
    if dfhack.constructions.insert(c) then
        existing[k] = true
        if CONSTRUCTED_FLOOR_TT then
            block.tiletype[lx][ly] = CONSTRUCTED_FLOOR_TT
        end
    end
end

-- ── Span helpers ─────────────────────────────────────────────────────────────

--[[ Extends a wall section horizontally. Two-pass: tiles are first inserted with a
placeholder tiletype, then re-suffixed once all neighbours are placed. ]]
local function do_wall_span(wx, wy, wz, dx, dy, existing, mat_type, mat_index, block_map)
    local placed = {}  -- { {nx, ny, is_fort}, ... }

    for step = 1, MAX_SPAN do
        local nx, ny   = wx + dx * step, wy + dy * step
        local block    = (block_map and block_from_map(block_map, nx, ny, wz))
                         or dfhack.maps.getTileBlock(nx, ny, wz)
        if not block then break end
        local lx, ly   = nx % 16, ny % 16
        local attrs    = df.tiletype.attrs[block.tiletype[lx][ly]]
        if not attrs or attrs.material ~= df.tiletype_material.AIR then break end
        if hash_percent(nx + 313, ny + 17, wz) < SPAN_WALL_GAP_PROB then break end
        local k = key_xyz(nx, ny, wz)
        if not existing[k] then
            local is_fort = CONSTRUCTED_FORTIFICATION_TT ~= nil
                            and mat_type == SUPERSTRUCTURE_MAT_TYPE
                            and mat_index == SUPERSTRUCTURE_MAT_INDEX
                            and hash_percent(nx, ny + 500, wz) < SPAN_WALL_FORT_PROB
            local c = df.construction:new()
            c.pos.x = nx; c.pos.y = ny; c.pos.z = wz
            c.mat_type = mat_type; c.mat_index = mat_index
            c.item_type = df.item_type.BLOCKS
            c.original_tile = original_tile_for(block.tiletype[lx][ly])
            c.flags.no_build_item = true
            if dfhack.constructions.insert(c) then
                existing[k] = true
                block.tiletype[lx][ly] = CONSTRUCTED_WALL_TT  -- placeholder
                placed[#placed + 1] = { nx, ny, is_fort }
            end
        end
    end

    -- Re-suffix now that all span tiles are placed; fortification tiles stay as-is.
    for _, p in ipairs(placed) do
        local nx, ny, is_fort = p[1], p[2], p[3]
        local blk = (block_map and block_from_map(block_map, nx, ny, wz))
                    or dfhack.maps.getTileBlock(nx, ny, wz)
        if blk then
            if is_fort then
                blk.tiletype[nx % 16][ny % 16] = CONSTRUCTED_FORTIFICATION_TT
            else
                blk.tiletype[nx % 16][ny % 16] = wall_tt(wall_suffix(nx, ny, wz, {}))
            end
        end
    end
    -- floor cap above each span wall
    for _, p in ipairs(placed) do
        insert_cap_floor(p[1], p[2], wz + 1, existing, mat_type, mat_index)
    end
end

--[[ Extends a floor slab with ragged edges. Center tiles are always placed to keep the
chain to the tower unbroken; side tiles may have gaps since they're always next to a solid center. ]]
local function do_floor_span(wx, wy, wz, dx, dy, existing, mat_type, mat_index, block_map)
    local pdx, pdy = -dy, dx

    local function try_floor(nx, ny)
        local blk = (block_map and block_from_map(block_map, nx, ny, wz))
                    or dfhack.maps.getTileBlock(nx, ny, wz)
        if not blk then return end
        local lx2, ly2 = nx % 16, ny % 16
        local at = df.tiletype.attrs[blk.tiletype[lx2][ly2]]
        if not at or at.material ~= df.tiletype_material.AIR then return end
        local k = key_xyz(nx, ny, wz)
        if existing[k] then return end
        local c = df.construction:new()
        c.pos.x = nx; c.pos.y = ny; c.pos.z = wz
        c.mat_type = mat_type; c.mat_index = mat_index
        c.item_type = df.item_type.BLOCKS
        c.original_tile = original_tile_for(blk.tiletype[lx2][ly2])
        c.flags.no_build_item = true
        if dfhack.constructions.insert(c) then
            existing[k] = true
            if CONSTRUCTED_FLOOR_TT then blk.tiletype[lx2][ly2] = CONSTRUCTED_FLOOR_TT end
        end
    end

    for step = 1, MAX_SPAN do
        local nx, ny = wx + dx * step, wy + dy * step
        local block  = (block_map and block_from_map(block_map, nx, ny, wz))
                       or dfhack.maps.getTileBlock(nx, ny, wz)
        if not block then break end
        local lx, ly = nx % 16, ny % 16
        local attrs  = df.tiletype.attrs[block.tiletype[lx][ly]]
        if not attrs or attrs.material ~= df.tiletype_material.AIR then break end
        -- center always placed; stop span if insert fails
        local k = key_xyz(nx, ny, wz)
        if not existing[k] then
            local c = df.construction:new()
            c.pos.x = nx; c.pos.y = ny; c.pos.z = wz
            c.mat_type = mat_type; c.mat_index = mat_index
            c.item_type = df.item_type.BLOCKS
            c.original_tile = original_tile_for(block.tiletype[lx][ly])
            c.flags.no_build_item = true
            if dfhack.constructions.insert(c) then
                existing[k] = true
                if CONSTRUCTED_FLOOR_TT then block.tiletype[lx][ly] = CONSTRUCTED_FLOOR_TT end
            else
                break
            end
        end
        -- sides only placed when center succeeded; avoids diagonal-only connections
        if existing[k] then
            for _, side in ipairs({ 1, -1 }) do
                if hash_percent(nx + side * 200, ny + side * 100, wz) < SPAN_SIDE_PROB then
                    if hash_percent(nx + side * 200, ny + side * 300, wz) >= SPAN_SIDE_GAP_PROB then
                        try_floor(nx + pdx * side, ny + pdy * side)
                    end
                end
            end
        end
    end
end

-- Catwalks: single-tile-wide floor chain. No gaps
local function do_catwalk_span(wx, wy, wz, dx, dy, existing, mat_type, mat_index, block_map)
    for step = 1, MAX_SPAN do
        local nx, ny = wx + dx * step, wy + dy * step
        local block  = (block_map and block_from_map(block_map, nx, ny, wz))
                       or dfhack.maps.getTileBlock(nx, ny, wz)
        if not block then break end
        local lx, ly = nx % 16, ny % 16
        local attrs  = df.tiletype.attrs[block.tiletype[lx][ly]]
        if not attrs or attrs.material ~= df.tiletype_material.AIR then break end
        local k = key_xyz(nx, ny, wz)
        if not existing[k] then
            local c = df.construction:new()
            c.pos.x = nx; c.pos.y = ny; c.pos.z = wz
            c.mat_type = mat_type; c.mat_index = mat_index
            c.item_type = df.item_type.BLOCKS
            c.original_tile = original_tile_for(block.tiletype[lx][ly])
            c.flags.no_build_item = true
            if dfhack.constructions.insert(c) then
                existing[k] = true
                if CONSTRUCTED_FLOOR_TT then block.tiletype[lx][ly] = CONSTRUCTED_FLOOR_TT end
            else
                break  -- no path back to ground
            end
        end
    end
end

-- Four cardinal directions used by generate_spans.
local SPAN_DIRS = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }

--[[ Emits spans from every tier of a wall tower. Span type shifts with height fraction:
walls near the bottom, floor slabs in the middle, catwalks near the top. ]]
local function generate_spans(wx, wy, wz_base, actual_h, existing, mat_type, mat_index, block_map)
    local base_block     = (block_map and block_from_map(block_map, wx, wy, wz_base))
                           or dfhack.maps.getTileBlock(wx, wy, wz_base)
    local is_underground = base_block
                           and base_block.designation[wx % 16][wy % 16].subterranean
    for tier = 0, actual_h do
        local frac    = actual_h > 0 and (tier / actual_h) or 0
        local wall_p  = math.floor(50 * (1 - frac) + 5  * frac + 0.5)
        local floor_p = math.floor(38 * (1 - math.abs(2 * frac - 1) ^ 1.4) + 0.5)
        local ctw_p   = math.floor(5  * (1 - frac) + 35 * frac + 0.5)
        local wz      = wz_base + tier
        for dir_idx, dir in ipairs(SPAN_DIRS) do
            local roll = hash_percent(wx * 4 + dir_idx + 77, wy + tier * 31, wz_base)
            if roll < wall_p then
                if not NO_WALL_SPANS and tier < actual_h and not is_underground then
                    do_wall_span(wx, wy, wz, dir[1], dir[2], existing, mat_type, mat_index, block_map)
                end
            elseif roll < wall_p + floor_p then
                if not NO_FLOOR_SPANS then
                    do_floor_span(wx, wy, wz, dir[1], dir[2], existing, mat_type, mat_index, block_map)
                end
            elseif roll < wall_p + floor_p + ctw_p then
                if not NO_CATWALK_SPANS then
                    do_catwalk_span(wx, wy, wz, dir[1], dir[2], existing, mat_type, mat_index, block_map)
                end
            end
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────

--[[ Scans a block and converts CONCRETE/floor grass tiles to constructions. wall_set must
be pre-built (pass 1). In NPC sites, wall tiles become floors to keep entrances clear. ]]
local function scan_block(block, existing, wall_set, in_site, road_set, block_map)
    local floors, walls, uppers = 0, 0, 0

    for _, ev in ipairs(block.block_events) do
        if getmetatable(ev) == "block_square_event_grassst" then
            local role = plant_role_cache[ev.plant_index]
            if role then
                for lx = 0, 15 do
                    for ly = 0, 15 do
                        if ev.amount[lx][ly] > 0 then
                            local wx = block.map_pos.x + lx
                            local wy = block.map_pos.y + ly
                            local wz = block.map_pos.z
                            local k  = key_xyz(wx, wy, wz)
                            -- in NPC sites: skip tiles inside buildings; force floors near doors
                            local in_site_excluded    = false
                            local in_site_force_floor = false
                            if in_site and role == "wall" then
                                local tt_attrs   = df.tiletype.attrs[block.tiletype[lx][ly]]
                                local shape_attr = tt_attrs and df.tiletype_shape.attrs[tt_attrs.shape]
                                local basic      = shape_attr and shape_attr.basic_shape
                                if existing[k]
                                   or basic == df.tiletype_shape_basic.Wall
                                   or basic == df.tiletype_shape_basic.Fortification
                                   or block.occupancy[lx][ly].no_grow
                                   or not block.designation[lx][ly].outside
                                   or dfhack.buildings.findAtTile(wx, wy, wz) then
                                    ev.amount[lx][ly] = 0
                                    in_site_excluded = true
                                elseif has_adjacent_door(wx, wy, wz) then
                                    in_site_force_floor = true
                                end
                            end
                            if not in_site_excluded then
                            if road_set and (road_set[k] or road_set[key_xyz(wx, wy, wz - 1)]) then
                                -- road tile: suppress
                                ev.amount[lx][ly] = 0
                            elseif block.occupancy[lx][ly].building == 0
                                and not block.occupancy[lx][ly].no_grow then
                                if existing[k] then
                                    -- chunk reload reset the grass amount; re-zero it
                                    ev.amount[lx][ly] = 0
                                else
                                local bmt, bmi = get_biome_mat(wx, wy, wz)
                                local c = df.construction:new()
                                c.pos.x     = wx
                                c.pos.y     = wy
                                c.pos.z     = wz
                                c.mat_type  = bmt
                                c.mat_index = bmi
                                c.item_type = df.item_type.BLOCKS
                                c.original_tile = original_tile_for(block.tiletype[lx][ly])
                                c.flags.no_build_item = true
                                if dfhack.constructions.insert(c) then
                                    existing[k] = true
                                    ev.amount[lx][ly] = 0  -- prevents re-conversion
                                    local tt_attrs2   = df.tiletype.attrs[block.tiletype[lx][ly]]
                                    local shape_attr2 = tt_attrs2 and df.tiletype_shape.attrs[tt_attrs2.shape]
                                    local basic2      = shape_attr2 and shape_attr2.basic_shape
                                    if basic2 == df.tiletype_shape_basic.Ramp then
                                        if CONSTRUCTED_RAMP_TT then
                                            block.tiletype[lx][ly] = CONSTRUCTED_RAMP_TT
                                        end
                                        floors = floors + 1
                                    elseif role == "floor" or is_floor_only_biome(wx, wy, wz) or in_site_force_floor then
                                        if CONSTRUCTED_FLOOR_TT then
                                            block.tiletype[lx][ly] = CONSTRUCTED_FLOOR_TT
                                        end
                                        floors = floors + 1
                                    else
                                        -- height-1 towers can't be stairs; check before is_stair
                                        local max_h    = get_biome_max_height(wx, wy, wz)
                                        local target_h = get_tower_height(wx, wy, wz, max_h)
                                        local is_stair = CONSTRUCTED_STAIR_UD_TT ~= nil
                                                         and CONSTRUCTED_STAIR_UP_TT ~= nil
                                                         and target_h > 1
                                                         and hash_percent(wx, wy, wz) < STAIR_PROB
                                        local is_fort  = not is_stair
                                                         and CONSTRUCTED_FORTIFICATION_TT ~= nil
                                                         and bmt == SUPERSTRUCTURE_MAT_TYPE
                                                         and bmi == SUPERSTRUCTURE_MAT_INDEX
                                                         and hash_percent(wx, wy + 1, wz) < FORT_PROB
                                        -- stair towers use STAIR_UP at ground so there's no downward exit
                                        local override_tt = is_stair and CONSTRUCTED_STAIR_UD_TT
                                                           or is_fort and CONSTRUCTED_FORTIFICATION_TT
                                                           or nil
                                        if is_stair then
                                            block.tiletype[lx][ly] = CONSTRUCTED_STAIR_UP_TT
                                        elseif override_tt then
                                            block.tiletype[lx][ly] = override_tt
                                        else
                                            local suffix = wall_suffix(wx, wy, wz, wall_set)
                                            local wtt = wall_tt(suffix)
                                            if wtt then block.tiletype[lx][ly] = wtt end
                                        end
                                        walls = walls + 1

                                        -- base grass is now zeroed, so this upper-tier chain runs once
                                        local cap_z    = wz + 1
                                        for tier = 1, target_h - 1 do
                                            if insert_upper_wall(wx, wy, wz + tier, existing, wall_set, tier, bmt, bmi, override_tt) then
                                                uppers = uppers + 1
                                                cap_z  = wz + tier + 1
                                            else
                                                break
                                            end
                                        end
                                        -- wall towers: floor cap on top; stair towers: StairDown cap (guard: cap_z-1 > wz)
                                        if not is_stair then
                                            insert_cap_floor(wx, wy, cap_z, existing, bmt, bmi)
                                        elseif CONSTRUCTED_STAIR_DOWN_TT and cap_z - 1 > wz then
                                            local top_block = dfhack.maps.getTileBlock(wx, wy, cap_z - 1)
                                            if top_block then
                                                top_block.tiletype[wx % 16][wy % 16] = CONSTRUCTED_STAIR_DOWN_TT
                                            end
                                        end
                                        local spans_h = is_stair and (cap_z - 1 - wz) or (cap_z - wz)
                                        generate_spans(wx, wy, wz, spans_h, existing, bmt, bmi, block_map)
                                    end
                                else
                                    -- insert failed (ruins_big already placed here); zero grass and cache
                                    ev.amount[lx][ly] = 0
                                    existing[k] = true
                                end
                                end  -- else (not existing[k])
                            end
                            end  -- not in_site_excluded
                        end
                    end
                end
            end
        end
    end

    return floors, walls, uppers
end

local function get_site_id()
    if dfhack.world.getCurrentSite then
        local site = dfhack.world.getCurrentSite()
        if site then return site.id end
    end
    return -1
end

-- True inside NPC settlements; player fortresses are excluded so ruins convert on embark.
local function is_npc_site()
    if not dfhack.world.getCurrentSite then return false end
    local site = dfhack.world.getCurrentSite()
    if not site then return false end
    if site.type == df.world_site_type.PlayerFortress then return false end
    return true
end

local function convert_ruins(force)
    if not dfhack.isMapLoaded() then return end
    if not PLASTCRETE_MAT_TYPE and not find_materials() then return end
    if not plant_role_cache then build_plant_cache() end

    local site_id = get_site_id()
    if force or site_id ~= S.last_site_id then
        S.processed_blocks = {}
        S.existing = nil  -- rebuild on site change
        S.last_site_id = site_id
    end

    local all_blocks = df.global.world.map.map_blocks
    local block_map  = make_block_map(all_blocks)
    local in_site    = is_npc_site()

    -- pass 1: wall positions for suffix computation
    local wall_set = collect_wall_positions(all_blocks)

    -- pass 2: road set to suppress ruins on roads
    local existing  = get_existing_set()
    local road_set  = build_road_set(block_map)

    -- pass 3: convert unprocessed blocks
    local tf, tw, tu = 0, 0, 0
    for _, block in ipairs(all_blocks) do
        local p  = block.map_pos
        local bk = key_xyz(p.x, p.y, p.z)
        if not S.processed_blocks[bk] then
            S.processed_blocks[bk] = true
            local f, w, u = scan_block(block, existing, wall_set, in_site, road_set, block_map)
            tf = tf + f; tw = tw + w; tu = tu + u
        end
    end

    if tf + tw > 0 then
        log(("Converted ruins: floors=%d walls=%d uppers=%d"):format(tf, tw, tu))
    end
end

local function scan_nearby()
    if not dfhack.isMapLoaded() then return end
    if is_player_map() then return end
    if not PLASTCRETE_MAT_TYPE then return end
    if not plant_role_cache then return end

    local adv = dfhack.world and dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if not adv or not adv.pos then return end

    local cx, cy, cz = adv.pos.x, adv.pos.y, adv.pos.z
    local r   = SCAN_RADIUS

    -- filter loaded blocks by bounding box to avoid C++ getTileBlock calls
    local nearby_blocks = {}
    for _, block in ipairs(df.global.world.map.map_blocks) do
        local p = block.map_pos
        if math.abs(p.x - cx) <= r + 16 and math.abs(p.y - cy) <= r + 16
           and p.z >= cz - 40 and p.z <= cz + 10 then
            nearby_blocks[#nearby_blocks + 1] = block
        end
    end

    table.sort(nearby_blocks, function(a, b)
        local pa, pb = a.map_pos, b.map_pos
        if pa.x ~= pb.x then return pa.x < pb.x end
        if pa.y ~= pb.y then return pa.y < pb.y end
        return pa.z < pb.z
    end)

    local block_map             = make_block_map(nearby_blocks)
    local in_site               = is_npc_site()
    local wall_set              = collect_wall_positions(nearby_blocks)
    local existing  = get_existing_set()
    local road_set  = build_road_set(block_map)

    -- always scan all nearby blocks; ev.amount > 0 guards against double-conversion on chunk reload
    local floors, walls, uppers = 0, 0, 0
    for _, block in ipairs(nearby_blocks) do
        local p  = block.map_pos
        local bk = key_xyz(p.x, p.y, p.z)
        S.processed_blocks[bk] = true
        local f, w, u = scan_block(block, existing, wall_set, in_site, road_set)
        floors = floors + f; walls = walls + w; uppers = uppers + u
    end

    if floors + walls > 0 then
        log(("scan_nearby: floors=%d walls=%d uppers=%d"):format(floors, walls, uppers))
    end

    S.last_scan_x = cx
    S.last_scan_y = cy
end

local function scan_tick(gen)
    if not S.watcher_enabled then return end
    if gen ~= S.scan_gen then return end
    -- fast travel: if player moved far, scan sooner to keep up
    local delay = SCAN_INTERVAL_TICKS
    local adv = dfhack.world and dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if adv and adv.pos and S.last_scan_x then
        local dx = adv.pos.x - S.last_scan_x
        local dy = adv.pos.y - S.last_scan_y
        if dx*dx + dy*dy > (SCAN_RADIUS * SCAN_RADIUS / 4) then
            delay = 30
        end
    end
    scan_nearby()
    dfhack.timeout(delay, "ticks", function() scan_tick(gen) end)
end

local function start_watcher()
    if S.watcher_enabled then return end
    S.watcher_enabled = true
    S.scan_gen = S.scan_gen + 1
    scan_tick(S.scan_gen)
end

local function stop_watcher()
    S.watcher_enabled = false
    S.scan_gen = S.scan_gen + 1
end

local function schedule_initial()
    S.init_gen = S.init_gen + 1
    local gen  = S.init_gen
    dfhack.timeout(INITIAL_DELAY_TICKS, "ticks", function()
        if gen ~= S.init_gen then return end
        convert_ruins(true)
    end)
end

local args = { ... }
local cmd  = args[1] or "enable"

if cmd == "enable" then
    convert_ruins(false)
    start_watcher()
    schedule_initial()
elseif cmd == "force" then
    convert_ruins(true)
elseif cmd == "disable" then
    S.init_gen = S.init_gen + 1
    stop_watcher()
    S.processed_blocks = {}
    S.existing = nil
    S.last_site_id = nil
elseif cmd == "status" then
    log(("watcher=%s mat_found=%s floor_tt=%s wall_tt=%s stair_ud_tt=%s fort_tt=%s"):format(
        tostring(S.watcher_enabled),
        tostring(PLASTCRETE_MAT_TYPE ~= nil),
        tostring(CONSTRUCTED_FLOOR_TT),
        tostring(CONSTRUCTED_WALL_TT),
        tostring(CONSTRUCTED_STAIR_UD_TT),
        tostring(CONSTRUCTED_FORTIFICATION_TT)))
elseif cmd == "debug" then
    S.debug = not S.debug
    log("Debug " .. (S.debug and "ON" or "OFF"))
elseif cmd == "debug-roads" then
    -- show road building counts and adventurer tile state
    local bother = df.global.world.buildings.other
    for _, key in ipairs(ROAD_OTHER_KEYS) do
        local vec = bother[key]
        local n = vec and #vec or -1
        log(("ZONE %s: %d buildings"):format(key, n))
        if vec and n > 0 then
            for i = 0, math.min(2, n - 1) do
                local b = vec[i]
                log(("  [%d] x=%d..%d y=%d..%d z=%d"):format(i, b.x1, b.x2, b.y1, b.y2, b.z))
            end
        end
    end
    local any_road = bother.ANY_ROAD
    log(("ANY_ROAD: %d buildings"):format(any_road and #any_road or -1))
    -- Report road_set tile count
    local road_set = build_road_set()
    local n = 0; for _ in pairs(road_set) do n = n + 1 end
    log(("road_set total tiles: %d"):format(n))
    -- Report adventurer tile details
    local adv = dfhack.world and dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if adv and adv.pos then
        local wx, wy, wz = adv.pos.x, adv.pos.y, adv.pos.z
        log(("Adventurer at %d,%d,%d — in road_set: %s"):format(
            wx, wy, wz, tostring(road_set[key_xyz(wx, wy, wz)] == true)))
        local block = dfhack.maps.getTileBlock(wx, wy, wz)
        if block then
            local lx, ly = wx % 16, wy % 16
            local occ    = block.occupancy[lx][ly]
            local tt     = block.tiletype[lx][ly]
            local attrs  = df.tiletype.attrs[tt]
            log(("  tiletype=%s material=%s"):format(
                tostring(df.tiletype[tt]),
                attrs and tostring(df.tiletype_material[attrs.material]) or "?"))
            log(("  occupancy.building=%s no_grow=%s"):format(
                tostring(occ.building), tostring(occ.no_grow)))
        end
        local bld = dfhack.buildings.findAtTile(wx, wy, wz)
        log(("  findAtTile: %s"):format(
            bld and tostring(df.building_type[bld:getType()]) or "nil"))
        local zones = dfhack.buildings.findCivzonesAt({x=wx, y=wy, z=wz})
        if zones and #zones > 0 then
            for _, z in ipairs(zones) do
                log(("  findCivzonesAt: civzone_type=%s"):format(
                    tostring(df.civzone_type[z.type])))
            end
        else
            log("  findCivzonesAt: none")
        end
    end
else
    log("Usage: ruins [enable|force|disable|status|debug|debug-roads]")
end
