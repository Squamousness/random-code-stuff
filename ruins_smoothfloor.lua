-- ruins_smoothfloor.lua

--   ruins_smoothfloor enable
--   ruins_smoothfloor disable
--   ruins_smoothfloor force
--   ruins_smoothfloor status

local SCAN_INTERVAL_TICKS  = 3
local BLOCKS_PER_TICK      = 20
local VISIBLE_BLOCK_RADIUS = 2   -- 2 blocks = 32 tiles; safely covers the DF adventure viewport

local SMOOTH_CLASSES = {
    HEAVY_STRUCTURE  = { floor=true, wall=true  },
    MIDDLE_STRUCTURE = { floor=true, wall=true  },
    LIGHT_STRUCTURE  = { floor=true, wall=true  },
    MACHINERY        = { floor=true, wall=false },
}

-- ============================================================================
-- TILETYPE CONSTANTS
-- ============================================================================

local STONE_MAT        = df.tiletype_material.STONE
local LAVA_STONE_MAT   = df.tiletype_material.LAVA_STONE
local SHAPE_WALL       = df.tiletype_shape.WALL
local SHAPE_OPEN_SPACE = df.tiletype_shape.EMPTY or -1
local SPECIAL_SMOOTH   = df.tiletype_special.SMOOTH
local BASIC_FLOOR      = df.tiletype_shape_basic.Floor
local BASIC_PEBBLE     = df.tiletype_shape_basic.Pebble
local BASIC_BOULDER    = df.tiletype_shape_basic.Boulder

local SMOOTH_FLOOR_TT      = df.tiletype.StoneFloorSmooth
local SMOOTH_LAVA_FLOOR_TT = df.tiletype.LavaFloorSmooth

local smooth_stone_wall_by_suffix = {}
local smooth_lava_wall_by_suffix  = {}
local smooth_stone_wall_fallback  = df.tiletype.StonePillar
local smooth_lava_wall_fallback   = df.tiletype.LavaPillar
local smooth_stone_wall_tt_set    = {}
local smooth_lava_wall_tt_set     = {}

for _, pair in ipairs{ {"Stone", smooth_stone_wall_by_suffix}, {"Lava", smooth_lava_wall_by_suffix} } do
    local prefix, tbl = pair[1], pair[2]
    for li = 0, 1 do for ri = 0, 1 do
    for ui = 0, 1 do for di = 0, 1 do
        local suffix = (li==1 and "L" or "")..(ri==1 and "R" or "")..(ui==1 and "U" or "")..(di==1 and "D" or "")
        local num = df.tiletype[prefix.."WallSmooth"..suffix]
        if num then tbl[li + ri*2 + ui*4 + di*8] = num end
    end end end end
end

if next(smooth_lava_wall_by_suffix) == nil then
    smooth_lava_wall_by_suffix = smooth_stone_wall_by_suffix
    smooth_lava_wall_fallback  = smooth_stone_wall_fallback
end

for _, i in pairs(smooth_stone_wall_by_suffix) do smooth_stone_wall_tt_set[i] = true end
if smooth_lava_wall_by_suffix ~= smooth_stone_wall_by_suffix then
    for _, i in pairs(smooth_lava_wall_by_suffix) do smooth_lava_wall_tt_set[i] = true end
end

-- Per-tiletype kind lookup built once at load
local tt_kind = (function()
    local t = {}
    for i, _ in ipairs(df.tiletype) do
        local a     = df.tiletype.attrs[i]
        local mat   = a.material
        local sa    = df.tiletype_shape.attrs[a.shape]
        local basic = sa and sa.basic_shape
        if a.special ~= SPECIAL_SMOOTH then
            if mat == STONE_MAT then
                if basic == BASIC_FLOOR or basic == BASIC_PEBBLE or basic == BASIC_BOULDER then t[i] = 'sf'
                elseif a.shape == SHAPE_WALL                                               then t[i] = 'sw' end
            elseif mat == LAVA_STONE_MAT then
                if basic == BASIC_FLOOR or basic == BASIC_PEBBLE or basic == BASIC_BOULDER then t[i] = 'lf'
                elseif a.shape == SHAPE_WALL                                               then t[i] = 'lw' end
            end
        elseif a.shape == SHAPE_WALL then
            if smooth_stone_wall_tt_set[i] then
                t[i] = 'sw_r'
            elseif smooth_lava_wall_tt_set[i] then
                t[i] = 'lw_r'
            end
        end
    end
    return t
end)()

