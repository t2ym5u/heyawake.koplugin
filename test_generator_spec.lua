-- Generator contract: reports progress, and is a pure function of the
-- math.random draws (the Daily Challenge builds the same grid on every
-- device from the same seed, so no clock may steer generation).
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

describe("Heyawake generator", function()
    local Board

    setup(function()
        Board = require("board")
    end)

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

    it("reports progress, between 0 and 1 and never backwards, ending at 1", function()
        for _, diff in ipairs({ "easy", "medium", "hard" }) do
            local seen = {}
            generate(8, diff, 7, function(f) seen[#seen + 1] = f end)
            assert.is_true(#seen > 1, diff)
            for k, f in ipairs(seen) do
                assert.is_true(f >= 0 and f <= 1, diff)
                if k > 1 then assert.is_true(f >= seen[k - 1], diff) end
            end
            assert.are.equal(1, seen[#seen])
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
end)
