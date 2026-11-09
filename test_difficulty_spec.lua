-- Difficulty guarantees for Heyawake (see docs/dev/TESTING.md, "Difficulty
-- specs"). Puzzles are graded by the solver's tiers (solver.lua): tier 1 =
-- counting, adjacency, three-room lines, connectivity; tier 2 = room
-- analysis, never trial. Easy: tier 1 only; Medium: one room analysis; Hard:
-- several (Board.t2Window). Generation is a pure function of math.random.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

-- Runs fn with os.clock unusable and os.time allowed only to the game timer.
local function withoutClock(fn)
    local clock, time = os.clock, os.time
    os.clock = function() error("generation read os.clock") end
    os.time = function(...)
        local src = debug.getinfo(2, "S").source
        if not src:find("timer%.lua$") then error("generation read os.time from " .. src) end
        return time(...)
    end
    local ok, err = pcall(fn)
    os.clock, os.time = clock, time
    if not ok then error(err, 0) end
end

describe("Heyawake difficulty", function()
    local Board, Solver

    setup(function()
        Board  = require("board")
        Solver = Board.Solver
    end)

    local function newBoard(n, diff, seed)
        math.randomseed(seed or 42)
        local b = Board:new{ n = n or 6 }
        b:generate(diff or "easy")
        return b
    end

    local function flatSolution(b)
        local t = {}
        for r = 1, b.n do
            for c = 1, b.n do t[(r - 1) * b.n + c] = b.solution[r][c] end
        end
        return t
    end

    -- Everything that defines the puzzle, as a string.
    local function fingerprint(b)
        local t = { b.n }
        for _, room in ipairs(b.rooms) do
            t[#t + 1] = table.concat({ room.r1, room.c1, room.r2, room.c2, room.clue or -1 }, ":")
        end
        for r = 1, b.n do
            for c = 1, b.n do t[#t + 1] = b.solution[r][c] and "#" or "." end
        end
        return table.concat(t, ",")
    end

    local function generate(n, diff, seed, on_progress)
        math.randomseed(seed)
        local b = Board:new{ n = n }
        withoutClock(function() b:generate(diff, on_progress) end)
        return b
    end

    describe("generator", function()
        local cases = {
            { n = 6,  diff = "easy",   seeds = 12 },
            { n = 6,  diff = "medium", seeds = 12 },
            { n = 6,  diff = "hard",   seeds = 12 },
            { n = 8,  diff = "easy",   seeds = 4 },
            { n = 8,  diff = "medium", seeds = 4 },
            { n = 8,  diff = "hard",   seeds = 4 },
            { n = 10, diff = "easy",   seeds = 2 },
            { n = 10, diff = "medium", seeds = 2 },
            { n = 10, diff = "hard",   seeds = 2 },
        }
        for _, case in ipairs(cases) do
            it(("%dx%d %s: valid, unique, guess-free, in its window"):format(case.n, case.n, case.diff), function()
                for seed = 1, case.seeds do
                    local b = newBoard(case.n, case.diff, seed)
                    assert.is_nil(b.gen_info.fallback)
                    assert.are.equal(case.n, b.n)
                    -- rooms tile the grid
                    local area = 0
                    for _, room in ipairs(b.rooms) do
                        area = area + (room.r2 - room.r1 + 1) * (room.c2 - room.c1 + 1)
                    end
                    assert.are.equal(case.n * case.n, area)
                    -- the stored solution obeys every rule with these clues
                    assert.is_true(Solver.isValidSolution(b.ctx, flatSolution(b)))
                    -- brute force agrees there is exactly one solution
                    assert.are.equal(1, Solver.countSolutions(b.ctx, 2))
                    -- the logic solver finishes within the difficulty's tier
                    local status, tier, st = Solver.solve(b.ctx, Board.TIER_CAP[case.diff])
                    assert.are.equal("solved", status)
                    assert.is_true(tier <= Board.TIER_CAP[case.diff])
                    for i, v in ipairs(flatSolution(b)) do
                        assert.are.equal(v, st[i] == Solver.SHADED)
                    end
                    -- no trial, and the amount of room analysis the level asks
                    local gstatus, _, t2 = Solver.grade(b.ctx)
                    assert.are.equal("solved", gstatus)
                    local w = Board.t2Window(case.diff, case.n)
                    assert.is_true(t2 >= w[1] and t2 <= w[2],
                        ("%dx%d %s seed %d: t2=%d"):format(case.n, case.n, case.diff, seed, t2))
                end
            end)
        end

        it("keeps the levels apart: hard needs more room analysis than medium", function()
            for _, n in ipairs({ 6, 8, 10 }) do
                assert.is_true(Board.t2Window("hard", n)[1] > Board.t2Window("medium", n)[2])
                assert.is_true(Board.t2Window("medium", n)[1] > Board.t2Window("easy", n)[2])
            end
            -- and medium/hard puzzles really do need room analysis
            for seed = 1, 6 do
                for _, diff in ipairs({ "medium", "hard" }) do
                    local b = newBoard(6, diff, 100 + seed)
                    assert.are.equal("stuck", (Solver.solve(b.ctx, 1)))
                end
            end
        end)

        it("stays within a generous time bound at 10x10", function()
            for seed = 1, 3 do
                for _, diff in ipairs({ "medium", "hard" }) do
                    local t0 = os.clock()
                    newBoard(10, diff, 500 + seed)
                    -- at most ~0.35 s on the Mac under LuaJIT
                    assert.is_true(os.clock() - t0 < 6)
                end
            end
        end)

        it("easy puzzles never need more than tier 1", function()
            for seed = 1, 8 do
                local b = newBoard(6, "easy", seed)
                assert.are.equal("solved", (Solver.solve(b.ctx, 1)))
            end
        end)

        it("builds the same puzzle from the same seed, without reading the clock", function()
            for _, case in ipairs({ { 6, "easy" }, { 8, "medium" }, { 10, "hard" } }) do
                local a = fingerprint(generate(case[1], case[2], 2024))
                local b = fingerprint(generate(case[1], case[2], 2024, function() end))
                assert.are.equal(a, b)
                assert.are_not.equal(a, fingerprint(generate(case[1], case[2], 2025)))
            end
        end)

        it("room analysis goes up from Easy to Hard on averages over seeds", function()
            local SEEDS = 6
            local avg = {}
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                local sum = 0
                for seed = 1, SEEDS do
                    local b = newBoard(6, diff, 300 + seed)
                    local _, _, t2 = Solver.grade(b.ctx)
                    sum = sum + t2
                end
                avg[diff] = sum / SEEDS
            end
            assert.are.equal(0, avg.easy)
            assert.is_true(avg.easy < avg.medium and avg.medium < avg.hard,
                ("%.1f / %.1f / %.1f"):format(avg.easy, avg.medium, avg.hard))
        end)
    end)
end)