-- ============================================================================
-- STATE
-- ============================================================================

local S = rawget(_G, "__smoothfloor_state")
if not S then
    S = {
        watcher_enabled    = false,
        scan_gen           = 0,
        frame_gen          = 0,
        last_frame_pos     = nil,
        bfs_queue          = {},
        bfs_head           = 1,
        bfs_tail           = 0,
        bfs_seen           = {},
        bfs_done           = {},
        bfs_block_count    = 0,
        current_timeout_id = -1,
    }
    _G.__smoothfloor_state = S
end
if S.scan_gen           == nil then S.scan_gen           = 0  end
if S.frame_gen          == nil then S.frame_gen          = 0  end
if S.last_frame_pos     == nil then S.last_frame_pos     = nil end
if S.bfs_queue          == nil then S.bfs_queue          = {} end
if S.bfs_head           == nil then S.bfs_head           = 1  end
if S.bfs_tail           == nil then S.bfs_tail           = 0  end
if S.bfs_seen           == nil then S.bfs_seen           = {} end
if S.bfs_done           == nil then S.bfs_done           = {} end
if S.bfs_block_count    == nil then S.bfs_block_count    = 0  end
if S.current_timeout_id == nil then S.current_timeout_id = -1 end

local function log(msg, ...) print("[smoothfloor] " .. string.format(msg, ...)) end

-- ============================================================================
-- INORGANIC CACHE
-- ============================================================================

local smooth_inorganic_cache = nil

local function build_inorganic_cache()
    smooth_inorganic_cache = {}
    local count = 0
    for i, m in ipairs(df.global.world.raws.inorganics.all) do
        local mat = m.material
        for _, rc in ipairs(mat.reaction_class) do
            local cfg = SMOOTH_CLASSES[rc.value]
            if cfg then
                smooth_inorganic_cache[i] = cfg
                count = count + 1
                break
            end
        end
    end
    log("inorganic cache built: %d matching", count)
end

-- ============================================================================
-- WALL SUFFIX HELPERS
-- ============================================================================

local function wall_at(nx, ny, nz)
    local tt = dfhack.maps.getTileType(nx, ny, nz)
    local a  = tt and df.tiletype.attrs[tt]
    return a ~= nil and a.shape == SHAPE_WALL
end

local function get_wall_idx(wx, wy, wz)
    return (wall_at(wx-1, wy,   wz) and 1 or 0)
         + (wall_at(wx+1, wy,   wz) and 2 or 0)
         + (wall_at(wx,   wy-1, wz) and 4 or 0)
         + (wall_at(wx,   wy+1, wz) and 8 or 0)
end

local function pick_smooth_wall_tt(tbl, fallback, wx, wy, wz)
    return tbl[get_wall_idx(wx, wy, wz)] or fallback
end

-- ============================================================================
-- SCAN LOGIC
-- ============================================================================

