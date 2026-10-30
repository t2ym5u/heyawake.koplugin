local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local gwb              = lrequire("common/grid_widget_base")
local GridWidgetBase   = gwb.GridWidgetBase
local drawLine         = gwb.drawLine
local drawDiagonalLine = gwb.drawDiagonalLine

local HeyawakeBoard = lrequire("board")

local C_BG        = Blitbuffer.COLOR_WHITE
local C_SHADED    = Blitbuffer.COLOR_BLACK
local C_WRONG_BG  = Blitbuffer.COLOR_GRAY
local C_GRID      = Blitbuffer.COLOR_GRAY_4
local C_ROOM      = Blitbuffer.COLOR_BLACK
local C_TEXT      = Blitbuffer.COLOR_BLACK
local C_TEXT_INV  = Blitbuffer.COLOR_WHITE

-- ---------------------------------------------------------------------------
-- HeyawakeBoardWidget
--
-- Thin grey cell lines, thick black room walls: the rooms are the puzzle, so
-- they must read at a glance on e-ink. A room's number sits in the top-left
-- corner of its top-left cell, as in print. Shaded cells are solid black; a
-- dot marks a cell known to be white.
-- ---------------------------------------------------------------------------

local HeyawakeBoardWidget = GridWidgetBase:extend{
    board = nil,
}

function HeyawakeBoardWidget:init()
    local n   = self.board and self.board.n or 6
    self.cols = n
    self.rows = n
    self.max_value = 99
    GridWidgetBase.init(self)
    -- About half the full-cell size: that leaves the cell's centre free for
    -- a dot.
    local full = self.number_face.orig_size or self.number_face.size
    self.clue_face = Font:getFace("cfont", math.max(10, math.floor(full * 0.62)))
end

function HeyawakeBoardWidget:onCellTap(row, col)
    if self.onCellAction then self.onCellAction(row, col, false) end
end

function HeyawakeBoardWidget:onCellHold(row, col)
    if self.onCellAction then self.onCellAction(row, col, true) end
end

function HeyawakeBoardWidget:paintTo(bb, x, y)
    local board = self.board
    if not board then return end
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local n        = board.n
    local size     = self.dimen.w
    local cell     = size / n
    local show_sol = board:isShowingSolution()
    local function cx(c) return x + math.floor((c - 1) * cell) end
    local function cy(r) return y + math.floor((r - 1) * cell) end
    local function cw(c) return math.floor(c * cell) - math.floor((c - 1) * cell) end

    bb:paintRect(x, y, size, size, C_BG)

    -- Cell fills
    for r = 1, n do
        for c = 1, n do
            local state = board.user[r][c]
            local wrong = not show_sol and board.wrong_marks[r][c]
            local shaded
            if show_sol then shaded = board.solution[r][c]
            else shaded = state == HeyawakeBoard.STATE_BLACK end
            if wrong then
                bb:paintRect(cx(c), cy(r), cw(c), cw(r), C_WRONG_BG)
            elseif shaded then
                bb:paintRect(cx(c), cy(r), cw(c), cw(r), C_SHADED)
            end
        end
    end

    -- Thin cell lines, then thick room walls on top.
    local thin  = Size.line.thin or 1
    local thick = math.max(3, math.floor(cell / 14))
    for i = 1, n - 1 do
        local off = math.floor(i * cell)
        drawLine(bb, x + off, y, thin, size, C_GRID)
        drawLine(bb, x, y + off, size, thin, C_GRID)
    end
    local half = math.floor(thick / 2)
    -- Wall segments overlap by a wall's width so corners join, clamped so
    -- the overlap never pokes out past the outer frame.
    local function wall(x0, y0, w0, h0)
        local x1, y1 = math.max(x0, x), math.max(y0, y)
        local x2, y2 = math.min(x0 + w0, x + size), math.min(y0 + h0, y + size)
        if x2 > x1 and y2 > y1 then drawLine(bb, x1, y1, x2 - x1, y2 - y1, C_ROOM) end
    end
    for r = 1, n do
        for c = 1, n do
            local k = board.room_of[r][c]
            if c < n and board.room_of[r][c + 1] ~= k then
                wall(cx(c + 1) - half, cy(r) - half, thick, cw(r) + thick)
            end
            if r < n and board.room_of[r + 1][c] ~= k then
                wall(cx(c) - half, cy(r + 1) - half, cw(c) + thick, thick)
            end
        end
    end
    drawLine(bb, x, y, size, thick, C_ROOM)
    drawLine(bb, x, y + size - thick, size, thick, C_ROOM)
    drawLine(bb, x, y, thick, size, C_ROOM)
    drawLine(bb, x + size - thick, y, thick, size, C_ROOM)

    -- Clues, dots, wrong-mark crosses.
    local pad   = self.number_padding or 2
    local inner = math.max(1, math.floor(cell - 2 * pad))
    for r = 1, n do
        for c = 1, n do
            local x0, y0, w0 = cx(c), cy(r), cw(c)
            local state  = board.user[r][c]
            local shaded = (show_sol and board.solution[r][c])
                or (not show_sol and state == HeyawakeBoard.STATE_BLACK)
            local wrong  = not show_sol and board.wrong_marks[r][c]
            local clue   = board:getClueAt(r, c)

            if clue then
                local text  = tostring(clue)
                local m     = RenderText:sizeUtf8Text(0, inner, self.clue_face, text, true, false)
                local inset = thick + math.max(2, math.floor(cell / 16))
                RenderText:renderUtf8Text(bb, x0 + inset, y0 + inset + m.y_top, self.clue_face,
                    text, true, false, (shaded and not wrong) and C_TEXT_INV or C_TEXT)
            end

            if not show_sol and state == HeyawakeBoard.STATE_WHITE_DOT then
                -- In a numbered cell the dot shifts down-right, off the digits.
                local rad = math.max(2, math.floor(cell * 0.11))
                local off = math.floor(w0 * (clue and 0.64 or 0.5))
                bb:paintCircle(x0 + off, y0 + off, rad, C_TEXT)
            end

            if wrong then
                local p   = math.max(1, math.floor(cell * 0.18))
                local len = math.max(0, w0 - 2 * p)
                local t   = math.max(2, math.floor(cell / 16))
                drawDiagonalLine(bb, x0 + p, y0 + p,      len, 1,  1, C_TEXT, t)
                drawDiagonalLine(bb, x0 + p, y0 + w0 - p, len, 1, -1, C_TEXT, t)
            end
        end
    end

    -- The hint target gets a heavy frame (inverted on a shaded cell).
    local sel = board.selected
    if sel and not show_sol and board.user[sel.r] then
        local x0, y0, w0 = cx(sel.c), cy(sel.r), cw(sel.c)
        local inset = thick + 1
        local bw = math.max(3, math.floor(cell / 12))
        local col = board.user[sel.r][sel.c] == HeyawakeBoard.STATE_BLACK and C_TEXT_INV or C_TEXT
        bb:paintBorder(x0 + inset, y0 + inset, w0 - 2 * inset, w0 - 2 * inset, bw, col)
    end
end

return HeyawakeBoardWidget
