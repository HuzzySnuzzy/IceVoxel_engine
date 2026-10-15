--!strict
--[[
	Firearms in the hand, in the manner of DayZ (Shared/Weapons): raising and lowering, the sights,
	firing, reloading, the fire mode and the light. Player/AimRules is the state machine and its
	numbers; this reads the input, runs it every frame and sends what the server must hear.

	  Raising   the use button (right mouse button; L2 on a gamepad; AIM on a touch screen, which
	            toggles) held with a firearm in hand raises it (Interaction/BlockInteraction hands
	            the press here unless it is on a block that opens a menu and the player isn't
	            sneaking): over the right shoulder in third person, down the sights in first person;
	            V (Toggle Sights; R3) goes down the sights from third person and back. Letting go,
	            another item or slot, a screen, the game mode switcher, typing, death, spectating,
	            swimming, climbing or lying down lowers it. The server hears raise and lower (the
	            Weapon message; it sets Types.AIM_ATTRIBUTE for everyone's poses and refuses shots
	            from a gun not raised for RaiseTicks). Config.Weapons.Enabled false: nothing raises,
	            guns only bash.
	  Firing    the attack button (left mouse button; R2; FIRE on a touch screen) fires only a raised
	            gun, once it has been up RaiseTicks (AimRules.settled); a lowered one bashes a mob in
	            reach (BlockInteraction's attack) and never mines. A semi-automatic fires once a
	            press, an automatic at its rate while held (Handling.shotTicks, AimRules.pull),
	            empty clicks dry, jammed or Ruined with the jam click. Each shot, after the camera,
	            the view bob and the sway moved the view (Camera + 6): the aim from the eyes (the
	            hull's, PlayerPhysics.eyeHeight) towards what the camera's centre ray hits within
	            Config.Weapons.MaxRange (blocks by their collision boxes, Shapes.sight; the mobs as
	            drawn; other players' hulls; what lies between the camera and the eyes is skipped),
	            or along the ray when that point isn't ahead (AimRules.aimFrom); the shot predicted
	            (ClientInventory.fire: the chamber empties, the next round feeds, the gun wears)
	            and its number sent in the Fire message (Net/WeaponSync: the shot counter, the
	            hotbar slot, the item, sights / moving / crouching / holding breath, the eyes, the
	            aim); drawn at once (Rendering/ShotView.ownShot: the class shot or the suppressed
	            one, the flash unless suppressed, a tracer to the aim, a pump's or bolt's rack);
	            the camera kicked (Handling.recoil, seeded by the player's UserId and the shot
	            counter: Player/AimCamera), the first-person gun too (Player/HeldItems.kick). The
	            server's record of the shot (ShotView) stops automatic fire when it refused it or
	            the gun jammed.
	  R         (X on a gamepad, RELOAD on a touch screen) on a jammed gun clears the jam (Inventory
	            action "weapon" op 3, UnjamTicks); else reloads (op 1): a detachable magazine gun
	            swaps in the fullest magazine and chambers (Handling.reloadTicks), an internal
	            magazine loads a round, then one every roundTicks (op 2) until it is full, the
	            matching rounds run out, the trigger is pressed or the hand changes. The predicted
	            inventory says what happened (Shared/Weapons/Loading through Inventory/Menu): an op
	            that changed nothing starts nothing (the server sees the same). While an action runs
	            (AimRules.lockTicks, as the server locks it) the gun doesn't fire and takes no other
	            op; item.firearm.reload, load_round and chamber play at once (predicted: the server
	            plays them for the others).
	  F, L      (DPad right, left) the next fire mode (op 4, ModeTicks) of a gun with more than one;
	            the weapon light on or off (op 5) when one is mounted.
	  Breath    the sprint key (L3) held in the sights holds breath (Handling: steadier, then out of
	            breath); raised, sprinting is barred (Player/AimCamera).
	  Guard     a melee weapon guarding (Interaction/MeleeInput.guarding) slows the player to
	            Config.Weapons.GuardSpeed and bars sprinting the same way (its pose is Player/
	            HeldItems').

	Interaction/BlockInteraction calls in (and requires this module, so nothing this module
	requires may require BlockInteraction):
	  attackPress(source, mob, attack)  the attack button went down with a firearm in hand
	                                    (`source` "mouse", "gamepad" or "touch"; `mob` the mob in
	                                    reach aimed at, if any; `attack(mob, heavy?)` hits it).
	                                    true: taken (a raised gun's trigger); false: BlockInteraction
	                                    bashes `mob` (a lowered gun). Mining never starts.
	  attackRelease(source)             the attack button went up (any held item; maybe never
	                                    pressed here)
	  usePress(source)                  the use button went down with a firearm in hand, not on a
	                                    block that opens a menu (unless sneaking): true when taken
	                                    (raising), false for BlockInteraction's use as before
	  useRelease(source)                the use button taken by usePress went up
	  hidesCrosshair()                  polled every frame: true hides Minecraft's crosshair
	                                    (raised: a shoulder dot or the sights instead)
	The client boot script calls `start(world)` after BlockInteraction.start; it starts the aim
	camera (Player/AimCamera), the HUD (Ui/WeaponHud) and the touch buttons (Ui/WeaponButtons).
	Nothing is created per frame: what is read off the held stack (its optic, muzzle device, fire
	mode, whether it may fire) is worked out again only when the stack changes.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Handling = require(Shared.Weapons.Handling)
local Items = require(Shared.Items)
local Origin = require(Shared.World.Origin)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Protocol = require(Shared.Net.Protocol)
local Shapes = require(Shared.Blocks.Shapes)
local VoxelRaycast = require(Shared.World.VoxelRaycast)
local WeaponState = require(Shared.Weapons.WeaponState)
local WeaponSync = require(Shared.Net.WeaponSync)
local Weapons = require(Shared.Weapons)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local MobRenderer = require(script.Parent.Parent.Entities.MobRenderer)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local GameModeSwitcher = require(script.Parent.Parent.Ui.GameModeSwitcher)
local Screens = require(script.Parent.Parent.Ui.Screens)
local WeaponButtons = require(script.Parent.Parent.Ui.WeaponButtons)
local WeaponHud = require(script.Parent.Parent.Ui.WeaponHud)
local AimCamera = require(script.Parent.Parent.Player.AimCamera)
local AimRules = require(script.Parent.Parent.Player.AimRules)
local HeldItems = require(script.Parent.Parent.Player.HeldItems)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local RemotePlayers = require(script.Parent.Parent.Player.RemotePlayers)
local SpectatorRules = require(script.Parent.Parent.Player.SpectatorRules)
local ShotRules = require(script.Parent.Parent.Rendering.ShotRules)
local ShotView = require(script.Parent.Parent.Rendering.ShotView)
local MeleeInput = require(script.Parent.MeleeInput)

-- Hits a mob (BlockInteraction's: an Attack message and a swing); `heavy` for the melee rework's
-- heavy attack.
export type Attack = (mob: MobRenderer.MobView, heavy: boolean?) -> ()

local CAMERA = Enum.RenderPriority.Camera.Value
-- The posture before anything else this frame; the shots after the camera, the view bob and the
-- sway (Player/AimCamera: Camera + 5).
local STATE_PRIORITY = CAMERA - 4
local FIRE_PRIORITY = CAMERA + 6
-- Lying down this far (MovementController's tilt) lowers the gun.
local LYING = 0.3
-- Sounds of the fire mode and the light switching (the dry click, quieter and higher).
local SWITCH_VOLUME, SWITCH_PITCH = 0.6, 1.6

local Firearms = {}

local started = false
local aim = AimRules.new()
-- What holds the gun up (by source: "mouse", "gamepad"), the touch AIM toggle, the trigger.
local raiseHeld: { [string]: boolean? } = {}
local touchRaise = false
local triggerHeld: { [string]: boolean? } = {}
-- The shot counter (Fire's u16) and the recoil's seed.
local shotCounter = 0
local seed = 0
-- The hand last seen (a change lowers the gun and lets go of everything).
local heldSlot, heldItem = 0, 0
-- The sound to play when the running action ends (a reload that chambered, a jam cleared).
local closing: string? = nil
-- This frame's input to AimRules.step and the HUD's state (filled in place).
local input: AimRules.Input = { held = false, blocked = true, raise = false, firstPerson = false }
local hud: WeaponHud.State = {
	held = false,
	posture = "lowered",
	raise = 0,
	progress = nil,
	action = nil,
	jammed = false,
	mode = nil,
	scoped = false,
	redDot = false,
}
-- The recoil's stance (filled in place).
local stance: Handling.Stance = { sights = false, moving = false, crouching = false }
local getBlock: (x: number, y: number, z: number) -> number? = function()
	return nil
end
local sightStops: (id: number) -> boolean = function()
	return true
end
local sightOutline: ((id: number, x: number, y: number, z: number) -> { number }?)? = nil

-- What the held stack says, worked out again when the stack (or the game mode) changes.
type Read = {
	stack: Items.Stack?,
	mode: string,
	optic: number?,
	muzzle: number?,
	muzzleFraction: number,
	modeIndex: number,
	auto: boolean,
	jammed: boolean,
	canFire: boolean,
	reason: string?,
	redDot: boolean,
	modeText: string?,
}
local read: Read = {
	stack = nil,
	mode = "",
	optic = nil,
	muzzle = nil,
	muzzleFraction = 1,
	modeIndex = 1,
	auto = false,
	jammed = false,
	canFire = false,
	reason = nil,
	redDot = false,
	modeText = nil,
}

local ACTION_WORDS: { [string]: string } = { reload = "RELOADING", round = "LOADING", unjam = "CLEARING" }

-- The firearm in hand and its spec (nil, nil: none).
local function heldGun(): (Items.Stack?, Weapons.FirearmSpec?)
	local stack = ClientInventory.selectedStack()
	local spec = if stack then Weapons.firearm(stack.item) else nil
	if spec == nil then
		return nil, nil
	end
	return stack, spec
end

-- Does the melee weapon in hand guard (Interaction/MeleeInput.guarding, read through `any`: the
-- module's first version had none)?
local function meleeGuarding(): boolean
	local guarding = (MeleeInput :: any).guarding
	return type(guarding) == "function" and guarding() == true
end

-- Do firearms work for this player (Config.Weapons.Enabled, not a spectator)?
local function enabled(): boolean
	return Config.Weapons.Enabled == true and not GameMode.isSpectator(ClientInventory.mode())
end

-- Reads the held gun's stack (see Read) when it changed.
local function refresh(stack: Items.Stack, spec: Weapons.FirearmSpec)
	local gameMode = ClientInventory.mode()
	if stack == read.stack and gameMode == read.mode then
		return
	end
	read.stack, read.mode = stack, gameMode
	local optic = WeaponState.attachment(stack, "optic")
	local muzzle, muzzleWear = WeaponState.attachment(stack, "muzzle")
	read.optic = optic
	read.muzzle = muzzle
	read.muzzleFraction = if muzzle then WeaponState.fraction(muzzle, muzzleWear) else 1
	read.modeIndex = WeaponState.modeIndex(stack)
	read.auto = WeaponState.mode(stack) == "auto"
	read.jammed = WeaponState.jammed(stack)
	read.canFire, read.reason = WeaponState.canFire(stack, GameMode.instabuild(gameMode))
	local opticSpec = Weapons.attachment(optic)
	read.redDot = opticSpec ~= nil and spec.scope == nil and not AimRules.scoped(opticSpec.zoom or 1)
	read.modeText = if #spec.modes > 1 then (if read.auto then "AUTO" else "SEMI") else nil
end

-- The eyes (world blocks: the hull's last tick, as the server's eye), nil without a character.
local function eyes(): (number?, number, number)
	local view = MovementController.current
	if view == nil then
		return nil, 0, 0
	end
	local state = view.state
	return state.x, state.y + PlayerPhysics.eyeHeight(state), state.z
end

-- Plays `sound` at the eyes.
local function play(sound: string, volume: number?, pitch: number?)
	local x, y, z = eyes()
	if x then
		SoundPlayer.play(sound, x, y, z, volume, pitch)
	end
end

-- Weapon op `op` on the held gun (predicted and sent: Inventory action "weapon"): whether the
-- prediction changed it, and whether it chambered a round.
local function weaponOp(op: number): (boolean, boolean)
	local before = ClientInventory.selectedStack()
	ClientInventory.apply({ kind = "weapon", op = op, slot = -1, part = 0 })
	return AimRules.outcome(before, ClientInventory.selectedStack())
end

--[[ R, F, L, V ]]

local function reload()
	local stack, spec = heldGun()
	local now = os.clock()
	if stack == nil or spec == nil or not enabled() or AimRules.busy(aim, now) then
		return
	end
	if WeaponState.jammed(stack) then
		-- (The server clears it as surely: only it knows of jams.)
		weaponOp(3)
		AimRules.startBusy(aim, "unjam", now, AimRules.lockTicks(spec, 3, false))
		closing = ShotRules.CHAMBER
		return
	end
	local changed, chambered = weaponOp(1)
	if not changed then
		return
	end
	if spec.magazine ~= nil then
		AimRules.startBusy(aim, "reload", now, AimRules.lockTicks(spec, 1, chambered))
		play(ShotRules.RELOAD)
		closing = if chambered then ShotRules.CHAMBER else nil
	else
		AimRules.startBusy(aim, "round", now, AimRules.lockTicks(spec, 1, chambered))
		play(ShotRules.LOAD_ROUND)
		aim.loading = true
	end
end

local function nextMode()
	local stack, spec = heldGun()
	local now = os.clock()
	if stack == nil or spec == nil or #spec.modes < 2 or not enabled() or AimRules.busy(aim, now) then
		return
	end
	weaponOp(4)
	AimRules.startBusy(aim, "mode", now, AimRules.lockTicks(spec, 4, false))
	play(ShotRules.DRY, SWITCH_VOLUME, SWITCH_PITCH)
end

local function switchLight()
	local stack = heldGun()
	if stack == nil or not enabled() or WeaponState.attachment(stack, "light") == nil then
		return
	end
	weaponOp(5)
	play(ShotRules.DRY, SWITCH_VOLUME, SWITCH_PITCH * 1.25)
end

--[[ The aim ]]

-- The nearest other player's hull on the ray (blocks) within `reach`.
local function playersOn(sx: number, sy: number, sz: number, dx: number, dy: number, dz: number, reach: number): number
	local standing = PlayerPhysics.STANDING
	local half = standing.width / 2
	local best = reach
	for player, remote in RemotePlayers.each() do
		if player and remote.alive and SpectatorRules.targetable(GameMode.of(player)) then
			local t = AimRules.rayBox(
				sx,
				sy,
				sz,
				dx,
				dy,
				dz,
				remote.x - half,
				remote.y,
				remote.z - half,
				remote.x + half,
				remote.y + standing.height,
				remote.z + half
			)
			if t and t < best then
				best = t
			end
		end
	end
	return best
end

--[[ Firing ]]

local function shoot(stack: Items.Stack, spec: Weapons.FirearmSpec)
	local view = MovementController.current
	local camera = workspace.CurrentCamera
	local ex, ey, ez = eyes()
	if view == nil or camera == nil or ex == nil then
		return
	end
	-- The camera's centre ray (blocks), from where it passes the eyes.
	local frame = camera.CFrame
	local ox, oy, oz = Origin.renderToBlocks(frame.Position)
	local look = frame.LookVector
	local dx, dy, dz = look.X, look.Y, look.Z
	local skip = math.max(0, (ex - ox) * dx + (ey - oy) * dy + (ez - oz) * dz)
	local sx, sy, sz = ox + dx * skip, oy + dy * skip, oz + dz * skip
	local reach = Config.Weapons.MaxRange
	local hit = VoxelRaycast.cast(sx, sy, sz, dx, dy, dz, reach, getBlock, sightStops, sightOutline)
	if hit then
		reach = hit.distance
	end
	local mob, mobDistance = MobRenderer.pick(Vector3.new(sx, sy, sz), look, reach)
	if mob then
		reach = math.min(reach, mobDistance)
	end
	reach = playersOn(sx, sy, sz, dx, dy, dz, reach)
	local tx, ty, tz = sx + dx * reach, sy + dy * reach, sz + dz * reach
	local ax, ay, az = AimRules.aimFrom(ex, ey, ez, tx, ty, tz, dx, dy, dz)

	-- Predicted, numbered and sent.
	local seq = ClientInventory.fire(stack.item)
	shotCounter = (shotCounter + 1) % 65536
	local state = view.state
	stance.sights = aim.posture == "sights"
	stance.moving = AimRules.moving(view.speed)
	stance.crouching = state.crouching
	ClientNet.send(
		Protocol.ClientMessage.Fire,
		WeaponSync.encodeFire({
			seq = seq,
			shot = shotCounter,
			slot = ClientInventory.selected(),
			item = stack.item,
			sights = stance.sights == true,
			moving = stance.moving == true,
			crouching = stance.crouching == true,
			breath = AimCamera.holdingBreath(),
			ox = ex,
			oy = ey,
			oz = ez,
			dx = ax,
			dy = ay,
			dz = az,
		})
	)

	-- Drawn and felt at once.
	local suppressed = Handling.suppressed(read.muzzle, read.muzzleFraction)
	ShotView.ownShot(
		ShotRules.fireSound(spec, suppressed, 0),
		suppressed,
		ShotRules.glow(read.muzzle, read.muzzleFraction),
		ex,
		ey,
		ez,
		tx,
		ty,
		tz,
		ShotRules.cycleDelay(spec, read.modeIndex)
	)
	local pitch, yaw = Handling.recoil(spec, stance, seed, shotCounter)
	AimCamera.kick(pitch, yaw)
	HeldItems.kick()
end

--[[ Every frame ]]

-- R3 toggles the sights while a gun is in hand, taken from Roblox's camera (which zooms on it).
local SIGHTS_ACTION = "IceVoxelGunSights"
local sightsBound = false
local function bindSights(on: boolean)
	if on == sightsBound then
		return
	end
	sightsBound = on
	if on then
		ContextActionService:BindActionAtPriority(SIGHTS_ACTION, function(_, state: Enum.UserInputState)
			if state == Enum.UserInputState.Begin then
				AimRules.toggleSights(aim)
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonR3)
	else
		ContextActionService:UnbindAction(SIGHTS_ACTION)
	end
end

local function stateStep()
	local now = os.clock()
	local stack, spec = heldGun()
	local slot = ClientInventory.selected()
	local item = if stack then stack.item else 0
	if slot ~= heldSlot or item ~= heldItem then
		-- Another hand: everything lets go (a held button raises nothing until pressed again).
		heldSlot, heldItem = slot, item
		table.clear(raiseHeld)
		table.clear(triggerHeld)
		touchRaise = false
		aim.loading = false
	end
	local armed = spec ~= nil and enabled()
	WeaponButtons.setShown(armed)
	bindSights(armed)

	local view = MovementController.current
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local state = if view then view.state else nil
	input.held = spec ~= nil
	input.blocked = not enabled()
		or view == nil
		or state == nil
		or humanoid == nil
		or humanoid.Health <= 0
		or Screens.isOpen()
		or GameModeSwitcher.isOpen()
		or Keybinds.typing()
		or MovementController.spectating() ~= nil
		or state.swimming
		or state.climbing
		or view.tilt > LYING
	input.raise = next(raiseHeld) ~= nil or touchRaise
	input.firstPerson = AimCamera.firstPerson()
	local op = AimRules.step(aim, input, now)
	if op then
		ClientNet.send(
			Protocol.ClientMessage.Weapon,
			WeaponSync.encodeWeapon(if op == "raise" then WeaponSync.Op.Raise else WeaponSync.Op.Lower)
		)
		if op == "lower" then
			table.clear(triggerHeld)
			touchRaise = false
		end
		WeaponButtons.setRaised(op == "raise")
	end

	if stack and spec then
		refresh(stack, spec)
	end
	-- (A melee weapon's guard slows the player as raising does: Interaction/MeleeInput.)
	local inHand = ClientInventory.selectedStack()
	local guard = spec == nil and inHand ~= nil and Weapons.melee(inHand.item) ~= nil and meleeGuarding()
	AimCamera.set(aim.posture, spec, if spec then read.optic else nil, now, guard)
	if view and state and humanoid then
		local breathKey = Keybinds.isDown("sprint")
			or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonL3)
		AimCamera.setStance(
			AimRules.moving(view.speed),
			state.crouching,
			humanoid.Health < humanoid.MaxHealth / 2,
			breathKey
		)
	end

	-- A timed action: its end, then the next round of an internal magazine.
	local progress, kind, finished = AimRules.progress(aim, now)
	if finished then
		local sound = closing
		closing = nil
		if sound and spec then
			play(sound)
		end
	end
	if aim.loading and progress == nil then
		if spec == nil or stack == nil or not AimRules.wantsRound(stack) then
			aim.loading = false
		else
			local changed = weaponOp(2)
			if changed then
				AimRules.startBusy(aim, "round", now, AimRules.lockTicks(spec, 2, false))
				play(ShotRules.LOAD_ROUND)
				progress, kind = 0, "round"
			else
				aim.loading = false
			end
		end
	end

	-- The HUD.
	hud.held = spec ~= nil
	hud.posture = aim.posture
	hud.raise = AimRules.raiseProgress(aim, now)
	hud.progress = if kind ~= nil and kind ~= "mode" then progress else nil
	hud.action = if kind then ACTION_WORDS[kind] else nil
	hud.jammed = spec ~= nil and read.jammed
	hud.mode = if spec then read.modeText else nil
	hud.scoped = AimCamera.scoped()
	hud.redDot = spec ~= nil and read.redDot
	WeaponHud.render(hud, now)
end

local function fireStep()
	local stack, spec = heldGun()
	if stack == nil or spec == nil or aim.posture == "lowered" then
		return
	end
	refresh(stack, spec)
	local now = os.clock()
	local trigger = next(triggerHeld) ~= nil
	local ticks = Handling.shotTicks(spec, read.modeIndex)
	local pull = AimRules.pull(aim, now, trigger, read.auto, ticks, read.canFire, read.reason)
	if pull == "fire" then
		shoot(stack, spec)
	elseif pull == "dry" then
		play(ShotRules.DRY)
	elseif pull == "jam" then
		play(ShotRules.JAM)
	end
end

--[[ API (see the header) ]]

-- Starts the firearms' input, camera, poses and HUD.
function Firearms.start(world: ClientWorld.ClientWorld)
	if started then
		return
	end
	started = true
	seed = Players.LocalPlayer.UserId
	getBlock = function(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end
	sightStops, sightOutline = Shapes.sight(getBlock)
	AimCamera.start()
	WeaponHud.start()
	WeaponButtons.start({
		fire = function(down: boolean)
			if down and aim.posture ~= "lowered" then
				triggerHeld.touch = true
				aim.loading = false
			else
				triggerHeld.touch = nil
			end
		end,
		aim = function()
			touchRaise = not touchRaise
		end,
		reload = reload,
	})
	-- The server's record of an own shot that stops automatic fire (refused, or a jam).
	ShotView.onOwnShot(function(shot: WeaponSync.Shot)
		AimRules.stop(aim)
		if shot.jammed then
			play(ShotRules.JAM)
		end
	end)
	UserInputService.InputBegan:Connect(function(press: InputObject, processed: boolean)
		if processed or Screens.isOpen() or GameModeSwitcher.isOpen() or Keybinds.typing() then
			return
		end
		local key = press.KeyCode
		if Keybinds.matches("reload", press) or key == Enum.KeyCode.ButtonX then
			reload()
		end
		if Keybinds.matches("fireMode", press) or key == Enum.KeyCode.DPadRight then
			nextMode()
		end
		if Keybinds.matches("weaponLight", press) or key == Enum.KeyCode.DPadLeft then
			switchLight()
		end
		if Keybinds.matches("sights", press) and heldGun() then
			AimRules.toggleSights(aim)
		end
	end)
	RunService:BindToRenderStep("IceVoxelFirearmsState", STATE_PRIORITY, stateStep)
	RunService:BindToRenderStep("IceVoxelFirearmsFire", FIRE_PRIORITY, fireStep)
end

-- The attack button went down with a firearm in hand (see the header).
function Firearms.attackPress(source: string, _mob: MobRenderer.MobView?, _attack: Attack): boolean
	-- (The attack button stops loading round by round, raised or not.)
	aim.loading = false
	if not enabled() or heldGun() == nil or aim.posture == "lowered" then
		return false
	end
	triggerHeld[source] = true
	return true
end

-- The attack button went up.
function Firearms.attackRelease(source: string)
	triggerHeld[source] = nil
end

-- The use button went down with a firearm in hand (see the header): raising.
function Firearms.usePress(source: string): boolean
	if not enabled() or heldGun() == nil then
		return false
	end
	raiseHeld[source] = true
	return true
end

-- The use button usePress took went up.
function Firearms.useRelease(source: string)
	raiseHeld[source] = nil
end

-- Should Minecraft's crosshair hide now (see the header)?
function Firearms.hidesCrosshair(): boolean
	return AimRules.hidesCrosshair(aim.posture)
end

return Firearms