-- include_hidden: when true, smooths hidden tiles too (used for LOS-boundary and BFS pre-smooth)
local function scan_block(block, resuffix, include_hidden)
    if not smooth_inorganic_cache then return 0, 0, false, false end
    local floors, walls = 0, 0
    local bx = block.map_pos.x
    local by = block.map_pos.y
    local bz = block.map_pos.z
    local biome_cache  = {}
    local has_non_open = false
    local has_non_wall = false

    for lx = 0, 15 do
        for ly = 0, 15 do
            local tt   = block.tiletype[lx][ly]
            local kind = tt_kind[tt]
            if kind then
                has_non_open = true
                if kind == 'sf' or kind == 'lf' then has_non_wall = true end
            else
                local a = df.tiletype.attrs[tt]
                if a then
                    if a.shape ~= SHAPE_OPEN_SPACE then has_non_open = true end
                    if a.shape ~= SHAPE_WALL        then has_non_wall = true end
                end
            end
            if kind == 'sf' or kind == 'sw' or kind == 'lf' or kind == 'lw' then
                if include_hidden or not block.designation[lx][ly].hidden then
                    local floor_ok, wall_ok
                    local rx, ry = dfhack.maps.getTileBiomeRgn(bx+lx, by+ly, bz)
                    local b
                    if rx then
                        local ck = rx * 100000 + ry
                        b = biome_cache[ck]
                        if b == nil then
                            local ri = dfhack.maps.getRegionBiome(rx, ry)
                            b = ri and df.world_geo_biome.find(ri.geo_index) or false
                            biome_cache[ck] = b
                        end
                        if b == false then b = nil end
                    end
                    if b then
                        local layer = b.layers[block.designation[lx][ly].geolayer_index]
                        local cfg   = layer and smooth_inorganic_cache[layer.mat_index]
                        if not cfg then
                            for _, fl in ipairs(b.layers) do
                                cfg = smooth_inorganic_cache[fl.mat_index]
                                if cfg then break end
                            end
                        end
                        if cfg then floor_ok = cfg.floor; wall_ok = cfg.wall end
                    end
                    if (kind == 'sf' or kind == 'lf') and floor_ok then
                        local ftt = (kind == 'sf') and SMOOTH_FLOOR_TT or SMOOTH_LAVA_FLOOR_TT
                        if ftt then block.tiletype[lx][ly] = ftt end
                        floors = floors + 1
                    elseif (kind == 'sw' or kind == 'lw') and wall_ok then
                        local tbl = (kind == 'sw') and smooth_stone_wall_by_suffix or smooth_lava_wall_by_suffix
                        local fb  = (kind == 'sw') and smooth_stone_wall_fallback  or smooth_lava_wall_fallback
                        local wtt = pick_smooth_wall_tt(tbl, fb, bx+lx, by+ly, bz)
                        if wtt then block.tiletype[lx][ly] = wtt end
                        walls = walls + 1
                    end
                end
            elseif resuffix and (kind == 'sw_r' or kind == 'lw_r') then
                if include_hidden or not block.designation[lx][ly].hidden then
                    local tbl = (kind == 'sw_r') and smooth_stone_wall_by_suffix or smooth_lava_wall_by_suffix
                    local fb  = (kind == 'sw_r') and smooth_stone_wall_fallback  or smooth_lava_wall_fallback
                    local wtt = pick_smooth_wall_tt(tbl, fb, bx+lx, by+ly, bz)
                    if wtt and wtt ~= tt then
                        block.tiletype[lx][ly] = wtt
                        walls = walls + 1
                    end
                end
            end
        end
    end

    return floors, walls, has_non_open, has_non_wall
end

local function is_player_map()
    if dfhack.world.isFortressMode and dfhack.world.isFortressMode() then return true end
    local site = dfhack.world.getCurrentSite and dfhack.world.getCurrentSite()
    return site ~= nil and site.type == df.world_site_type.PlayerFortress
end

local function player_block_pos()
    local adv = dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if not adv or not adv.pos then return nil end
    local px, py, pz = adv.pos.x, adv.pos.y, adv.pos.z
    return px - (px % 16), py - (py % 16), pz
end

local function smooth_visible_area()
    if not dfhack.isMapLoaded() then return end
    local pbx, pby, pbz = player_block_pos()
    if not pbx then return end
    local tf, tw = 0, 0
    for dbx = -VISIBLE_BLOCK_RADIUS, VISIBLE_BLOCK_RADIUS do
        for dby = -VISIBLE_BLOCK_RADIUS, VISIBLE_BLOCK_RADIUS do
            -- outer ring of the visible area: pre-smooth hidden tiles at the LOS boundary
            local at_edge = math.abs(dbx) == VISIBLE_BLOCK_RADIUS or math.abs(dby) == VISIBLE_BLOCK_RADIUS
            for dbz = -1, 1 do
                local block = dfhack.maps.getTileBlock(
                    pbx + dbx * 16, pby + dby * 16, pbz + dbz)
                if block then
                    local f, w = scan_block(block, false, at_edge)
                    tf = tf + f; tw = tw + w
                end
            end
        end
    end
    if tf + tw > 0 then
        log("smooth_visible_area: floors=%d walls=%d", tf, tw)
    end
