--!strict
--[[
	The local player's movement: a Minecraft-style hull (Shared/Movement/PlayerPhysics) simulated
	against the client's block data at 20 ticks per second. The Roblox character is purely
	cosmetic: it is put where the hull is every frame and never touches anything itself.

	  Input     on a keyboard and mouse (Settings/Keybinds.usingKeys: Roblox's last input) the key
	            bindings (Options > Controls > Key Binds): Walk Forwards / Backwards, Strafe Left /
	            Right and Jump held (Keybinds.isDown); otherwise the default control scripts' move
	            vector (PlayerModule: gamepad, touch; Humanoid.MoveDirection if a game replaces
	            them), turned by the camera like the default controls do, and Humanoid.Jump. (So the
	            control scripts' own W A S D, arrows and Space move nothing once rebound.) Sprint
	            and sneak: their key bindings plus Config.Movement's gamepad buttons, bound through
	            ContextActionService (again when the bindings change), and the touch buttons. The
	            sprint key toggles sprinting (or is held, ToggleSprint = false: the Sprint setting;
	            switching it lets go of whatever the old mode latched, `followSprintMode`); double
	            tapping forward sprints too. The sneak key is held (or toggles, ToggleSneak: the
	            Sneak setting, likewise); the touch button always toggles.
	  Ticks     fixed 50 ms steps like Minecraft; the character is drawn interpolated between the
	            last two ticks (as Minecraft does), before the camera updates each frame. Steps up
	            (Config.Movement.StepHeight, just over a block) are drawn as a quick climb.
	  Character its parts are in a collision group that collides with nothing (Rig), the Humanoid
	            is held in the Physics state (it applies no forces of its own), a VectorForce
	            cancels gravity, and the root part is moved with CFrame + velocity. The client owns
	            its character, so that replicates to everyone like normal movement. In the
	            swimming / crawling pose the body lies down (pitched with the view when swimming),
	            as Roblox's own Swimming state and Minecraft's renderer do.
	  Facing    towards where the character walks, or where the camera looks in first person and
	            with shift lock.
	  Camera    at the hull's eye height (eased like Minecraft's when crouching / crawling); the
	            field of view widens while flying (x 1.1) and sprinting (Config.Movement.SprintFov),
	            eased like Minecraft's FOV modifier, on top of the FOV setting (`setFieldOfView`;
	            without one, whatever the camera's field of view is), scaled by the FOV Effects
	            setting (`setFovEffects`, Minecraft's: 0 keeps the field of view still). Minecraft's
	            view bobbing while walking on the ground (`setViewBobbing`) and the hurt tilt when
	            health drops (`setDamageTilt`'s share: Player/ViewBob): applied after Roblox's
	            camera and the screen effects have moved it (VIEW_BOB_PRIORITY) and taken off
	            again before the camera updates (`unbob`), so the camera's own turning never takes
	            them in; none while frozen or spectating someone.
	  Modes     the game mode attribute (Shared/GameMode) gives the hull its abilities
	            (PlayerPhysics.setGameMode): creative may fly (double tap jump); spectators always
	            fly, through everything (noClip), and their mouse wheel changes the flying speed
	            while the spectator menu is closed (Ui/SpectatorGui, PlayerPhysics.
	            scrollFlyingSpeed). Switching to survival or adventure stops flying: the player
	            falls; from spectator to creative keeps flying, as in Minecraft.
	  Spectate  a spectator's left click on a player (Interaction/BlockInteraction) spectates them:
	            the camera looks from their eyes (CameraSubject: their Humanoid, first person, its
	            CameraOffset set here every frame, as their own client's never replicates: standing
	            eyes, or lying ones as far as the body is pitched, since the pose doesn't replicate
	            either) and the hull follows their feet every frame, so the world streams around
	            them. Sneaking, a teleport, leaving spectator mode or the target dying or leaving
	            stops it, where the target was (ServerPlayer.setCamera, wantsToStopRiding).
	  Screens   while an inventory screen (Ui/Screens) or the game mode switcher (Ui/
	            GameModeSwitcher) is open the input is neutral: the player stops (a sprint toggled
	            on stays on), as Minecraft releases every key mapping when a screen opens.
	  Waiting   until the full detail chunks under the hull are visible (after spawning and
	            teleports), it stays frozen in place.
	  Teleports the server sets the feet position as attributes (Rig), and the streamer is told the
	            destination at once (`teleported`: teleport mode); other scripts moving the
	            character far are noticed too, and the hull follows.
	  Knockback explosions push the hull (`knockback`: the server's Explosion message adds to its
	            velocity, as Minecraft's client does).
	  Damage    landings after falls are reported to the server for fall damage. The Physics state
	            does not die on its own, so the controller puts the Humanoid into Dead itself.
	  Effects   the status effects the server sent (Player/EffectState) go onto the hull before
	            every tick: Speed, Slowness and Oil Coated's speed factor, Jump Boost, Blindness
	            keeping sprints from starting (PlayerPhysics); the field of view follows the speed
	            factor as Minecraft's does ((factor + 1) / 2, Speed I: x 1.1).
	  Sounds    after every tick, Audio/MovementSounds plays the footsteps, swimming, splashes and
	            hurting landings of what the hull did.

	CharacterAnimator plays the avatar's animations from the hull state.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local KeyBindings = require(Shared.KeyBindings)
local Protocol = require(Shared.Net.Protocol)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Rig = require(Shared.Movement.Rig)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local GameModeSwitcher = require(script.Parent.Parent.Ui.GameModeSwitcher)
local Screens = require(script.Parent.Parent.Ui.Screens)
local SpectatorGui = require(script.Parent.Parent.Ui.SpectatorGui)
local MovementSounds = require(script.Parent.Parent.Audio.MovementSounds)
local EffectState = require(script.Parent.EffectState)
local Exertion = require(script.Parent.Exertion)
local ViewBob = require(script.Parent.ViewBob)

local BLOCK = Config.BlockSize
local Movement = Config.Movement
local TICK_RATE = PlayerPhysics.TICK_RATE
local TICK = 1 / TICK_RATE
-- Ticks run at most per frame (a long hitch does not fast-forward the player).
local MAX_TICKS_PER_FRAME = 5
-- Runs right before the camera, so the camera follows this frame's position.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value - 1
-- The view bob and hurt tilt go on after the camera and the screen effects (Rendering/
-- ExplosionView + 1, FluidFog + 2, EffectView + 3) have moved it.
local VIEW_BOB_PRIORITY = Enum.RenderPriority.Camera.Value + 4
-- The server moves new characters to the spawn first; don't trust their position before that.
local SPAWN_SETTLE = 3
-- A root part further than this (studs) from where the controller left it was moved by a script.
local MOVED_TOLERANCE = 4
-- Studs per block per tick -> studs per second.
local VELOCITY_SCALE = BLOCK * TICK_RATE
-- Minecraft eases the camera's eye height and the field of view half the remaining way each tick.
local EASE_PER_TICK = 0.5
-- How fast the body lies down / gets up (Minecraft's swimAmount: 0.09 per tick).
local TILT_PER_SECOND = 0.09 * TICK_RATE
-- After a step up the drawn character catches up with the hull at this rate (per second), at
-- most this many blocks behind.
local STEP_CATCH_UP = 14
local MAX_STEP_LAG = 1.5
-- The camera counts as first person this close (studs) to its focus (Roblox's camera switches to
-- first person below 1 stud of zoom).
local FIRST_PERSON_DISTANCE = 1
-- Roblox's camera can't go wider than this.
local MAX_FOV = 120
-- Field of view modifier while flying (AbstractClientPlayer.getFieldOfViewModifier).
local FLYING_FOV = 1.1
-- Eye heights (blocks) of a standing and a lying (swimming / crawling) player.
local STANDING_EYE = PlayerPhysics.dimensions("standing").eye
local LYING_EYE = PlayerPhysics.dimensions("crawling").eye

-- The terrain streamer: whether the ground under (x, z) is shown, and (optional) a teleport's
-- destination (feet, blocks), so it selects there at once (teleport mode beyond
-- Streaming.TeleportDistance).
type Streamer = {
	isReady: (self: any, x: number, z: number) -> boolean,
	teleported: ((self: any, feet: Vector3) -> ())?,
}

export type View = {
	-- Hull state (blocks), updated every tick; also the game mode's abilities: whether the player
	-- may fly (creative, spectator), flies, moves through blocks (spectator) and how fast it flies
	-- (state.mayFly, state.flying, state.noClip, state.flyingSpeed).
	state: PlayerPhysics.State,
	-- Where the hull is drawn this frame (feet, blocks, between the last two ticks) and the
	-- character's facing (radians around Y).
	feet: Vector3,
	yaw: number,
	-- How far the body lies down: 0 upright .. 1 in the swimming / crawling pose.
	tilt: number,
	-- Horizontal speed over the last tick (blocks per second).
	speed: number,
	-- os.clock() of the last jump.
	jumpedAt: number,
	-- Waiting for the ground to load (after spawning / teleports).
	frozen: boolean,
}

local MovementController = {}

-- The local player's movement while a character exists (BlockInteraction, the F3 overlay, the
-- animator read it).
MovementController.current = nil :: View?

-- The FOV settings (Settings/): the field of view (nil: the camera's own) and how much of the
-- flying / sprinting widening shows (0..1).
local fovSetting: number? = nil
local fovEffects = 1
-- A status effect's sway of the field of view (Nausea), a multiplier.
local fovSway = 1
-- The View Bobbing and Damage Tilt settings (Settings/: on, and the tilt's share 0..1).
local viewBobbing = true
local damageTilt = 1
-- The camera moved by the view bob last frame: what it was before and what it was set to
-- (read back, so an untouched camera compares equal), to put it back before the camera updates.
local bobCamera: Camera? = nil
local bobClean = CFrame.identity
local bobSet = CFrame.identity

-- The player a spectator spectates (nil: none), and the camera mode to go back to afterwards.
local spectated: Player? = nil
local cameraModeBefore: Enum.CameraMode? = nil
-- The spectated player's Humanoid whose CameraOffset is set here, and what it was before.
local offsetHumanoid: Humanoid? = nil
local offsetBefore = Vector3.zero

-- Gives the spectated player's Humanoid its own CameraOffset back.
local function releaseOffset()
	local humanoid = offsetHumanoid
	if humanoid then
		humanoid.CameraOffset = offsetBefore
		offsetHumanoid = nil
	end
end

--[[
	Spectates `target` (a spectator's click on them), or stops (nil): the camera looks from the
	target's eyes and the hull follows them until sneaking, a teleport or a game mode change.
]]
function MovementController.spectate(target: Player?)
	if target == spectated then
		return
	end
	local player = Players.LocalPlayer
	spectated = target
	releaseOffset()
	if target then
		if cameraModeBefore == nil then
			cameraModeBefore = player.CameraMode
		end
		player.CameraMode = Enum.CameraMode.LockFirstPerson
		return
	end
	-- Back to the player's own eyes, where the target was.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local camera = workspace.CurrentCamera
	if camera and humanoid then
		camera.CameraSubject = humanoid
	end
	if cameraModeBefore then
		player.CameraMode = cameraModeBefore
		cameraModeBefore = nil
	end
end

-- The player being spectated, or nil.
function MovementController.spectating(): Player?
	return spectated
end

--[[
	An explosion's knockback (blocks per tick, the server's Explosion message through
	Rendering/ExplosionView): added to the hull's velocity (PlayerPhysics.knockback: not for
	spectators nor creative flight), unless the player waits for the ground or follows someone.
]]
function MovementController.knockback(kx: number, ky: number, kz: number)
	local view = MovementController.current
	if view == nil or view.frozen or spectated ~= nil then
		return
	end
	PlayerPhysics.knockback(view.state, kx, ky, kz)
end

--[[
	What ContextActionService binds for the sprint or sneak action: the key binding `action`
	(Settings/Keybinds; a key or a mouse button, none when not bound) and Config's gamepad buttons
	among `names` (Config's keyboard key is only the binding's default).
]]
local function actionInputs(action: string, names: { string }): { any }
	local inputs: { any } = {}
	local bound = Keybinds.input(action)
	if bound then
		table.insert(inputs, bound)
	end
	for _, name in names do
		if KeyBindings.find(name) == nil then
			local ok, code = pcall(function()
				return (Enum.KeyCode :: any)[name]
			end)
			if ok and code then
				table.insert(inputs, code)
			else
				warn(`[IceVoxel] Config.Movement: unknown key {name}`)
			end
		end
	end
	return inputs
end

local function setGroup(part: Instance, group: string)
	if part:IsA("BasePart") then
		part.CollisionGroup = group
	end
end

-- Yaw (radians around Y) that faces direction (x, z); Roblox characters look down -Z.
local function yawOf(x: number, z: number): number
	return math.atan2(-x, -z)
end

local function angleDifference(a: number, b: number): number
	return (a - b + math.pi) % (2 * math.pi) - math.pi
end

-- Fraction of the way to ease this frame for something Minecraft eases EASE_PER_TICK per tick.
local function ease(dt: number): number
	return 1 - EASE_PER_TICK ^ (dt * TICK_RATE)
end

--[[
	The camera's heading on the ground (unit x, z): where "forward" input goes. Same as the default
	control scripts (ControlModule calculateRawMoveVector), which use the up vector when the camera
	looks straight up or down.
]]
local function cameraHeading(cframe: CFrame): (number, number)
	local _, _, _, r00, r01, r02, _, _, r12, _, _, r22 = cframe:GetComponents()
	local c, s = r22, r02
	if r12 >= 1 or r12 <= -1 then
		c, s = r00, -r01 * math.sign(r12)
	end
	local norm = math.sqrt(c * c + s * s)
	if norm < 1e-6 then
		return 0, -1
	end
	return -s / norm, -c / norm
end

-- Height (studs) above the HumanoidRootPart, in its space, that Roblox's camera aims at
-- (CameraModule BaseCamera: R6 and scaled R15 1.5 plus half the root part's growth, else 2).
local function cameraHeight(hum: Humanoid, root: BasePart): number
	if hum.RigType == Enum.HumanoidRigType.R15 then
		if hum.AutomaticScalingEnabled then
			return 1.5 + (root.Size.Y - 2) / 2
		end
		return 2
	end
	return 1.5
end

--[[
	Puts the camera at the eyes of the spectated player (`humanoid`, feet at `feet` in blocks):
	Roblox's camera aims at its fixed height above their root part plus their CameraOffset in the
	root's space, and the offset their own client sets (below) never replicates. Their pose doesn't
	either: standing eyes, or lying ones as far as the body is pitched (as Rig.feet reads it).
]]
local function aimAtEyes(humanoid: Humanoid, feet: Vector3)
	local root = humanoid.RootPart
	if root == nil then
		return
	end
	if offsetHumanoid ~= humanoid then
		releaseOffset()
		offsetHumanoid, offsetBefore = humanoid, humanoid.CameraOffset
	end
	local pitch = math.acos(math.clamp(root.CFrame.UpVector.Y, -1, 1))
	local tilt = math.clamp(pitch / (math.pi / 2), 0, 1)
	local eye = STANDING_EYE + (LYING_EYE - STANDING_EYE) * tilt
	local toEye = (feet + Vector3.new(0, eye, 0)) * BLOCK - root.Position
	local offset = root.CFrame:VectorToObjectSpace(toEye) - Vector3.new(0, cameraHeight(humanoid, root), 0)
	if (humanoid.CameraOffset - offset).Magnitude > 1e-3 then
		humanoid.CameraOffset = offset
	end
end

--[[
	The FOV setting (degrees, Minecraft's 30..110; nil: leave the camera's own). Applies at once,
	also with no character (the camera keeps it, and gets it again when it is replaced).
]]
local cameraWatched = false
function MovementController.setFieldOfView(fov: number?)
	fovSetting = fov
	local function apply()
		local camera = workspace.CurrentCamera
		local value = fovSetting
		if camera and value and MovementController.current == nil then
			camera.FieldOfView = math.clamp(value, 1, MAX_FOV)
		end
	end
	apply()
	if not cameraWatched then
		cameraWatched = true
		workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(apply)
	end
end

-- The FOV Effects setting: how much of the flying and sprinting widening shows (0..1).
function MovementController.setFovEffects(scale: number)
	fovEffects = math.clamp(scale, 0, 1)
end

-- The FOV Effects setting's share (0..1). (Nausea's wobble follows Distortion Effects instead:
-- Rendering/EffectView.setDistortion.)
function MovementController.fovEffects(): number
	return fovEffects
end

-- A status effect's sway of the field of view (Nausea: Rendering/EffectView), a multiplier on it
-- applied every frame (1: none).
function MovementController.setFovSway(multiplier: number)
	fovSway = multiplier
end

-- The View Bobbing setting: the camera bobs while walking (Minecraft's bobView).
function MovementController.setViewBobbing(on: boolean)
	viewBobbing = on
end

-- The Damage Tilt setting: how far the camera tilts when hurt (0..1 of Minecraft's 14 degrees).
function MovementController.setDamageTilt(share: number)
	damageTilt = math.clamp(share, 0, 1)
end

-- Takes last frame's view bob off the camera (before the camera updates), if nothing else moved it.
local function unbob()
	local camera = bobCamera
	if camera then
		bobCamera = nil
		if camera.CFrame == bobSet then
			camera.CFrame = bobClean
		end
	end
end

function MovementController.start(world: ClientWorld.ClientWorld, streamer: Streamer)
	local player = Players.LocalPlayer
	local physicsWorld: PlayerPhysics.World = {
		getBlock = function(x: number, y: number, z: number): number?
			return world:getBlock(x, y, z)
		end,
	}

	-- The default control scripts, if the game has them (false: tried and failed).
	local controls: any = nil
	local function controlMoveVector(): Vector3?
		if controls == nil then
			local scripts = player:FindFirstChildOfClass("PlayerScripts")
			local module = scripts and scripts:FindFirstChild("PlayerModule")
			if module == nil or not module:IsA("ModuleScript") then
				return nil
			end
			local ok, result = pcall(function()
				return (require :: any)(module):GetControls()
			end)
			controls = if ok and result then result else false
		end
		if not controls then
			return nil
		end
		local ok, vector = pcall(function()
			return controls:GetMoveVector()
		end)
		return if ok and typeof(vector) == "Vector3" then vector else nil
	end

	-- An inventory screen or the game mode switcher has the keys: the player stands still.
	local function inputTaken(): boolean
		return Screens.isOpen() or GameModeSwitcher.isOpen()
	end

	-- Sprint / sneak keys and touch toggles.
	local sprintHeld, sprintOn = false, false
	local sneakHeld, sneakOn = false, false
	-- The key binding each action is bound with now (to bind again when it changes).
	local boundWith: { [string]: any } = {}
	local function bind(
		name: string,
		action: string,
		buttons: { string },
		title: string,
		onChange: (held: boolean, touch: boolean) -> ()
	)
		boundWith[name] = Keybinds.input(action) or false
		ContextActionService:BindActionAtPriority(name, function(_, inputState: Enum.UserInputState, input: InputObject)
			local touch = input.UserInputType == Enum.UserInputType.Touch
			-- In an inventory screen, gamepad buttons (B closes it), mouse buttons and touches go
			-- on to the screens; releases still count, so nothing stays held.
			local pass = Screens.isOpen() and input.UserInputType ~= Enum.UserInputType.Keyboard
			if inputState == Enum.UserInputState.Begin then
				if not pass then
					onChange(true, touch)
				end
			elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
				onChange(false, touch)
			end
			-- Keep Shift from also toggling the shift lock.
			return if pass then Enum.ContextActionResult.Pass else Enum.ContextActionResult.Sink
		end, Movement.TouchButtons, Enum.ContextActionPriority.High.Value, table.unpack(actionInputs(action, buttons)))
		if Movement.TouchButtons then
			ContextActionService:SetTitle(name, title)
		end
	end
	local function setTitle(name: string, title: string)
		if Movement.TouchButtons then
			ContextActionService:SetTitle(name, title)
		end
	end
	-- The Sprint setting can switch between Toggle and Hold at any time (Settings "controls"):
	-- what the old mode latched lets go, or nothing could stop the sprint any more.
	local sprintToggles = Movement.ToggleSprint
	local function followSprintMode()
		if Movement.ToggleSprint ~= sprintToggles then
			sprintToggles = Movement.ToggleSprint
			sprintHeld, sprintOn = false, false
			setTitle("IceVoxelSprint", "Sprint")
		end
	end
	-- The Sneak setting likewise (the touch button toggles either way).
	local sneakToggles = Movement.ToggleSneak
	local function followSneakMode()
		if Movement.ToggleSneak ~= sneakToggles then
			sneakToggles = Movement.ToggleSneak
			sneakHeld, sneakOn = false, false
			setTitle("IceVoxelSneak", "Sneak")
		end
	end
	local function onSprint(held: boolean, touch: boolean)
		followSprintMode()
		if touch or Movement.ToggleSprint then
			-- (Ctrl+Q in an inventory screen must not toggle sprinting.)
			if held and not inputTaken() then
				-- Toggles what the player sees: a sprint started by double tapping stops too.
				local view = MovementController.current
				sprintOn = not (sprintOn or (view ~= nil and view.state.sprinting))
				if not sprintOn and view then
					view.state.sprinting = false
				end
				setTitle("IceVoxelSprint", if sprintOn then "Sprinting" else "Sprint")
			end
		else
			sprintHeld = held
		end
	end
	local function onSneak(held: boolean, touch: boolean)
		followSneakMode()
		if touch or Movement.ToggleSneak then
			-- (A shift click in an inventory screen must not toggle sneaking.)
			if held and (touch or not inputTaken()) then
				sneakOn = not sneakOn
				setTitle("IceVoxelSneak", if sneakOn then "Sneaking" else "Sneak")
			end
		else
			sneakHeld = held
		end
	end
	local function bindSprint()
		bind("IceVoxelSprint", "sprint", Movement.SprintKeys, if sprintOn then "Sprinting" else "Sprint", onSprint)
	end
	local function bindSneak()
		bind("IceVoxelSneak", "sneak", Movement.SneakKeys, if sneakOn then "Sneaking" else "Sneak", onSneak)
	end
	bindSprint()
	bindSneak()
	-- A key binding changed (Options > Controls > Key Binds): bound again with the new key; what
	-- the old key held lets go.
	Keybinds.changed:Connect(function()
		if (Keybinds.input("sprint") or false) ~= boundWith.IceVoxelSprint then
			ContextActionService:UnbindAction("IceVoxelSprint")
			sprintHeld = false
			bindSprint()
		end
		if (Keybinds.input("sneak") or false) ~= boundWith.IceVoxelSneak then
			ContextActionService:UnbindAction("IceVoxelSneak")
			sneakHeld = false
			bindSneak()
		end
	end)

	-- Sprinting widens the camera's field of view (whatever it is set to) by Movement.SprintFov.
	local fovModifier = 1
	local fovCamera: Camera? = nil
	local baseFov = 70
	-- What this controller last set the field of view to (nil: nothing yet).
	local setFov: number? = nil
	local function updateFov(dt: number, target: number)
		local camera = workspace.CurrentCamera
		if camera == nil then
			return
		end
		if camera ~= fovCamera or setFov == nil or math.abs(camera.FieldOfView - setFov) > 1e-3 then
			-- First frame, a new camera, or another script changed it: that is the base now.
			fovCamera = camera
			baseFov = camera.FieldOfView
		end
		local setting = fovSetting
		if setting then
			baseFov = setting
		end
		target = 1 + (target - 1) * fovEffects
		fovModifier += (target - fovModifier) * ease(dt)
		if math.abs(target - fovModifier) < 1e-4 then
			fovModifier = target
		end
		camera.FieldOfView = math.clamp(baseFov * fovModifier * fovSway, 1, MAX_FOV)
		setFov = camera.FieldOfView
	end
	local function resetFov()
		local camera = fovCamera
		if camera and setFov and math.abs(camera.FieldOfView - setFov) <= 1e-3 then
			camera.FieldOfView = baseFov
		end
		fovModifier, fovCamera, setFov = 1, nil, nil
	end

	local connections: { RBXScriptConnection } = {}
	local function disconnectAll()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		RunService:UnbindFromRenderStep("IceVoxelMovement")
		RunService:UnbindFromRenderStep("IceVoxelViewBob")
		unbob()
		MovementController.current = nil
		MovementController.spectate(nil)
		resetFov()
	end

	local function onCharacter(character: Model)
		disconnectAll()
		local root = character:WaitForChild("HumanoidRootPart", 10)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if root == nil or humanoid == nil or not root:IsA("BasePart") or not humanoid:IsA("Humanoid") then
			return
		end
		local rootPart: BasePart, hum: Humanoid = root, humanoid
		if hum.Health <= 0 or character.Parent == nil then
			return
		end

		-- Cosmetic rig: no collisions, no humanoid forces, no gravity.
		for _, part in character:GetDescendants() do
			setGroup(part, Rig.COLLISION_GROUP)
		end
		table.insert(
			connections,
			character.DescendantAdded:Connect(function(part)
				setGroup(part, Rig.COLLISION_GROUP)
			end)
		)
		-- Parts leaving the character (a dropped tool) collide normally again.
		table.insert(
			connections,
			character.DescendantRemoving:Connect(function(part)
				setGroup(part, "Default")
			end)
		)
		hum.AutoRotate = false
		hum:ChangeState(Enum.HumanoidStateType.Physics)
		local attachment = Instance.new("Attachment")
		attachment.Name = "IceVoxelMovement"
		attachment.Parent = rootPart
		local antiGravity = Instance.new("VectorForce")
		antiGravity.Name = "IceVoxelAntiGravity"
		antiGravity.Attachment0 = attachment
		antiGravity.RelativeTo = Enum.ActuatorRelativeTo.World
		antiGravity.ApplyAtCenterOfMass = true
		antiGravity.Parent = rootPart
		-- The joint holding the body to the root part (R15 LowerTorso.Root, R6 RootJoint). The
		-- step-up catch-up lowers the body through it, so the root part (the player's position for
		-- the server and other players) always stays on the hull.
		local rootJoint: Motor6D? = nil
		local rootJointC0 = CFrame.identity
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("Motor6D") and descendant.Part0 == rootPart then
				rootJoint = descendant
				rootJointC0 = descendant.C0
				break
			end
		end

		-- Hull, starting where the server put the character.
		local spawnedAt = os.clock()
		local feet = character:GetAttribute(Rig.TELEPORT_FEET)
		local start = if typeof(feet) == "Vector3" then feet else Rig.feet(character) or Vector3.zero
		local state = PlayerPhysics.new(start.X, start.Y, start.Z)
		state.stepHeight = Movement.StepHeight
		PlayerPhysics.setGameMode(state, GameMode.of(player))
		local _, rootYaw = rootPart.CFrame:ToOrientation()
		local view: View = {
			state = state,
			feet = start,
			yaw = rootYaw,
			tilt = 0,
			speed = 0,
			jumpedAt = -math.huge,
			frozen = true,
		}
		MovementController.current = view

		local previous = start
		local accumulator = 0
		local jumpLatched = false
		-- Blocks the drawn character is below the hull after stepping up.
		local stepLag = 0
		-- Eye height (blocks) the camera is at, easing towards the hull's.
		local eye = PlayerPhysics.eyeHeight(state)
		-- Where the root part was put last frame (studs), its velocity then and that frame's length.
		local lastPlaced: Vector3? = nil
		local lastVelocity = Vector3.zero
		local lastDt = 0
		local settled = typeof(feet) == "Vector3"

		local function snap(position: Vector3)
			PlayerPhysics.place(state, position.X, position.Y, position.Z)
			previous = position
			view.feet = position
			view.speed = 0
			view.frozen = true
			accumulator = 0
			stepLag = 0
		end
		local function onTeleport()
			local target = character:GetAttribute(Rig.TELEPORT_FEET)
			if typeof(target) == "Vector3" then
				-- (A teleport ends spectating, as ServerPlayer.teleportTo sets the camera back.)
				MovementController.spectate(nil)
				settled = true
				snap(target)
				local teleported = streamer.teleported
				if teleported then
					teleported(streamer, target)
				end
			end
		end
		table.insert(connections, character:GetAttributeChangedSignal(Rig.TELEPORT_FEET):Connect(onTeleport))
		table.insert(connections, character:GetAttributeChangedSignal(Rig.TELEPORT_COUNT):Connect(onTeleport))

		local function release()
			disconnectAll()
			antiGravity:Destroy()
			attachment:Destroy()
			hum.CameraOffset = Vector3.zero
			if rootJoint then
				rootJoint.C0 = rootJointC0
			end
			for _, part in character:GetDescendants() do
				setGroup(part, "Default")
			end
		end
		table.insert(connections, hum.Died:Connect(release))
		-- The Physics state does not die by itself when health runs out.
		local function dieIfDead()
			if hum.Health <= 0 and hum:GetState() ~= Enum.HumanoidStateType.Dead then
				hum:ChangeState(Enum.HumanoidStateType.Dead)
			end
		end
		table.insert(connections, hum.HealthChanged:Connect(dieIfDead))

		-- Jump held now (never while a screen is open): the Jump key binding on a keyboard,
		-- else the control scripts' (gamepad A, the touch jump button).
		local function jumpHeld(): boolean
			if inputTaken() then
				return false
			end
			return if Keybinds.usingKeys() then Keybinds.isDown("jump") else hum.Jump
		end

		local function readInput(dt: number): PlayerPhysics.Input
			-- An open inventory screen (or the switcher) takes the input: stand still, keep facing
			-- the same way.
			if inputTaken() then
				jumpLatched = false
				return {
					moveX = 0,
					moveZ = 0,
					forward = 0,
					facingX = -math.sin(view.yaw),
					facingZ = -math.cos(view.yaw),
					lookY = math.clamp(workspace.CurrentCamera.CFrame.LookVector.Y, -1, 1),
					jump = false,
					sneak = false,
					sprint = false,
				}
			end
			local camera = workspace.CurrentCamera
			local cameraCFrame = camera.CFrame
			local headingX, headingZ = cameraHeading(cameraCFrame)
			local rightX, rightZ = -headingZ, headingX

			-- Input relative to the camera (keyboard diagonals are longer than 1, as in Minecraft;
			-- the physics normalises them): the movement key bindings on a keyboard, else the
			-- control scripts' stick or thumbstick.
			local strafe, ahead
			local usingKeys = Keybinds.usingKeys()
			local vector = if usingKeys then nil else controlMoveVector()
			if usingKeys then
				strafe = (if Keybinds.isDown("right") then 1 else 0) - (if Keybinds.isDown("left") then 1 else 0)
				ahead = (if Keybinds.isDown("forward") then 1 else 0) - (if Keybinds.isDown("back") then 1 else 0)
			elseif vector then
				strafe, ahead = vector.X, -vector.Z
			else
				local move = hum.MoveDirection
				strafe = move.X * rightX + move.Z * rightZ
				ahead = move.X * headingX + move.Z * headingZ
			end
			local moveX = rightX * strafe + headingX * ahead
			local moveZ = rightZ * strafe + headingZ * ahead
			local length = math.sqrt(strafe * strafe + ahead * ahead)

			-- Facing: the camera's direction in first person and with shift lock, else where the
			-- character walks (turning smoothly).
			local firstPerson = (cameraCFrame.Position - camera.Focus.Position).Magnitude < FIRST_PERSON_DISTANCE
			local lockedToCamera = firstPerson or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
			local facingX, facingZ, forward
			if lockedToCamera then
				facingX, facingZ, forward = headingX, headingZ, ahead
				view.yaw = yawOf(headingX, headingZ)
			else
				if length > 1e-3 then
					facingX, facingZ = moveX / length, moveZ / length
					local turn = angleDifference(yawOf(facingX, facingZ), view.yaw)
					local maxTurn = Movement.TurnSpeed * dt
					view.yaw += math.clamp(turn, -maxTurn, maxTurn)
				else
					facingX, facingZ = -math.sin(view.yaw), -math.cos(view.yaw)
				end
				forward = math.min(length, 1)
			end

			jumpLatched = jumpLatched or jumpHeld()
			followSprintMode()
			followSneakMode()
			return {
				moveX = moveX,
				moveZ = moveZ,
				forward = forward,
				facingX = facingX,
				facingZ = facingZ,
				lookY = math.clamp(cameraCFrame.LookVector.Y, -1, 1),
				jump = jumpLatched,
				sneak = sneakHeld or sneakOn,
				sprint = sprintHeld or sprintOn,
			}
		end

		RunService:BindToRenderStep("IceVoxelMovement", RENDER_PRIORITY, function(dt: number)
			-- (Last frame's bob off first: the input reads the camera's own direction.)
			unbob()
			if rootPart.Parent == nil then
				return
			end
			if hum.Health <= 0 then
				dieIfDead()
				return
			end
			-- Stay in the Physics state (anything else would apply humanoid forces).
			local humanoidState = hum:GetState()
			if humanoidState ~= Enum.HumanoidStateType.Physics and humanoidState ~= Enum.HumanoidStateType.Dead then
				hum:ChangeState(Enum.HumanoidStateType.Physics)
			end
			antiGravity.Force = Vector3.new(0, rootPart.AssemblyMass * workspace.Gravity, 0)

			-- Moved by some other script? Follow it. Roblox physics moves the root along its velocity
			-- in between, for a step that need not match this frame's dt (hitches), so allow for
			-- the velocity over both frames.
			local placed = lastPlaced
			local drift = lastVelocity.Magnitude * (dt + lastDt)
			if placed and (rootPart.Position - placed).Magnitude > MOVED_TOLERANCE + drift then
				local moved = Rig.feet(character)
				if moved then
					snap(moved)
				end
			end

			local frameInput = readInput(dt)
			stepLag *= math.exp(-STEP_CATCH_UP * dt)
			-- Spectating someone: follow their feet (no ticks of our own); sneaking leaves (not a
			-- Shift that a screen or the switcher takes: a container's shift click).
			local following: Vector3? = nil
			local target = spectated
			if target then
				local other = target.Character
				local otherHumanoid = other and other:FindFirstChildOfClass("Humanoid")
				local otherFeet = other and Rig.feet(other)
				if
					not GameMode.isSpectatorOf(player)
					or target.Parent == nil
					or otherHumanoid == nil
					or otherHumanoid.Health <= 0
					or otherFeet == nil
					or frameInput.sneak
				then
					MovementController.spectate(nil)
				else
					local camera = workspace.CurrentCamera
					if camera and camera.CameraSubject ~= otherHumanoid then
						camera.CameraSubject = otherHumanoid
					end
					aimAtEyes(otherHumanoid, otherFeet)
					following = otherFeet
				end
			end
			if following then
				PlayerPhysics.place(state, following.X, following.Y, following.Z)
				previous = following
				accumulator = 0
				stepLag = 0
				view.speed = 0
			elseif view.frozen then
				-- Wait for the server's spawn teleport (fresh characters) and for the ground.
				if not settled and os.clock() - spawnedAt > SPAWN_SETTLE then
					settled = true
				end
				-- Jumps pressed while waiting don't fire afterwards.
				jumpLatched = false
				if settled and streamer:isReady(math.floor(state.x), math.floor(state.z)) then
					view.frozen = false
					accumulator = 0
				end
			else
				accumulator = math.min(accumulator + dt, TICK * MAX_TICKS_PER_FRAME)
				while accumulator >= TICK do
					accumulator -= TICK
					previous = Vector3.new(state.x, state.y, state.z)
					-- (The status effects as the server last sent them.)
					state.speedFactor = EffectState.speedFactor()
					state.jumpBoost, state.fallReduction = EffectState.jumpBoost()
					state.noSprint = EffectState.noSprint()
					local events = PlayerPhysics.tick(state, frameInput, physicsWorld)
					MovementSounds.tick(state, events, previous, physicsWorld.getBlock)
					-- (Thirst: sprinting, swimming and jumps, Tough As Nails.)
					Exertion.tick(state, events, previous)
					frameInput.jump = jumpHeld()
					jumpLatched = false
					view.speed = math.sqrt((state.x - previous.X) ^ 2 + (state.z - previous.Z) ^ 2) * TICK_RATE
					if events.jumped then
						view.jumpedAt = os.clock()
					end
					if events.stepUp > 0 then
						-- A step up is a whole block in one tick: draw it as a quick climb instead.
						previous += Vector3.new(0, events.stepUp, 0)
						stepLag = math.min(stepLag + events.stepUp, MAX_STEP_LAG)
					end
					if events.landed and events.damage > 0 and Movement.FallDamage then
						ClientNet.send(Protocol.ClientMessage.Fall, Protocol.encodeFall(events.fallDistance))
					end
				end
			end

			-- Draw the character between the last two ticks.
			local alpha = if view.frozen then 1 else accumulator / TICK
			local hull = previous:Lerp(Vector3.new(state.x, state.y, state.z), alpha)
			view.feet = hull

			-- Lie down in the swimming / crawling pose: face down, or along the view when swimming
			-- (Minecraft's PlayerRenderer), the body's middle at the middle of the low hull.
			local lying = state.pose == "crawling"
			view.tilt = math.clamp(view.tilt + (if lying then dt else -dt) * TILT_PER_SECOND, 0, 1)
			local bodyPitch = math.pi / 2
			if state.inWater then
				bodyPitch = math.clamp(math.pi / 2 - math.asin(frameInput.lookY), 0, math.pi)
			end
			local rootHeight = Rig.rootHeight(character, view.tilt)
			local cframe = CFrame.new(view.feet * BLOCK + Vector3.new(0, rootHeight, 0))
				* CFrame.Angles(0, view.yaw, 0)
				* CFrame.Angles(-bodyPitch * view.tilt, 0, 0)
			local velocity = if view.frozen
				then Vector3.zero
				else Vector3.new(state.vx, state.vy, state.vz) * VELOCITY_SCALE
			rootPart.CFrame = cframe
			rootPart.AssemblyLinearVelocity = velocity
			rootPart.AssemblyAngularVelocity = Vector3.zero
			lastPlaced, lastVelocity, lastDt = cframe.Position, velocity, dt

			-- The camera looks from the hull's eyes, whatever the body does (Roblox's camera adds
			-- CameraOffset in the root part's space).
			eye += (PlayerPhysics.eyeHeight(state) - eye) * ease(dt)
			local lag = Vector3.new(0, -stepLag * BLOCK, 0)
			if rootJoint then
				rootJoint.C0 = CFrame.new(cframe:VectorToObjectSpace(lag)) * rootJointC0
			end
			local toEye = Vector3.new(0, eye * BLOCK - rootHeight, 0) + lag
			hum.CameraOffset = cframe:VectorToObjectSpace(toEye) - Vector3.new(0, cameraHeight(hum, rootPart), 0)

			-- Minecraft's FOV modifier: x 1.1 flying, x SprintFov sprinting, and the effects' speed.
			local fov = 1
			if not view.frozen then
				fov = (if state.flying then FLYING_FOV else 1)
					* (if state.sprinting then Movement.SprintFov else 1)
					* ((state.speedFactor + 1) / 2)
			end
			updateFov(dt, fov)
		end)

		-- Minecraft's view bobbing and hurt tilt (Player/ViewBob), after the camera and the screen
		-- effects moved it; `unbob` takes them off before the camera updates again.
		local walk, bob = 0, 0
		local hurtAt = -math.huge
		local lastHealth = hum.Health
		table.insert(
			connections,
			hum.HealthChanged:Connect(function(health: number)
				if health < lastHealth and health > 0 then
					hurtAt = os.clock()
				end
				lastHealth = health
			end)
		)
		RunService:BindToRenderStep("IceVoxelViewBob", VIEW_BOB_PRIORITY, function(dt: number)
			local camera = workspace.CurrentCamera
			if camera == nil or hum.Health <= 0 then
				return
			end
			local state = view.state
			local still = view.frozen or spectated ~= nil
			local bobbing = not still and state.onGround and not state.swimming and not state.flying
			walk, bob = ViewBob.advance(walk, bob, view.speed, bobbing, dt)
			local x, y, roll, pitch = 0, 0, 0, 0
			if viewBobbing and not still and bob > 0 then
				x, y, roll, pitch = ViewBob.bobView(walk, bob)
			end
			roll += ViewBob.hurtRoll((os.clock() - hurtAt) * ViewBob.TICKS_PER_SECOND, damageTilt)
			if x == 0 and y == 0 and roll == 0 and pitch == 0 then
				return
			end
			-- The view moves by the bob, so the camera by its inverse.
			local clean = camera.CFrame
			local offset = CFrame.new(x * BLOCK, y * BLOCK, 0)
				* CFrame.Angles(0, 0, math.rad(roll))
				* CFrame.Angles(math.rad(pitch), 0, 0)
			camera.CFrame = clean * offset:Inverse()
			bobCamera, bobClean, bobSet = camera, clean, camera.CFrame
		end)
	end

	-- The server sets the game mode: the hull gets its abilities at once (survival and adventure
	-- stop flying; spectators fly through everything), and only spectators spectate.
	player:GetAttributeChangedSignal(GameMode.ATTRIBUTE):Connect(function()
		local mode = GameMode.of(player)
		local view = MovementController.current
		if view then
			PlayerPhysics.setGameMode(view.state, mode)
		end
		if not GameMode.isSpectator(mode) then
			MovementController.spectate(nil)
		end
	end)
	-- The spectator's wheel with the spectator menu closed: the flying speed, by whole notches.
	SpectatorGui.onFlyingSpeed(function(steps: number)
		local view = MovementController.current
		if view and view.state.noClip then
			PlayerPhysics.scrollFlyingSpeed(view.state, steps)
		end
	end)

	player.CharacterAdded:Connect(onCharacter)
	player.CharacterRemoving:Connect(disconnectAll)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

return MovementController
