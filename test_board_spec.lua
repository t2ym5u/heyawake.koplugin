local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("HeyawakeBoard", function()
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

    -- Plays the stored solution onto the board.
    local function playSolution(b)
        for r = 1, b.n do
            for c = 1, b.n do
                if b.solution[r][c] then b:setCellState(r, c, Board.STATE_BLACK) end
            end
        end
    end

    -- -----------------------------------------------------------------------
    describe("solver rules", function()
        -- A 3x3 grid of three vertical 3x1 rooms: every row crosses two walls.
        local function stripes()
            return Solver.buildContext(3, {
                { r1 = 1, c1 = 1, r2 = 3, c2 = 1 },
                { r1 = 1, c1 = 2, r2 = 3, c2 = 2 },
                { r1 = 1, c1 = 3, r2 = 3, c2 = 3 },
            })
        end

        it("finds one three-room line per row of three stripes", function()
            local ctx = stripes()
            assert.are.equal(3, #ctx.windows)
            for _, w in ipairs(ctx.windows) do assert.are.equal(3, #w) end
        end)

        it("rejects an all-white line through three rooms", function()
            local ctx = stripes()
            local st = {}
            for i = 1, 9 do st[i] = false end
            assert.is_false(Solver.isValidSolution(ctx, st))
        end)

        it("rejects touching shaded cells", function()
            local ctx = stripes()
            local st = {}
            for i = 1, 9 do st[i] = false end
            st[1], st[2] = true, true
            assert.is_false(Solver.isValidSolution(ctx, st))
        end)

        it("rejects white cells cut apart", function()
            -- Shading (1,2), (2,1) isolates the corner (1,1).
            local ctx = Solver.buildContext(3, { { r1 = 1, c1 = 1, r2 = 3, c2 = 3 } })
            local st = {}
            for i = 1, 9 do st[i] = false end
            st[2], st[4] = true, true
            assert.is_false(Solver.isValidSolution(ctx, st))
        end)

        it("accepts a valid shading and checks room numbers", function()
            local rooms = {
                { r1 = 1, c1 = 1, r2 = 3, c2 = 1, clue = 1 },
                { r1 = 1, c1 = 2, r2 = 3, c2 = 2 },
                { r1 = 1, c1 = 3, r2 = 3, c2 = 3 },
            }
            local ctx = Solver.buildContext(3, rooms)
            -- One shade per row, none touching, whites connected:
            -- (1,3), (2,1), (3,3).
            local st = {}
            for i = 1, 9 do st[i] = false end
            st[3], st[4], st[9] = true, true, true
            assert.is_true(Solver.isValidSolution(ctx, st))
            rooms[1].clue = 2
            assert.is_false(Solver.isValidSolution(ctx, st))
        end)

        it("shades the last open cell of a three-room line", function()
            -- Only the top row crosses walls: three 1x1 rooms over one 2x3.
            local ctx = Solver.buildContext(3, {
                { r1 = 1, c1 = 1, r2 = 1, c2 = 1 },
                { r1 = 1, c1 = 2, r2 = 1, c2 = 2 },
                { r1 = 1, c1 = 3, r2 = 1, c2 = 3 },
                { r1 = 2, c1 = 1, r2 = 3, c2 = 3 },
            })
            assert.are.equal(1, #ctx.windows)
            local st = { Solver.WHITE, Solver.UNKNOWN, Solver.WHITE }
            for i = 4, 9 do st[i] = Solver.UNKNOWN end
            local ok = Solver.propagate(ctx, st, 1)
            assert.is_true(ok)
            assert.are.equal(Solver.SHADED, st[2])
        end)

        it("fills a room whose number equals its open cells", function()
            local ctx = Solver.buildContext(3, {
                { r1 = 1, c1 = 1, r2 = 1, c2 = 3, clue = 2 },
                { r1 = 2, c1 = 1, r2 = 3, c2 = 3 },
            })
            local st = {}
            for i = 1, 9 do st[i] = Solver.UNKNOWN end
            -- 1x3 room with 2: only the two ends work (tier 2 room analysis).
            Solver.propagate(ctx, st, 2)
            assert.are.equal(Solver.SHADED, st[1])
            assert.are.equal(Solver.WHITE,  st[2])
            assert.are.equal(Solver.SHADED, st[3])
        end)

        it("keeps a cell white when shading it would cut whites apart", function()
            local ctx = Solver.buildContext(3, { { r1 = 1, c1 = 1, r2 = 3, c2 = 3 } })
            local st = {}
            for i = 1, 9 do st[i] = Solver.UNKNOWN end
            st[1] = Solver.WHITE      -- corner white
            st[4] = Solver.SHADED     -- (2,1) shaded: (1,2) is the only way out
            Solver.propagate(ctx, st, 1)
            assert.are.equal(Solver.WHITE, st[2])
        end)

        it("reports a contradiction on an impossible room", function()
            local ctx = Solver.buildContext(3, {
                { r1 = 1, c1 = 1, r2 = 1, c2 = 2, clue = 2 },
                { r1 = 1, c1 = 3, r2 = 3, c2 = 3 },
                { r1 = 2, c1 = 1, r2 = 3, c2 = 2 },
            })
            assert.are.equal("invalid", (Solver.solve(ctx, 3)))
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("generator", function()
        it("leaves some rooms without a number", function()
            local b = newBoard(8, "medium", 3)
            local blank = 0
            for _, room in ipairs(b.rooms) do
                if not room.clue then blank = blank + 1 end
            end
            assert.is_true(blank > 0)
        end)

        it("fallback puzzle is unique", function()
            local fb = Board._FALLBACK
            local ctx = Solver.buildContext(fb.n, fb.rooms)
            assert.are.equal(1, Solver.countSolutions(ctx, 2))
            assert.are.equal("solved", (Solver.solve(ctx, 2)))
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("play", function()
        it("cycles empty -> shaded -> dot -> empty", function()
            local b = newBoard(6, "easy")
            b:cycleCellState(1, 1)
            assert.are.equal(Board.STATE_BLACK, b.user[1][1])
            b:cycleCellState(1, 1)
            assert.are.equal(Board.STATE_WHITE_DOT, b.user[1][1])
            b:cycleCellState(1, 1)
            assert.are.equal(Board.STATE_UNKNOWN, b.user[1][1])
        end)

        it("undo restores the previous state", function()
            local b = newBoard(6, "easy")
            assert.is_false(b:canUndo())
            b:cycleCellState(2, 3)
            b:cycleCellState(2, 3)
            assert.is_true(b:canUndo())
            Board.undo(b)
            assert.are.equal(Board.STATE_BLACK, b.user[2][3])
            Board.undo(b)
            assert.are.equal(Board.STATE_UNKNOWN, b.user[2][3])
            assert.is_false((Board.undo(b)))
        end)

        it("is solved when the shading matches, dots optional", function()
            local b = newBoard(6, "medium")
            assert.is_false(b:isSolved())
            playSolution(b)
            assert.is_true(b:isSolved())
            assert.is_false(b.timer:isRunning())
        end)

        it("is not solved with an extra shade", function()
            local b = newBoard(6, "medium")
            playSolution(b)
            for r = 1, b.n do
                for c = 1, b.n do
                    if not b.solution[r][c] then
                        b:setCellState(r, c, Board.STATE_BLACK)
                        assert.is_false(b:isSolved())
                        return
                    end
                end
            end
        end)

        it("validateRules flags touching shades and passes the solution", function()
            local b = newBoard(6, "easy")
            playSolution(b)
            assert.is_true((b:validateRules()))
            -- find a shaded cell with a white neighbour and shade it too
            for r = 1, b.n do
                for c = 1, b.n - 1 do
                    if b.solution[r][c] and not b.solution[r][c + 1] then
                        b:setCellState(r, c + 1, Board.STATE_BLACK)
                        local ok, v = b:validateRules()
                        assert.is_false(ok)
                        assert.is_true(#v >= 1)
                        return
                    end
                end
            end
        end)

        it("checkProgress marks a wrong dot", function()
            local b = newBoard(6, "easy")
            for r = 1, b.n do
                for c = 1, b.n do
                    if b.solution[r][c] then
                        b:setCellState(r, c, Board.STATE_WHITE_DOT)
                        b:checkProgress()
                        assert.is_true(b.wrong_marks[r][c])
                        return
                    end
                end
            end
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("hints", function()
        it("each hint agrees with the solution and the hints finish the puzzle", function()
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                local b = newBoard(6, diff, 5)
                local guard = 0
                while not b:isSolved() do
                    guard = guard + 1
                    assert.is_true(guard < 100)
                    local step = b:findHint()
                    assert.is_not_nil(step)
                    assert.are.equal("fill", step.kind)
                    local want = b.solution[step.r][step.c] and Board.STATE_BLACK
                        or Board.STATE_WHITE_DOT
                    assert.are.equal(want, step.value)
                    assert.is_true(b:applyHint(step))
                end
            end
        end)

        it("a hint is a deduction, not a random reveal", function()
            local b = newBoard(8, "medium", 2)
            local step = b:findHint()
            assert.is_not_nil(step.tier)
            assert.is_true(step.tier <= 2)
        end)

        it("reports a mistake before revealing", function()
            local b = newBoard(6, "easy")
            for r = 1, b.n do
                for c = 1, b.n do
                    if not b.solution[r][c] then
                        b:setCellState(r, c, Board.STATE_BLACK)
                        local step = b:findHint()
                        assert.are.equal("mistake", step.kind)
                        assert.are.equal(r, step.r)
                        assert.are.equal(c, step.c)
                        b:applyHint(step)
                        assert.are.equal(Board.STATE_UNKNOWN, b.user[r][c])
                        return
                    end
                end
            end
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("persistence", function()
        it("round-trips through serialize/load", function()
            local b = newBoard(8, "hard", 9)
            b:cycleCellState(1, 1)
            b:cycleCellState(2, 2)
            b:cycleCellState(2, 2)
            b.hints_used = 2
            local data = b:serialize()
            assert.is_true(b.timer:isRunning())

            local b2 = Board:new{ n = 6 }
            assert.is_true(b2:load(data))
            assert.are.equal(8, b2.n)
            assert.are.equal("hard", b2.difficulty)
            assert.are.equal(#b.rooms, #b2.rooms)
            for k, room in ipairs(b.rooms) do
                assert.are.same(room.clue, b2.rooms[k].clue)
            end
            for r = 1, b.n do
                for c = 1, b.n do
                    assert.are.equal(b.user[r][c], b2.user[r][c])
                    assert.are.equal(b.solution[r][c], b2.solution[r][c])
                    assert.are.equal(b.room_of[r][c], b2.room_of[r][c])
                end
            end
            assert.are.equal(2, b2.hints_used)
            assert.is_true(b2:canUndo())
            Board.undo(b2)
            assert.are.equal(Board.STATE_BLACK, b2.user[2][2])
            assert.are.equal(1, Solver.countSolutions(b2.ctx, 2))
        end)

        -- 1.0.x made Hard puzzles that needed a trial, which the solver no
        -- longer does: such a save must still load and play, and the hint
        -- must still finish it (by revealing once logic is stuck).
        it("loads and finishes a Hard puzzle saved by 1.0.x", function()
            local sol = { { 0, 0, 1, 0, 0, 0 }, { 0, 1, 0, 0, 1, 0 }, { 0, 0, 1, 0, 0, 1 },
                          { 1, 0, 0, 1, 0, 0 }, { 0, 1, 0, 0, 1, 0 }, { 0, 0, 0, 0, 0, 0 } }
            local solution = {}
            for r = 1, 6 do
                solution[r] = {}
                for c = 1, 6 do solution[r][c] = sol[r][c] == 1 end
            end
            local b = Board:new{}
            assert.is_true(b:load({
                n = 6, difficulty = "hard", solution = solution, hints_used = 0,
                rooms = {
                    { r1 = 2, c1 = 4, r2 = 3, c2 = 4, clue = 0 },
                    { r1 = 1, c1 = 5, r2 = 3, c2 = 6, clue = -1 },
                    { r1 = 4, c1 = 3, r2 = 5, c2 = 3, clue = -1 },
                    { r1 = 4, c1 = 6, r2 = 5, c2 = 6, clue = 0 },
                    { r1 = 6, c1 = 1, r2 = 6, c2 = 3, clue = -1 },
                    { r1 = 6, c1 = 4, r2 = 6, c2 = 6, clue = 0 },
                    { r1 = 2, c1 = 2, r2 = 3, c2 = 3, clue = -1 },
                    { r1 = 1, c1 = 2, r2 = 1, c2 = 4, clue = -1 },
                    { r1 = 4, c1 = 1, r2 = 5, c2 = 2, clue = 2 },
                    { r1 = 4, c1 = 4, r2 = 5, c2 = 5, clue = -1 },
                    { r1 = 1, c1 = 1, r2 = 3, c2 = 1, clue = 0 },
                },
            }))
            assert.are.equal(1, Solver.countSolutions(b.ctx, 2))
            assert.are.equal("stuck", (Solver.solve(b.ctx, 2)))
            local guard = 0
            while not b:isSolved() do
                guard = guard + 1
                assert.is_true(guard < 100)
                local step = b:findHint()
                assert.is_not_nil(step)
                assert.are.equal("fill", step.kind)
                assert.is_true(b:applyHint(step))
            end
        end)

        it("rejects garbage", function()
            local b = Board:new{}
            assert.is_false(b:load(nil))
            assert.is_false(b:load({ n = 6 }))
        end)
    end)
end)
