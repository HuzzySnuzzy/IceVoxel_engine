--[[
	Roblox's fade of the local character held off while the DayZ camera draws the body
	(Player/CameraFade): on a fake client whose PlayerModule has a TransparencyController made as
	Roblox's is (a class table its CameraModule makes one controller from, updated every frame, which
	at its full fade marks itself dirty again on every update: 1 at the 0.5 studs LockFirstPerson
	keeps the camera from its focus), with Player/FirstPersonBody's rule after it (each part written
	only where it differs from what it should be):
	- unhooked, every part is written twice every frame (the review's 20 + 20);
	- hooked and held off, the controller writes nothing and the body's rule only what changes (the
	  parts once, then nothing frame after frame);
	- let go (spectating someone, a spectator), the controller fades every part again at once;
	- a PlayerModule without the method is left alone (`hooked` false).
]]

local FakeClient = require("../lib/FakeClient")

return function(t, shared, require, _server, _client)
	-- A TransparencyController as Roblox's PlayerModule makes it (CameraModule/
	-- TransparencyController's Update, its branch for a camera within 2 studs of its focus).
	local function controllerClass(): any
		local Controller = {}
		Controller.__index = Controller
		function Controller.new()
			return setmetatable({ transparencyDirty = false, lastTransparency = nil, cachedParts = {} }, Controller)
		end
		function Controller:Update(dt: number)
			-- (ClassicCamera in LockFirstPerson: the camera 0.5 studs behind its focus.)
			local distance = 0.5
			local transparency = if distance < 2 then 1 - (distance - 0.5) / 1.5 else 0
			if transparency < 0.5 then
				transparency = 0
			end
			if self.lastTransparency and transparency < 1 and self.lastTransparency < 0.95 then
				local delta = math.clamp(transparency - self.lastTransparency, -2.8 * dt, 2.8 * dt)
				transparency = self.lastTransparency + delta
			else
				self.transparencyDirty = true
			end
			if self.transparencyDirty or self.lastTransparency ~= transparency then
				for part in self.cachedParts do
					part.LocalTransparencyModifier = transparency
				end
				self.transparencyDirty = false
				self.lastTransparency = transparency
			end
		end
		return Controller
	end

	-- The fake client: PlayerScripts.PlayerModule.CameraModule.TransparencyController (with
	-- `withUpdate` false a module without Update), twenty character parts counting their writes.
	local function setUp(withUpdate: boolean)
		local Instance = FakeClient.Instance
		local player = Instance.new("Player")
		local scripts = Instance.new("PlayerScripts")
		scripts.Name = "PlayerScripts"
		scripts.Parent = player
		local playerModule = Instance.new("ModuleScript")
		playerModule.Name = "PlayerModule"
		playerModule.Parent = scripts
		local cameraModule = Instance.new("ModuleScript")
		cameraModule.Name = "CameraModule"
		cameraModule.Parent = playerModule
		local fadeModule = Instance.new("ModuleScript")
		fadeModule.Name = "TransparencyController"
		fadeModule.Parent = cameraModule
		local Controller = controllerClass()
		if not withUpdate then
			Controller.Update = nil
		end
		-- CameraModule's one controller, made from the class before the hook (as it is on joining).
		local controller = Controller.new()
		local counter = { writes = 0 }
		local parts = {}
		for i = 1, 20 do
			local part = setmetatable({ value = 0 }, {
				__index = function(self, key: string)
					return if key == "LocalTransparencyModifier" then rawget(self, "value") else nil
				end,
				__newindex = function(self, key: string, value: number)
					assert(key == "LocalTransparencyModifier", key)
					counter.writes += 1
					rawset(self, "value", value)
				end,
			})
			parts[i] = part
			controller.cachedParts[part] = true
		end
		local load = FakeClient.loader(shared, function(target: any): any
			if target == fadeModule then
				return Controller
			end
			return require(target)
		end, {}, { Players = { LocalPlayer = player } })
		return load("src/client/Player/CameraFade.luau"), controller, parts, counter
	end

	-- One frame: Roblox's camera (its controller's Update), then FirstPersonBody's rule (third
	-- person, the whole body drawn: 0 where it isn't). Returns the writes by each.
	local function frame(controller: any, parts: { any }, counter: { writes: number }): (number, number)
		counter.writes = 0
		controller:Update(1 / 60)
		local roblox = counter.writes
		for _, part in parts do
			if part.LocalTransparencyModifier ~= 0 then
				part.LocalTransparencyModifier = 0
			end
		end
		return roblox, counter.writes - roblox
	end

	t.test("camera fade: unhooked, Roblox's controller and the body write every part every frame", function()
		local _, controller, parts, counter = setUp(true)
		for _ = 1, 3 do
			local roblox, body = frame(controller, parts, counter)
			t.eq(roblox, 20, "the controller fades every part")
			t.eq(body, 20, "the body's rule writes every part back")
		end
	end)

	t.test("camera fade: held off, the body's rule alone writes, and only what changes", function()
		local CameraFade, controller, parts, counter = setUp(true)
		local held = true
		CameraFade.hook(function(): boolean
			return held
		end)
		t.ok(CameraFade.hooked(), "hooked")
		-- (The parts start faded, as Roblox left them before the rig took over.)
		for _, part in parts do
			part.LocalTransparencyModifier = 1
		end
		local roblox, body = frame(controller, parts, counter)
		t.eq(roblox, 0, "the controller writes nothing")
		t.eq(body, 20, "the body shown once")
		for _ = 1, 5 do
			roblox, body = frame(controller, parts, counter)
			t.eq(roblox, 0)
			t.eq(body, 0, "then nothing, frame after frame")
		end
		-- Let go (spectating someone, a spectator): the controller fades everything at once again.
		held = false
		counter.writes = 0
		controller:Update(1 / 60)
		t.eq(counter.writes, 20, "faded again in full")
		t.eq(parts[1].LocalTransparencyModifier, 1)
	end)

	t.test("camera fade: a PlayerModule without the method is left alone", function()
		local CameraFade, controller = setUp(false)
		CameraFade.hook(function(): boolean
			return true
		end)
		t.ok(not CameraFade.hooked(), "not hooked")
		t.eq(controller.Update, nil, "nothing put in its place")
	end)
end
