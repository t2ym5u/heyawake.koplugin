-- Generator contract: reports progress, and never reads the clock while
-- doing so. (Same seed -> same puzzle lives in test_difficulty_spec.lua.)
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
end)
