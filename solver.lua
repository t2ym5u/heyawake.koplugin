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
-- There is no trial tier ("shade this cell and see what breaks"): that is
-- guessing, and no puzzle may need it. Difficulty comes from how much room
-- analysis a puzzle takes (Solver.grade).
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
-- (read-only) by every context, as the generator builds many. Alongside the
-- lists, the same neighbours flat (cell i's are nflat[4i-3 .. 4i-4+deg[i]]),
-- for ruleConnect's inner loop; and the rows and columns as cell lists.
local nbr_cache = {}
local function neighbours(n)
    local g = nbr_cache[n]
    if g then return g.nbr, g end
    local nbr, nflat, deg = {}, {}, {}
    for r = 1, n do
        for c = 1, n do
            local i = (r - 1) * n + c
            local l = {}
            if r > 1 then l[#l + 1] = i - n end
            if r < n then l[#l + 1] = i + n end
            if c > 1 then l[#l + 1] = i - 1 end
            if c < n then l[#l + 1] = i + 1 end
            nbr[i] = l
            deg[i] = #l
            for m = 1, #l do nflat[4 * i - 4 + m] = l[m] end
        end
    end
    local lines = {}
    for r = 1, n do
        local row = {}
        for c = 1, n do row[c] = (r - 1) * n + c end
        lines[#lines + 1] = row
    end
    for c = 1, n do
        local col = {}
        for r = 1, n do col[r] = (r - 1) * n + c end
        lines[#lines + 1] = col
    end
    g = { nbr = nbr, nflat = nflat, deg = deg, lines = lines, windows = {} }
    nbr_cache[n] = g
    return nbr, g
end

function Solver.buildContext(n, rooms)
    local N = n * n
    local nbr, g = neighbours(n)
    local ctx = { n = n, N = N, rooms = rooms, nbr = nbr, nflat = g.nflat, deg = g.deg,
                  room_of = {}, room_cells = {}, windows = {}, cell_windows = {},
                  stamp = 0, room_seen = {}, win_seen = {} }
    local room_of, cell_windows, windows = ctx.room_of, ctx.cell_windows, ctx.windows
    for i = 1, N do cell_windows[i] = {} end

    for k, room in ipairs(rooms) do
        local cells = {}
        for r = room.r1, room.r2 do
            for c = room.c1, room.c2 do
                local i = (r - 1) * n + c
                room_of[i] = k
                cells[#cells + 1] = i
            end
        end
        ctx.room_cells[k] = cells
    end

    -- A white line through three rooms crosses two consecutive borders, so
    -- for every pair of consecutive borders on a row (or column) the cells
    -- from just before the first to just after the second need one shade.
    -- (Window cell lists are shared, read-only, by every context of the size.)
    local win_cache = g.windows
    local borders = {}
    for li, cells in ipairs(g.lines) do
        local nb = 0
        for p = 1, n - 1 do
            if room_of[cells[p]] ~= room_of[cells[p + 1]] then
                nb = nb + 1
                borders[nb] = p
            end
        end
        for b = 1, nb - 1 do
            local p1, p2 = borders[b], borders[b + 1] + 1
            local key = (li * (n + 1) + p1) * (n + 1) + p2
            local w = win_cache[key]
            if not w then
                w = {}
                for p = p1, p2 do w[#w + 1] = cells[p] end
                win_cache[key] = w
            end
            local wk = #windows + 1
            windows[wk] = w
            for m = 1, #w do
                local cw = cell_windows[w[m]]
                cw[#cw + 1] = wk
            end
        end
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
-- through setv(R, i, v), which records them in R, the propagation's run
-- record (see Solver.propagate). One module-level setter rather than a
-- closure per propagation: LuaJIT ties compiled code to a closure's
-- identity, so a fresh closure per call kept it compiling new traces until
-- its machine-code area filled up and had to be flushed, many times per
-- puzzle.
-- ---------------------------------------------------------------------------

local function setv(R, i, v)
    local state = R.state
    local cur = state[i]
    if cur == UNKNOWN then
        state[i] = v
        R.changed = true
        local pending = R.pending
        pending[#pending + 1] = i
        local k = R.room_of[i]
        R.room_dirty[k] = true
        local tier = R.cur_tier
        local log = R.log
        if log then log[#log + 1] = { i = i, value = v, tier = tier, round = R.round } end
        local stats = R.stats
        if stats and tier == 2 then
            -- One room analysis = one room deciding cells in one pass.
            local key = R.round * (R.nrooms + 1) + k
            if not stats[key] then stats[key] = true; stats.steps = stats.steps + 1 end
        end
        if tier > R.max_tier then R.max_tier = tier end
    elseif cur ~= v then
        R.conflict = true
    end
end

-- Tier 1, room saturation for room k.
local function basicRoom(ctx, state, R, k)
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
            if state[cells[m]] == UNKNOWN then setv(R, cells[m], fill) end
        end
    end
    return true
end

-- Tier 1, three-room line: window w needs a shaded cell.
local function basicWindow(state, R, w)
    local open, last = 0, nil
    for m = 1, #w do
        local i = w[m]
        local v = state[i]
        if v == SHADED then return true end
        if v == UNKNOWN then open = open + 1; last = i end
    end
    if open == 0 then return false end
    if open == 1 then setv(R, last, SHADED) end
    return true
end

-- Tier 1: adjacency, room saturation, three-room lines. With `cells` (the
-- cells decided since the last call, which left a fixpoint), only what those
-- cells touch is looked at: nothing else can have anything new to say.
-- Without it, everything is.
local function ruleBasic(ctx, state, R, cells)
    local nbr = ctx.nbr
    if not cells then
        for i = 1, ctx.N do
            if state[i] == SHADED then
                local nb = nbr[i]
                for m = 1, #nb do
                    local j = nb[m]
                    local v = state[j]
                    if v == SHADED then return false end
                    if v == UNKNOWN then setv(R, j, WHITE) end
                end
            end
        end
        for k = 1, #ctx.rooms do
            if not basicRoom(ctx, state, R, k) then return false end
        end
        local windows = ctx.windows
        for k = 1, #windows do
            if not basicWindow(state, R, windows[k]) then return false end
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
                if v == UNKNOWN then setv(R, j, WHITE) end
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
            if not basicRoom(ctx, state, R, k) then return false end
        end
    end
    local windows, cell_windows, win_seen = ctx.windows, ctx.cell_windows, ctx.win_seen
    for c = 1, #cells do
        local cw = cell_windows[cells[c]]
        for m = 1, #cw do
            local k = cw[m]
            if win_seen[k] ~= stamp then
                win_seen[k] = stamp
                if not basicWindow(state, R, windows[k]) then return false end
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
local function ruleConnect(ctx, state, R)
    local N = ctx.N
    local root
    for i = 1, N do
        if state[i] == WHITE then root = i; break end
    end
    if not root then return true end

    -- Flat arrays and an explicit stack pointer: this runs at every step of
    -- the generator's solves and of the solution counter, so it is the
    -- solver's hot loop. The arrays live in the
    -- context and are reused (nothing here calls back into the solver).
    local disc, low, wsub, parent, iter = ctx.cc_disc, ctx.cc_low, ctx.cc_wsub, ctx.cc_parent, ctx.cc_iter
    local stack, must_white = ctx.cc_stack, ctx.cc_mw
    if not disc then
        disc, low, wsub, parent, iter, stack, must_white = {}, {}, {}, {}, {}, {}, {}
        ctx.cc_disc, ctx.cc_low, ctx.cc_wsub, ctx.cc_parent, ctx.cc_iter = disc, low, wsub, parent, iter
        ctx.cc_stack, ctx.cc_mw = stack, must_white
    end
    local nflat, deg = ctx.nflat, ctx.deg
    for i = 1, N do disc[i] = 0 end
    local time = 1
    disc[root], low[root], wsub[root], parent[root], iter[root] = 1, 1, 1, 0, 1
    stack[1] = root
    local sp, nmw = 1, 0
    while sp > 0 do
        local v = stack[sp]
        local k = iter[v]
        if k <= deg[v] then
            iter[v] = k + 1
            local u = nflat[4 * v - 4 + k]
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
            if v == UNKNOWN then setv(R, i, SHADED) end
        end
    end
    for m = 1, nmw do
        local p = must_white[m]
        if state[p] == UNKNOWN then setv(R, p, WHITE) end
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
-- The enumeration for ruleRooms: places `need` shades on open[1..nopen]
-- with no two touching, counting in hits[i] the placements that shade i.
-- An explicit stack rather than recursion (LuaJIT compiles a plain loop far
-- better): it visits the same nodes in the same order, and counts them
-- exactly as a recursive call per node would. Returns the number of
-- placements, or nil if it ran past ROOM_ENUM_BUDGET nodes. `W` holds the
-- working arrays (taken is left all nil).
local function enumerate(W, nbr, nopen, need)
    local open, hits, taken, chosen = W.open, W.hits, W.taken, W.chosen
    local f_idx, f_left, f_stage = W.f_idx, W.f_left, W.f_stage
    local nchosen, total, nodes = 0, 0, 0
    local sp = 1
    f_idx[1], f_left[1], f_stage[1] = 1, need, 0
    while sp > 0 do
        local idx, left, stage = f_idx[sp], f_left[sp], f_stage[sp]
        if stage == 0 then
            nodes = nodes + 1
            if nodes > ROOM_ENUM_BUDGET then
                for m = 1, nchosen do taken[chosen[m]] = nil end
                return nil
            end
            if left == 0 then
                total = total + 1
                for m = 1, nchosen do
                    local i = chosen[m]
                    hits[i] = hits[i] + 1
                end
                sp = sp - 1
            elseif nopen - idx + 1 < left then
                sp = sp - 1
            else
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
                    f_stage[sp] = 1
                    sp = sp + 1
                    f_idx[sp], f_left[sp], f_stage[sp] = idx + 1, left - 1, 0
                else
                    f_stage[sp] = 2
                    sp = sp + 1
                    f_idx[sp], f_left[sp], f_stage[sp] = idx + 1, left, 0
                end
            end
        elseif stage == 1 then
            -- Back from the branch that shaded open[idx]: now without it.
            nchosen = nchosen - 1
            taken[open[idx]] = nil
            f_stage[sp] = 2
            sp = sp + 1
            f_idx[sp], f_left[sp], f_stage[sp] = idx + 1, left, 0
        else
            sp = sp - 1
        end
    end
    return total
end

local function ruleRooms(ctx, state, R, dirty)
    local nbr = ctx.nbr
    -- The enumeration's working set, kept in the context and shared by
    -- every room.
    local W = ctx.enum_w
    if not W then
        W = { open = {}, hits = {}, taken = {}, chosen = {}, f_idx = {}, f_left = {}, f_stage = {} }
        ctx.enum_w = W
    end
    local open, hits = W.open, W.hits
    local nopen = 0
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
                local total = enumerate(W, nbr, nopen, need)
                if total then
                    if total == 0 then return false end
                    for m = 1, #cells do
                        local i = cells[m]
                        if state[i] == UNKNOWN then
                            local h = hits[i]
                            if h == total then setv(R, i, SHADED)
                            elseif h == 0 then setv(R, i, WHITE) end
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

-- Applies the rules up to `cap` (1 or 2; more is the same as 2) to a
-- fixpoint, always trying the lowest tier first. Mutates `state`. Returns ok
-- (false = contradiction), the highest tier that produced a deduction, and
-- the ordered list of deductions ({ i, value, tier, round }; `round` counts
-- the tier-2 passes so far); pass log = false to skip keeping that list.
-- `seeds`, optional: the cells just decided in a state that was otherwise a
-- fixpoint of these rules (a search branch). Only what they touch is looked
-- at first, which is what keeps searches cheap; the result is the same as a
-- full pass.
function Solver.propagate(ctx, state, cap, log, seeds, stats)
    cap = cap or 2
    if log == nil then log = {} end
    local room_of = ctx.room_of
    -- The run record setv() writes to. pending: cells decided since
    -- ruleBasic last looked (nil: look at everything); room_dirty: rooms
    -- ruleRooms has to enumerate again.
    local R = { state = state, changed = false, conflict = false, pending = nil,
                room_dirty = {}, room_of = room_of, log = log, stats = stats,
                cur_tier = 1, round = 0, max_tier = 0, nrooms = #ctx.rooms }
    local room_dirty = R.room_dirty
    if seeds then
        local pending = {}
        for m = 1, #seeds do
            pending[m] = seeds[m]
            room_dirty[room_of[seeds[m]]] = true
        end
        R.pending = pending
    else
        for k = 1, #ctx.rooms do room_dirty[k] = true end
    end

    while true do
        R.changed = false
        R.cur_tier = 1
        local cells = R.pending
        R.pending = {}
        if not ruleBasic(ctx, state, R, cells) or R.conflict then return false, R.max_tier, log end
        if not R.changed then
            R.cur_tier = 1
            if not ruleConnect(ctx, state, R) or R.conflict then return false, R.max_tier, log end
        end
        if not R.changed and cap >= 2 then
            R.cur_tier = 2
            R.round = R.round + 1
            if not ruleRooms(ctx, state, R, room_dirty) or R.conflict then return false, R.max_tier, log end
        end
        if not R.changed then break end
    end
    return true, R.max_tier, log
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

-- Grades a puzzle: like solve() at tier 2 from scratch, plus the amount of
-- room analysis it took -- the number of room analyses that decided at least
-- one cell (a room counted once per tier-2 pass). Returns status, max tier,
-- that count, and the final state.
function Solver.grade(ctx)
    local state = {}
    for i = 1, ctx.N do state[i] = UNKNOWN end
    local stats = { steps = 0 }
    local ok, max_tier = Solver.propagate(ctx, state, 2, false, nil, stats)
    local steps = stats.steps
    if not ok then return "invalid", max_tier, steps, state end
    for i = 1, ctx.N do
        if state[i] == UNKNOWN then return "stuck", max_tier, steps, state end
    end
    if not Solver.isValidSolution(ctx, state) then return "invalid", max_tier, steps, state end
    return "solved", max_tier, steps, state
end

-- ---------------------------------------------------------------------------
-- Brute-force counter (propagation + branching), independent of how far the
-- logic gets. Returns the number of solutions found, capped at `limit`.
-- ---------------------------------------------------------------------------

-- One node of the counter: propagates st (from `seed`, the cell just
-- branched on), then branches shaded-first on its first unknown cell.
-- Returns the count so far. A plain function rather than a closure made per
-- count (see setv).
local function countFrom(ctx, limit, st, seed, count)
    if count >= limit then return count end
    if not Solver.propagate(ctx, st, 2, false, seed and { seed }) then return count end
    local N = ctx.N
    local pick
    for i = 1, N do
        if st[i] == UNKNOWN then pick = i; break end
    end
    if not pick then
        if Solver.isValidSolution(ctx, st) then count = count + 1 end
        return count
    end
    for b = 1, 2 do
        local child = copyState(st, N)
        child[pick] = b == 1 and SHADED or WHITE
        count = countFrom(ctx, limit, child, pick, count)
        if count >= limit then return count end
    end
    return count
end

function Solver.countSolutions(ctx, limit, state)
    limit = limit or 2
    local N = ctx.N
    local start = {}
    for i = 1, N do start[i] = state and state[i] or UNKNOWN end
    return countFrom(ctx, limit, start, nil, 0)
end

-- Building a context runs interpreted: it is called for every layout the
-- generator tries, and its many small one-off loops kept LuaJIT compiling
-- traces it would barely use (with board.lua's generator steps, which run
-- interpreted for the same reason, the worst cases on a desktop about halve:
-- 10x10 Hard ~0.22 s to ~0.1 s; the rules themselves stay compiled).
if jit then jit.off(Solver.buildContext, true) end

return Solver