end

-- One-time scan: smooths all currently exposed eligible underground stone.
-- Called once at enable for fortress mode.
local function scan_all_subterranean()
    if not dfhack.isMapLoaded() then return end
    local blocks = df.global.world.map.map_blocks
    local tf, tw = 0, 0
    for i = 0, #blocks - 1 do
        local block = blocks[i]
        if block.designation[0][0].subterranean then
            local f, w = scan_block(block, false)
            tf = tf + f; tw = tw + w
        end
    end
    if tf + tw > 0 then
        log("smoothed underground: floors=%d walls=%d", tf, tw)
    end
end

-- ============================================================================
-- VIEW HELPER
-- ============================================================================

-- Returns true when the adventure view is the active screen.
local function is_dungeon_view()
    if not df.viewscreen_dungeonmodest then return false end
    local vs = dfhack.gui.getCurViewscreen and dfhack.gui.getCurViewscreen()
    return vs ~= nil and vs._type == df.viewscreen_dungeonmodest
end

-- ============================================================================
-- BFS FLOOD-FILL
-- ============================================================================

local function block_key(bx, by, bz)
    return (bx / 16) * 4000000 + (by / 16) * 1000 + bz
end

local function bfs_reset()
    S.bfs_queue = {}
    S.bfs_head  = 1
    S.bfs_tail  = 0
    S.bfs_seen  = {}
    S.bfs_done  = {}
end

local function bfs_enqueue(bx, by, bz)
    local k = block_key(bx, by, bz)
    if S.bfs_seen[k] or S.bfs_done[k] then return end
    S.bfs_seen[k]           = true
    S.bfs_tail              = S.bfs_tail + 1
    S.bfs_queue[S.bfs_tail] = {bx, by, bz}
end

-- Processes up to BLOCKS_PER_TICK entries from the front of the BFS queue.
local function bfs_step()
    if S.bfs_head > S.bfs_tail then return end
    local map        = df.global.world.map
    local limit      = math.min(S.bfs_head + BLOCKS_PER_TICK - 1, S.bfs_tail)
    local tf, tw     = 0, 0
    local pbx, pby, pbz = player_block_pos()
    local in_dungeon = is_dungeon_view()

    for i = S.bfs_head, limit do
        local entry      = S.bfs_queue[i]
        S.bfs_queue[i]   = nil                        -- release reference
        local bx, by, bz = entry[1], entry[2], entry[3]
        local k          = block_key(bx, by, bz)
        S.bfs_seen[k]    = nil

        local block = dfhack.maps.getTileBlock(bx, by, bz)
        if block then
            S.bfs_done[k] = true
            local in_view = in_dungeon and pbx ~= nil
                and math.abs(bx - pbx) / 16 <= VISIBLE_BLOCK_RADIUS
                and math.abs(by - pby) / 16 <= VISIBLE_BLOCK_RADIUS
                and math.abs(bz - pbz) <= 1
            local has_non_open, has_non_wall
            if not in_view then
                local f, w, nno, nnw = scan_block(block, false, true)
                tf = tf + f; tw = tw + w
                has_non_open = nno
                has_non_wall = nnw
            else
                has_non_open = false
                has_non_wall = false
                for lx = 0, 15 do
                    for ly = 0, 15 do
                        local a = df.tiletype.attrs[block.tiletype[lx][ly]]
                        if a then
                            if a.shape ~= SHAPE_OPEN_SPACE then has_non_open = true end
                            if a.shape ~= SHAPE_WALL        then has_non_wall = true end
                        end
                        if has_non_open and has_non_wall then goto bfs_analyze_done end
                    end
                end
                ::bfs_analyze_done::
            end

            if bx >= 16              then bfs_enqueue(bx - 16, by,     bz) end
            if bx + 16 < map.x_count then bfs_enqueue(bx + 16, by,     bz) end
            if by >= 16              then bfs_enqueue(bx,     by - 16,  bz) end
            if by + 16 < map.y_count then bfs_enqueue(bx,     by + 16,  bz) end
            if has_non_open and bz + 1 < map.z_count then bfs_enqueue(bx, by, bz + 1) end
            if has_non_wall and bz > 0               then bfs_enqueue(bx, by, bz - 1) end
        end
    end

    S.bfs_head = limit + 1
    if tf + tw > 0 then
        log("smoothed: floors=%d walls=%d", tf, tw)
    end
