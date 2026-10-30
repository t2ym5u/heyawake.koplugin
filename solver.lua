-- ---------------------------------------------------------------------------
-- solver.lua — Heyawake logic solver and solution counter.
--
-- Pure Lua, no KOReader dependency, so the generator, the Hint button and the
-- unit tests all share one implementation of the rules.
--
-- Cells are addressed flat: i = (r - 1) * n + c. A solver state is an array
-- of UNKNOWN / SHADED / WHITE per cell.
--
-- Deductions come in tiers, the way a person meets them:
--   tier 1  a shaded cell's neighbours are white; a room that has all its
--           shaded cells has only white left (and the reverse when every
--           unknown is needed); a three-room line with one cell left open
--           must be shaded there; a cell whose shading would cut white cells
--           apart is white, and a pocket no white cell can reach is shaded.
--   tier 2  room analysis: every way of placing a room's remaining shaded
--           cells without them touching agrees on a cell.
--   tier 3  trial: shading (or whitening) a cell leads, by tiers 1-2, to a
--           contradiction, so it takes the other value.
-- Every deduction is forced, so a puzzle the solver finishes has exactly one
-- solution; the generator relies on that, and countSolutions() cross-checks
-- it in the tests.
-- ---------------------------------------------------------------------------

local UNKNOWN, SHADED, WHITE = 0, 1, 2

local Solver = {
    UNKNOWN = UNKNOWN,
    SHADED  = SHADED,
    WHITE   = WHITE,
}

-- Room enumerations bigger than this give up (no deduction, still sound).
local ROOM_ENUM_BUDGET = 20000

-- ---------------------------------------------------------------------------
-- Context: everything about a puzzle that does not change while solving.
--   rooms = { { r1, c1, r2, c2, clue = k or nil }, ... }
-- ---------------------------------------------------------------------------

