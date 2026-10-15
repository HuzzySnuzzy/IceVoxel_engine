--[[
	Where the open inventory docks the status icons (client Ui/StatusDock): set and read back, one
	table kept (nothing allocated per call), cleared with nil, and a serial that changes exactly
	when what `get` returns does.
]]

return function(t, _shared, require, _server, client)
	local StatusDock = require(client.Ui.StatusDock)

	t.test("status dock: set, read back, clear; one table; the serial follows changes", function()
		StatusDock.set(nil, 1)
		local none, noneScale = StatusDock.get()
		t.eq(none, nil, "nothing docked")
		t.eq(noneScale, 1)
		local before = StatusDock.serial()
		local at = { x = 10, y = 20, w = 93, h = 23 }
		StatusDock.set(at, 4)
		local rect, scale = StatusDock.get()
		t.ok(rect ~= nil and rect ~= at, "a copy, not the caller's table")
		t.eq((rect :: any).x, 10)
		t.eq((rect :: any).h, 23)
		t.eq(scale, 4)
		t.ok(StatusDock.serial() > before, "the serial changed")
		local serial = StatusDock.serial()
		StatusDock.set({ x = 10, y = 20, w = 93, h = 23 }, 4)
		t.eq(StatusDock.serial(), serial, "the same dock: no change")
		local again = StatusDock.get()
		t.eq(again, rect, "the same table kept")
		StatusDock.set({ x = 11, y = 20, w = 93, h = 23 }, 4)
		t.ok(StatusDock.serial() > serial, "moved: a change")
		t.eq(StatusDock.get(), rect, "still the same table")
		StatusDock.set(nil, 1)
		t.eq(StatusDock.get(), nil, "cleared")
		local cleared = StatusDock.serial()
		StatusDock.set(nil, 1)
		t.eq(StatusDock.serial(), cleared, "clearing twice is no change")
	end)
end
