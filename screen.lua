local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase         = require("screen_base")
local MenuHelper         = require("menu_helper")
local HeyawakeBoard        = lrequire("board")
local HeyawakeBoardWidget  = lrequire("board_widget")
local GenProgress          = lrequire("gen_progress")

local GRID_SIZES   = { 6, 8, 10 }
local DEFAULT_SIZE = 6

-- ---------------------------------------------------------------------------
-- HeyawakeScreen
-- ---------------------------------------------------------------------------

local GAME_RULES_EN = _([[
Heyawake — Rules

The grid is divided into rooms by thick walls. Shade some cells so that:

1. A room with a number contains exactly that many shaded cells. Rooms without a number may hold any count.
2. Shaded cells never touch each other side by side (touching at a corner is fine).
3. All unshaded cells form one single orthogonally connected area.
4. No straight horizontal or vertical line of unshaded cells crosses more than one wall, i.e. spans three rooms.

Tap a cell to cycle: Empty → Shaded → Dot → Empty. A dot marks a cell you know is unshaded; dots are optional. Hold to clear a cell.
]])

local GAME_RULES_FR = [[
Heyawake — Règles

La grille est divisée en pièces par des murs épais. Noircissez des cases de sorte que :

1. Une pièce portant un nombre contient exactement autant de cases noires. Une pièce sans nombre peut en contenir un nombre quelconque.
2. Deux cases noires ne se touchent jamais par un côté (le contact en diagonale est permis).
3. Toutes les cases blanches forment une seule zone orthogonalement connectée.
4. Aucune ligne droite, horizontale ou verticale, de cases blanches ne traverse plus d'un mur, c'est-à-dire ne s'étend sur trois pièces.

Appuyez sur une case pour cycler : Vide → Noire → Point → Vide. Un point marque une case que vous savez blanche ; les points sont facultatifs. Restez appuyé pour vider une case.
]]

local HeyawakeScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function HeyawakeScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", DEFAULT_SIZE)
    self.board  = HeyawakeBoard:new{ n = n }
    if not self.board:load(state) then
        local diff = self.plugin:getSetting("difficulty", "easy")
        GenProgress.run(function(on_progress) self.board:generate(diff, on_progress) end)
    end
    self.last_check_result = nil
    ScreenBase.init(self)
end

function HeyawakeScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function HeyawakeScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Heyawake"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = self:getGridButtonText(), callback = function() self:openGridMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            { text = self:getRevealButtonText(), callback = function() self:toggleSolution() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Controls first: the board is sized from whatever room they leave.
    self.status_text:setMaxWidth(self:getControlsWidth())
    local action_bar = self:buildActionBar({
        { text = _("Check"),  callback = function() self:onCheck() end },
        { text = _("Hint"), callback = function() self:onHint() end },
        { id = "undo_button", text = _("Undo"),
          callback = function() self:onUndo() end },
    })
    self.undo_button = action_bar:getButtonById("undo_button")
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    -- The widget draws its own thick outer border, so the frame only pads.
    local frame_pad   = Size.padding.large
    local frame_extra = 2 * frame_pad
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = HeyawakeBoardWidget:new{
        board        = self.board,
        max_size     = math.min(budget_w, budget_h) - frame_extra,
        onCellAction = function(r, c, is_hold)
            self:onCellAction(r, c, is_hold)
        end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }
    self:_updateUndoButton()

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Cell interaction
-- ---------------------------------------------------------------------------

function HeyawakeScreen:onCellAction(r, c, is_hold)
    if self.board:isShowingSolution() or self.board:isSolved() then return end
    if is_hold then
        self.board:setCellState(r, c, HeyawakeBoard.STATE_UNKNOWN)
    else
        self.board:cycleCellState(r, c)
    end
    self.last_check_result = nil
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    self:updateStatus()
    self:refreshActionBar()
end

-- ---------------------------------------------------------------------------
-- Game actions
-- ---------------------------------------------------------------------------

function HeyawakeScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "easy")
    local n    = self.plugin:getSetting("grid_n", DEFAULT_SIZE)
    self.board = HeyawakeBoard:new{ n = n }
    GenProgress.run(function(on_progress) self.board:generate(diff, on_progress) end)
    self.last_check_result = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function HeyawakeScreen:onUndo()
    -- The board's `undo` field (its UndoStack) shadows the :undo() method.
    local ok, msg = HeyawakeBoard.undo(self.board)
    if ok then
        self.last_check_result = nil
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
        self:updateStatus()
    else
        self:updateStatus(msg)
    end
    self:refreshActionBar()
end

function HeyawakeScreen:isRoundOver()
    return self.board:isSolved()
end

-- A hint can place the last cell, so the round may end here.
function HeyawakeScreen:onHint()
    ScreenBase.onHint(self)
    self:refreshActionBar()
end

function HeyawakeScreen:onCheck()
    -- A wrong mark counts even when it breaks no rule yet: it is crossed out
    -- on the board, so the status must not say all is well.
    local wrong = self.board:checkProgress()
    local ok, violations = self.board:validateRules()
    ok = ok and wrong == 0
    self.last_check_result = ok
    self.board_widget:refresh()
    if ok then
        if self.board:isSolved() then
            self:updateStatus()
        else
            self:updateStatus(_("No violations found so far."))
        end
    else
        self:updateStatus(T(_("Check: %1 violation(s) found."), math.max(#violations, wrong)))
    end
end

function HeyawakeScreen:toggleSolution()
    self.board:toggleSolution()
    self.board_widget:refresh()
    if self.reveal_button then
        self.reveal_button:setText(self:getRevealButtonText(), self.reveal_button.width)
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Grid size menu
-- ---------------------------------------------------------------------------

function HeyawakeScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes + 1] = {
            id   = sz,
            text = sz .. "\xC3\x97" .. sz,
        }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", DEFAULT_SIZE),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Difficulty menu
-- ---------------------------------------------------------------------------

function HeyawakeScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "easy"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

function HeyawakeScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isShowingSolution() then
        status = _("Solution is shown; editing is disabled.")
    elseif self.board:isSolved() then
        status = T(_("Solved! Time: %1"), self.board.timer:format())
    else
        local diff  = self.board.difficulty
        local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        status = self:joinStatus(
            T("%1×%1", self.board.n), label, T(_("Shaded: %1"), self.board:getShadedCount()))
    end
    ScreenBase.updateStatus(self, status)
end

-- ---------------------------------------------------------------------------
-- Button text helpers
-- ---------------------------------------------------------------------------

function HeyawakeScreen:getGridButtonText()
    return T(_("Size: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function HeyawakeScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "easy")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Difficulty: %1"), label)
end

function HeyawakeScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide solution") or _("Show solution")
end

function HeyawakeScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return HeyawakeScreen