end

-- ============================================================================
-- PER-FRAME SMOOTH  (beats the renderer for normal adventure walking)
-- ============================================================================

local function frame_smooth_tick(gen)
    if not S.watcher_enabled    then return end
    if gen ~= S.frame_gen       then return end
    if dfhack.isMapLoaded() and is_dungeon_view() and not is_player_map() then
        local adv = dfhack.world.getAdventurer and dfhack.world.getAdventurer()
        if adv and adv.pos then
            local px, py, pz = adv.pos.x, adv.pos.y, adv.pos.z
            local lp = S.last_frame_pos
            if not lp or lp[1] ~= px or lp[2] ~= py or lp[3] ~= pz then
                smooth_visible_area()
                S.last_frame_pos = {px, py, pz}
            end
        end
    end
    dfhack.timeout(1, 'frames', function() frame_smooth_tick(gen) end)
end

-- ============================================================================
-- VIEWSCREEN HOOK  (fast-travel / menu-exit detection)
-- ============================================================================

-- Called on every SC_VIEWSCREEN_CHANGED
local function on_enter_dungeon_view()
    if not S.watcher_enabled    then return end
    if not dfhack.isMapLoaded() then return end
    if is_player_map()          then return end
    if not is_dungeon_view()    then return end

    local cur_count = #df.global.world.map.map_blocks
    if cur_count ~= S.bfs_block_count then
        S.bfs_block_count = cur_count
        bfs_reset()
    end

    -- Synchronously smooth everything the player will see before the first frame renders.
    smooth_visible_area()

    local adv = dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if adv and adv.pos then
        local px, py, pz = adv.pos.x, adv.pos.y, adv.pos.z
        bfs_enqueue(px - (px % 16), py - (py % 16), pz)
    end
    -- Six steps (~120 blocks) pre-smooth the ring just outside the visible radius.
    for _ = 1, 6 do bfs_step() end
end

local function register_viewscreen_hook()
    if not SC_VIEWSCREEN_CHANGED then return end
    dfhack.onStateChange["smoothfloor_vschange"] = function(sc)
        if sc == SC_VIEWSCREEN_CHANGED then pcall(on_enter_dungeon_view) end
    end
end

local function unregister_viewscreen_hook()
    dfhack.onStateChange["smoothfloor_vschange"] = nil
end

-- ============================================================================
-- WATCHER
-- ============================================================================

local function stop_watcher()
    dfhack.timeout_active(S.current_timeout_id, nil)
    S.current_timeout_id = -1
    S.watcher_enabled    = false
    S.scan_gen           = S.scan_gen + 1
    S.frame_gen          = S.frame_gen + 1
    S.last_frame_pos     = nil
end

