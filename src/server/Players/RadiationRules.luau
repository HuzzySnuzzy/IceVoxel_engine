--!strict
--[[
	One player's radiation on the server, pure (no Roblox APIs, so the tests run it over a fake
	world and inventory): a look at what is around and carried, the dose it builds, and the
	Radiation Sickness it gives (Shared/Radiation's rules; Config.Radiation). Players/Radiation
	keeps a State per character and makes a look once a second a player.

	  Look      `look(state, getBlock, body, seconds, hooks)`: for a survival or adventure player
	            (GameMode.isSurvivalLike), the rate is the blocks around
	            the body's centre (Radiation.scan, half the standing height above the feet) and
	            what they carry (Radiation.carried: slots, armor, cursor and `body.extra`), less
	            the Hazmat suit's share (Radiation.shielding of the armor worn); for anyone else 0.
	            Then the dose takes `seconds` at that rate (Radiation.dose: it decays in every
	            mode) and, for a survival or adventure player, each symptom of its level
	            (Radiation.symptoms) is given or renewed through `hooks` (Radiation.renewal: what
	            they have now, `current`, decides). Returns the rate. With Config.Radiation off a
	            look is 0 and leaves the dose as it is.
	  Death     a new character's State starts at no dose (`new()`); a saved one comes back with
	            its dose (`new(dose)`, checked: a finite dose, at least 0).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Radiation = require(Shared.Radiation)

export type State = {
	-- The dose (Sv) and the last look's rate (Sv/h, after shielding), with its parts: the blocks'
	-- and the carried (before shielding) and the share kept out.
	dose: number,
	rate: number,
	blocks: number,
	carried: number,
	share: number,
}

-- What a look reads of the player: their feet (blocks), game mode and what they carry.
export type Body = {
	x: number,
	y: number,
	z: number,
	mode: string,
	inventory: Radiation.Carrying?,
	-- More stacks with them (an open crafting grid of their own; nil: none).
	extra: { [number]: Items.Stack? }?,
}

-- The player's effects: the amplifier of one they have (nil: not) and its ticks left, and a give.
export type Hooks = {
	current: (effect: number) -> (number?, number),
	give: (effect: number, ticks: number, amplifier: number) -> (),
}

local RadiationRules = {}

-- The body's centre above the feet (blocks): where the radiation is measured.
RadiationRules.CENTRE = PlayerPhysics.dimensions("standing").height / 2

-- A State with `dose` (Sv; nil, negative or not finite: none).
function RadiationRules.new(dose: number?): State
	local value = if type(dose) == "number" and dose == dose and dose ~= math.huge and dose > 0 then dose else 0
	return { dose = value, rate = 0, blocks = 0, carried = 0, share = 0 }
end

--[[
	One look of `seconds` (see the header) at `body` among `getBlock`'s blocks; `hooks` (nil: none)
	give the sickness. Returns the rate (Sv/h).
]]
function RadiationRules.look(
	state: State,
	getBlock: Radiation.GetBlock,
	body: Body,
	seconds: number,
	hooks: Hooks?
): number
	local rate, blocks, carried, share = 0, 0, 0, 0
	if not Config.Radiation.Enabled then
		-- (Off: the dose is kept as it is, for when it is back.)
		state.rate, state.blocks, state.carried, state.share = rate, blocks, carried, share
		return 0
	end
	local exposed = GameMode.isSurvivalLike(body.mode)
	if exposed then
		blocks = Radiation.scan(getBlock, body.x, body.y + RadiationRules.CENTRE, body.z)
		local inventory = body.inventory
		if inventory then
			carried = Radiation.carried(inventory, body.extra)
			share = Radiation.shielding(inventory.armor)
		end
		rate = Radiation.exposure(blocks + carried, share)
	end
	state.rate, state.blocks, state.carried, state.share = rate, blocks, carried, share
	state.dose = Radiation.dose(state.dose, rate, seconds)
	if hooks and exposed then
		for _, symptom in Radiation.symptoms(Radiation.level(state.dose)) do
			local current, ticks = hooks.current(symptom.effect)
			local give = Radiation.renewal(symptom.effect, symptom.amplifier, current, ticks)
			if give then
				hooks.give(symptom.effect, give, symptom.amplifier)
			end
		end
	end
	return rate
end

return RadiationRules
