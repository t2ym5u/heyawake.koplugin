local UndoStack  = require("undo_stack")
local Timer      = require("timer")
local grid_utils = require("grid_utils")
local Hint       = require("hint")

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local Solver = package.loaded[_dir .. "solver"]
if not Solver then
    Solver = assert(loadfile(_dir .. "solver.lua"))()
    package.loaded[_dir .. "solver"] = Solver
end

local emptyGrid     = grid_utils.emptyGrid
local emptyBoolGrid = grid_utils.emptyBoolGrid
local copyGrid      = grid_utils.copyGrid
local shuffle       = grid_utils.shuffle

-- The player's marks use the solver's encoding, so a board can be handed to
-- the solver as is.
local STATE_UNKNOWN   = Solver.UNKNOWN   -- 0
local STATE_BLACK     = Solver.SHADED    -- 1
local STATE_WHITE_DOT = Solver.WHITE     -- 2

local DEFAULT_N          = 6
local DEFAULT_DIFFICULTY = "easy"

-- Difficulty = the highest solver tier the puzzle may need (see solver.lua),
-- and how much room analysis (tier 2) it takes. Easy is counting, adjacency,
-- three-room lines and keeping the white cells connected; medium adds a
-- little room analysis; hard several times as much (its rooms may merge
-- up to HARD_MERGE_MAX_AREA cells). No level ever needs a trial ("shade
-- this cell and see what breaks"): that is guessing. T2_WINDOW[difficulty][n] = { min, max } room analyses (see
-- Solver.grade); the generator keeps the puzzle inside it.
local TIER_CAP = { easy = 1, medium = 2, hard = 2 }
local T2_WINDOW = {
    easy   = { [6] = { 0, 0 }, [8] = { 0, 0 }, [10] = { 0, 0 } },
    medium = { [6] = { 1, 1 }, [8] = { 1, 1 }, [10] = { 1, 1 } },
    hard   = { [6] = { 2, math.huge }, [8] = { 3, math.huge }, [10] = { 3, math.huge } },
}
local function t2Window(difficulty, n)
    local w = T2_WINDOW[difficulty] or T2_WINDOW.easy
    return w[n] or w[10]
end

-- Rooms: at most ROOM_MAX_DIM cells on a side and ROOM_MAX_AREA cells.
local ROOM_MAX_DIM  = 4
local ROOM_MAX_AREA = { [6] = 6, [8] = 8, [10] = 9 }

local MAX_ATTEMPTS     = 40   -- shaded layouts tried per puzzle
local TIER_ATTEMPTS    = 40   -- of which: tries to land in the level's window
local MAX_SPLITS       = 30   -- room cuts allowed to make a layout solvable
local SHADE_PROBABILITY = 0.4 -- chance a free cell is tried shaded first
-- The shading search is heavy-tailed: most layouts shade within a few dozen
-- nodes, the rest wander for thousands. Giving up early and trying a fresh
-- layout is far cheaper on average (measured: about 3x on 10x10) and cuts
-- the tail. SHADE_LAYOUTS bounds the fresh layouts tried per attempt.
local function shadeNodeBudget(n) return math.max(30, math.floor(n * n / 2)) end
local SHADE_LAYOUTS     = 60
local MERGE_MAX_AREA    = 12
-- Hard merges into larger rooms: more ways to place their shaded cells, so
-- more room analysis to rule them out.
local HARD_MERGE_MAX_AREA = 16
local HARD_REMOVAL_ORDERS = 2

-- ---------------------------------------------------------------------------
-- Room partition: guillotine cuts until every piece is small enough, then
-- random stops so room sizes vary. Cuts avoid 1-cell rooms when they can.
-- ---------------------------------------------------------------------------

