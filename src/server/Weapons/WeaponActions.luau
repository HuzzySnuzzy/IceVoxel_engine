--!strict
--[[
	How players hold their weapons, and the time weapon actions take, on the server (Weapons/init
	hands it the real modules: Env; tests/spec/WeaponFiring hands it fakes).

	  Aim      Weapon messages (Net/WeaponSync.Op), at most WEAPON_RATE a second (the rest
	           dropped): raise with a firearm in hand (and Config.Weapons.Enabled), lower, guard
	           with a melee weapon of Shared/Weapons (and Config.Weapons.Melee.Enabled), unguard.
	           The aim lives in the player attribute Inventory/Types.AIM_ATTRIBUTE (AIM_RAISED or
	           AIM_GUARD: every client's poses, Mobs/Mobs' guard), and here with when the gun was
	           raised (Weapons/FireRules' "raise": no shot before Config.Weapons.RaiseTicks) and
	           the hotbar slot and item it was raised with. `tick` (every frame, only over the
	           players aiming) drops an aim whose player died, became a spectator, changed slot or
	           whose hand holds another item (whatever the client says), so a raise or a guard
	           never carries over to the next weapon or the next life; `lower` drops it at once
	           (Weapons/init: a character coming or going).
	  Locks    the inventory's weapon actions (Inventory action "weapon", Shared/Weapons/Loading,
	           through Players/Inventories.setWeaponHooks): `allow` refuses ops 1..4 (reload, load
	           a round, clear a jam, fire mode) while a lock runs (one tick of slack), and so does
	           FireRules for shots (`busyUntil`); `applied` starts the lock of an action that
	           changed the gun (`effect`; an action Loading refused, which hands back the stack as
	           it was, locks nothing and sounds nothing), by Shared/Weapons/Handling.actionLock,
	           the one rule the client's Interaction/Firearms times the same action by:
	             reload (detachable)  reloadTicks when a magazine went in, plus chamberTicks when a
	                                  round was chambered; chamberTicks when only that
	             reload (internal),
	             load a round         roundTicks when a round went in
	             clear a jam          Config.Weapons.UnjamTicks
	             fire mode            Config.Weapons.ModeTicks
	             light, detach        none
	  Sounds   the predicted ones (Shared/Sounds side "predicted": the acting client played its
	           own) for everyone near but the player, at their feet: item.firearm.reload when a
	           magazine went in, item.firearm.chamber when a round was chambered (after the
	           magazine's ticks) or a jam cleared, item.firearm.load_round for a round loaded by
	           hand.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Types = require(Shared.Inventory.Types)
local WeaponSync = require(Shared.Net.WeaponSync)
local Weapons = require(Shared.Weapons)
local Handling = require(Shared.Weapons.Handling)

local FireRules = require(script.Parent.FireRules)

type Stack = Items.Stack

-- What WeaponActions needs of the world (the game's real modules, or a spec's fakes).
export type Env = {
	settings: FireRules.Settings,
	-- Seconds (the server's clock).
	now: () -> number,
	-- The stack in the player's hand, the selected hotbar slot (nil: no inventory).
	held: (player: any) -> Stack?,
	selected: (player: any) -> number?,
	alive: (player: any) -> boolean,
	mode: (player: any) -> string,
	-- Sets Types.AIM_ATTRIBUTE (nil clears it).
	setAim: (player: any, aim: string?) -> (),
	-- Plays a sound at the player for everyone near but them.
	play: (player: any, sound: string) -> (),
	-- Runs `callback` `seconds` from now.
	later: (seconds: number, callback: () -> ()) -> (),
}

-- A predicted sound of a weapon action, `delay` ticks after it.
export type Cue = { sound: string, delay: number }

type PlayerState = {
	bucket: FireRules.Bucket,
	aim: string?,
	raisedAt: number?,
	slot: number?,
	item: number?,
	busyUntil: number?,
}

export type WeaponActions = {
	env: Env,
	states: { [any]: PlayerState },
	-- The players with an aim (`tick` looks only at them).
	aiming: { [any]: boolean },
	weapon: (self: WeaponActions, player: any, op: number) -> boolean,
	allow: (self: WeaponActions, player: any, action: Types.Action) -> boolean,
	applied: (self: WeaponActions, player: any, action: Types.Action, before: Stack?, after: Stack?) -> (),
	tick: (self: WeaponActions) -> (),
	lower: (self: WeaponActions, player: any) -> (),
	raised: (self: WeaponActions, player: any) -> (string?, number?),
	busyUntil: (self: WeaponActions, player: any) -> number?,
	forget: (self: WeaponActions, player: any) -> (),
}

local WeaponActions = {}
WeaponActions.__index = WeaponActions

-- Weapon messages a second a player may send (the rest are dropped).
WeaponActions.WEAPON_RATE = 20
-- Inventory weapon ops (Types.Action "weapon").
WeaponActions.RELOAD = 1
WeaponActions.LOAD_ROUND = 2
WeaponActions.UNJAM = 3
WeaponActions.MODE = 4
WeaponActions.LIGHT = 5
WeaponActions.DETACH = 6

local RELOAD_SOUND = "item.firearm.reload"
local CHAMBER_SOUND = "item.firearm.chamber"
local LOAD_SOUND = "item.firearm.load_round"
local NONE: { Cue } = table.freeze({})
local TICK = Handling.TICK

function WeaponActions.new(env: Env): WeaponActions
	local self = { env = env, states = {}, aiming = {} }
	return (setmetatable(self, WeaponActions) :: any) :: WeaponActions
end

local function stateOf(self: WeaponActions, player: any): PlayerState
	local state = self.states[player]
	if state == nil then
		state = { bucket = FireRules.newBucket(WeaponActions.WEAPON_RATE) }
		self.states[player] = state
	end
	return state
end

local function setAim(self: WeaponActions, player: any, state: PlayerState, aim: string?)
	if state.aim == aim then
		return
	end
	state.aim = aim
	if aim == nil then
		state.raisedAt, state.slot, state.item = nil, nil, nil
		self.aiming[player] = nil
	else
		self.aiming[player] = true
	end
	self.env.setAim(player, aim)
end

-- May `player` aim (alive, no spectator)?
local function mayAim(env: Env, player: any): boolean
	return env.alive(player) and not GameMode.isSpectator(env.mode(player))
end

--[[
	A Weapon message's op (see the header's Aim): true when it changed the aim.
]]
function WeaponActions.weapon(self: WeaponActions, player: any, op: number): boolean
	local env = self.env
	local s = env.settings
	local now = env.now()
	local state = stateOf(self, player)
	if not FireRules.take(state.bucket, now, WeaponActions.WEAPON_RATE, WeaponActions.WEAPON_RATE) then
		return false
	end
	local Op = WeaponSync.Op
	local held = env.held(player)
	local item = if held and held.count > 0 then held.item else nil
	if op == Op.Raise then
		if not s.Enabled or Weapons.firearm(item) == nil or not mayAim(env, player) then
			return false
		end
		local slot = env.selected(player)
		if state.aim == Types.AIM_RAISED and state.slot == slot and state.item == item then
			-- (Raised already: the time it went up stands.)
			return false
		end
		-- (From guarding, or raised with another gun: up again from now.)
		setAim(self, player, state, Types.AIM_RAISED)
		state.raisedAt, state.slot, state.item = now, slot, item
		return true
	elseif op == Op.Lower then
		if state.aim ~= Types.AIM_RAISED then
			return false
		end
		setAim(self, player, state, nil)
		return true
	elseif op == Op.Guard then
		if not s.Melee.Enabled or Weapons.melee(item) == nil or not mayAim(env, player) then
			return false
		end
		if state.aim == Types.AIM_GUARD then
			return false
		end
		setAim(self, player, state, Types.AIM_GUARD)
		state.raisedAt, state.slot, state.item = nil, env.selected(player), item
		return true
	elseif op == Op.Unguard then
		if state.aim ~= Types.AIM_GUARD then
			return false
		end
		setAim(self, player, state, nil)
		return true
	end
	return false
end

-- Drops every aim that no longer holds (see the header's Aim).
function WeaponActions.tick(self: WeaponActions)
	local env = self.env
	for player in self.aiming do
		local state = self.states[player]
		if state == nil then
			self.aiming[player] = nil
			continue
		end
		local held = env.held(player)
		local item = if held and held.count > 0 then held.item else nil
		local still = mayAim(env, player) and item ~= nil and item == state.item and env.selected(player) == state.slot
		if still and state.aim == Types.AIM_RAISED then
			still = env.settings.Enabled and Weapons.firearm(item) ~= nil
		elseif still then
			still = env.settings.Melee.Enabled and Weapons.melee(item) ~= nil
		end
		if not still then
			setAim(self, player, state, nil)
		end
	end
end

-- The player's aim (Types.AIM_RAISED, AIM_GUARD or nil) and when the gun went up (raised only).
function WeaponActions.raised(self: WeaponActions, player: any): (string?, number?)
	local state = self.states[player]
	if state == nil then
		return nil, nil
	end
	return state.aim, if state.aim == Types.AIM_RAISED then state.raisedAt else nil
end

-- When the player's weapon action lock ends (nil: none).
function WeaponActions.busyUntil(self: WeaponActions, player: any): number?
	local state = self.states[player]
	return if state then state.busyUntil else nil
end

-- (Ops a lock holds back.)
local function locked(op: number): boolean
	return op >= WeaponActions.RELOAD and op <= WeaponActions.MODE
end

-- The weapon hooks' `allow` (see the header's Locks).
function WeaponActions.allow(self: WeaponActions, player: any, action: Types.Action): boolean
	if action.kind ~= "weapon" or not locked(action.op) then
		return true
	end
	local busy = self:busyUntil(player)
	return busy == nil or self.env.now() >= busy - Handling.SLACK_TICKS * TICK
end

--[[
	What a weapon action that turned `before` into `after` costs (see the header's Locks and
	Sounds): the lock's ticks and the sounds for the others. The lock is Shared/Weapons/Handling
	.actionLock's, the rule the client's Interaction/Firearms times its own by; nothing for an
	action that changed nothing or acted on anything but a firearm.
]]
function WeaponActions.effect(
	action: Types.Action,
	before: Stack?,
	after: Stack?,
	s: FireRules.Settings
): (number, { Cue })
	if action.kind ~= "weapon" then
		return 0, NONE
	end
	local kind, ticks, chambered = Handling.actionLock(action.op, before, after, s)
	if kind == "reload" then
		local spec = Weapons.firearm((before :: Stack).item) :: Weapons.FirearmSpec
		local cues: { Cue } = { { sound = RELOAD_SOUND, delay = 0 } }
		if chambered then
			table.insert(cues, { sound = CHAMBER_SOUND, delay = spec.reloadTicks })
		end
		return ticks, cues
	elseif kind == "chamber" or kind == "unjam" then
		return ticks, { { sound = CHAMBER_SOUND, delay = 0 } }
	elseif kind == "round" then
		return ticks, { { sound = LOAD_SOUND, delay = 0 } }
	elseif kind == "mode" then
		return ticks, NONE
	end
	return 0, NONE
end

-- The weapon hooks' `applied` (see the header's Locks and Sounds).
function WeaponActions.applied(self: WeaponActions, player: any, action: Types.Action, before: Stack?, after: Stack?)
	local env = self.env
	local ticks, cues = WeaponActions.effect(action, before, after, env.settings)
	if ticks > 0 then
		local state = stateOf(self, player)
		state.busyUntil = env.now() + ticks * TICK
	end
	for _, cue in cues do
		if cue.delay > 0 then
			local sound = cue.sound
			env.later(cue.delay * TICK, function()
				if self.states[player] ~= nil then
					env.play(player, sound)
				end
			end)
		else
			env.play(player, cue.sound)
		end
	end
end

-- Drops the player's aim, raised or guarding (their character came or went).
function WeaponActions.lower(self: WeaponActions, player: any)
	local state = self.states[player]
	if state ~= nil and state.aim ~= nil then
		setAim(self, player, state, nil)
	end
end

-- Forgets a player who left (their aim is cleared with them).
function WeaponActions.forget(self: WeaponActions, player: any)
	self.states[player] = nil
	self.aiming[player] = nil
end

return WeaponActions
