--!strict
--[[
	Drinking and filling bottles and canteens (Tough As Nails) on this player's client, for
	Interaction/BlockInteraction: a right click (`use`, after a block's own menu) with a Glass
	Bottle, a canteen, a filled bottle or an empty hand does what Shared/ToughAsNails/Drinks
	.action says, aiming at a water source along Minecraft's source-only ray (BlockInteraction's
	`waterAt`):
	  fill   Drink fill at the source (the server fills it and splashes)                swing
	  hand   Drink hand at the source, and the gulp at once (TAN's hand drinking)       swing
	  drink  Drink start, then while the use button stays down (`stop` when it is let go), the
	         same item in the same hotbar slot and no screen open, Drinks.USE_TICKS (32) ticks
	         count at 20 a second, with Minecraft's gulp (entity.generic.drink) every 4 ticks from
	         the 7th (LivingEntity.triggerItemUseEffects); at 32, Drink finish and the last gulp.
	         Anything else cancels it (Drink cancel). The arm stays put (Player/HeldItems has no
	         use animation) and the player moves at full speed: only the sounds tell.
	Nothing is predicted: the server's inventory snapshot brings the emptied bottle or the worn
	canteen, and its Survival message the thirst. Spectators do none of it, and drinks need
	SurvivalState.canDrink (thirsty, or creative).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local Rig = require(Shared.Movement.Rig)
local Drinks = require(Shared.ToughAsNails.Drinks)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local Screens = require(script.Parent.Parent.Ui.Screens)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local SurvivalState = require(script.Parent.Parent.Player.SurvivalState)

-- A water source cell (VoxelRaycast's hit, at least its cell).
export type Source = { x: number, y: number, z: number }

local Drinking = {}

local DRINK = "entity.generic.drink"
local TICK = 1 / 20
-- Minecraft's gulps: every 4 ticks once 7 have passed (remaining ticks <= USE_TICKS - 7).
local GULP_EVERY = 4
local GULP_FROM = 7

type Holding = { slot: number, item: number, elapsed: number, ticks: number }
local holding: Holding? = nil
local started = false

-- Minecraft's drinking sound at this player (pitch 0.9..1.0: the event's own variance).
local function gulp()
	local character = Players.LocalPlayer.Character
	local feet = if character then Rig.feet(character) else nil
	if feet then
		SoundPlayer.play(DRINK, feet.X, feet.Y + 1.5, feet.Z)
	end
end

local function cancel()
	if holding then
		holding = nil
		ClientNet.send(Protocol.ClientMessage.Drink, Protocol.encodeDrink(Protocol.DrinkAction.Cancel))
	end
end

-- Is the player holding a drink to their mouth?
function Drinking.isDrinking(): boolean
	return holding ~= nil
end

-- How far the drink has got (0..1), nil when none.
function Drinking.progress(): number?
	local current = holding
	return if current then math.min(current.ticks / Drinks.USE_TICKS, 1) else nil
end

-- Does a right click with `stack` (nil: empty hand) possibly do something here?
function Drinking.handles(stack: Items.Stack?): boolean
	if stack == nil then
		return SurvivalState.handDrinking() and SurvivalState.get() ~= nil
	end
	return Drinks.isWaterItem(stack.item)
end

--[[
	A right click with `stack` in hand (nil: empty) in game `mode`; `waterAt` gives the water source
	aimed at (nil: none). Returns what it did ("fill", "hand", "drink") or nil.
]]
function Drinking.use(stack: Items.Stack?, mode: string, waterAt: () -> Source?): Drinks.Action?
	if holding or GameMode.isSpectator(mode) or not Drinking.handles(stack) then
		return nil
	end
	local source = waterAt()
	local action = Drinks.action(stack, source ~= nil, SurvivalState.canDrink(mode), SurvivalState.handDrinking())
	if (action == "fill" or action == "hand") and source then
		local kind = if action == "fill" then Protocol.DrinkAction.Fill else Protocol.DrinkAction.Hand
		ClientNet.send(Protocol.ClientMessage.Drink, Protocol.encodeDrink(kind, source.x, source.y, source.z))
		if action == "hand" then
			gulp()
		end
		return action
	elseif action == "drink" and stack then
		holding = { slot = ClientInventory.selected(), item = stack.item, elapsed = 0, ticks = 0 }
		ClientNet.send(Protocol.ClientMessage.Drink, Protocol.encodeDrink(Protocol.DrinkAction.Start))
		return action
	end
	return nil
end

-- The use button was let go: a drink not finished yet is cancelled.
function Drinking.stop()
	cancel()
end

local function update(dt: number)
	local current = holding
	if current == nil then
		return
	end
	local stack = ClientInventory.selectedStack()
	if Screens.isOpen() or ClientInventory.selected() ~= current.slot or stack == nil or stack.item ~= current.item then
		cancel()
		return
	end
	current.elapsed += dt
	while current.ticks < Drinks.USE_TICKS and current.elapsed >= (current.ticks + 1) * TICK do
		current.ticks += 1
		local remaining = Drinks.USE_TICKS - current.ticks
		if remaining == 0 then
			holding = nil
			ClientNet.send(Protocol.ClientMessage.Drink, Protocol.encodeDrink(Protocol.DrinkAction.Finish))
			gulp()
			return
		elseif remaining <= Drinks.USE_TICKS - GULP_FROM and remaining % GULP_EVERY == 0 then
			gulp()
		end
	end
end

function Drinking.start()
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(update)
end

return Drinking
