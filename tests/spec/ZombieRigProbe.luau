--[[
	The zombie rig Studio probe (tools/probes/ZombieRigProbe.client.luau) run whole in Lune, so it
	is known to finish and count right before anyone runs it on a device, and the parts glue it
	shares with the game (client Entities/MobParts, which MobRenderer draws the mobs with).

	Both run on Lune's Roblox instances (@lune/roblox: Parts, Fires and Folders whose properties
	are Roblox's own, and which are locked once destroyed, so a Fire destroyed with a part errors
	when it is moved again, as in Roblox), with the game's modules from the runner and stand-ins
	for what Lune lacks: a clock that moves FRAME seconds a RenderStepped, RenderStepped itself,
	task.wait, the camera, the MicroProfiler labels and Workspace:BulkMoveTo (its two lists the
	same length, as Roblox requires).

	  probe   both passes finish and print their lines: the rigs pass with at most 16 full rigs
	          and 40 in all, 464 parts moved a frame, the boxes pass two boxes a zombie; no part
	          made after the warm-up, no flames lost; its folder gone at the end. Every
	          CHECK_EVERY-th move the moved parts are checked as the scene shows them: each in the
	          probe's folder and moved once, sized and painted as MobRigPool asked, shadows only
	          from the head and torsos (the first ShadowParts of them) and from the boxes, every
	          frame a rotation (CFrame.new takes the 12 numbers as given: orthonormal, not
	          mirrored). It measures no time: the Lua and frame columns are the device's to fill
	          (tools/probes/README.md).
	  flames  a burning zombie walked through every tier with no spare rigs, so every rig let go
	          is destroyed: its Fire is always on the part its tier burns on and outlives them all.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local PROBE = "tools/probes/ZombieRigProbe.client.luau"
local PARTS = "src/client/Entities/MobParts.luau"
local GLOBALS = "script, require, game, workspace, Instance, Vector3, CFrame, Color3, Enum, task, debug, os, print"
-- The stand-in's frame (30 a second: the probe's 2 x 40 s in 2400 frames).
local FRAME = 1 / 30
-- Moves between two checks of the moved parts.
local CHECK_EVERY = 7
-- (Workspace:BulkMoveTo added to Lune's Workspace.)
local BULK_MOVE_ADDED = false

-- A script's source with GLOBALS declared from the chunk's arguments (after the --! lines).
local function withHeader(source: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = `local {GLOBALS} = ...; ` .. (lines[i] or "")
	return table.concat(lines, "\n")
end

-- One line the probe printed: pass name, then its numbers in order.
local LINE = "^%[ZombieRigProbe%] (%a+)%s*| Lua ms ([%d%.]+) / ([%d%.]+) / ([%d%.]+) | frame ms ([%d%.]+) / ([%d%.]+) | "
	.. "(%d+) parts moved | (%d+) / (%d+) rigs | (%d+) parts made after the warm%-up | (%d+) flames lost$"

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local MobList = require(shared.Entities.MobList)
	local MobModel = require(client.Entities.MobModel)
	local MobRig = require(client.Entities.MobRig)
	local MobRigPool = require(client.Entities.MobRigPool)
	local ZombieLooks = require(client.Entities.ZombieLooks)

	local BLOCK = Config.BlockSize
	local S = Config.Mobs.Rig
	local FULL, REDUCED, IMPOSTOR = MobRig.FULL, MobRig.REDUCED, MobRig.IMPOSTOR

	-- The slots that cast shadows by tier (the impostor's boxes all do).
	local casts = { {}, {}, {} }
	for i, slot in { MobRig.HEAD, MobRig.UPPER_TORSO, MobRig.LOWER_TORSO } do
		casts[FULL][slot] = i <= S.ShadowParts
	end
	for i, slot in { MobRig.REDUCED_HEAD, MobRig.TORSO } do
		casts[REDUCED][slot] = i <= S.ShadowParts
	end

	-- Workspace:BulkMoveTo (Lune lets a method be added to a class once): the scene's own.
	local scenes: { current: any } = { current = nil }
	if not BULK_MOVE_ADDED then
		BULK_MOVE_ADDED = true
		roblox.implementMethod("Workspace", "BulkMoveTo", function(self, ...)
			return scenes.current.bulkMoveTo(self, ...)
		end)
	end

	-- A scene: a Workspace with a camera, a stand-in clock, RenderStepped and task.wait, and what
	-- the probe printed and the checks found.
	local function scene()
		local Instance = roblox.Instance
		local dataModel = Instance.new("DataModel")
		local workspace = dataModel:GetService("Workspace")
		local camera = Instance.new("Camera")
		-- (The fallback when there is no character: the probe's centre, block (100, 70, -40).)
		camera.Focus = roblox.CFrame.new(100 * BLOCK, 70 * BLOCK + 3, -40 * BLOCK)
		camera.Parent = workspace
		workspace.CurrentCamera = camera
		local w: any = {
			workspace = workspace,
			now = 5000,
			frames = 0,
			connections = {},
			lines = {},
			labels = {},
			depth = 0,
			moves = 0,
			checked = 0,
			problems = {},
		}
		local function problem(text: string)
			if #w.problems < 10 then
				table.insert(w.problems, text)
			end
		end
		w.problem = problem
		w.RunService = {
			RenderStepped = {
				Connect = function(_, fn: (number) -> ())
					local connection = { fn = fn }
					table.insert(w.connections, connection)
					return {
						Disconnect = function()
							local i = table.find(w.connections, connection)
							if i then
								table.remove(w.connections, i)
							end
						end,
					}
				end,
			},
		}
		w.task = {
			wait = function(seconds: number): number
				local target = w.now + seconds - 1e-9
				while w.now < target do
					w.now += FRAME
					w.frames += 1
					for _, connection in table.clone(w.connections) do
						connection.fn(FRAME)
					end
				end
				return seconds
			end,
		}
		w.debug = {
			profilebegin = function(label: string)
				w.depth += 1
				w.labels[label] = (w.labels[label] or 0) + 1
			end,
			profileend = function()
				w.depth -= 1
				if w.depth < 0 then
					problem("profileend without profilebegin")
				end
			end,
		}
		w.os = {
			clock = function(): number
				return w.now
			end,
		}
		w.print = function(...)
			table.insert(w.lines, table.concat({ ... }, " "))
		end
		w.player = {
			Character = nil,
			WaitForChild = function(_, name: string)
				assert(name == "PlayerScripts", `no fake child {name}`)
				return {
					WaitForChild = function(_, child: string)
						assert(child == "IceVoxel", `no fake child {child}`)
						return client
					end,
				}
			end,
		}
		w.game = {
			GetService = function(_, name: string): any
				if name == "ReplicatedStorage" then
					return shared.Parent
				elseif name == "Players" then
					return { LocalPlayer = w.player }
				elseif name == "RunService" then
					return w.RunService
				end
				error(`no fake service {name}`)
			end,
		}
		-- Workspace:BulkMoveTo: the lists as Roblox requires them; every CHECK_EVERY-th move, each
		-- part in the scene and moved once, each frame a rotation.
		w.bulkMoveTo = function(self, parts: { any }, cframes: { any }, mode: any)
			assert(self == workspace, "BulkMoveTo on another Workspace")
			assert(mode == roblox.Enum.BulkMoveMode.FireCFrameChanged, "BulkMoveTo's mode")
			if #parts ~= #cframes then
				error(`BulkMoveTo: {#parts} parts and {#cframes} CFrames`)
			end
			w.moves += 1
			if w.moves % CHECK_EVERY ~= 0 then
				return
			end
			local seen = {}
			for i, part in parts do
				if seen[part] then
					problem(`a part moved twice in one BulkMoveTo (move {w.moves})`)
				end
				seen[part] = true
				local folder = part.Parent
				if folder == nil or folder.Parent ~= workspace then
					problem(`a part moved out of the scene (move {w.moves})`)
				end
				local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cframes[i]:GetComponents()
				local rows = { { r00, r01, r02 }, { r10, r11, r12 }, { r20, r21, r22 } }
				for a = 1, 3 do
					for b = 1, 3 do
						local dot = rows[a][1] * rows[b][1] + rows[a][2] * rows[b][2] + rows[a][3] * rows[b][3]
						if math.abs(dot - (if a == b then 1 else 0)) > 1e-4 then
							problem(`a frame that is not a rotation (move {w.moves}, part {i}: rows {a}.{b} = {dot})`)
						end
					end
				end
				local det = r00 * (r11 * r22 - r12 * r21)
					- r01 * (r10 * r22 - r12 * r20)
					+ r02 * (r10 * r21 - r11 * r20)
				if det < 0 then
					problem(`a mirrored frame (move {w.moves}, part {i})`)
				end
				part.CFrame = cframes[i]
			end
			w.checked += 1
		end
		scenes.current = w
		return w
	end

	-- Entities/MobParts loaded with the scene's globals.
	local function partsModule(w: any): any
		local chunk = luau.load(withHeader(fs.readFile(PARTS)), { debugName = PARTS })
		return chunk(
			client.Entities.MobParts,
			require,
			w.game,
			w.workspace,
			roblox.Instance,
			roblox.Vector3,
			roblox.CFrame,
			roblox.Color3,
			roblox.Enum,
			w.task,
			w.debug,
			w.os,
			w.print
		)
	end

	-- Every drawn part of every rig as MobRigPool asked: size, colour, shadow (on real Parts).
	local function checkPool(w: any, pool: any)
		for _, entry in pool.order do
			local rig = entry.rig
			local shape = rig.shape
			for slot = 1, shape.count do
				if not shape.hidden[slot] then
					local part = rig.parts[slot]
					local k = slot * 3
					local size = part.Size
					if
						math.abs(size.X - shape.size[k - 2]) > 1e-3
						or math.abs(size.Y - shape.size[k - 1]) > 1e-3
						or math.abs(size.Z - shape.size[k]) > 1e-3
					then
						w.problem(`tier {rig.tier} slot {slot} sized {size}, not as its shape`)
					end
					local r, g, b = ZombieLooks.unpack(rig.painted[slot])
					local colour = part.Color
					if
						math.round(colour.R * 255) ~= r
						or math.round(colour.G * 255) ~= g
						or math.round(colour.B * 255) ~= b
					then
						w.problem(`tier {rig.tier} slot {slot} painted {colour}, not {r}, {g}, {b}`)
					end
					local shadow = if rig.tier == IMPOSTOR then true else casts[rig.tier][slot] == true
					if part.CastShadow ~= shadow then
						w.problem(`tier {rig.tier} slot {slot} CastShadow {part.CastShadow}`)
					end
				end
			end
		end
	end

	t.test("zombie rig probe: both passes finish in Lune, no part made after the warm-up, no flames lost", function()
		local w = scene()
		local MobParts = partsModule(w)
		local pools = {}
		-- The probe gets MobParts with its move watched (the pool checked every CHECK_EVERY-th).
		local watched = setmetatable({
			move = function(pool: any, cframes: { any })
				MobParts.move(pool, cframes)
				if pools[pool] == nil then
					pools[pool] = true
				end
				if w.moves % CHECK_EVERY == 0 then
					checkPool(w, pool)
				end
			end,
		}, { __index = MobParts })
		local function probeRequire(node: any): any
			if node == client.Entities.MobParts then
				return watched
			end
			return require(node)
		end
		math.randomseed(20261014)
		local chunk = luau.load(withHeader(fs.readFile(PROBE)), { debugName = PROBE })
		chunk(
			nil,
			probeRequire,
			w.game,
			w.workspace,
			roblox.Instance,
			roblox.Vector3,
			roblox.CFrame,
			roblox.Color3,
			roblox.Enum,
			w.task,
			w.debug,
			w.os,
			w.print
		)
		t.eq(#w.problems, 0, `the moved parts: {table.concat(w.problems, "; ")}`)
		t.eq(w.depth, 0, "every profilebegin ended")
		t.eq(#w.connections, 0, "both passes disconnected")
		local passes = 0
		for _ in pools do
			passes += 1
		end
		t.eq(passes, 2, "a pool a pass")
		-- 5 s, then 2 x 40 s and a frame or two each to notice the end.
		t.ok(w.frames >= 85 / FRAME and w.frames <= 85 / FRAME + 10, `frames run: {w.frames}`)
		t.ok(w.labels.IceVoxelZombieRigs >= 80 / FRAME, "the MicroProfiler label every frame of both passes")
		t.ok(w.checked >= 80 / FRAME / CHECK_EVERY - 2, `moves checked: {w.checked}`)
		t.eq(#w.lines, 3, `lines printed: {table.concat(w.lines, " / ")}`)
		print(`         the probe's lines in Lune ({w.checked} moves checked; no time measured):`)
		for _, line in w.lines do
			print("           " .. line)
		end
		local results = {}
		for i = 1, 2 do
			local line = w.lines[i]
			local name, _, _, _, frameMean, _, moved, full, reduced, made, lost = string.match(line, LINE)
			t.ok(name ~= nil, `a probe line: {line}`)
			results[name] = {
				frameMean = tonumber(frameMean),
				moved = tonumber(moved),
				full = tonumber(full),
				reduced = tonumber(reduced),
				made = tonumber(made),
				lost = tonumber(lost),
			}
		end
		t.ok(string.find(w.lines[3], "[ZombieRigProbe] done", 1, true) ~= nil, "the last line")
		local zombies = 0
		local boxes = 0
		for _, kind in MobList.kinds do
			if kind.zombie then
				zombies += 1
				boxes = math.max(boxes, #kind.parts)
			end
		end
		local rigs, flat = results.rigs, results.boxes
		t.ok(rigs ~= nil and flat ~= nil, "a rigs and a boxes line")
		t.near(rigs.frameMean, FRAME * 1000, 0.01, "the stand-in's frames")
		-- The rigs pass (its busiest frame): the caps hold, both tiers are used, nothing made or lost.
		t.ok(rigs.full <= S.MaxFull and rigs.full >= S.MaxFull / 2, `full rigs: {rigs.full}`)
		t.ok(rigs.reduced >= 1 and rigs.full + rigs.reduced <= S.MaxRigs, `rigs: {rigs.full} / {rigs.reduced}`)
		t.ok(rigs.moved <= 16 * 17 + 24 * 8, `parts moved: {rigs.moved}`)
		t.ok(rigs.moved > 60 * 2, `parts moved: {rigs.moved}`)
		t.eq(rigs.made, 0, "parts made after the warm-up (rigs)")
		t.eq(rigs.lost, 0, "flames lost (rigs)")
		-- The boxes pass: two boxes a zombie.
		t.eq(flat.full + flat.reduced, 0, "no rig (boxes)")
		t.ok(flat.moved <= 60 * boxes and flat.moved >= 60, `parts moved: {flat.moved}`)
		t.eq(flat.made, 0, "parts made after the warm-up (boxes)")
		t.eq(flat.lost, 0, "flames lost (boxes)")
		-- Its folder gone (the camera stays).
		t.eq(#w.workspace:GetChildren(), 1, "the probe's folder is gone")
		t.ok(zombies >= 2, "zombie kinds")
	end)

	t.test("mob parts: on Roblox instances, flames outlive every rig let go and destroyed under them", function()
		local w = scene()
		local MobParts = partsModule(w)
		local folder = roblox.Instance.new("Folder")
		folder.Parent = w.workspace
		-- No spares: every rig let go is destroyed, with whatever hangs on its parts.
		local settings = table.clone(S)
		settings.SpareFull, settings.SpareReduced = 0, 0
		local pool = MobRigPool.new(MobParts.factory(folder), settings)
		local zombie = MobList.get(MobList.find("Zombie") :: number) :: MobList.Kind
		local mob = MobModel.new(1, zombie, 1, { x = 2, y = 0, z = 0, yaw = 0, health = 20, flags = 0 }, 0)
		MobRigPool.add(pool, mob)
		local flames = MobParts.flames(zombie.height)
		t.near(flames.Size, math.max(2, zombie.height * MobParts.FLAME_SIZE), 1e-4, "sized by the mob's height")
		MobRigPool.setFlames(pool, 1, flames)
		local cframes = {}
		local now = 0
		local tiers = {}
		-- Out through the reduced tier and the boxes, and back.
		for _, x in { 2, 25, 60, 30, 5, 60, 2 } do
			mob.x, mob.z, mob.fx, mob.fz = x, 0, x, 0
			mob.duration = 0
			for _ = 1, 2 do
				now += 1 / 60
				MobRigPool.frame(pool, now, 0, zombie.height / 2, 0, 0, 0)
				MobParts.move(pool, cframes)
				local entry = pool.entries[1]
				local anchor = MobRigPool.anchor(entry)
				t.eq(flames.Parent, anchor, `on the part its tier burns on (x {x})`)
				t.eq((anchor :: any).Parent, folder, "a part in the scene")
			end
			table.insert(tiers, (pool.entries[1].rig :: any).tier)
		end
		t.eq(table.concat(tiers, " "), "1 2 3 2 1 3 1", "the tiers walked through")
		t.ok(pool.destroyed >= 5 * 8, `rigs destroyed under the flames: {pool.destroyed} parts`)
		-- Still a live Fire (a destroyed one's Parent is locked: setting it errors).
		flames.Parent = folder
		flames.Parent = MobRigPool.anchor(pool.entries[1])
		MobRigPool.remove(pool, 1)
		t.eq(flames.Parent, nil, "taken off when the mob goes")
		flames:Destroy()
		t.eq(#folder:GetChildren(), 0, "no part left in the scene")
	end)
end
