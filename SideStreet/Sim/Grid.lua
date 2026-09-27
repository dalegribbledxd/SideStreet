-- SideStreet grid math shared by simulation, renderer and picking.
-- Rotation R(a,b) = (-b,a) (one quarter turn). Must match tools/build_art.py.
-- Projection (view coords u,v in tiles, z in tiles): sx = (u - v)*32, sy = (u + v)*16 - z*32.
local _, SS = ...
local G = {}
SS.Grid = G

G.TILE_W, G.TILE_H, G.Z_PX = 64, 32, 32
G.DIRS = { [0] = { 0, 1 }, [1] = { -1, 0 }, [2] = { 0, -1 }, [3] = { 1, 0 } }

function G.rot(a, b, k)
    k = k % 4
    if k == 1 then return -b, a elseif k == 2 then return -a, -b elseif k == 3 then return b, -a end
    return a, b
end

function G.dirToFacing(dx, dy)
    if math.abs(dx) > math.abs(dy) then return dx > 0 and 3 or 1 end
    return dy >= 0 and 0 or 2
end

-- World cell -> view cell for view rotation r on a W x H lot.
function G.vcell(i, j, r, W, H)
    r = r % 4
    if r == 1 then return H - 1 - j, i elseif r == 2 then return W - 1 - i, H - 1 - j elseif r == 3 then return j, W - 1 - i end
    return i, j
end

-- Continuous world position -> view position.
function G.vpos(x, y, r, W, H)
    r = r % 4
    if r == 1 then return H - y, x elseif r == 2 then return W - x, H - y elseif r == 3 then return y, W - x end
    return x, y
end

-- View position -> world position (inverse of vpos).
function G.wpos(u, v, r, W, H)
    r = r % 4
    if r == 1 then return v, H - u elseif r == 2 then return W - u, H - v elseif r == 3 then return W - v, u end
    return u, v
end

function G.viewSize(r, W, H)
    if r % 2 == 1 then return H, W end
    return W, H
end

function G.project(u, v, z)
    return (u - v) * 32, (u + v) * 16 - (z or 0) * 32
end

-- Footprint cells of an object instance in world coordinates.
function G.footprint(def, o)
    local out = {}
    local fp = def.fp or { { 0, 0 } }
    for n = 1, #fp do
        local dx, dy = G.rot(fp[n][1], fp[n][2], o.f)
        out[n] = { o.x + dx, o.y + dy, fp[n][1], fp[n][2] }
    end
    return out
end

-- Wall edge key crossed when stepping from (i,j) to a 4-neighbour.
function G.edgeBetween(i, j, ni, nj)
    if ni == i + 1 then return "y:" .. ni .. ":" .. j
    elseif ni == i - 1 then return "y:" .. i .. ":" .. j
    elseif nj == j + 1 then return "x:" .. i .. ":" .. nj
    else return "x:" .. i .. ":" .. j end
end

-- Parse a wall key into axis, i, j and its two adjacent cells (a = lower side).
function G.parseEdge(key)
    local axis, i, j = key:match("^(%a):(%-?%d+):(%-?%d+)$")
    i, j = tonumber(i), tonumber(j)
    if axis == "x" then return axis, i, j, i, j - 1, i, j end
    return axis, i, j, i - 1, j, i, j
end
