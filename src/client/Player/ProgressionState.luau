--!strict
--[[
	This player's knowledge, Age and skills as the server last sent them (Protocol Progress, server
	Players/Progression): what the HUD's knowledge bar (Ui/Hud), the Age banner (Ui/AgeToast), the
	skill tree (Ui/SkillTreeScreen), the crafting screens' locked results and JEI's lock marks
	read, and the rules the client predicts with the same functions as the server:

	  * the recipe gate on the predicted inventory (ClientInventory.setRecipes: `allows`), so a
	    locked crafting result is never predicted;
	  * the mining speed (`miningFactor`: Interaction/BlockInteraction's mining, as ServerNet's
	    check) and the campfire's boiling wait (`boilSpeed`).

	nil until the first message (a fresh Stone Age player's rules meanwhile), and for good when
	Config.Progression is off (everything is allowed, nothing is drawn).

	Changes play sounds (Shared/Sounds/SoundList): knowledge gained the orb's pickup (at most
	ORB_INTERVAL apart), a level gained the level-up, an Age reached the challenge fanfare and
	its banner. The first message after joining plays nothing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Progression = require(Shared.Progression)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)

-- Seconds between two orb sounds.
local ORB_INTERVAL = 0.08

local ProgressionState = {}

local player = Players.LocalPlayer
local status: Progression.Status? = nil
-- `status` as a state for the shared rules (no discoveries: the client has their counts only).
local state: Progression.State = Progression.new()
local changedEvent = Instance.new("BindableEvent")
local ageEvent = Instance.new("BindableEvent")
local lastOrb = 0

-- Fires when a new status arrives.
ProgressionState.changed = changedEvent.Event
-- Fires (age: Progression.Age) when the player reaches an Age (not on joining).
ProgressionState.ageReached = ageEvent.Event

-- Is progression on (Config.Progression.Enabled)?
function ProgressionState.enabled(): boolean
	return Config.Progression.Enabled == true
end

-- The last status the server sent (nil: none yet, or progression is off).
function ProgressionState.get(): Progression.Status?
	return status
end

-- The status as a state for Shared/Progression's rules (a fresh one until the first message).
function ProgressionState.state(): Progression.State
	return state
end

--[[
	The state the recipe gate judges this player by: nil when it doesn't apply (progression or
	Config.Progression.GateRecipes off, creative), so Shared/Progression allows everything.
]]
function ProgressionState.gate(): Progression.State?
	if
		ProgressionState.enabled()
		and Config.Progression.GateRecipes == true
		and not GameMode.instabuild(GameMode.of(player))
	then
		return state
	end
	return nil
end

-- May this player make `item` (a crafting or smelting result)?
function ProgressionState.allows(item: number): boolean
	return Progression.allows(ProgressionState.gate(), item)
end

-- Why this player may not make `item` ("Requires the Iron Age"), or nil when they may.
function ProgressionState.lockText(item: number): string?
	return Progression.lockText(ProgressionState.gate(), item)
end

-- The state Progression's perks read: nil with progression off (no perks; Mining.playerFactor).
function ProgressionState.perks(): Progression.State?
	return if ProgressionState.enabled() then state else nil
end

-- This player's mining speed with `tool` (Progression.miningFactor; 1 with progression off).
function ProgressionState.miningFactor(tool: number?): number
	return if ProgressionState.enabled() then Progression.miningFactor(state, tool) else 1
end

-- How many times as fast this player boils water on a campfire (Progression.boilSpeed).
function ProgressionState.boilSpeed(): number
	return if ProgressionState.enabled() then Progression.boilSpeed(state) else 1
end

-- The gate the predicted inventory gets (Types.Window `recipes`).
local function recipeGate(item: number): boolean
	return ProgressionState.allows(item)
end

local function receive(incoming: Progression.Status)
	local previous = status
	status = incoming
	state = Progression.fromStatus(incoming)
	-- (The gate's answers changed: the prediction is rebuilt with them.)
	ClientInventory.setRecipes(recipeGate)
	if previous then
		local Ages = Progression.Ages
		if incoming.age > previous.age then
			SoundPlayer.playFlat("ui.toast.challenge_complete")
			for index = previous.age + 1, incoming.age do
				ageEvent:Fire(Ages.get(index))
			end
		elseif Progression.Knowledge.levelOf(incoming.points) > Progression.Knowledge.levelOf(previous.points) then
			SoundPlayer.playFlat("entity.player.levelup")
		elseif incoming.points > previous.points then
			local now = os.clock()
			if now - lastOrb >= ORB_INTERVAL then
				lastOrb = now
				SoundPlayer.playFlat("entity.experience_orb.pickup")
			end
		end
	end
	changedEvent:Fire()
end

-- Asks the server to unlock skill tree node `id` (it answers with a new status or a notice).
function ProgressionState.unlock(id: string)
	local skill = Progression.Skills.byId(id)
	if skill then
		ClientNet.send(Protocol.ClientMessage.UnlockSkill, Protocol.encodeUnlockSkill(skill.index))
	end
end

function ProgressionState.start()
	if not ProgressionState.enabled() then
		return
	end
	ClientInventory.setRecipes(recipeGate)
	-- (Creative players have every recipe: the prediction again after a switch.)
	player:GetAttributeChangedSignal(GameMode.ATTRIBUTE):Connect(function()
		ClientInventory.setRecipes(recipeGate)
	end)
	ClientNet.on(Protocol.ServerMessage.Progress, function(payload: buffer)
		local incoming = Protocol.decodeProgress(payload)
		if incoming then
			receive(incoming)
		end
	end)
end

return ProgressionState