-- Fires every SCAN_INTERVAL_TICKS ticks.
-- Fortress mode: scans newly-revealed blocks as the map grows.
-- Adventure mode: seeds BFS from the adventurer's current block and drains it.
local function scan_tick(gen)
    S.current_timeout_id = -1
    if not S.watcher_enabled  then return end
    if gen ~= S.scan_gen      then return end
    if not dfhack.isMapLoaded() then
        S.current_timeout_id = dfhack.timeout(SCAN_INTERVAL_TICKS, 'ticks', function() scan_tick(gen) end)
        return
    end

    if is_player_map() then
        local blocks    = df.global.world.map.map_blocks
        local cur_count = #blocks
        if cur_count > S.bfs_block_count then
            local tf, tw = 0, 0
            for i = S.bfs_block_count, cur_count - 1 do
                local block = blocks[i]
                if not block.designation[0][0].subterranean then
                    local f, w = scan_block(block, false)
                    tf = tf + f; tw = tw + w
                end
            end
            if tf + tw > 0 then
                log("smoothed: floors=%d walls=%d", tf, tw)
            end
            S.bfs_block_count = cur_count
        end
        S.current_timeout_id = dfhack.timeout(SCAN_INTERVAL_TICKS, 'ticks', function() scan_tick(gen) end)
        return
    end

    -- Adventure mode: BFS flood-fill from adventurer.
    local cur_count = #df.global.world.map.map_blocks
    if cur_count < S.bfs_block_count then
        -- Chunks were unloaded (fast travel handled via viewscreen hook, but catch it here too).
        bfs_reset()
    end
    S.bfs_block_count = cur_count

    if is_dungeon_view() then smooth_visible_area() end

    local adv = dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if adv and adv.pos then
        local px, py, pz = adv.pos.x, adv.pos.y, adv.pos.z
        local bx = px - (px % 16)
        local by = py - (py % 16)
        local k  = block_key(bx, by, pz)
        S.bfs_done[k] = nil
        S.bfs_seen[k] = nil
        bfs_enqueue(bx, by, pz)
    end

    bfs_step()
    S.current_timeout_id = dfhack.timeout(SCAN_INTERVAL_TICKS, 'ticks', function() scan_tick(gen) end)
end

local function start_watcher()
    if S.watcher_enabled then return end
    dfhack.timeout_active(S.current_timeout_id, nil)
    S.watcher_enabled    = true
    S.scan_gen           = S.scan_gen + 1
    S.frame_gen          = S.frame_gen + 1
    S.last_frame_pos     = nil
    frame_smooth_tick(S.frame_gen)
    scan_tick(S.scan_gen)
end

-- ============================================================================
-- COMMANDS
-- ============================================================================

local args = { ... }
local cmd  = args[1] or "enable"

if cmd == "enable" then
    if not smooth_inorganic_cache then build_inorganic_cache() end
    register_viewscreen_hook()
    if dfhack.isMapLoaded() and is_player_map() then
        scan_all_subterranean()
        local blocks = df.global.world.map.map_blocks
        local n      = #blocks
        local tf, tw = 0, 0
        for i = 0, n - 1 do
            local block = blocks[i]
            if not block.designation[0][0].subterranean then
                local f, w = scan_block(block, false)
                tf = tf + f; tw = tw + w
            end
        end
        if tf + tw > 0 then
            log("smoothed: floors=%d walls=%d", tf, tw)
        end
        S.bfs_block_count = n
    end
    start_watcher()
elseif cmd == "force" then
    if not smooth_inorganic_cache then build_inorganic_cache() end
    if dfhack.isMapLoaded() then
        local blocks = df.global.world.map.map_blocks
        local tf, tw = 0, 0
        for i = 0, #blocks - 1 do
            local f, w = scan_block(blocks[i], true, true)
            tf = tf + f; tw = tw + w
        end
        if tf + tw > 0 then
            log("smoothed: floors=%d walls=%d", tf, tw)
        end
        bfs_reset()
        S.bfs_block_count = #blocks
    end
elseif cmd == "disable" then
    unregister_viewscreen_hook()
    stop_watcher()
    smooth_inorganic_cache = nil
    bfs_reset()
    S.bfs_block_count = 0
elseif cmd == "status" then
    local n = 0; for _ in pairs(smooth_stone_wall_by_suffix) do n = n + 1 end
    log("watcher=%s timeout_active=%s cache=%s floor_tt=%s wall_variants=%d queue=%d",
        tostring(S.watcher_enabled),
        tostring(dfhack.timeout_active(S.current_timeout_id)),
        tostring(smooth_inorganic_cache ~= nil),
        tostring(SMOOTH_FLOOR_TT),
        n,
        math.max(0, S.bfs_tail - S.bfs_head + 1))
else
    log("Usage: ruins_smoothfloor [enable|disable|force|status]")
end