-- Neighbour lists depend on the size only: built once per size and shared
-- (read-only) by every context, as the generator builds many.
local nbr_cache = {}
local function neighbours(n)
    local nbr = nbr_cache[n]
    if nbr then return nbr end
    nbr = {}
    for r = 1, n do
        for c = 1, n do
            local i = (r - 1) * n + c
            local l = {}
            if r > 1 then l[#l + 1] = i - n end
            if r < n then l[#l + 1] = i + n end
            if c > 1 then l[#l + 1] = i - 1 end
            if c < n then l[#l + 1] = i + 1 end
            nbr[i] = l
        end
    end
    nbr_cache[n] = nbr
    return nbr
end

function Solver.buildContext(n, rooms)
    local N = n * n
    local ctx = { n = n, N = N, rooms = rooms, nbr = neighbours(n), room_of = {},
                  room_cells = {}, windows = {}, cell_windows = {},
                  stamp = 0, room_seen = {}, win_seen = {} }
    for i = 1, N do ctx.cell_windows[i] = {} end

    for k, room in ipairs(rooms) do
        local cells = {}
        for r = room.r1, room.r2 do
            for c = room.c1, room.c2 do
                local i = (r - 1) * n + c
                ctx.room_of[i] = k
                cells[#cells + 1] = i
            end
        end
        ctx.room_cells[k] = cells
    end

    -- A white line through three rooms crosses two consecutive borders, so
    -- for every pair of consecutive borders on a row (or column) the cells
    -- from just before the first to just after the second need one shade.
    local function addLine(cells)
        local borders = {}
        for p = 1, #cells - 1 do
            if ctx.room_of[cells[p]] ~= ctx.room_of[cells[p + 1]] then
                borders[#borders + 1] = p
            end
        end
        for b = 1, #borders - 1 do
            local w = {}
            for p = borders[b], borders[b + 1] + 1 do w[#w + 1] = cells[p] end
            ctx.windows[#ctx.windows + 1] = w
            for _, i in ipairs(w) do
                local cw = ctx.cell_windows[i]
                cw[#cw + 1] = #ctx.windows
            end
        end
    end
    for r = 1, n do
        local row = {}
        for c = 1, n do row[c] = (r - 1) * n + c end
        addLine(row)
    end
    for c = 1, n do
        local col = {}
        for r = 1, n do col[r] = (r - 1) * n + c end
        addLine(col)
    end
    return ctx
end

-- ---------------------------------------------------------------------------
-- Full validity of a completely decided state (no UNKNOWN left).
-- ---------------------------------------------------------------------------

local function whitesConnected(ctx, state)
    local start, total = nil, 0
    for i = 1, ctx.N do
        if state[i] ~= SHADED then
            total = total + 1
            start = start or i
        end
    end
    if not start then return true end
    local seen, stack, count = { [start] = true }, { start }, 1
    while #stack > 0 do
        local i = stack[#stack]
        stack[#stack] = nil
        for _, j in ipairs(ctx.nbr[i]) do
            if state[j] ~= SHADED and not seen[j] then
                seen[j] = true
                count = count + 1
                stack[#stack + 1] = j
            end
        end
    end
    return count == total
end
Solver.whitesConnected = whitesConnected

-- `shaded` may be a solver state or a boolean array; anything not SHADED/true
-- counts as white.
function Solver.isValidSolution(ctx, state)
    local st = {}
    for i = 1, ctx.N do
        local v = state[i]
        st[i] = (v == SHADED or v == true) and SHADED or WHITE
    end
    for i = 1, ctx.N do
        if st[i] == SHADED then
            for _, j in ipairs(ctx.nbr[i]) do
                if st[j] == SHADED then return false end
            end
        end
    end
    for k, room in ipairs(ctx.rooms) do
        if room.clue then
            local s = 0
            for _, i in ipairs(ctx.room_cells[k]) do
                if st[i] == SHADED then s = s + 1 end
            end
            if s ~= room.clue then return false end
        end
    end
    for _, w in ipairs(ctx.windows) do
        local any = false
        for _, i in ipairs(w) do
            if st[i] == SHADED then any = true; break end
        end
        if not any then return false end
    end
    return whitesConnected(ctx, st)
end

-- ---------------------------------------------------------------------------
-- Rules. Each returns false on contradiction, true otherwise; deductions go
-- through `set`, which records them.
-- ---------------------------------------------------------------------------

-- Tier 1, room saturation for room k.
local function basicRoom(ctx, state, set, k)
    local clue = ctx.rooms[k].clue
    if not clue then return true end
    local s, u = 0, 0
    local cells = ctx.room_cells[k]
    for m = 1, #cells do
        local v = state[cells[m]]
        if v == SHADED then s = s + 1 elseif v == UNKNOWN then u = u + 1 end
    end
    if s > clue or s + u < clue then return false end
    if u > 0 and (s == clue or s + u == clue) then
        local fill = (s == clue) and WHITE or SHADED
        for m = 1, #cells do
            if state[cells[m]] == UNKNOWN then set(cells[m], fill) end
        end
    end
    return true
end

-- Tier 1, three-room line: window w needs a shaded cell.
local function basicWindow(state, set, w)
    local open, last = 0, nil
    for m = 1, #w do
        local i = w[m]
        local v = state[i]
        if v == SHADED then return true end
        if v == UNKNOWN then open = open + 1; last = i end
    end
    if open == 0 then return false end
    if open == 1 then set(last, SHADED) end
    return true
end

-- Tier 1: adjacency, room saturation, three-room lines. With `cells` (the
-- cells decided since the last call, which left a fixpoint), only what those
-- cells touch is looked at: nothing else can have anything new to say.
-- Without it, everything is.
local function ruleBasic(ctx, state, set, cells)
    local nbr = ctx.nbr
    if not cells then
        for i = 1, ctx.N do
            if state[i] == SHADED then
                local nb = nbr[i]
                for m = 1, #nb do
                    local j = nb[m]
                    local v = state[j]
                    if v == SHADED then return false end
                    if v == UNKNOWN then set(j, WHITE) end
                end
            end
        end
        for k = 1, #ctx.rooms do
            if not basicRoom(ctx, state, set, k) then return false end
        end
        local windows = ctx.windows
        for k = 1, #windows do
            if not basicWindow(state, set, windows[k]) then return false end
        end
        return true
    end
    for c = 1, #cells do
        local i = cells[c]
        if state[i] == SHADED then
            local nb = nbr[i]
            for m = 1, #nb do
                local j = nb[m]
                local v = state[j]
                if v == SHADED then return false end
                if v == UNKNOWN then set(j, WHITE) end
            end
        end
    end
    -- Each room and line once per call: ctx.seen holds the number of the
    -- call that last looked at it (a stamp, so nothing needs clearing).
    local stamp = ctx.stamp + 1
    ctx.stamp = stamp
    local room_of, room_seen = ctx.room_of, ctx.room_seen
    for c = 1, #cells do
        local k = room_of[cells[c]]
        if room_seen[k] ~= stamp then
            room_seen[k] = stamp
            if not basicRoom(ctx, state, set, k) then return false end
        end
    end
    local windows, cell_windows, win_seen = ctx.windows, ctx.cell_windows, ctx.win_seen
    for c = 1, #cells do
        local cw = cell_windows[cells[c]]
        for m = 1, #cw do
            local k = cw[m]
            if win_seen[k] ~= stamp then
                win_seen[k] = stamp
                if not basicWindow(state, set, windows[k]) then return false end
            end
        end
    end
    return true
end

-- Tier 1 (second half): connectivity, via articulation points of the non-shaded graph
-- rooted at a white cell. A non-root unknown cell v whose removal cuts off a
-- DFS subtree holding a white cell must stay white. Non-shaded cells the root
-- cannot reach must be shaded; a white cell it cannot reach is a
-- contradiction.
local function ruleConnect(ctx, state, set)
    local N, nbr = ctx.N, ctx.nbr
    local root
    for i = 1, N do
        if state[i] == WHITE then root = i; break end
    end
    if not root then return true end

    -- Flat arrays and an explicit stack pointer: this runs inside every trial
    -- of tier 3, so it is the solver's hot loop. The arrays live in the
    -- context and are reused (nothing here calls back into the solver).
    local disc, low, wsub, parent, iter = ctx.cc_disc, ctx.cc_low, ctx.cc_wsub, ctx.cc_parent, ctx.cc_iter
    if not disc then
        disc, low, wsub, parent, iter = {}, {}, {}, {}, {}
        ctx.cc_disc, ctx.cc_low, ctx.cc_wsub, ctx.cc_parent, ctx.cc_iter = disc, low, wsub, parent, iter
    end
    for i = 1, N do disc[i] = 0 end
    local time = 1
    disc[root], low[root], wsub[root], parent[root], iter[root] = 1, 1, 1, 0, 1
    local stack, sp = { root }, 1
    local must_white, nmw = {}, 0
    while sp > 0 do
        local v = stack[sp]
        local nb = nbr[v]
        local k = iter[v]
        if k <= #nb then
            iter[v] = k + 1
            local u = nb[k]
            if state[u] ~= SHADED then
                local du = disc[u]
                if du == 0 then
                    time = time + 1
                    disc[u], low[u] = time, time
                    wsub[u] = (state[u] == WHITE) and 1 or 0
                    parent[u], iter[u] = v, 1
                    sp = sp + 1
                    stack[sp] = u
                elseif u ~= parent[v] and du < low[v] then
                    low[v] = du
                end
            end
        else
            sp = sp - 1
            local p = parent[v]
            if p ~= 0 then
                local lv = low[v]
                if lv < low[p] then low[p] = lv end
                wsub[p] = wsub[p] + wsub[v]
                if lv >= disc[p] and wsub[v] > 0 and state[p] == UNKNOWN then
                    nmw = nmw + 1
                    must_white[nmw] = p
                end
            end
        end
    end
    for i = 1, N do
        if disc[i] == 0 then
            local v = state[i]
            if v == WHITE then return false end
            if v == UNKNOWN then set(i, SHADED) end
        end
    end
    for m = 1, nmw do
        local p = must_white[m]
        if state[p] == UNKNOWN then set(p, WHITE) end
    end
    return true
end

-- Tier 2: room analysis. Enumerate every way to place the room's missing
-- shaded cells on its unknown cells with no two touching (each other or an
-- already shaded cell); a cell shaded in all of them is shaded, in none of
-- them white.
-- Only rooms in `dirty` are looked at, and their flag cleared: a room whose
-- cells have not changed since it was last enumerated gives nothing new (the
-- enumeration reads the room's own cells only, once tier 1 has whitened every
-- cell beside a shade).
local function ruleRooms(ctx, state, set, dirty)
    local nbr = ctx.nbr
    -- The enumeration's working set, shared by every room of this call (one
    -- closure per call rather than per room: this runs inside every trial).
    local open, hits, taken, chosen = {}, {}, {}, {}
    local nopen, nchosen, total, nodes, aborted = 0, 0, 0, 0, false
    local function rec(idx, left)
        if aborted then return end
        nodes = nodes + 1
        if nodes > ROOM_ENUM_BUDGET then aborted = true; return end
        if left == 0 then
            total = total + 1
            for m = 1, nchosen do
                local i = chosen[m]
                hits[i] = hits[i] + 1
            end
            return
        end
        if nopen - idx + 1 < left then return end
        local i = open[idx]
        local free = true
        local nb = nbr[i]
        for m = 1, #nb do
            if taken[nb[m]] then free = false; break end
        end
        if free then
            taken[i] = true
            nchosen = nchosen + 1
            chosen[nchosen] = i
            rec(idx + 1, left - 1)
            nchosen = nchosen - 1
            taken[i] = nil
        end
        rec(idx + 1, left)
    end
    for k, room in ipairs(ctx.rooms) do
        if room.clue and dirty[k] then
            dirty[k] = nil
            local cells = ctx.room_cells[k]
            local s, u_total = 0, 0
            nopen = 0
            for m = 1, #cells do
                local i = cells[m]
                local v = state[i]
                hits[i] = 0
                if v == SHADED then
                    s = s + 1
                elseif v == UNKNOWN then
                    u_total = u_total + 1
                    local ok = true
                    local nb = nbr[i]
                    for q = 1, #nb do
                        if state[nb[q]] == SHADED then ok = false; break end
                    end
                    if ok then nopen = nopen + 1; open[nopen] = i end
                end
            end
            local need = room.clue - s
            if need < 0 or need > nopen then return false end
            if u_total > 0 then
                total, nodes, aborted, nchosen = 0, 0, false, 0
                rec(1, need)
                if not aborted then
                    if total == 0 then return false end
                    for m = 1, #cells do
                        local i = cells[m]
                        if state[i] == UNKNOWN then
                            local h = hits[i]
                            if h == total then set(i, SHADED)
                            elseif h == 0 then set(i, WHITE) end
                        end
                    end
                end
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Propagation
-- ---------------------------------------------------------------------------

local function copyState(state, N)
    local t = {}
    for i = 1, N do t[i] = state[i] end
    return t
end
Solver.copyState = copyState

-- Applies the rules up to `cap` to a fixpoint, always trying the lowest tier
-- first. Mutates `state`. Returns ok (false = contradiction), the highest
-- tier that produced a deduction, and the ordered list of deductions
-- ({ i, value, tier }); pass log = false to skip keeping that list.
-- `seeds`, optional: the cells just decided in a state that was otherwise a
-- fixpoint of these rules (a trial, a search branch). Only what they touch
-- is looked at first, which is what keeps trials and searches cheap; the
-- result is the same as a full pass.
function Solver.propagate(ctx, state, cap, log, seeds)
    cap = cap or 3
    if log == nil then log = {} end
    local max_tier = 0
    local cur_tier = 1
    local changed = false
    local conflict = false
    local trial_from = 1
    local trial_cache = {}
    local room_of = ctx.room_of
    -- Cells decided since ruleBasic last looked (nil: look at everything),
    -- and rooms ruleRooms has to enumerate again.
    local pending, room_dirty = nil, {}
    if seeds then
        pending = {}
        for m = 1, #seeds do
            pending[m] = seeds[m]
            room_dirty[room_of[seeds[m]]] = true
        end
    else
        for k = 1, #ctx.rooms do room_dirty[k] = true end
    end
    local function set(i, v)
        if state[i] == UNKNOWN then
            state[i] = v
            changed = true
            pending[#pending + 1] = i
            room_dirty[room_of[i]] = true
            if log then log[#log + 1] = { i = i, value = v, tier = cur_tier } end
            if cur_tier > max_tier then max_tier = cur_tier end
        elseif state[i] ~= v then
            conflict = true
        end
    end

    while true do
        changed = false
        cur_tier = 1
        local cells = pending
        pending = {}
        if not ruleBasic(ctx, state, set, cells) or conflict then return false, max_tier, log end
        if not changed then
            cur_tier = 1
            if not ruleConnect(ctx, state, set) or conflict then return false, max_tier, log end
        end
        if not changed and cap >= 2 then
            cur_tier = 2
            if not ruleRooms(ctx, state, set, room_dirty) or conflict then return false, max_tier, log end
        end
        if not changed and cap >= 3 then
            cur_tier = 3
            -- Resume the scan after the last cell that gave something:
            -- cells before it already failed to, and rescanning them after
            -- every single trial deduction made hard 10x10 grids crawl.
            -- A trial that ended without contradiction is remembered with
            -- its end state: while everything known since still agrees with
            -- that state, rerunning the trial would end the same way (the
            -- rules only ever deduce more from more), so it is skipped.
            local N = ctx.N
            for step = 0, N - 1 do
                local i = (trial_from + step - 1) % N + 1
                if state[i] == UNKNOWN then
                    for v = SHADED, WHITE do
                        local key = i * 2 + v
                        local prev = trial_cache[key]
                        local still = false
                        if prev then
                            still = true
                            for j = 1, N do
                                local sj = state[j]
                                if sj ~= UNKNOWN and sj ~= prev[j] then still = false; break end
                            end
                        end
                        if not still then
                            local trial = copyState(state, N)
                            trial[i] = v
                            if Solver.propagate(ctx, trial, 2, false, { i }) then
                                trial_cache[key] = trial
                            else
                                set(i, v == SHADED and WHITE or SHADED)
                                break
                            end
                        end
                    end
                    if changed then trial_from = i % N + 1; break end
                end
            end
            if conflict then return false, max_tier, log end
        end
        if not changed then break end
    end
    return true, max_tier, log
end

-- Solves from `state` (default: nothing known) with rules up to `cap`.
-- Returns status ("solved" | "stuck" | "invalid"), the max tier used, and the
-- final state.
function Solver.solve(ctx, cap, state)
    state = state and copyState(state, ctx.N) or {}
    for i = 1, ctx.N do state[i] = state[i] or UNKNOWN end
    local ok, max_tier = Solver.propagate(ctx, state, cap, false)
    if not ok then return "invalid", max_tier, state end
    for i = 1, ctx.N do
        if state[i] == UNKNOWN then return "stuck", max_tier, state end
    end
    if not Solver.isValidSolution(ctx, state) then return "invalid", max_tier, state end
    return "solved", max_tier, state
end

-- ---------------------------------------------------------------------------
-- Brute-force counter (propagation + branching), independent of how far the
-- logic gets. Returns the number of solutions found, capped at `limit`.
-- ---------------------------------------------------------------------------

function Solver.countSolutions(ctx, limit, state)
    limit = limit or 2
    local N = ctx.N
    local count = 0
    local function rec(st, seed)
        if count >= limit then return end
        if not Solver.propagate(ctx, st, 2, false, seed and { seed }) then return end
        local pick
        for i = 1, N do
            if st[i] == UNKNOWN then pick = i; break end
        end
        if not pick then
            if Solver.isValidSolution(ctx, st) then count = count + 1 end
            return
        end
        for _, v in ipairs({ SHADED, WHITE }) do
            local child = copyState(st, N)
            child[pick] = v
            rec(child, pick)
            if count >= limit then return end
        end
    end
    local start = {}
    for i = 1, N do start[i] = state and state[i] or UNKNOWN end
    rec(start)
    return count
end

return Solver
