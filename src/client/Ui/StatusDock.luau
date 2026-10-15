--!strict
--[[
	Where the open inventory wants the status icons (the notifiers): Ui/Screens sets it from the
	inventory screen every frame while the inventory is the shown screen (its quickbar band's
	status rectangle) and clears it otherwise; the HUD's status icons read it every frame and
	draw themselves there (docked, notifiers only) while it is set, in the HUD's corner otherwise.

	Rules:

	  * The rectangle is in absolute screen pixels (the GUI's AbsolutePosition space) and `scale`
	    is the GUI scale to draw at there.
	  * Nothing is allocated per call: the rectangle is copied into one table kept here, and `get`
	    returns that same table (read it, never keep or change it) or nil. `serial` grows whenever
	    what `get` returns changes, so readers can skip comparing fields.
	  * Pure: no Roblox APIs.
]]

export type Rect = { x: number, y: number, w: number, h: number }

local StatusDock = {}

local rect: Rect = { x = 0, y = 0, w = 0, h = 0 }
local docked = false
local dockScale = 1
local changes = 0

-- Docks the status icons at `at` (absolute screen pixels) drawn at GUI `scale`; nil undocks.
function StatusDock.set(at: Rect?, scale: number)
	if at == nil then
		if docked or dockScale ~= scale then
			docked = false
			dockScale = scale
			changes += 1
		end
		return
	end
	if docked and dockScale == scale and rect.x == at.x and rect.y == at.y and rect.w == at.w and rect.h == at.h then
		return
	end
	rect.x, rect.y, rect.w, rect.h = at.x, at.y, at.w, at.h
	docked = true
	dockScale = scale
	changes += 1
end

-- The dock (nil: none) and its scale.
function StatusDock.get(): (Rect?, number)
	return if docked then rect else nil, dockScale
end

-- A number that changes whenever the dock does.
function StatusDock.serial(): number
	return changes
end

return StatusDock
