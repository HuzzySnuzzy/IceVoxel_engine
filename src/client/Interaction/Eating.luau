--!strict
--[[
	Eating on this player's client, for Interaction/BlockInteraction: a right click with a food in
	hand (Shared/Items/Foods: the meat mobs drop, cooked or raw, and rotten flesh), when no block's
	menu takes the click, starts Minecraft's 32 tick hold, as Interaction/Drinking does for drinks:

	  start   Eat start, then while the use button stays down (`stop` when it is let go), the same
	          item in the same hotbar slot and no screen open, Foods.USE_TICKS (32) ticks count at
	          20 a second, with Minecraft's bite (entity.generic.eat) every 4 ticks from the 7th
	          (LivingEntity.triggerItemUseEffects); at 32, Eat finish and the burp
	          (entity.player.burp). Anything else cancels it (Eat cancel).
	Only when the player may eat (Foods.canEat: hurt, or in creative; never a spectator). Nothing is
	predicted: the server's inventory snapshot brings the eaten item and the health comes back with
	the character's.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Foods = require(Shared.Items.Foods)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local Rig = require(Shared.Movement.Rig)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local Screens = require(script.Parent.Parent.Ui.Screens)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)

local Eating = {}

local TICK = 1 / 20
-- Minecraft's bites: every 4 ticks once 7 have passed.
local BITE_EVERY = 4
local BITE_FROM = 7

type Holding = { slot: number, item: number, elapsed: number, ticks: number }
local holding: Holding? = nil
local started = false

local function play(sound: string)
	local character = Players.LocalPlayer.Character
	local feet = if character then Rig.feet(character) else nil
	if feet then
		SoundPlayer.play(sound, feet.X, feet.Y + 1.5, feet.Z)
	end
end

local function cancel()
	if holding then
		holding = nil
		ClientNet.send(Protocol.ClientMessage.Eat, Protocol.encodeEat(Protocol.EatAction.Cancel))
	end
end

-- Is the player eating?
function Eating.isEating(): boolean
	return holding ~= nil
end

-- How far the food has got (0..1), nil when none.
function Eating.progress(): number?
	local current = holding
	return if current then math.min(current.ticks / Foods.USE_TICKS, 1) else nil
end

-- Is `stack` food?
function Eating.handles(stack: Items.Stack?): boolean
	return stack ~= nil and Foods.isFood(stack.item)
end

-- May the player eat now (their character's health, game `mode`)?
local function mayEat(mode: string): boolean
	local character = Players.LocalPlayer.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil or humanoid.Health <= 0 then
		return false
	end
	return Foods.canEat(humanoid.Health, humanoid.MaxHealth, mode)
end

-- A right click with `stack` in game `mode`: starts eating it. Returns whether it did.
function Eating.use(stack: Items.Stack?, mode: string): boolean
	if holding or stack == nil or not Eating.handles(stack) or not mayEat(mode) then
		return false
	end
	holding = { slot = ClientInventory.selected(), item = stack.item, elapsed = 0, ticks = 0 }
	ClientNet.send(Protocol.ClientMessage.Eat, Protocol.encodeEat(Protocol.EatAction.Start))
	return true
end

-- The use button was let go: a food not finished yet is put away.
function Eating.stop()
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
	while current.ticks < Foods.USE_TICKS and current.elapsed >= (current.ticks + 1) * TICK do
		current.ticks += 1
		local remaining = Foods.USE_TICKS - current.ticks
		if remaining == 0 then
			holding = nil
			ClientNet.send(Protocol.ClientMessage.Eat, Protocol.encodeEat(Protocol.EatAction.Finish))
			play("entity.player.burp")
			return
		elseif remaining <= Foods.USE_TICKS - BITE_FROM and remaining % BITE_EVERY == 0 then
			play("entity.generic.eat")
		end
	end
end

function Eating.start()
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(update)
end

return Eating
