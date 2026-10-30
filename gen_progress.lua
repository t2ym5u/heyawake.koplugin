-- ---------------------------------------------------------------------------
-- gen_progress.lua — progress bar around a blocking puzzle generation.
--
-- Same pattern as sudoku-common/base_screen.lua's generateWithProgress,
-- vendored here (game-common has no such helper). GenProgress.run(fn) calls
-- fn(on_progress) synchronously; the generator calls on_progress(fraction)
-- (0..1) as it goes. A ProgressbarDialog only appears once generation has
-- already run past SHOW_DELAY_MS, so quick generations (most of them, on a
-- desktop) never flash a dialog on e-ink. ProgressbarDialog:reportProgress
-- forces its own repaint (UIManager:forceRePaint), which is what lets it
-- update while the generator holds the UI thread.
--
-- The clock here only decides whether to show the dialog: the generator
-- never sees it, so a seed still builds the same puzzle on every device
-- (the Daily Challenge, run through DailySeed.run, relies on that).
-- ---------------------------------------------------------------------------

local ProgressbarDialog = require("ui/widget/progressbardialog")
local time              = require("ui/time")
local _                 = require("i18n")

local GenProgress = {
    SHOW_DELAY_MS = 200,
}

function GenProgress.run(fn)
    local start = time.now()
    local dialog
    local ok, err = pcall(fn, function(fraction)
        if not dialog then
            if time.to_ms(time.since(start)) < GenProgress.SHOW_DELAY_MS then return end
            dialog = ProgressbarDialog:new{
                title                = _("Generating puzzle…"),
                progress_max         = 1,
                refresh_time_seconds = 0.15,
                dismissable          = false,
            }
            dialog:show()
        end
        dialog:reportProgress(math.max(0, math.min(1, fraction)))
    end)
    if dialog then dialog:close() end
    if not ok then error(err, 0) end
end

return GenProgress
