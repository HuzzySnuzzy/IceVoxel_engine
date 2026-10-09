--!strict
--[[
	This player's mana as the server last sent it (Net/MagicSync Mana, server Players/Mana): what
	the HUD's stars (Ui/ManaHud) and casting (Interaction/Casting) read. Mana and max are 0
	until the first message (none comes with Config.Mana off: no stars are drawn then).

	  changedAt  os.clock() when the whole mana or the max last changed (the HUD's stars linger
	             Config.Mana.HudLinger after it).
	  refused    a message saying a cast was refused for want of mana fires `refused` (the newest
	             cast this client predicted didn't happen: Rendering/ProjectileView drops its
	             projectile) and blinks the stars; `noteRefused` blinks them for a cast this
	             client didn't send for want of mana.
	  full       regeneration just filled it: Terraria's chime, entity.player.mana_full (flat).
	  spend      a cast predicted here takes its mana at once, so a held button doesn't predict a
	             cast the server will refuse; the server's next message (sent at once after the
	             cast) says what is true.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local MagicSync = require(Shared.Net.MagicSync)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)

local ManaState = {}

local FULL = "entity.player.mana_full"

local mana, max = 0, 0
local changedAt = -math.huge
local refusedAt = -math.huge
local changedEvent = Instance.new("BindableEvent")
local refusedEvent = Instance.new("BindableEvent")
-- Fires when a message changes the mana or the max.
ManaState.changed = changedEvent.Event
-- Fires when the server refused a cast for want of mana.
ManaState.refused = refusedEvent.Event

-- Mana (whole, after predicted casts) and max mana (0, 0 before the first message).
function ManaState.get(): (number, number)
	return mana, max
end

-- os.clock() when the mana or the max last changed.
function ManaState.changedAt(): number
	return changedAt
end

-- os.clock() when a cast was last refused for want of mana.
function ManaState.refusedAt(): number
	return refusedAt
end

-- Is there `amount` mana to cast with (as far as this client knows)?
function ManaState.has(amount: number): boolean
	return mana >= amount
end

-- A cast this client didn't send for want of mana: the stars blink as for a refused one (no
-- prediction is taken away: none was made).
function ManaState.noteRefused()
	refusedAt = os.clock()
end

-- A cast this client predicts takes `amount` now (see the header).
function ManaState.spend(amount: number)
	if amount > 0 then
		mana = math.max(0, mana - amount)
		changedAt = os.clock()
		changedEvent:Fire()
	end
end

function ManaState.start()
	ClientNet.on(Protocol.ServerMessage.Mana, function(payload: buffer)
		local status = MagicSync.decodeMana(payload)
		if status == nil then
			return
		end
		local now = os.clock()
		if status.mana ~= mana or status.max ~= max then
			mana, max = status.mana, status.max
			changedAt = now
			changedEvent:Fire()
		end
		if status.refused then
			refusedAt = now
			refusedEvent:Fire()
		end
		if status.full then
			SoundPlayer.playFlat(FULL)
		end
	end)
end

return ManaState