local function partition(n)
    local max_area = ROOM_MAX_AREA[n] or 12
    local rooms = {}
    local function split(r1, c1, r2, c2)
        local h, w = r2 - r1 + 1, c2 - c1 + 1
        local area = h * w
        local must = h > ROOM_MAX_DIM or w > ROOM_MAX_DIM or area > max_area
        if not must and (area <= 2 or math.random() < 0.45) then
            rooms[#rooms + 1] = { r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
            return
        end
        local by_rows
        if h > ROOM_MAX_DIM then by_rows = true
        elseif w > ROOM_MAX_DIM then by_rows = false
        elseif h ~= w then by_rows = h > w
        else by_rows = math.random() < 0.5 end
        local len, other = by_rows and h or w, by_rows and w or h
        local cuts, fallback = {}, {}
        for k = 1, len - 1 do
            fallback[#fallback + 1] = k
            if k * other >= 2 and (len - k) * other >= 2 then cuts[#cuts + 1] = k end
        end
        if #cuts == 0 then cuts = fallback end
        local k = cuts[math.random(#cuts)]
        if by_rows then
            split(r1, c1, r1 + k - 1, c2)
            split(r1 + k, c1, r2, c2)
        else
            split(r1, c1, r2, c1 + k - 1)
            split(r1, c1 + k, r2, c2)
        end
    end
    split(1, 1, n, n)
    return rooms
end

-- ---------------------------------------------------------------------------
-- Solution shading: a randomised depth-first search over the clue-free
-- puzzle, using the solver's own propagation (no touching shades, every
-- three-room line broken, white cells connected) to prune. Each free cell is
-- tried shaded first with probability SHADE_PROBABILITY, which sets the
-- density. Returns a flat boolean array, or nil if the room layout admits no
-- shading within the node budget (a count of search nodes, never a clock).
-- ---------------------------------------------------------------------------

local function makeShading(ctx)
    local N = ctx.N
    local budget = shadeNodeBudget(ctx.n)
    local order = {}
    for i = 1, N do order[i] = i end
    shuffle(order)
    local rank, windows = {}, ctx.windows
    for k, i in ipairs(order) do rank[i] = k end
    local nodes = 0
    local function rec(st, seed)
        nodes = nodes + 1
        if nodes > budget then return nil end
        if not Solver.propagate(ctx, st, 2, false, seed and { seed }) then return nil end
        -- Fail first: branch inside the three-room line with the fewest
        -- open cells left (its earliest cell in `order`), where a dead end
        -- shows soonest; once every line has its shade, take cells in order.
        -- Measured on 10x10, this needs a third of the nodes.
        local pick, best_open
        for _, w in ipairs(windows) do
            local open, done = 0, false
            for m = 1, #w do
                local v = st[w[m]]
                if v == Solver.SHADED then done = true; break end
                if v == Solver.UNKNOWN then open = open + 1 end
            end
            if not done and (not best_open or open < best_open) then
                best_open, pick = open, nil
                for m = 1, #w do
                    local i = w[m]
                    if st[i] == Solver.UNKNOWN and (not pick or rank[i] < rank[pick]) then pick = i end
                end
            end
        end
        if not pick then
            for _, i in ipairs(order) do
                if st[i] == Solver.UNKNOWN then pick = i; break end
            end
        end
        if not pick then
            return Solver.isValidSolution(ctx, st) and st or nil
        end
        local first, second = Solver.WHITE, Solver.SHADED
        if math.random() < SHADE_PROBABILITY then first, second = second, first end
        for _, v in ipairs({ first, second }) do
            local child = Solver.copyState(st, N)
            child[pick] = v
            local res = rec(child, pick)
            if res then return res end
            if nodes > budget then return nil end
        end
        return nil
    end
    local start = {}
    for i = 1, N do start[i] = Solver.UNKNOWN end
    local st = rec(start)
    if not st then return nil end
    local shaded = {}
    for i = 1, N do shaded[i] = st[i] == Solver.SHADED end
    return shaded
end

-- ---------------------------------------------------------------------------
-- Puzzle generation.
--
-- 1. Random rooms, then a random valid shading for them (makeShading).
-- 2. Every room gets its clue. If the solver (tier 1 for easy, tier 2
--    otherwise) still gets stuck, the room of a cell it could not decide is
--    cut in two (where the shading stays valid under the new borders): more,
--    smaller rooms carry more information. Repeat until the solver finishes.
-- 3. Needless walls go again: neighbouring rooms are merged wherever the
--    solver still finishes (mergeRooms) -- fewer, larger rooms read more like
--    a printed Heyawake than the sliver rooms step 2 leaves behind.
-- 4. Clues are removed one at a time, in random order, as long as the solver
--    still finishes (for medium: without needing more room analysis than
--    its window allows).
-- 5. The puzzle is graded (Solver.grade); one inside the level's window of
--    room analyses is taken, else the closest found is kept.
-- The solver finishing proves uniqueness: each of its deductions is forced,
-- so a puzzle it completes has exactly one solution. (The test suite
-- cross-checks this with a brute-force count over many seeds; the generator
-- does not repeat it, as it costs more than everything else on 10x10 hard.)
-- Returns { rooms (with .clue), shaded (flat booleans), info }, or nil.
-- ---------------------------------------------------------------------------

local function setClues(ctx, shaded)
    for k, cells in ipairs(ctx.room_cells) do
        local s = 0
        for _, i in ipairs(cells) do if shaded[i] then s = s + 1 end end
        ctx.rooms[k].clue = s
    end
end

-- Cuts room k of `rooms` in two at a random place that keeps `shaded` a
-- valid solution. Returns the new rooms and context, or nil.
local function splitRoom(n, rooms, k, shaded)
    local room = rooms[k]
    local cuts = {}
    for r = room.r1, room.r2 - 1 do cuts[#cuts + 1] = { rows = true, at = r } end
    for c = room.c1, room.c2 - 1 do cuts[#cuts + 1] = { rows = false, at = c } end
    shuffle(cuts)
    -- One-cell rooms are legal but look like noise: cut elsewhere if possible.
    local h, w = room.r2 - room.r1 + 1, room.c2 - room.c1 + 1
    local function smallest(cut)
        if cut.rows then return math.min(cut.at - room.r1 + 1, room.r2 - cut.at) * w end
        return math.min(cut.at - room.c1 + 1, room.c2 - cut.at) * h
    end
    local good, poor = {}, {}
    for _, cut in ipairs(cuts) do
        local list = smallest(cut) >= 2 and good or poor
        list[#list + 1] = cut
    end
    for _, cut in ipairs(poor) do good[#good + 1] = cut end
    cuts = good
    -- The cut only adds a wall, and the clues are recounted, so the shading
    -- stays valid unless some white line now runs through three rooms; only
    -- the lines through the cut room can, so only they are checked before a
    -- whole context is built.
    local room_of = {}
    for j, other in ipairs(rooms) do
        if j ~= k then
            for r = other.r1, other.r2 do
                for c = other.c1, other.c2 do room_of[(r - 1) * n + c] = j end
            end
        end
    end
    local function lineOk(cells)
        local pre = { [0] = 0 }
        for p = 1, #cells do pre[p] = pre[p - 1] + (shaded[cells[p]] and 1 or 0) end
        local last
        for p = 1, #cells - 1 do
            if room_of[cells[p]] ~= room_of[cells[p + 1]] then
                -- Cells last .. p + 1 cross two walls: one must be shaded.
                if last and pre[p + 1] == pre[last - 1] then return false end
                last = p
            end
        end
        return true
    end
    local function linesOk()
        for r = room.r1, room.r2 do
            local cells = {}
            for c = 1, n do cells[c] = (r - 1) * n + c end
            if not lineOk(cells) then return false end
        end
        for c = room.c1, room.c2 do
            local cells = {}
            for r = 1, n do cells[r] = (r - 1) * n + c end
            if not lineOk(cells) then return false end
        end
        return true
    end
    for _, cut in ipairs(cuts) do
        local a, b
        if cut.rows then
            a = { r1 = room.r1, c1 = room.c1, r2 = cut.at, c2 = room.c2 }
            b = { r1 = cut.at + 1, c1 = room.c1, r2 = room.r2, c2 = room.c2 }
        else
            a = { r1 = room.r1, c1 = room.c1, r2 = room.r2, c2 = cut.at }
            b = { r1 = room.r1, c1 = cut.at + 1, r2 = room.r2, c2 = room.c2 }
        end
        for _, part in ipairs({ a, b }) do
            for r = part.r1, part.r2 do
                for c = part.c1, part.c2 do room_of[(r - 1) * n + c] = part end
            end
        end
        if linesOk() then
            local new_rooms = {}
            for j, other in ipairs(rooms) do
                if j ~= k then new_rooms[#new_rooms + 1] = other end
            end
            new_rooms[#new_rooms + 1] = a
            new_rooms[#new_rooms + 1] = b
            local ctx = Solver.buildContext(n, new_rooms)
            setClues(ctx, shaded)
            return new_rooms, ctx
        end
    end
    return nil
end

-- Undoes needless cuts: two side-by-side rooms whose union is a rectangle
-- (at most ROOM_MAX_DIM a side, max_area cells) become one, with the
-- combined count, whenever the solver at `cap` still finishes. Removing a wall
-- never breaks the shading (a line through three rooms after the merge ran
-- through at least three before it). One pass over the candidate pairs in
-- random order. Returns the rooms, context and number of merges.
local function mergeRooms(n, rooms, ctx, shaded, cap, max_area)
    local cands = {}
    for a = 1, #rooms do
        for b = a + 1, #rooms do
            local A, B = rooms[a], rooms[b]
            local side = A.r1 == B.r1 and A.r2 == B.r2 and (A.c2 + 1 == B.c1 or B.c2 + 1 == A.c1)
            local stack = A.c1 == B.c1 and A.c2 == B.c2 and (A.r2 + 1 == B.r1 or B.r2 + 1 == A.r1)
            if side or stack then cands[#cands + 1] = { A, B } end
        end
    end
    shuffle(cands)
    local dead, merged = {}, 0
    for _, pair in ipairs(cands) do
        local A, B = pair[1], pair[2]
        if not dead[A] and not dead[B] then
            local U = { r1 = math.min(A.r1, B.r1), c1 = math.min(A.c1, B.c1),
                        r2 = math.max(A.r2, B.r2), c2 = math.max(A.c2, B.c2) }
            local h, w = U.r2 - U.r1 + 1, U.c2 - U.c1 + 1
            if h <= ROOM_MAX_DIM and w <= ROOM_MAX_DIM and h * w <= max_area then
                local new_rooms = {}
                for _, room in ipairs(rooms) do
                    if room ~= A and room ~= B then new_rooms[#new_rooms + 1] = room end
                end
                new_rooms[#new_rooms + 1] = U
                local new_ctx = Solver.buildContext(n, new_rooms)
                setClues(new_ctx, shaded)
                if Solver.solve(new_ctx, cap) == "solved" then
                    rooms, ctx = new_rooms, new_ctx
                    dead[A], dead[B] = true, true
                    merged = merged + 1
                end
            end
        end
    end
    return rooms, ctx, merged
end

-- Generation progress for on_progress(fraction): `inner` (0..1) is how far
-- the current attempt is; each new attempt fills half of what is left of the
-- bar, so it only ever moves forward.
local function report(on_progress, attempt, inner)
    if on_progress then on_progress(1 - 0.5 ^ (attempt - 1) * (1 - inner / 2)) end
end

-- Distance of a room-analysis count to the window, 0 = inside.
local function windowGap(t2, w)
    if t2 < w[1] then return w[1] - t2 end
    if t2 > w[2] then return t2 - w[2] end
    return 0
end

local function generatePuzzle(n, difficulty, stats, on_progress)
    local cap = TIER_CAP[difficulty] or 1
    local window = t2Window(difficulty, n)
    local merge_area = difficulty == "hard" and HARD_MERGE_MAX_AREA or MERGE_MAX_AREA
    local function note(key)
        if stats then stats[key] = (stats[key] or 0) + 1 end
    end
    -- Solved at the cap, and (when a maximum applies) without more room
    -- analysis than the window allows.
    local floor_t2 = 0
    local function fits(ctx)
        if cap < 2 then return Solver.solve(ctx, cap) == "solved" end
        local status, _, t2 = Solver.grade(ctx)
        if status ~= "solved" or t2 > window[2] then return false end
        if difficulty == "hard" then
            if t2 < floor_t2 then return false end
            floor_t2 = t2
        end
        return true
    end
    local best, best_gap
    for attempt = 1, MAX_ATTEMPTS do
        report(on_progress, attempt, 0)
        local rooms, ctx, shaded
        for _ = 1, SHADE_LAYOUTS do
            rooms = partition(n)
            ctx = Solver.buildContext(n, rooms)
            shaded = makeShading(ctx)
            if shaded then break end
        end
        report(on_progress, attempt, 0.15)
        local status, splits = nil, 0
        if shaded then
            setClues(ctx, shaded)
            while splits <= MAX_SPLITS do
                local st, _tier
                status, _tier, st = Solver.solve(ctx, cap)
                if status ~= "stuck" then break end
                local stuck = {}
                for i = 1, ctx.N do
                    if st[i] == Solver.UNKNOWN then stuck[#stuck + 1] = i end
                end
                shuffle(stuck)
                local done = false
                for _, i in ipairs(stuck) do
                    local new_rooms, new_ctx = splitRoom(n, rooms, ctx.room_of[i], shaded)
                    if new_rooms then
                        rooms, ctx, done = new_rooms, new_ctx, true
                        break
                    end
                end
                if not done then break end
                splits = splits + 1
                report(on_progress, attempt, 0.15 + 0.15 * splits / MAX_SPLITS)
            end
        end
        if not shaded then note("no_shading")
        elseif status ~= "solved" then note("split_failed:" .. tostring(status)) end
        local merges = 0
        if status == "solved" then
            report(on_progress, attempt, 0.3)
            rooms, ctx, merges = mergeRooms(n, rooms, ctx, shaded, cap, merge_area)
            report(on_progress, attempt, 0.5)
            -- Clue removal at the difficulty's tier. (A tier-1 pass before
            -- medium's tier-2 one was tried: it leaves room analysis almost
            -- nothing to remove.) Hard never takes a removal that lowers the
            -- amount of room analysis, and tries a few removal orders on the
            -- same layout, keeping the one that needs the most: cheaper than
            -- a fresh layout.
            local order = {}
            for k = 1, #rooms do order[k] = k end
            local initial = {}
            for k, room in ipairs(rooms) do initial[k] = room.clue end
            local passes = difficulty == "hard" and HARD_REMOVAL_ORDERS or 1
            local keep, keep_t2, keep_clues
            for pass = 1, passes do
                for k, room in ipairs(rooms) do room.clue = initial[k] end
                shuffle(order)
                floor_t2 = cap >= 2 and select(3, Solver.grade(ctx)) or 0
                for j, k in ipairs(order) do
                    report(on_progress, attempt,
                        0.5 + 0.5 * ((pass - 1) * #order + j) / (passes * #order))
                    local clue = rooms[k].clue
                    if clue then
                        rooms[k].clue = nil
                        if not fits(ctx) then rooms[k].clue = clue end
                    end
                end
                if passes > 1 then
                    local st, _, t2 = Solver.grade(ctx)
                    local nclues = 0
                    for _, room in ipairs(rooms) do
                        if room.clue then nclues = nclues + 1 end
                    end
                    if st == "solved" and (not keep or t2 > keep_t2
                            or (t2 == keep_t2 and nclues < keep_clues)) then
                        keep, keep_t2, keep_clues = {}, t2, nclues
                        for k, room in ipairs(rooms) do keep[k] = room.clue end
                    end
                    if t2 >= window[1] then break end
                end
            end
            if keep then
                for k, room in ipairs(rooms) do room.clue = keep[k] end
            end
            local final, tier, t2 = Solver.grade(ctx)
            if final == "solved" and tier <= cap then
                local clues = 0
                for _, room in ipairs(rooms) do
                    if room.clue then clues = clues + 1 end
                end
                local cand = { rooms = rooms, shaded = shaded,
                               info = { tier = tier, cap = cap, t2 = t2, attempts = attempt,
                                        splits = splits, merges = merges,
                                        clues = clues, rooms = #rooms } }
                local gap = windowGap(t2, window)
                note("ok_t2_" .. t2)
                if not best or gap < best_gap then best, best_gap = cand, gap end
                if gap == 0 or attempt >= TIER_ATTEMPTS then break end
            else
                note("final_check_failed")
            end
        end
    end
    return best
end

-- Last resort, never seen in practice (generation did not fail once in a
-- 1,800-seed sweep over every size and level): a fixed 6x6 puzzle, generated
-- once and checked unique by the test suite.
local FALLBACK = {
    n = 6,
    rooms = {
        { r1 = 1, c1 = 2, r2 = 2, c2 = 2 },
        { r1 = 1, c1 = 3, r2 = 2, c2 = 4, clue = 1 },
        { r1 = 1, c1 = 5, r2 = 2, c2 = 6, clue = 1 },
        { r1 = 4, c1 = 1, r2 = 4, c2 = 2 },
        { r1 = 5, c1 = 1, r2 = 6, c2 = 1 },
        { r1 = 5, c1 = 2, r2 = 6, c2 = 2, clue = 0 },
        { r1 = 3, c1 = 3, r2 = 3, c2 = 5 },
        { r1 = 4, c1 = 4, r2 = 6, c2 = 5 },
        { r1 = 3, c1 = 6, r2 = 4, c2 = 6, clue = 0 },
        { r1 = 5, c1 = 6, r2 = 6, c2 = 6 },
        { r1 = 1, c1 = 1, r2 = 1, c2 = 1 },
        { r1 = 2, c1 = 1, r2 = 2, c2 = 1, clue = 0 },
        { r1 = 4, c1 = 3, r2 = 5, c2 = 3 },
        { r1 = 6, c1 = 3, r2 = 6, c2 = 3 },
        { r1 = 3, c1 = 1, r2 = 3, c2 = 1, clue = 0 },
        { r1 = 3, c1 = 2, r2 = 3, c2 = 2 },
    },
}

-- ---------------------------------------------------------------------------
-- HeyawakeBoard
-- ---------------------------------------------------------------------------

local HeyawakeBoard = {}
HeyawakeBoard.__index = HeyawakeBoard

function HeyawakeBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    local obj = {
        n               = n,
        difficulty      = opts.difficulty or DEFAULT_DIFFICULTY,
        rooms           = {},
        room_of         = emptyGrid(n),
        solution        = emptyBoolGrid(n),
        user            = emptyGrid(n),
        wrong_marks     = emptyBoolGrid(n),
        reveal_solution = false,
        undo            = UndoStack:new{ max_size = 200 },
        timer           = Timer:new(),
        hints_used      = 0,
        gen_info        = nil,
    }
    setmetatable(obj, self)
    return obj
end

-- Rebuilds everything derived from `rooms` (room_of, solver context).
function HeyawakeBoard:_indexRooms()
    local n = self.n
    self.room_of = emptyGrid(n)
    for k, room in ipairs(self.rooms) do
        for r = room.r1, room.r2 do
            for c = room.c1, room.c2 do self.room_of[r][c] = k end
        end
    end
    self.ctx = Solver.buildContext(n, self.rooms)
end

function HeyawakeBoard:_reset()
    local n = self.n
    self.user            = emptyGrid(n)
    self.wrong_marks     = emptyBoolGrid(n)
    self.reveal_solution = false
    self.hints_used      = 0
    self.selected        = nil
    self.undo:clear()
    self.timer:reset()
    self.timer:start()
end

-- on_progress(fraction), optional, is called as generation advances (the
-- screen drives a progress bar with it). Generation only draws on
-- math.random and counts its work (node and attempt budgets), never the
-- clock, so a seed always gives the same puzzle: the Daily Challenge relies
-- on it.
function HeyawakeBoard:generate(difficulty, on_progress)
    self.difficulty = difficulty or self.difficulty
    local n = self.n
    local best
    for _ = 1, 3 do
        best = generatePuzzle(n, self.difficulty, nil, on_progress)
        if best then break end
    end
    if on_progress then on_progress(1) end
    local flat
    if best then
        self.rooms, flat, self.gen_info = best.rooms, best.shaded, best.info
    else
        self.n = FALLBACK.n
        n = self.n
        self.rooms = {}
        for k, room in ipairs(FALLBACK.rooms) do
            self.rooms[k] = { r1 = room.r1, c1 = room.c1, r2 = room.r2, c2 = room.c2, clue = room.clue }
        end
        local _, _, st = Solver.solve(Solver.buildContext(n, self.rooms), 2)
        flat = {}
        for i = 1, n * n do flat[i] = st[i] == Solver.SHADED end
        self.gen_info = { fallback = true }
    end
    self:_indexRooms()
    self.solution = emptyBoolGrid(n)
    for r = 1, n do
        for c = 1, n do self.solution[r][c] = flat[(r - 1) * n + c] and true or false end
    end
    self:_reset()
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

function HeyawakeBoard:getRoom(r, c)
    return self.rooms[self.room_of[r][c]]
end

-- The clue of the room whose top-left cell is (r, c), else nil.
function HeyawakeBoard:getClueAt(r, c)
    local room = self:getRoom(r, c)
    if room and room.r1 == r and room.c1 == c then return room.clue end
    return nil
end

function HeyawakeBoard:userState()
    local n, st = self.n, {}
    for r = 1, n do
        for c = 1, n do st[(r - 1) * n + c] = self.user[r][c] end
    end
    return st
end

-- ---------------------------------------------------------------------------
-- Cell state mutation
-- ---------------------------------------------------------------------------

function HeyawakeBoard:setCellState(r, c, state)
    if state ~= STATE_UNKNOWN and state ~= STATE_BLACK and state ~= STATE_WHITE_DOT then
        return false, "invalid_state"
    end
    self.selected = nil
    local prev = self.user[r][c]
    if prev == state then return true end
    self.undo:push{ r = r, c = c, prev_state = prev }
    self.user[r][c] = state
    self.wrong_marks[r][c] = false
    self:_afterMove()
    return true
end

-- Tap order: empty -> shaded -> dot -> empty.
function HeyawakeBoard:cycleCellState(r, c)
    local cur = self.user[r][c]
    local nxt = (cur == STATE_UNKNOWN) and STATE_BLACK
        or (cur == STATE_BLACK) and STATE_WHITE_DOT
        or STATE_UNKNOWN
    return self:setCellState(r, c, nxt)
end

function HeyawakeBoard:_afterMove()
    if self:isSolved() then
        self.timer:stop()
    elseif not self.timer:isRunning() then
        self.timer:start()
    end
end

function HeyawakeBoard:setSelection(r, c)
    self.selected = { r = r, c = c }
end

-- ---------------------------------------------------------------------------
-- Undo
-- ---------------------------------------------------------------------------

function HeyawakeBoard:canUndo()
    return self.undo:canUndo()
end

function HeyawakeBoard:undo()
    local entry = self.undo:pop()
    if not entry then
        return false, UndoStack.NOTHING_TO_UNDO
    end
    self.user[entry.r][entry.c]        = entry.prev_state
    self.wrong_marks[entry.r][entry.c] = false
    self:_afterMove()
    return true
end

-- ---------------------------------------------------------------------------
-- Progress / validation
-- ---------------------------------------------------------------------------

-- Marks every shade or dot that disagrees with the solution.
-- Returns how many there are.
function HeyawakeBoard:checkProgress()
    local n, wrong = self.n, 0
    for r = 1, n do
        for c = 1, n do
            local u, sb = self.user[r][c], self.solution[r][c]
            local bad = (u == STATE_BLACK and not sb) or (u == STATE_WHITE_DOT and sb) or false
            self.wrong_marks[r][c] = bad
            if bad then wrong = wrong + 1 end
        end
    end
    return wrong
end

-- Solved once the shading matches: dots are notes, and unmarked cells count
-- as white. The solution is unique, so matching it is the same as obeying
-- every rule.
function HeyawakeBoard:isSolved()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            if (self.user[r][c] == STATE_BLACK) ~= self.solution[r][c] then return false end
        end
    end
    return true
end

-- Rule breaks the player's marks already make, whatever the rest becomes:
-- touching shades, a room over its number, a three-room line of dots, dots
-- walled off from each other.
function HeyawakeBoard:validateRules()
    local ctx = self.ctx
    local st = self:userState()
    local violations = {}
    for i = 1, ctx.N do
        if st[i] == STATE_BLACK then
            for _, j in ipairs(ctx.nbr[i]) do
                if j > i and st[j] == STATE_BLACK then
                    violations[#violations + 1] = "adjacent:" .. i .. ":" .. j
                end
            end
        end
    end
    for k, room in ipairs(self.rooms) do
        if room.clue then
            local s, open = 0, 0
            for _, i in ipairs(ctx.room_cells[k]) do
                if st[i] == STATE_BLACK then s = s + 1
                elseif st[i] == STATE_UNKNOWN then open = open + 1 end
            end
            if s > room.clue or s + open < room.clue then
                violations[#violations + 1] = "room:" .. k
            end
        end
    end
    for k, w in ipairs(ctx.windows) do
        local all_dots = true
        for _, i in ipairs(w) do
            if st[i] ~= STATE_WHITE_DOT then all_dots = false; break end
        end
        if all_dots then violations[#violations + 1] = "line:" .. k end
    end
    -- Dots must still be able to meet through non-shaded cells.
    local start
    for i = 1, ctx.N do
        if st[i] == STATE_WHITE_DOT then start = i; break end
    end
    if start then
        local seen, stack = { [start] = true }, { start }
        while #stack > 0 do
            local i = stack[#stack]
            stack[#stack] = nil
            for _, j in ipairs(ctx.nbr[i]) do
                if st[j] ~= STATE_BLACK and not seen[j] then
                    seen[j] = true
                    stack[#stack + 1] = j
                end
            end
        end
        for i = 1, ctx.N do
            if st[i] == STATE_WHITE_DOT and not seen[i] then
                violations[#violations + 1] = "disconnected"
                break
            end
        end
    end
    return #violations == 0, violations
end

function HeyawakeBoard:getShadedCount()
    local n, count = self.n, 0
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] == STATE_BLACK then count = count + 1 end
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Solution reveal
-- ---------------------------------------------------------------------------

function HeyawakeBoard:toggleSolution()
    self.reveal_solution = not self.reveal_solution
end

function HeyawakeBoard:isShowingSolution()
    return self.reveal_solution
end

-- ---------------------------------------------------------------------------
-- Hints
-- ---------------------------------------------------------------------------

-- Hint.install gives the mistake-first reveal machinery. Dots are notes, but
-- a dot on a cell that must be shaded is still a real mistake, so the default
-- equality is right here.
Hint.install(HeyawakeBoard, {
    getUser     = function(b, r, c) return b.user[r][c] end,
    getSolution = function(b, r, c)
        return b.solution[r][c] and STATE_BLACK or STATE_WHITE_DOT
    end,
    isEmpty     = function(v) return v == STATE_UNKNOWN end,
    setCell     = function(b, r, c, v) return b:setCellState(r, c, v) end,
    blank       = STATE_UNKNOWN,
})

-- Unlike the stock heuristic, a Heyawake hint points at a cell the player can
-- actually deduce from what is on the board: mistakes first (via the stock
-- machinery), then a deduction the solver makes from the player's marks (its
-- first shade, else its first white cell). Only when the solver deduces
-- nothing (it always does, on a generated puzzle) does it fall back to the
-- stock pick.
local gridFindHint = HeyawakeBoard.findHint
function HeyawakeBoard:findHint()
    local step, reason = gridFindHint(self)
    if not step or step.kind == "mistake" then return step, reason end
    local st = self:userState()
    local ok, _, log = Solver.propagate(self.ctx, st, 2)
    if ok and log[1] then
        -- Prefer the first shade the solver finds: dots are optional, so a
        -- hint that only says "this cell is white" barely moves the game on.
        local d = log[1]
        for _, e in ipairs(log) do
            if e.value == STATE_BLACK then d = e; break end
        end
        local n = self.n
        local r, c = math.floor((d.i - 1) / n) + 1, (d.i - 1) % n + 1
        return { kind = "fill", r = r, c = c, value = d.value, tier = d.tier }
    end
    return step, reason
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function HeyawakeBoard:serialize()
    local n = self.n
    local rooms = {}
    for k, room in ipairs(self.rooms) do
        rooms[k] = { r1 = room.r1, c1 = room.c1, r2 = room.r2, c2 = room.c2,
                     clue = room.clue or -1 }
    end
    local sol = emptyBoolGrid(n)
    local wm  = emptyBoolGrid(n)
    for r = 1, n do
        for c = 1, n do
            sol[r][c] = self.solution[r][c] and true or false
            wm[r][c]  = self.wrong_marks[r][c] and true or false
        end
    end
    -- Timer:serialize() stops the clock to fold in the elapsed time; restart
    -- it so saving mid-game does not freeze the timer.
    local timer = self.timer:serialize()
    if timer.was_running then self.timer:start() end
    return {
        n               = n,
        difficulty      = self.difficulty,
        rooms           = rooms,
        solution        = sol,
        user            = copyGrid(self.user, n),
        wrong_marks     = wm,
        reveal_solution = self.reveal_solution,
        undo            = self.undo:serialize(),
        timer           = timer,
        hints_used      = self.hints_used,
    }
end

function HeyawakeBoard:load(data)
    if type(data) ~= "table" or type(data.rooms) ~= "table" or not data.solution then
        return false
    end
    local n = tonumber(data.n) or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFFICULTY
    self.rooms = {}
    for k, room in ipairs(data.rooms) do
        local clue = tonumber(room.clue)
        self.rooms[k] = { r1 = room.r1, c1 = room.c1, r2 = room.r2, c2 = room.c2,
                          clue = (clue and clue >= 0) and clue or nil }
    end
    self:_indexRooms()
    self.user = copyGrid(data.user or {}, n)
    self.solution    = emptyBoolGrid(n)
    self.wrong_marks = emptyBoolGrid(n)
    for r = 1, n do
        for c = 1, n do
            local s = data.solution[r] and data.solution[r][c]
            self.solution[r][c] = (s == true or s == 1)
            local w = data.wrong_marks and data.wrong_marks[r] and data.wrong_marks[r][c]
            self.wrong_marks[r][c] = (w == true or w == 1)
        end
    end
    self.reveal_solution = data.reveal_solution or false
    self.hints_used = tonumber(data.hints_used) or 0
    self.undo = UndoStack:new{ max_size = 200 }
    if data.undo then self.undo:load(data.undo) end
    self.timer = Timer:new()
    self.timer:load(data.timer)
    return true
end

HeyawakeBoard.STATE_UNKNOWN   = STATE_UNKNOWN
HeyawakeBoard.STATE_BLACK     = STATE_BLACK
HeyawakeBoard.STATE_WHITE_DOT = STATE_WHITE_DOT
HeyawakeBoard.TIER_CAP        = TIER_CAP
HeyawakeBoard.Solver          = Solver
HeyawakeBoard.t2Window        = t2Window
HeyawakeBoard._partition      = partition
HeyawakeBoard._generatePuzzle = generatePuzzle
HeyawakeBoard._makeShading    = makeShading
HeyawakeBoard._FALLBACK       = FALLBACK

-- The generator's own steps run interpreted (and so do the closures they
-- make): they are branchy one-off code that kept LuaJIT compiling new
-- traces, so often that its trace cache filled and was flushed many times
-- per puzzle, recompiling the solver's hot loops each time. The solver's
-- rules, where the time goes, stay compiled. Same puzzles either way.
if jit then
    for _, f in ipairs({ partition, makeShading, setClues, splitRoom, mergeRooms, generatePuzzle }) do
        jit.off(f, true)
    end
end

return HeyawakeBoard
