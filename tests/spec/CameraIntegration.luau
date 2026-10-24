--[[
	The camera's parts together (docs/ARCHITECTURE "Camera": the rig, the first-person body, aim and
	targeting, the body's motion), on the merged sources and their pure rules:
	- the frame order: every render step bound in src/client at the priority the Camera section's
	  frame table gives (Roblox's camera at Camera: the rig + 1, Player/FirstPersonBody + 2,
	  Player/SpectatorView + 3, the view bob + 4, the aim's sway + 5, Player/BodyTwist + 6,
	  Player/HeldItems + 7, Player/EquipmentLooks + 8, the sound listener and
	  Interaction/BlockInteraction's frame (targeting reads the camera as drawn) + 9; before it the
	  trigger's state - 4, the origin - 3, the remote players and the unsway - 2, the movement - 1),
	  AimCamera's mouse lock only without the rig, and HeldItems and BlockInteraction off
	  RenderStepped;
	- the require rules: no cycle among the client modules; nothing Interaction/Firearms or
	  Interaction/MeleeInput reaches requires Interaction/BlockInteraction; Player/CameraRig reaches
	  no Ui/ or Interaction/ module, nor MovementController or AimCamera; Player/FirstPersonBody
	  requires only CameraRig, FirstPersonRules and SpectatorRules (and Shared) and reaches none of
	  MovementController, AimCamera and HeldItems;
	- one writer each: the characters' LocalTransparencyModifier (FirstPersonBody the local one with
	  the rig, SpectatorView raising; AimCamera's third-person sights only without the rig; held
	  items and worn pieces their own models), the joints' C0 (MovementController the root,
	  BodyTwist the hips and the waist, WeaponPoses the shoulders and the neck, FirstPersonBody the
	  arms in first person);
	- the freelook contract between them: the camera's turn from the aim is positive to the left
	  (CameraRules.aim, what CameraRig.freelookOffset gives), WeaponPoses' neck reach is BodyRules'
	  neck share, and the neck and the waist make Config.Camera.FreelookYawFirst.
]]

