--[[
	The re-base core (client Rendering/Rebase) with fake parts, camera and workspace (BulkMoveTo
	recorded): off, nothing moves and requests are dropped; past RebaseDistance one step moves the
	origin under the camera with one BulkMoveTo of every mover's parts (each moved by -d), movers
	called once in order with (dx, dz) after Origin's listeners, the camera's CFrame and Focus
	shifted; a request (teleport) beats the camera's plan, and one within SoftDistance leaves it to
	the camera; hidden reasons count once each and let the soft distance move it; a failing mover is
	left out while the others move; removed movers aren't called; `now` forces a move; the stats.

	Rebase is loaded here with its Roblox globals as arguments (as tests/spec/RenderPipeline loads
	Rendering modules); Shared modules come from the runner (its Origin, reset around each test).
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local V3 = roblox.Vector3
local CF = roblox.CFrame

local PATH = "src/client/Rendering/Rebase.luau"
local GLOBALS = "script, require, game, workspace, Vector3, CFrame, Enum, os, warn, print"

-- Rebase's source with GLOBALS declared from the chunk's arguments (after the --! lines).
local function withHeader(source: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = `local {GLOBALS} = ...; ` .. (lines[i] or "")
	return table.concat(lines, "\n")
end

return function(t, shared, require, _server, _client)
	local Config = require(shared.Config)
	local Origin = require(shared.World.Origin)
	local Settings = Config.Origin
	local wasEnabled = Settings.Enabled
	local source = withHeader(fs.readFile(PATH))

	-- A fresh Rebase in a fake world: the camera at render (x, 50, z).
	local function world(cameraX: number, cameraZ: number): any
		local w: any = {
			moves = {},
			warnings = {},
			lines = {},
			camera = {
				CFrame = CF.new(cameraX, 50, cameraZ) * CF.Angles(0, 0.3, 0),
				Focus = CF.new(cameraX, 48, cameraZ - 10),
			},
		}
		w.workspace = {
			CurrentCamera = w.camera,
			BulkMoveTo = function(_, parts: { any }, cframes: { any }, mode: any)
				table.insert(w.moves, { parts = table.clone(parts), cframes = table.clone(cframes), mode = mode })
			end,
		}
		local game = {
			GetService = function(_, name: string): any
				assert(name == "ReplicatedStorage", `no fake service {name}`)
				return {
					WaitForChild = function(_, child: string)
						assert(child == "IceVoxel")
						return shared
					end,
				}
			end,
		}
		local chunk = luau.load(source, { debugName = PATH })
		w.Rebase = chunk({ Name = "Rebase" }, require, game, w.workspace, V3, CF, roblox.Enum, os, function(...)
			table.insert(w.warnings, table.concat({ ... }, " "))
		end, function(...)
			table.insert(w.lines, table.concat({ ... }, " "))
		end)
		-- Parts placed once (MOVE): a mover for each list.
		function w.parts(name: string, count: number): { any }
			local list = {}
			for i = 1, count do
				table.insert(list, { Name = `{name}{i}`, CFrame = CF.new(i * 3, 10, -i * 3) })
			end
			return list
		end
		function w.mover(list: { any }, log: { any }, name: string)
			return function(dx: number, dz: number, parts: { any }, cframes: { any })
				table.insert(log, { name, dx, dz, Origin.epoch })
				local d = V3.new(dx, 0, dz)
				for _, part in list do
					table.insert(parts, part)
					table.insert(cframes, part.CFrame - d)
				end
			end
		end
		return w
	end

	local function begin(on: boolean)
		Origin.reset()
		Settings.Enabled = on
	end
	local function finish()
		Origin.reset()
		Settings.Enabled = wasEnabled
	end

	t.test("rebase: off, nothing moves and requests are dropped", function()
		begin(false)
		local w = world(1e6, -1e6)
		local log = {}
		w.Rebase.register("terrain", w.mover(w.parts("p", 3), log, "terrain"))
		w.Rebase.request(3e6, 3e6)
		w.Rebase.now()
		w.Rebase.step()
		t.eq(#w.moves, 0, "no BulkMoveTo")
		t.eq(#log, 0, "no mover")
		t.eq(Origin.x, 0)
		t.eq(w.camera.CFrame.Position, V3.new(1e6, 50, -1e6), "the camera stays")
		-- Switched on, the dropped request doesn't come back (the camera is near now).
		Settings.Enabled = true
		w.camera.CFrame = CF.new(10, 50, 10)
		w.Rebase.step()
		t.eq(#w.moves, 0, "the request was dropped")
		finish()
	end)

	t.test("rebase: past RebaseDistance one step moves everything once, the camera too", function()
		begin(true)
		local cameraX = Settings.RebaseDistance + 100
		local w = world(cameraX, -500)
		local log = {}
		local heard = {}
		Origin.onRebase(function(dx, dz, epoch)
			table.insert(log, { "listener", dx, dz, epoch })
			table.insert(heard, epoch)
		end)
		local terrain, pipes = w.parts("t", 5), w.parts("p", 2)
		w.Rebase.register("terrain", w.mover(terrain, log, "terrain"))
		w.Rebase.register("pipes", w.mover(pipes, log, "pipes"))
		local look = w.camera.CFrame.LookVector
		-- Within: nothing.
		w.camera.CFrame = CF.new(Settings.RebaseDistance, 50, 0)
		w.Rebase.step()
		t.eq(#w.moves, 0, "at the distance: nothing")
		w.camera.CFrame = CF.new(cameraX, 50, -500) * CF.Angles(0, 0.3, 0)
		w.Rebase.step()
		local dx, dz = Origin.snap(cameraX), Origin.snap(-500)
		t.eq(Origin.x, dx, "the origin under the camera (X)")
		t.eq(Origin.z, dz, "and Z")
		t.eq(#w.moves, 1, "one BulkMoveTo")
		local move = w.moves[1]
		t.eq(move.mode, roblox.Enum.BulkMoveMode.FireCFrameChanged, "firing CFrameChanged")
		t.eq(#move.parts, 7, "every mover's parts")
		for i, part in move.parts do
			t.eq(move.cframes[i], part.CFrame - V3.new(dx, 0, dz), `{part.Name} moved by -d`)
		end
		t.eq(move.parts[1], terrain[1], "in the movers' order")
		t.eq(move.parts[6], pipes[1])
		-- Listener first, then the movers in order, each once, with the move.
		t.eq(#log, 3)
		t.eq(log[1][1], "listener")
		t.eq(log[2][1], "terrain")
		t.eq(log[3][1], "pipes")
		t.eq(log[2][2], dx)
		t.eq(log[2][3], dz)
		t.eq(log[3][4], 1, "after the epoch moved")
		-- The camera and its focus by -d, still looking the same way.
		t.ok(w.camera.CFrame.Position:FuzzyEq(V3.new(cameraX - dx, 50, -500 - dz), 1e-3), "camera moved")
		t.ok(w.camera.CFrame.LookVector:FuzzyEq(look, 1e-6), "camera turned nowhere")
		t.ok(w.camera.Focus.Position:FuzzyEq(V3.new(cameraX - dx, 48, -510 - dz), 1e-3), "focus moved")
		-- The next step: the camera is near the origin, nothing more.
		w.Rebase.step()
		t.eq(#w.moves, 1, "once")
		-- Stats and the line.
		local stats = w.Rebase.stats()
		t.eq(stats.count, 1)
		t.eq(stats.lastParts, 7)
		t.eq(stats.epoch, 1)
		t.eq(stats.x, dx)
		t.eq(stats.z, dz)
		t.ok(stats.lastMs >= 0, "timed")
		t.eq(#w.lines, 1)
		t.ok(string.find(w.lines[1], "origin moved by", 1, true) ~= nil, w.lines[1])
		finish()
	end)

	t.test("rebase: a request beats the camera; one within SoftDistance leaves it to the camera", function()
		begin(true)
		local w = world(Settings.RebaseDistance + 1000, 0)
		w.Rebase.request(-3e6 + 0.5, 1e5)
		w.Rebase.step()
		t.eq(Origin.x, Origin.snap(-3e6 + 0.5), "the destination's X")
		t.eq(Origin.z, Origin.snap(1e5), "the destination's Z")
		t.eq(Origin.epoch, 1, "one move")
		-- A request near the origin: the camera's plan instead.
		Origin.reset()
		local w2 = world(Settings.RebaseDistance + 1000, 0)
		w2.Rebase.request(Settings.SoftDistance - 1, 0)
		w2.Rebase.step()
		t.eq(Origin.x, Origin.snap(Settings.RebaseDistance + 1000), "under the camera")
		t.eq(Origin.epoch, 1)
		-- Requests are used once.
		w2.Rebase.step()
		t.eq(Origin.epoch, 1, "nothing pending")
		finish()
	end)

	t.test("rebase: hidden reasons count once each and allow the soft distance", function()
		begin(true)
		local soft = Settings.SoftDistance
		local w = world(soft + 10, 0)
		t.ok(not w.Rebase.hidden(), "nothing hidden")
		w.Rebase.step()
		t.eq(Origin.epoch, 0, "past soft, not hidden: no move")
		w.Rebase.setHidden("map", true)
		w.Rebase.setHidden("screen", true)
		w.Rebase.setHidden("map", true)
		w.Rebase.setHidden("map", false)
		t.ok(w.Rebase.hidden(), "the screen still hides")
		w.Rebase.setHidden("screen", false)
		w.Rebase.setHidden("screen", false)
		t.ok(not w.Rebase.hidden(), "nothing hides any more (no negative count)")
		w.Rebase.step()
		t.eq(Origin.epoch, 0, "not hidden: no move")
		w.Rebase.setHidden("menu", true)
		w.Rebase.step()
		t.eq(Origin.epoch, 1, "hidden: moved")
		t.eq(Origin.x, Origin.snap(soft + 10))
		finish()
	end)

	t.test("rebase: a failing mover is left out, removed movers aren't called", function()
		begin(true)
		local w = world(-Settings.RebaseDistance - 1, 0)
		local log = {}
		local good = w.parts("g", 2)
		w.Rebase.register("good", w.mover(good, log, "good"))
		w.Rebase.register("broken", function(_dx, _dz, parts, _cframes)
			table.insert(parts, { Name = "half", CFrame = CF.new() })
			error("broken mover")
		end)
		w.Rebase.register("unpaired", function(_dx, _dz, parts, _cframes)
			table.insert(parts, { Name = "lonely", CFrame = CF.new() })
		end)
		local removed = w.Rebase.register("removed", w.mover(w.parts("r", 4), log, "removed"))
		removed()
		local after = w.parts("a", 1)
		w.Rebase.register("after", w.mover(after, log, "after"))
		w.Rebase.step()
		t.eq(#w.moves, 1)
		local names = {}
		for _, part in w.moves[1].parts do
			table.insert(names, part.Name)
		end
		t.eq(table.concat(names, " "), "g1 g2 a1", "only the good movers' parts")
		t.eq(#w.moves[1].cframes, 3, "paired")
		t.eq(#w.warnings, 2, "both failures warned about")
		for _, entry in log do
			t.ok(entry[1] ~= "removed", "the removed mover isn't called")
		end
		finish()
	end)

	t.test("rebase: now forces a move, under the camera or by one snap", function()
		begin(true)
		local w = world(100, -100)
		w.Rebase.now()
		w.Rebase.step()
		t.eq(Origin.epoch, 1, "moved")
		t.eq(Origin.x, Settings.Snap, "by one snap along X (the camera was over the origin)")
		t.eq(Origin.z, 0)
		-- Away from it: under the camera.
		w.camera.CFrame = CF.new(2000, 50, -2000)
		w.Rebase.now()
		w.Rebase.step()
		t.eq(Origin.x, Origin.snap(Settings.Snap + 2000))
		t.eq(Origin.z, Origin.snap(-2000))
		-- With no movers and no parts: no BulkMoveTo, but the camera still moves.
		t.eq(#w.moves, 0, "no BulkMoveTo for no parts")
		t.ok(math.abs(w.camera.CFrame.Position.X) < Settings.Snap, "the camera moved")
		finish()
	end)
end