local fs = require("@lune/fs")

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local BodyRules = require(client.Player.BodyRules)
	local CameraRules = require(client.Player.CameraRules)
	local WeaponPoses = require(client.Player.WeaponPoses)

	local CAMERA = 200
	local EPS = 1e-9

	-- Every module file under src/client (not the boot scripts), by its place ("Player/CameraRig";
	-- a folder's init.luau is the folder).
	local function modules(): { [string]: string }
		local found: { [string]: string } = {}
		local function walk(dir: string, place: string)
			for _, name in fs.readDir(dir) do
				local path = `{dir}/{name}`
				if fs.isDir(path) then
					walk(path, if place == "" then name else `{place}/{name}`)
				elseif string.sub(name, -5) == ".luau" and string.find(name, "%.client%.luau$") == nil then
					local stem = string.sub(name, 1, -6)
					local key = if stem == "init" then place elseif place == "" then stem else `{place}/{stem}`
					found[key] = path
				end
			end
		end
		walk("src/client", "")
		return found
	end
	local files = modules()

	-- `source` without its comments (block comments first).
	local function code(source: string): string
		source = string.gsub(source, "%-%-%[(=*)%[.-%]%1%]", "")
		return (string.gsub(source, "%-%-[^\n]*", ""))
	end

	--[[ The frame order ]]

	-- The definition of the local constant `name` in `source` (its expression), if any.
	local function constant(source: string, name: string): string?
		local expression = string.match(source, `\n%s*local {name}%s*=%s*([^\n]+)`)
		return if expression then string.match(expression, "^(.-)%s*$") else nil
	end

	-- A priority's value (`expression` in `source`): Roblox's camera's, a number, a constant, and
	-- sums and differences of them; nil when it can't be read.
	local function value(source: string, expression: string, depth: number): number?
		expression = string.match(expression, "^%s*(.-)%s*$") :: string
		if depth > 6 then
			return nil
		elseif expression == "Enum.RenderPriority.Camera.Value" then
			return CAMERA
		end
		local number = tonumber(expression)
		if number then
			return number
		end
		local left, op, right = string.match(expression, "^(.-)%s*([%+%-])%s*([%w_%.]+)$")
		if left and left ~= "" then
			local a, b = value(source, left, depth + 1), value(source, right, depth + 1)
			if a and b then
				return if op == "+" then a + b else a - b
			end
			return nil
		end
		if string.match(expression, "^[%a_][%w_]*$") then
			local definition = constant(source, expression)
			if definition then
				return value(source, definition, depth + 1)
			end
		end
		return nil
	end

	-- Every render step bound in src/client: its name, its priority's offset from the camera's, and
	-- the module binding it.
	local function steps(): { [string]: { offset: number?, module: string } }
		local bound: { [string]: { offset: number?, module: string } } = {}
		for key, path in files do
			local source = code(fs.readFile(path))
			for nameExpression, priorityExpression in string.gmatch(source, "BindToRenderStep%(%s*([^,]+),%s*([^,]+),") do
				local name = string.match(nameExpression, '^"([^"]+)"$')
				if name == nil then
					local definition = constant(source, nameExpression)
					name = if definition then string.match(definition, '^"([^"]+)"') else nil
				end
				local priority = value(source, priorityExpression, 0)
				bound[name or `{key}: {nameExpression}`] =
					{ offset = if priority then priority - CAMERA else nil, module = key }
			end
		end
		return bound
	end

	t.test("camera integration: every render step at its place in the frame (Camera +/- n)", function()
		-- The Camera section's frame table (docs/ARCHITECTURE): name -> offset from Camera (200).
		local expected: { [string]: number } = {
			IceVoxelFirearmsState = -4,
			IceVoxelOrigin = -3,
			IceVoxelRemotePlayers = -2,
			IceVoxelAimUnsway = -2,
			IceVoxelMovement = -1,
			IceVoxelDying = -1,
			IceVoxelCameraRig = 1,
			IceVoxelAimLock = 1,
			IceVoxelScreensMouse = 1,
			IceVoxelChatMouse = 1,
			IceVoxelSwitcherMouse = 1,
			IceVoxelExplosionShake = 1,
			IceVoxelMobs = 1,
			IceVoxelItems = 1,
			IceVoxelProjectiles = 1,
			IceVoxelShots = 1,
			IceVoxelTurrets = 1,
			IceVoxelTransmitters = 1,
			IceVoxelFirstPersonBody = 2,
			IceVoxelWeatherState = 2,
			IceVoxelFluidView = 2,
			IceVoxelEffectView = 3,
			IceVoxelSpectators = 3,
			IceVoxelViewBob = 4,
			IceVoxelAimSway = 5,
			IceVoxelFirearmsFire = 6,
			IceVoxelBodyTwist = 6,
			IceVoxelHeldItems = 7,
			IceVoxelEquipmentLooks = 8,
			IceVoxelSoundListener = 9,
			IceVoxelInteraction = 9,
		}
		local bound = steps()
		for name, step in bound do
			t.ok(step.offset ~= nil, `{name} ({step.module}): its priority can't be read`)
			t.ok(
				expected[name] ~= nil,
				`{name} ({step.module}) is new: give it a place in docs/ARCHITECTURE's frame table and here`
			)
			t.eq(step.offset, expected[name], `{name} ({step.module})`)
		end
		for name in expected do
			t.ok(bound[name] ~= nil, `{name} is bound`)
		end
		-- Who binds the camera's own steps.
		local owners = {
			IceVoxelCameraRig = "Player/CameraRig",
			IceVoxelFirstPersonBody = "Player/FirstPersonBody",
			IceVoxelSpectators = "Player/SpectatorView",
			IceVoxelViewBob = "Player/MovementController",
			IceVoxelAimSway = "Player/AimCamera",
			IceVoxelBodyTwist = "Player/BodyTwist",
			IceVoxelHeldItems = "Player/HeldItems",
			IceVoxelEquipmentLooks = "Player/EquipmentLooks",
			IceVoxelSoundListener = "Audio/SoundPlayer",
			IceVoxelInteraction = "Interaction/BlockInteraction",
		}
		for name, owner in owners do
			t.eq(bound[name].module, owner, `{name}'s module`)
		end
		-- The chain each step reads the one before of: the camera placed, then seen, then moved,
		-- then the body turned, the hands on it, its clothes, and the ears last.
		local chain = {
			"IceVoxelMovement",
			"IceVoxelCameraRig",
			"IceVoxelFirstPersonBody",
			"IceVoxelSpectators",
			"IceVoxelViewBob",
			"IceVoxelAimSway",
			"IceVoxelBodyTwist",
			"IceVoxelHeldItems",
			"IceVoxelEquipmentLooks",
			"IceVoxelSoundListener",
		}
		for i = 2, #chain do
			t.ok(
				(bound[chain[i - 1]].offset :: number) < (bound[chain[i]].offset :: number),
				`{chain[i - 1]} before {chain[i]}`
			)
		end
		t.ok((bound.IceVoxelMovement.offset :: number) < 0, "the body is pushed before Roblox's camera")
		t.ok((bound.IceVoxelCameraRig.offset :: number) > 0, "the rig after Roblox's camera")
		-- AimCamera's mouse lock (and its third-person sights) only without the rig; the held items
		-- are a bound step, not a RenderStepped connection.
		local aimCamera = code(fs.readFile(files["Player/AimCamera"]))
		t.ok(
			string.find(
				aimCamera,
				'if not CameraRig%.enabled%(%) then%s*RunService:BindToRenderStep%("IceVoxelAimLock"'
			) ~= nil,
			"AimCamera locks the mouse only without the rig"
		)
		t.ok(string.find(code(fs.readFile(files["Player/HeldItems"])), "RenderStepped") == nil, "HeldItems is bound")
		-- Targeting reads the camera after its last move (the rig, the bob, the sway), whatever
		-- order Roblox gives RenderStepped connections: BlockInteraction's frame is a bound step.
		t.ok(
			string.find(code(fs.readFile(files["Interaction/BlockInteraction"])), "RenderStepped") == nil,
			"BlockInteraction's frame is bound"
		)
		for _, mover in { "IceVoxelCameraRig", "IceVoxelViewBob", "IceVoxelAimSway" } do
			t.ok(
				(bound[mover].offset :: number) < (bound.IceVoxelInteraction.offset :: number),
				`targeting after {mover}`
			)
		end
	end)

	--[[ The require rules ]]

	-- The client modules `key` requires through script.Parent... (as the WeaponClient spec reads).
	local function requires(key: string): { string }
		local found = {}
		local parts = string.split(key, "/")
		for chain in string.gmatch(code(fs.readFile(files[key])), "require%(script(%.[%w%.]+)%)") do
			local at = table.clone(parts)
			for step in string.gmatch(chain, "%.(%w+)") do
				if step == "Parent" then
					table.remove(at)
				else
					table.insert(at, step)
				end
			end
			local target = table.concat(at, "/")
			if files[target] then
				table.insert(found, target)
			end
		end
		return found
	end

	local function reach(key: string): { [string]: boolean }
		local seen: { [string]: boolean } = {}
		local function walk(at: string)
			if seen[at] then
				return
			end
			seen[at] = true
			for _, next in requires(at) do
				walk(next)
			end
		end
		walk(key)
		return seen
	end

	t.test("camera integration: no require cycle, and the camera's modules keep out of them", function()
		-- No cycle anywhere in the client (a module required while it loads fails in Roblox).
		local state: { [string]: number } = {}
		local path: { string } = {}
		local cycles: { string } = {}
		local function visit(at: string)
			state[at] = 1
			table.insert(path, at)
			for _, next in requires(at) do
				if state[next] == 1 then
					local from = table.find(path, next) :: number
					table.insert(cycles, table.concat(path, " -> ", from) .. " -> " .. next)
				elseif state[next] == nil then
					visit(next)
				end
			end
			table.remove(path)
			state[at] = 2
		end
		local count = 0
		for key in files do
			count += 1
			if state[key] == nil then
				visit(key)
			end
		end
		t.ok(count > 150, `client modules found ({count})`)
		t.eq(#cycles, 0, `require cycles: {table.concat(cycles, "; ")}`)

		-- Nothing the buttons' handlers reach requires BlockInteraction (it requires them).
		for _, start in { "Interaction/Firearms", "Interaction/MeleeInput" } do
			local reached = reach(start)
			t.ok(not reached["Interaction/BlockInteraction"], `{start} reaches Interaction/BlockInteraction`)
		end
		t.ok(reach("Interaction/Firearms")["Player/HeldItems"], "the walk follows Firearms into the held items")

		-- The rig needs no screen, no interaction, neither the movement nor the aim's camera.
		local rig = reach("Player/CameraRig")
		for key in rig do
			t.ok(string.sub(key, 1, 3) ~= "Ui/", `CameraRig reaches {key}`)
			t.ok(string.sub(key, 1, 12) ~= "Interaction/", `CameraRig reaches {key}`)
		end
		t.ok(not rig["Player/MovementController"], "CameraRig reaches MovementController")
		t.ok(not rig["Player/AimCamera"], "CameraRig reaches AimCamera")

		-- The first-person body: the rig and two pure rule sets (EquipmentLooks requires it, and
		-- MovementController EquipmentLooks); its rules add only the pure AimRules.
		local allowed =
			{ ["Player/CameraRig"] = true, ["Player/FirstPersonRules"] = true, ["Player/SpectatorRules"] = true }
		for _, key in requires("Player/FirstPersonBody") do
			t.ok(allowed[key], `FirstPersonBody requires {key}`)
		end
		local body = reach("Player/FirstPersonBody")
		for _, banned in { "Player/MovementController", "Player/AimCamera", "Player/HeldItems" } do
			t.ok(not body[banned], `FirstPersonBody reaches {banned}`)
		end
		t.eq(table.concat(requires("Player/FirstPersonRules"), ","), "Player/AimRules", "FirstPersonRules")
		for _, pure in { "Player/CameraRules", "Player/BodyRules", "Player/SpectatorRules" } do
			t.eq(#requires(pure), 0, `{pure} requires no client module`)
		end
	end)

	--[[ One writer each ]]

	-- The client modules whose code matches `pattern`, sorted, joined with ",".
	local function writers(pattern: string): string
		local found = {}
		for key, path in files do
			if string.find(code(fs.readFile(path)), pattern) then
				table.insert(found, key)
			end
		end
		table.sort(found)
		return table.concat(found, ",")
	end

	t.test("camera integration: one writer for the body's visibility and for each joint", function()
		-- LocalTransparencyModifier: FirstPersonBody (the local character with the rig on),
		-- SpectatorView (raising, every character), AimCamera (third-person sights without the rig),
		-- HeldItems and EquipmentLooks (their own models, never a character's parts).
		t.eq(
			writers("LocalTransparencyModifier%s*=[^=]"),
			"Player/AimCamera,Player/EquipmentLooks,Player/FirstPersonBody,Player/HeldItems,Player/SpectatorView",
			"who writes LocalTransparencyModifier"
		)
		local aimCamera = code(fs.readFile(files["Player/AimCamera"]))
		t.ok(
			string.find(aimCamera, 'posture == "sights" and not realFirstPerson and not CameraRig%.enabled%(%)', 1)
				~= nil,
			"AimCamera hides the character for the third-person sights only without the rig"
		)
		-- Motor6D C0: the root (MovementController), the hips and the waist (BodyTwist), the
		-- shoulders and the neck (WeaponPoses), the arms in true first person (FirstPersonBody).
		t.eq(
			writers("%.C0%s*=[^=]"),
			"Player/BodyTwist,Player/FirstPersonBody,Player/MovementController,Player/WeaponPoses",
			"who writes a joint's C0"
		)
		t.eq(writers("%.Transform%s*=[^=]"), "", "nobody writes the animation's Transform")
		local movement = code(fs.readFile(files["Player/MovementController"]))
		for target in string.gmatch(movement, "([%w_%.]+)%.C0%s*=[^=]") do
			t.eq(target, "rootJoint", "MovementController writes the root joint only")
		end
		-- The joints each names (its code's quoted names: a joint, or its side's half of one).
		local joints = {
			["Player/BodyTwist"] = {
				has = { "Hip", "Waist" },
				never = { "Shoulder", "Elbow", "Wrist", "Neck", "Root" },
			},
			["Player/FirstPersonBody"] = {
				has = { "Shoulder", "Elbow", "Wrist" },
				never = { "Hip", "Waist", "Neck", "Root" },
			},
			["Player/WeaponPoses"] = {
				has = { "Shoulder", "Neck" },
				never = { "Hip", "Waist", "Elbow", "Wrist", "Root" },
			},
		}
		for key, names in joints do
			local quoted: { [string]: boolean } = {}
			for name in string.gmatch(code(fs.readFile(files[key])), '"([%w ]+)"') do
				quoted[name] = true
			end
			-- A joint's names: itself, each side's (R15 "RightHip", R6 "Right Hip"), R6's root.
			local function named(joint: string): boolean
				for _, name in { joint, `Left{joint}`, `Right{joint}`, `Left {joint}`, `Right {joint}`, `{joint}Joint` } do
					if quoted[name] then
						return true
					end
				end
				return false
			end
			for _, joint in names.has do
				t.ok(named(joint), `{key} turns its {joint}`)
			end
			for _, joint in names.never do
				t.ok(not named(joint), `{key} leaves the {joint}`)
			end
		end
	end)

	--[[ Freelook between the rig, the head and the waist ]]

	t.test("camera integration: freelook's turn is left-positive, the neck and the waist agree", function()
		-- The aim at yaw 0.2, freelook pressed, the camera turned left (a larger yaw) and up: the
		-- aim holds, the offset (CameraRig.freelookOffset) is the camera minus the aim.
		local look = CameraRules.newLook()
		CameraRules.aim(look, 0.2, 0.1)
		CameraRules.freelook(look, true, true, false, true)
		CameraRules.aim(look, 0.2, 0.1)
		local aimYaw, aimPitch = CameraRules.aim(look, 1.7, 0.4)
		t.near(aimYaw, 0.2, EPS, "the aim's yaw held")
		t.near(aimPitch, 0.1, EPS, "the aim's pitch held")
		t.near(look.yaw, 1.5, EPS, "camera minus aim: positive to the left")
		t.near(look.pitch, 0.3, EPS, "positive up")

		-- The head takes the turn up to the neck's reach (WeaponPoses.applyLook clamps to it), the
		-- waist the rest up to its own (BodyTwist through BodyRules.waist): DayZ's first-person room.
		t.near(WeaponPoses.NECK_YAW, BodyRules.NECK_YAW, EPS, "the head's reach is the body's neck share")
		t.near(WeaponPoses.NECK_PITCH, math.rad(60), EPS, "the head's pitch reach")
		local room = math.rad(Config.Camera.FreelookYawFirst)
		for _, side in { 1, -1 } do
			local yaw = side * room
			t.near(BodyRules.neck(yaw) + BodyRules.waist(0, 0, yaw), yaw, 1e-9, "neck and waist make the room")
			t.near(math.abs(BodyRules.neck(yaw)), WeaponPoses.NECK_YAW, EPS, "the neck at its reach")
		end
		t.near(BodyRules.waist(0, 0, look.yaw), look.yaw - BodyRules.NECK_YAW, EPS, "the waist beyond the neck")
		t.near(BodyRules.waist(0, 0, math.rad(50)), 0, EPS, "within the neck's reach the waist stays")
		-- Third person's wider room (FreelookYaw) turns the head and the waist no further.
		local wide = math.rad(Config.Camera.FreelookYaw)
		t.near(BodyRules.neck(wide) + BodyRules.waist(0, 0, wide), room, 1e-9, "the body's turn stops at the room")
	end)
end
