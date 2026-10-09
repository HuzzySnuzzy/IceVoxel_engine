--!strict
--[[
	What WAILA ("What Am I Looking At", Ui/Waila) says about the thing under the crosshair: an icon
	and lines of coloured text in Jade's order. Pure (no Roblox APIs), so the tests check the
	content; Ui/Waila draws it.

	  name      the block's name, white (a chest adds its slots in gray: "Chest (27 slots)"); a
	            dropped item's name and count; a player's display name and @name; a mob's kind
	            ("Zombie") with its health in red ("Health 14 / 20", half hearts: `mob`)
	  harvest   blocks only: the tool and tier they need to drop anything, with a green check or a
	            red cross for whether the held item harvests them ("Requires Iron Pickaxe"), or
	            the tool that mines them fastest when any hand will do ("Tool: Shovel"), or
	            "Unbreakable"
	  fluids    a fluid block is named by its fluid ("Lava" for every level and for CaveLava), and
	            one that gives light says so ("Light 15": lava lights its surroundings, which the
	            client draws with only some of its cells' lights)
	  pipes     Mekanism's transmitters: the mode of the side the Configurator points at ("Side:
	            Pull"); a transporter's colour ("Colour: Red") and the items inside it ("Items:
	            12"); a Mechanical Pipe's fluid ("Lava: ~4,000 / 8,000 mB": the fluid its network
	            holds, its fill byte times the capacity of the pipes the client sees connected, so
	            approximate; "Empty: 0 / 2,000 mB"); a Universal Cable's capacity ("Capacity: 8
	            kJ/t", Mekanism's tooltip; its sides set to push or pull read "Side: Push (as
	            Normal)": that is how they act).
	            Fluid Tanks: "Water: 12,000 / 32,000 mB" (Jade's Mekanism tank tooltip).
	  machines  Mekanism machines (Shared/Machines), from their Machines record: "Energy: 1.2 kJ /
	            20 kJ" ("Energy: Infinite" for the creative cube) and the machine's status
	            ("Producing 200 J/t", "Using 50 J/t", "Charging 4 kJ/t", "No power":
	            Machines.status, from the record's numbers and its kind's state code), then its
	            tanks ("Oil: 3,000 / 10,000 mB", `MachineFacts.tanks`: the record's, Protocol's
	            MachineRecord `tanks` from Machines.tankContents; empty without a record).
	  structures  structure blocks: their mode and structure name ("Mode: Save", "Name: hut");
	            jigsaws: name, target and pool (their records, Net/StructureNet). Creative only
	            blocks (structure blocks, structure voids, jigsaws) say "Creative only" where
	            the harvest line goes: survival players can't break them.
	  explosives  TNT: "Explosive: power 4" in gold; the Nuke: "Explosive: 24 block crater"; lit
	            ones (which can't be broken) "Lit: stand back!" in red where the harvest line goes
	            (`explosiveLine`)
	  light     blocks and fluids: "Light level 7", the light where a mob would stand: the cell on
	            top of an opaque block, a see-through block's own cell (`lightLine`). It is the
	            larger of the cell's block light and sky light, as Minecraft's light level, from the
	            client's estimate (the engine keeps no light map: Ui/Waila asks Shared/World/
	            LightEstimate.blockLight, which the server's mob spawning uses too, and
	            Rendering/LightingController.skyLight). Red where block light is 0
	            and sky light at most 7 (Minecraft 1.18+'s monsters may spawn there at any time),
	            yellow where block light is 0 under more sky (they may spawn at night), green where
	            a light source reaches it. The F3 view adds both parts ("block 0, sky 15").
	  details   players: health and game mode
	  extended  while the F3 overlay is open, gray lines with what the game knows: internal name
	            and id, position and chunk, biome, hardness, tool kind and level, drops with the
	            held item and by hand (a tall plant's top: what its lower half drops, as breaking
	            either half harvests the plant once), break time with the held item (Mining.ticks /
	            20, standing and dry, at the player's own speed: Haste, Mining Fatigue, the mining
	            perks), light, fluid level, render kind, solidity, friction and menu, whether it is
	            climbed (ladders, vines, rope) and how a cobweb slows ("Slows x 0.25 across, x 0.05
	            up and down", Blocks.stuckIn); for
	            transmitters their tier's numbers, the packed side modes and each side's mode,
	            colour and fill byte, the connected sides and the network the client sees; for
	            tanks their tier's numbers and contents; for machines their kind and part in an
	            energy network, the block's energy numbers and the last tick's flows
	  mod name  "IceVoxel" in blue italics, always last (Jade names the mod a thing comes from)

	Survival mining progress travels in `Info.progress` (Ui/Waila draws it as Jade's line along
	the panel's bottom edge, so it moves without rebuilding the text).

	Colours are names (Minecraft's chat colours, see Ui/Waila); a segment with `mark` starts with a
	check (true) or a cross (false).

	The panel's decisions live here too, so they are tested: what it names when a block, an entity
	and water are on the aim (`choose`), where it goes and at what scale (`placement`: centred, out
	of the minimap's corner and right of the F3 text when it can), and the italic shear
	(`italicShifts`).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Biomes = require(Shared.Biomes)
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Machines = require(Shared.Machines)
local Mining = require(Shared.Mining)
local MobList = require(Shared.Entities.MobList)
local Settings = require(Shared.Structures.Settings)
local Transmitters = require(Shared.Transmitters)

export type Colour = "white" | "gray" | "darkGray" | "blue" | "green" | "red" | "yellow" | "gold"

-- A run of text in one colour. `mark` draws a check (true) or a cross (false) before it.
export type Segment = { text: string, colour: Colour, italic: boolean?, mark: boolean? }
export type Line = { Segment }

-- What the panel shows on the left: an item's icon, a plain colour box (blocks that are no item,
-- like bedrock) or a player's head.
export type Icon = { item: number?, colour: { number }?, userId: number? }

export type Info = {
	icon: Icon?,
	lines: { Line },
	-- Survival mining progress of the block, 0..1 (nil: not being mined).
	progress: number?,
}

-- What the client knows about a Mekanism transmitter (Rendering/TransmitterRenderer).
export type TransmitterFacts = {
	-- Packed side modes, colour (0..16) and fill byte (0..255), as the server sent them.
	modes: number,
	colour: number,
	fluid: number,
	-- The fluid a pipe's network holds (Shared/Fluids id; nil or 0: none known, water when full).
	fluidId: number?,
	-- The side the Configurator points at (BlockInteraction.targetSide); nil: none.
	side: number?,
	-- Items and stacks in transit inside it.
	items: number,
	stacks: number,
	-- Connected sides (bit `side`): to transmitters, to acceptors.
	transmitters: number,
	acceptors: number,
	-- The connected transmitters the client sees, their pipes' capacity (mB), and whether the
	-- count is complete.
	networkSize: number,
	networkCapacity: number,
	networkComplete: boolean,
}

-- A fluid tank's contents (fluid: Shared/Fluids id, 0 none; mB).
export type TankFacts = { fluid: number, amount: number }
-- One of a machine's tanks (Protocol's MachineTank): its fluid (0 empty), amount and capacity (mB).
export type MachineTankFacts = { fluid: number, amount: number, capacity: number }

-- A machine's state (its Machines record, Rendering/TransmitterRenderer.machine; J and J/t), with
-- its kind's state code (Shared/Machines KindSpec `state`, 0 without one).
export type MachineFacts = {
	energy: number,
	capacity: number,
	input: number,
	output: number,
	rate: number,
	active: boolean,
	state: number,
	-- Its tanks' contents in tank order (the record's, Machines.tankContents; nil for a kind
	-- without tanks).
	tanks: { MachineTankFacts }?,
}

-- Optional facts about a block's surroundings that only the client knows.
export type BlockContext = {
	-- Mining progress (BlockInteraction.miningProgress).
	progress: number?,
	-- The biome's name at the block's column (extended view).
	biome: string?,
	-- Mekanism transmitters, fluid tanks and machines.
	transmitter: TransmitterFacts?,
	tank: TankFacts?,
	machine: MachineFacts?,
	-- A structure block's or jigsaw's settings, as the server sent them (nil: not known yet).
	structure: Settings.StructureSettings?,
	jigsaw: Settings.JigsawSettings?,
	-- The light where a mob would stand on the block (`lightLine`); nil: not known (unloaded).
	light: LightFacts?,
	-- The player's own mining speed with the held item (Mining.playerFactor: Haste, Mining
	-- Fatigue, the mining perks), for the break time; nil: 1.
	miningFactor: number?,
}

-- Minecraft's light parts at a cell, 0..15 each.
export type LightFacts = { block: number, sky: number }

local WailaInfo = {}

WailaInfo.MOD_NAME = "IceVoxel"
-- Text drawn for a check / cross in `text` (the panel draws them as pixel art).
WailaInfo.CHECK = "✔"
WailaInfo.CROSS = "✘"

local CHUNK = Config.ChunkSize

--[[ Text helpers ]]

-- "OakLog" -> "Oak Log" (the same rule as Items' display names).
local function spaced(name: string): string
	return (string.gsub(name, "(%l)(%u)", "%1 %2"))
end

-- 1.5 -> "1.5", 2 -> "2", 0.989 -> "0.989".
local function number(value: number): string
	if value == math.floor(value) and math.abs(value) < 1e15 then
		return string.format("%d", value)
	end
	return string.format("%g", value)
end

-- A whole number with thousands separators, as Mekanism writes amounts: 32000 -> "32,000".
function WailaInfo.thousands(value: number): string
	local text = string.format("%d", math.floor(math.abs(value) + 0.5))
	local grouped = string.reverse((string.gsub(string.reverse(text), "(%d%d%d)", "%1,")))
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return if value <= -0.5 then "-" .. grouped else grouped
end

-- Seconds with at most two decimals: 23 ticks -> "1.15 s".
local function seconds(ticks: number): string
	return `{number(math.floor(ticks / Mining.TICK_RATE * 100 + 0.5) / 100)} s`
end

local function segment(text: string, colour: Colour): Segment
	return { text = text, colour = colour }
end

-- White text after a check (true) or a cross (false).
local function marked(text: string, ok: boolean): Segment
	return { text = text, colour = "white", mark = ok }
end

local function gray(text: string): Line
	return { segment(text, "gray") }
end

-- The plain text of a line, a mark written as CHECK / CROSS and a space (for tests and logs).
function WailaInfo.text(line: Line): string
	local parts = {}
	for _, s in line do
		if s.mark ~= nil then
			table.insert(parts, (if s.mark then WailaInfo.CHECK else WailaInfo.CROSS) .. " ")
		end
		table.insert(parts, s.text)
	end
	return table.concat(parts)
end

-- Every line's text (WailaInfo.text), in order.
function WailaInfo.texts(info: Info): { string }
	local out = {}
	for _, line in info.lines do
		table.insert(out, WailaInfo.text(line))
	end
	return out
end

local function modLine(): Line
	local name: Segment = { text = WailaInfo.MOD_NAME, colour = "blue", italic = true }
	return { name }
end

--[[ Names ]]

-- A biome's display name by index (Biomes.list): "BirchForest" -> "Birch Forest".
function WailaInfo.biomeName(index: number): string
	local biome = Biomes.list[index]
	return if biome then spaced(biome.name) else "?"
end

--[[
	A block's name as players know it: its display name ("Wall Torch", "Block of Coal"), a fluid's
	group ("Water" for every level of water), or the spaced internal name.
]]
function WailaInfo.blockName(block: number): string
	local def = Blocks.get(block)
	if def == nil then
		return "?"
	end
	local fluid = def.fluid
	if fluid and fluid.level ~= 0 then
		return WailaInfo.blockName(Blocks.fluidId(fluid.group, 0))
	end
	if def.displayName then
		return def.displayName
	end
	local item = Items.ofBlock(block)
	return if item then Items.displayName(item) else spaced(def.name)
end

-- The icon of a block: its item (a wall torch shows the Torch, flowing water the Water), else a
-- box in its colour.
function WailaInfo.blockIcon(block: number): Icon
	local def = Blocks.get(block)
	local fluid = def and def.fluid
	local source = if fluid then Blocks.fluidId(fluid.group, 0) else block
	local item = Items.ofBlock(source)
	if item then
		return { item = item }
	end
	return { colour = if def then def.color else { 255, 0, 255 } }
end

-- The weakest tool of each kind and harvest level (Wooden rather than Golden at level 0), by name.
local toolNames: { [string]: { [number]: { name: string, speed: number } } } = {}
for _, def in Items.list do
	local tool = def.tool
	if tool then
		local byLevel = toolNames[tool.kind]
		if byLevel == nil then
			byLevel = {}
			toolNames[tool.kind] = byLevel
		end
		local known = byLevel[tool.level]
		if known == nil or tool.speed < known.speed then
			byLevel[tool.level] = { name = def.displayName, speed = tool.speed }
		end
	end
end

-- "pickaxe" -> "Pickaxe".
local function kindName(kind: string): string
	return string.upper(string.sub(kind, 1, 1)) .. string.sub(kind, 2)
end

-- The tool of `kind` at harvest `level` ("Iron Pickaxe"), or a generic name when there is none.
function WailaInfo.toolName(kind: string, level: number): string
	local byLevel = toolNames[kind]
	local known = byLevel and byLevel[level]
	return if known then known.name else `Level {level} {kindName(kind)}`
end

-- A stack as text: "Cobblestone", "Glow Dust x4"; nil is "nothing".
local function stackText(stack: Items.Stack?): string
	if stack == nil then
		return "nothing"
	end
	local name = Items.displayName(stack.item)
	return if stack.count > 1 then `{name} x{stack.count}` else name
end

-- "source", "flowing 3" or "falling" for a fluid block, nil for anything else.
function WailaInfo.fluidState(block: number): string?
	local def = Blocks.get(block)
	local fluid = def and def.fluid
	if fluid == nil then
		return nil
	end
	if fluid.level == 0 then
		return "source"
	elseif fluid.level >= 8 then
		return "falling"
	end
	return `flowing {fluid.level}`
end

-- The chunk of a block column and the column's place in it (floored, so -1 is in chunk -1 at 15).
function WailaInfo.chunkOf(x: number, z: number): (number, number, number, number)
	return x // CHUNK, z // CHUNK, x % CHUNK, z % CHUNK
end

--[[ Mekanism pipes ]]

-- A gray label and a white value: "Side: " "Pull".
local function labelled(label: string, value: string): Line
	return { segment(label, "gray"), segment(value, "white") }
end

-- The sides in a mask, by their initials: "D, N, E"; "none".
local function sideList(mask: number): string
	local names = {}
	for side = 0, 5 do
		if bit32.band(mask, bit32.lshift(1, side)) ~= 0 then
			table.insert(names, string.sub(Transmitters.sideName(side), 1, 1))
		end
	end
	return if #names > 0 then table.concat(names, ", ") else "none"
end

-- "Water: 12,000 / 32,000 mB" ("Empty: 0 / ..." without a fluid); `approximate` adds "~" to an
-- amount that is neither 0 nor full.
local function fluidLine(fluid: number, amount: number, capacity: number, approximate: boolean): Line
	local name = Transmitters.fluidName(fluid)
	local about = if approximate and amount > 0 and amount < capacity then "~" else ""
	return labelled(`{name}: `, `{about}{WailaInfo.thousands(amount)} / {WailaInfo.thousands(capacity)} mB`)
end

--[[
	The lines of a transmitter: the Configurator's side and its mode, a transporter's colour and
	items, a pipe's water (the network's fill byte over the capacity of the pipes connected to it,
	this one's own when it is alone).
]]
function WailaInfo.transmitterLines(block: number, facts: TransmitterFacts): { Line }
	local lines: { Line } = {}
	local side = facts.side
	local kind = Transmitters.kindOf(block)
	if side ~= nil and Transmitters.isSide(side) then
		local mode = Transmitters.modeOf(facts.modes, side)
		local name = Transmitters.modeName(mode)
		-- (A Universal Cable's PUSH and PULL act as NORMAL: say so, the arm shows no band.)
		if kind == "energy" and (mode == Transmitters.MODES.PUSH or mode == Transmitters.MODES.PULL) then
			name ..= ` (as {Transmitters.modeName(Transmitters.MODES.NORMAL)})`
		end
		table.insert(lines, labelled("Side: ", name))
	end
	if kind == "item" then
		table.insert(lines, labelled("Colour: ", Transmitters.colourName(facts.colour)))
		if facts.items > 0 then
			table.insert(lines, labelled("Items: ", WailaInfo.thousands(facts.items)))
		end
	elseif kind == "energy" then
		table.insert(lines, labelled("Capacity: ", `{Items.formatEnergy(Transmitters.cableCapacity(block))}/t`))
	elseif kind == "fluid" then
		local capacity = if facts.networkCapacity > 0 then facts.networkCapacity else Transmitters.pipeCapacity(block)
		local amount = Transmitters.fillAmount(facts.fluid, capacity)
		-- (A record without the fluid, from before pipes carried more than water: water.)
		local fluid = facts.fluidId or 0
		if fluid == 0 and amount > 0 then
			fluid = Transmitters.FLUIDS.WATER
		end
		table.insert(lines, fluidLine(if amount > 0 then fluid else 0, amount, capacity, true))
	end
	return lines
end

-- The extended (F3) lines of a transmitter.
function WailaInfo.transmitterDetails(block: number, facts: TransmitterFacts): { Line }
	local lines: { Line } = {}
	local tier = Transmitters.tier(block)
	local tierIndex = Transmitters.tierOf(block) or 0
	local tierName = if tier then tier.name else "?"
	local kind = Transmitters.kindOf(block)
	local pull = Transmitters.pullAmount(block)
	if kind == "item" then
		local restrictive = if Transmitters.isRestrictive(block) then ", restrictive" else ""
		local speed, cost = Transmitters.speed(block), number(Transmitters.pathCost(block))
		table.insert(
			lines,
			gray(`Transporter tier {tierIndex} ({tierName}{restrictive}), pull {pull}, speed {speed}, cost {cost}`)
		)
	elseif kind == "energy" then
		local capacity = WailaInfo.thousands(Transmitters.cableCapacity(block))
		table.insert(lines, gray(`Cable tier {tierIndex} ({tierName}), {capacity} J/t`))
	else
		local capacity = WailaInfo.thousands(Transmitters.pipeCapacity(block))
		table.insert(
			lines,
			gray(`Pipe tier {tierIndex} ({tierName}), {capacity} mB, pull {WailaInfo.thousands(pull)} mB/t`)
		)
	end
	local modes = {}
	for side = 0, 5 do
		local initial = string.sub(Transmitters.sideName(side), 1, 1)
		table.insert(modes, `{initial} {Transmitters.modeName(Transmitters.modeOf(facts.modes, side))}`)
	end
	table.insert(lines, gray(string.format("Modes 0x%03X: %s", facts.modes, table.concat(modes, ", "))))
	table.insert(lines, gray(`Colour {facts.colour}, fill {facts.fluid} / 255`))
	local linked, accepting = sideList(facts.transmitters), sideList(facts.acceptors)
	table.insert(lines, gray(`Connected: transmitters {linked}; acceptors {accepting}`))
	local more = if facts.networkComplete then "" else "+"
	local network = `Network {facts.networkSize}{more} transmitters`
	if kind == "fluid" then
		network ..= `, {WailaInfo.thousands(facts.networkCapacity)}{more} mB`
	elseif kind == "energy" then
		network ..= `, {WailaInfo.thousands(facts.networkCapacity)}{more} J/t`
	end
	table.insert(lines, gray(network))
	if kind == "item" then
		table.insert(lines, gray(`In transit {facts.stacks} stacks, {facts.items} items`))
	end
	return lines
end

-- The lines of a fluid tank: "Water: 12,000 / 32,000 mB".
function WailaInfo.tankLines(block: number, facts: TankFacts): { Line }
	return { fluidLine(facts.fluid, facts.amount, Transmitters.tankCapacity(block), false) }
end

-- The extended (F3) lines of a fluid tank.
function WailaInfo.tankDetails(block: number, facts: TankFacts): { Line }
	local tier = Transmitters.tier(block)
	local tierIndex = Transmitters.tierOf(block) or 0
	local tierName = if tier then tier.name else "?"
	local output = WailaInfo.thousands(Transmitters.tankOutput(block))
	local fluid = Transmitters.fluidName(facts.fluid)
	return {
		gray(`Tank tier {tierIndex} ({tierName}), output {output} mB/t`),
		gray(`Fluid {facts.fluid} ({fluid}), {WailaInfo.thousands(facts.amount)} mB`),
	}
end

--[[ Mekanism machines ]]

local function viewOf(block: number, facts: MachineFacts): Machines.View
	return {
		block = block,
		energy = facts.energy,
		capacity = facts.capacity,
		input = facts.input,
		output = facts.output,
		rate = facts.rate,
		active = facts.active,
		state = facts.state,
	}
end

-- What WAILA knows of a machine without a record: empty and idle at its block's capacity, its
-- tanks empty (the server's default record).
function WailaInfo.machineDefaults(block: number): MachineFacts
	local energy = Machines.energyOf(block)
	local capacity = if energy then energy.capacity else 0
	local tanks: { MachineTankFacts }? = nil
	if Machines.hasTanks(block) then
		local empty: { MachineTankFacts } = {}
		for i, tank in Machines.tanks(block) do
			empty[i] = { fluid = 0, amount = 0, capacity = tank.capacity }
		end
		tanks = empty
	end
	return {
		energy = if capacity == math.huge then math.huge else 0,
		capacity = capacity,
		input = 0,
		output = 0,
		rate = 0,
		active = false,
		state = 0,
		tanks = tanks,
	}
end

-- "Energy: 1.2 kJ / 20 kJ" (Mekanism's energy display), "Energy: Infinite" for the creative cube.
function WailaInfo.energyText(energy: number, capacity: number): string
	if capacity == math.huge then
		return "Infinite"
	end
	return `{Items.formatEnergy(energy)} / {Items.formatEnergy(capacity)}`
end

--[[
	The lines of a machine: its energy, then its status (Machines.status) when it has one, then
	each tank's contents when the facts carry them ("Lava: 5,000 / 24,000 mB").
]]
function WailaInfo.machineLines(block: number, facts: MachineFacts): { Line }
	local lines: { Line } = { labelled("Energy: ", WailaInfo.energyText(facts.energy, facts.capacity)) }
	local status = Machines.status(block, viewOf(block, facts))
	if status then
		table.insert(lines, { segment(status, "white") })
	end
	local tanks = facts.tanks
	if tanks then
		for _, tank in tanks do
			local amount = if tank.fluid ~= 0 then tank.amount else 0
			table.insert(lines, fluidLine(tank.fluid, amount, tank.capacity, false))
		end
	end
	return lines
end

-- "Light 15" for a fluid that gives light (lava), nil for any other block.
function WailaInfo.fluidLight(block: number): Line?
	local def = Blocks.get(block)
	if def == nil or def.fluid == nil or def.light <= 0 then
		return nil
	end
	return { segment(`Light {def.light}`, "gold") }
end

--[[
	"Light level N" for the light `facts` (N = the larger part, Minecraft's light level), coloured
	for mob spawning: red with no block light and sky light at most 7 (monsters may spawn at any
	time), yellow with no block light under more sky (at night), green when a light source reaches
	it. `extended` (F3) adds the parts.
]]
function WailaInfo.lightLine(facts: LightFacts, extended: boolean): Line
	local block = math.clamp(math.floor(facts.block), 0, 15)
	local sky = math.clamp(math.floor(facts.sky), 0, 15)
	local colour: Colour = if block > 0 then "green" elseif sky <= 7 then "red" else "yellow"
	local line: Line = { segment(`Light level {math.max(block, sky)}`, colour) }
	if extended then
		table.insert(line, segment(` (block {block}, sky {sky})`, "gray"))
	end
	return line
end

-- The extended (F3) lines of a machine.
function WailaInfo.machineDetails(block: number, facts: MachineFacts): { Line }
	local kind = Machines.kindOf(block)
	local energy = Machines.energyOf(block)
	local role = Machines.role(block) or "no energy flow"
	local lines: { Line } = { gray(`Machine {if kind then kind.name else "?"} ({role})`) }
	if energy then
		local input = if energy.input then `{Items.formatEnergy(energy.input)}/t` else "none"
		local output = if energy.output then `{Items.formatEnergy(energy.output)}/t` else "none"
		table.insert(lines, gray(`Holds {Items.formatEnergy(energy.capacity)}, in {input}, out {output}`))
	end
	table.insert(lines, gray(`Last tick: in {Items.formatEnergy(facts.input)}, out {Items.formatEnergy(facts.output)}`))
	local working = if facts.active then "active" else "idle"
	table.insert(lines, gray(`Rate {Items.formatEnergy(facts.rate)}/t, {working}`))
	return lines
end

--[[ Blocks ]]

--[[
	The harvest line of `block` for a player holding `held` (an item id, nil = bare hands), or nil
	when no tool matters:
	  * blocks needing a tool of some tier: "Requires Iron Pickaxe", checked when the held item
	    harvests it (Items.canHarvest), crossed when it would drop nothing;
	  * blocks any hand harvests that a tool mines faster: "Tool: Shovel", always checked;
	  * "Unbreakable" for bedrock and the like.
]]
function WailaInfo.harvest(block: number, held: number?): Line?
	local def = Blocks.get(block)
	if def == nil or def.fluid then
		return nil
	end
	if def.creativeOnly then
		-- (Minecraft's hardness -1 for survival; creative breaks them at once.)
		return { segment("Creative only", "gold") }
	end
	if not def.breakable or def.hardness < 0 then
		return { segment("Unbreakable", "red") }
	end
	local tool = def.tool
	if tool == nil then
		return nil
	end
	local level = def.toolLevel
	if level ~= nil then
		return { marked(`Requires {WailaInfo.toolName(tool, level)}`, Items.canHarvest(block, held)) }
	end
	return { marked(`Tool: {kindName(tool)}`, true) }
end

local LIT: { [number]: boolean } = { [Blocks.id.LitTnt] = true, [Blocks.id.LitNuke] = true }

-- What an explosive says (see the header), nil for other blocks.
function WailaInfo.explosiveLine(block: number): Line?
	if LIT[block] then
		return { segment("Lit: stand back!", "red") }
	elseif block == Blocks.id.Tnt then
		return { segment(`Explosive: power {Config.Tnt.Power}`, "gold") }
	elseif block == Blocks.id.Nuke then
		return { segment(`Explosive: {Config.Nuke.Radius} block crater`, "gold") }
	end
	return nil
end

-- The extended (F3) lines of a block.
local function blockDetails(
	block: number,
	held: number?,
	x: number,
	y: number,
	z: number,
	context: BlockContext?
): { Line }
	local def = Blocks.get(block)
	local lines: { Line } = {}
	local cx, cz, lx, lz = WailaInfo.chunkOf(x, z)
	table.insert(lines, gray(`{def.name} #{block}`))
	table.insert(lines, gray(`Position {x}, {y}, {z}`))
	table.insert(lines, gray(`Chunk {cx}, {cz} (local {lx}, {lz})`))
	local biome = context and context.biome
	if biome then
		table.insert(lines, gray(`Biome {biome}`))
	end
	local fluidState = WailaInfo.fluidState(block)
	local fluid = def.fluid
	if fluidState and fluid then
		table.insert(lines, gray(`Fluid {fluid.group}, {fluidState}`))
	else
		local unbreakable = not def.breakable or def.hardness < 0
		table.insert(lines, gray(if unbreakable then "Hardness unbreakable" else `Hardness {number(def.hardness)}`))
		local tool = def.tool
		if tool then
			local level = def.toolLevel
			table.insert(lines, gray(if level ~= nil then `Tool {tool}, level {level}` else `Tool {tool}, any level`))
		else
			table.insert(lines, gray("Tool none"))
		end
		if not unbreakable then
			-- (Breaking either half of a tall plant harvests its lower half: server EditRules.harvested.)
			local harvested = Blocks.plantBottom(block) or block
			if held ~= nil then
				table.insert(
					lines,
					gray(`Drops with {Items.displayName(held)}: {stackText(Items.drops(harvested, held))}`)
				)
			end
			table.insert(lines, gray(`Drops by hand: {stackText(Items.drops(harvested, nil))}`))
			if def.creativeOnly then
				table.insert(lines, gray("Breaks in creative only (at once)"))
			elseif def.hardness == 0 then
				table.insert(lines, gray("Breaks at once"))
			else
				local ticks = Mining.ticks(block, true, false, held, context and context.miningFactor)
				table.insert(lines, gray(`Breaks in {seconds(ticks)} ({ticks} ticks)`))
			end
		end
	end
	table.insert(lines, gray(`Light {Blocks.light(block)}`))
	local solid = if def.solid then "solid" else "not solid"
	table.insert(lines, gray(`Render {def.render}, {solid}, friction {number(def.friction)}`))
	if Blocks.isClimbable(block) then
		table.insert(lines, gray("Climbable"))
	end
	local stuck = Blocks.stuckIn(block)
	if stuck then
		table.insert(lines, gray(`Slows x {number(stuck[1])} across, x {number(stuck[2])} up and down`))
	end
	if def.menu then
		-- (A machine's slots are its kind's, not BlockList's `container`.)
		local slots = Machines.containerSize(block)
		table.insert(lines, gray(if slots > 0 then `Menu {def.menu}, {slots} slots` else `Menu {def.menu}`))
	end
	return lines
end

--[[ Structure blocks and jigsaws ]]

-- "Save" for "save".
local function capitalised(text: string): string
	return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

--[[
	The lines of a structure block (its mode from the block, the rest from its settings when the
	client has them): "Mode: Save", "Name: hut" (a DATA block shows its marker instead).
]]
function WailaInfo.structureLines(block: number, settings: Settings.StructureSettings?): { Line }
	local mode = Blocks.structureMode(block)
	if mode == nil then
		return {}
	end
	local lines: { Line } = { labelled("Mode: ", capitalised(mode)) }
	if settings then
		if mode == "data" then
			table.insert(lines, labelled("Data: ", if settings.metadata ~= "" then settings.metadata else "(none)"))
		else
			table.insert(lines, labelled("Name: ", if settings.name ~= "" then settings.name else "(none)"))
		end
	end
	return lines
end

-- The F3 lines of a structure block: its region and, in LOAD mode, how it places.
function WailaInfo.structureDetails(block: number, settings: Settings.StructureSettings): { Line }
	local mode = Blocks.structureMode(block)
	if mode ~= "save" and mode ~= "load" then
		return {}
	end
	local o, size = settings.offset, settings.size
	local lines: { Line } = {
		gray(`Offset {o[1]}, {o[2]}, {o[3]}, size {size[1]} x {size[2]} x {size[3]}`),
	}
	if mode == "load" then
		table.insert(
			lines,
			gray(
				`Rotation {settings.rotation * 90}, mirror {settings.mirror}, integrity {number(settings.integrity)}, seed {string.format(
					"%d",
					settings.seed
				)}`
			)
		)
	end
	table.insert(
		lines,
		gray(
			`Bounding box {if settings.showBoundingBox then "on" else "off"}, invisible blocks {if settings.showInvisible
				then "on"
				else "off"}`
		)
	)
	return lines
end

-- The lines of a jigsaw: "Name: ", "Target: ", "Pool: " (from its settings, when known).
function WailaInfo.jigsawLines(settings: Settings.JigsawSettings?): { Line }
	if settings == nil then
		return {}
	end
	return {
		labelled("Name: ", settings.name),
		labelled("Target: ", settings.target),
		labelled("Pool: ", settings.pool),
	}
end

-- The F3 lines of a jigsaw: its orientation, final state and joint.
function WailaInfo.jigsawDetails(block: number, settings: Settings.JigsawSettings?): { Line }
	local front, top = Blocks.jigsawOrientation(block)
	local lines: { Line } = {}
	if front and top then
		table.insert(lines, gray(`Front {front}, top {top}`))
	end
	if settings then
		table.insert(lines, gray(`Turns into {settings.finalState}, joint {settings.joint}`))
	end
	return lines
end

--[[
	What WAILA shows for `block` at (x, y, z) to a player holding `held` (an item id, nil = bare
	hands); `extended` adds the F3 details.
]]
function WailaInfo.block(
	block: number,
	held: number?,
	x: number,
	y: number,
	z: number,
	extended: boolean,
	context: BlockContext?
): Info
	local def = Blocks.get(block)
	local name: Line = { segment(WailaInfo.blockName(block), "white") }
	-- Storage shows its size (contents are only known while it is open, so nothing more).
	if def and def.menu == "Chest" and def.container > 0 then
		table.insert(name, segment(` ({def.container} slots)`, "gray"))
	end
	local lines: { Line } = { name }
	local harvest = if LIT[block] then nil else WailaInfo.harvest(block, held)
	if harvest then
		table.insert(lines, harvest)
	end
	local explosive = WailaInfo.explosiveLine(block)
	if explosive then
		table.insert(lines, explosive)
	end
	-- (F3's details say the light of every block.)
	local light = if extended then nil else WailaInfo.fluidLight(block)
	if light then
		table.insert(lines, light)
	end
	if context and context.light then
		table.insert(lines, WailaInfo.lightLine(context.light, extended))
	end
	-- Mekanism pipes, tanks and machines: what the server says about them.
	local transmitter = if context and Transmitters.isTransmitter(block) then context.transmitter else nil
	local tank = if context and Transmitters.isTank(block) then context.tank else nil
	local machine = if context and Machines.isMachine(block) then context.machine else nil
	if transmitter then
		for _, line in WailaInfo.transmitterLines(block, transmitter) do
			table.insert(lines, line)
		end
	elseif tank then
		for _, line in WailaInfo.tankLines(block, tank) do
			table.insert(lines, line)
		end
	elseif machine then
		for _, line in WailaInfo.machineLines(block, machine) do
			table.insert(lines, line)
		end
	elseif Blocks.isStructureBlock(block) then
		for _, line in WailaInfo.structureLines(block, context and context.structure) do
			table.insert(lines, line)
		end
	elseif Blocks.isJigsaw(block) then
		for _, line in WailaInfo.jigsawLines(context and context.jigsaw) do
			table.insert(lines, line)
		end
	end
	if extended and def then
		for _, line in blockDetails(block, held, x, y, z, context) do
			table.insert(lines, line)
		end
		if transmitter then
			for _, line in WailaInfo.transmitterDetails(block, transmitter) do
				table.insert(lines, line)
			end
		elseif tank then
			for _, line in WailaInfo.tankDetails(block, tank) do
				table.insert(lines, line)
			end
		elseif machine then
			for _, line in WailaInfo.machineDetails(block, machine) do
				table.insert(lines, line)
			end
		elseif Blocks.isStructureBlock(block) and context and context.structure then
			for _, line in WailaInfo.structureDetails(block, context.structure) do
				table.insert(lines, line)
			end
		elseif Blocks.isJigsaw(block) then
			for _, line in WailaInfo.jigsawDetails(block, context and context.jigsaw) do
				table.insert(lines, line)
			end
		end
	end
	table.insert(lines, modLine())
	return { icon = WailaInfo.blockIcon(block), lines = lines, progress = context and context.progress }
end

--[[ Entities ]]

-- A dropped item (entity `id`, at (x, y, z) in blocks, the bottom centre of its box).
function WailaInfo.item(
	item: number,
	count: number,
	extended: boolean,
	id: number?,
	x: number?,
	y: number?,
	z: number?
): Info
	local name: Line = { segment(Items.displayName(item), "white") }
	if count > 1 then
		table.insert(name, segment(` x{count}`, "gray"))
	end
	local lines: { Line } = { name }
	if extended then
		local def = Items.get(item)
		table.insert(lines, gray(`{if def then def.name else "?"} #{item}`))
		if id then
			table.insert(lines, gray(`Item entity {id}`))
		end
		if x and y and z then
			table.insert(lines, gray(string.format("Position %.2f, %.2f, %.2f", x, y, z)))
		end
	end
	table.insert(lines, modLine())
	return { icon = { item = item }, lines = lines, progress = nil }
end

export type PlayerFacts = {
	displayName: string,
	name: string,
	userId: number,
	-- Health and its maximum (the Humanoid's; shown in Minecraft's 20 points).
	health: number,
	maxHealth: number,
	gameMode: string,
	-- Feet position (blocks); the extended view shows the block it is in.
	x: number?,
	y: number?,
	z: number?,
}

-- A mob (client Entities/MobRenderer's view of it).
export type MobFacts = {
	kind: MobList.Kind,
	variant: number,
	id: number,
	-- Half hearts left (the server's, rounded up).
	health: number,
	-- Feet position (blocks); the extended view shows the block it is in.
	x: number?,
	y: number?,
	z: number?,
}

--[[
	A mob: its name, its health in half hearts of its kind's ("Health 6 / 10", red, as a player's)
	and, with F3, its kind's id, its entity id and the block its feet are in. The icon is a box in
	its colour (a sheep's fleece in its variant's).
]]
function WailaInfo.mob(facts: MobFacts, extended: boolean): Info
	local kind = facts.kind
	local lines: { Line } = {
		{ segment(kind.displayName, "white") },
		{ segment(`Health {math.max(math.ceil(facts.health), 0)} / {kind.health}`, "red") },
	}
	if extended then
		table.insert(lines, gray(`{kind.name} #{kind.id}, {if kind.hostile then "monster" else "creature"}`))
		table.insert(lines, gray(`Mob entity {facts.id}`))
		local x, y, z = facts.x, facts.y, facts.z
		if x and y and z then
			table.insert(lines, gray(`Position {math.floor(x)}, {math.floor(y)}, {math.floor(z)}`))
		end
	end
	table.insert(lines, modLine())
	return { icon = { colour = MobList.variantColor(kind, facts.variant) }, lines = lines, progress = nil }
end

-- Health in Minecraft's points (20 = 10 hearts), rounded up like the HUD's hearts.
function WailaInfo.healthPoints(health: number, maxHealth: number): number
	if maxHealth <= 0 then
		return 0
	end
	return math.clamp(math.ceil(health / maxHealth * 20 - 1e-6), 0, 20)
end

-- Another player.
function WailaInfo.player(facts: PlayerFacts, extended: boolean): Info
	local name: Line = { segment(facts.displayName, "white") }
	if facts.name ~= facts.displayName then
		table.insert(name, segment(` @{facts.name}`, "gray"))
	end
	local lines: { Line } = {
		name,
		{ segment(`Health {WailaInfo.healthPoints(facts.health, facts.maxHealth)} / 20`, "red") },
		gray(facts.gameMode),
	}
	if extended then
		table.insert(lines, gray(`User {facts.userId}`))
		local x, y, z = facts.x, facts.y, facts.z
		if x and y and z then
			-- (The block of the feet: the text only changes when they reach another block.)
			table.insert(lines, gray(`Position {math.floor(x)}, {math.floor(y)}, {math.floor(z)}`))
		end
	end
	table.insert(lines, modLine())
	return { icon = { userId = facts.userId }, lines = lines, progress = nil }
end

--[[ Aiming at entities ]]

--[[
	Where the ray from (ox, oy, oz) along (dx, dy, dz) (any length; distances are along it as a
	unit vector) enters the box (minX, minY, minZ)..(maxX, maxY, maxZ): the distance, 0 when it
	starts inside, nil when it misses or the box is behind.
]]
function WailaInfo.rayBox(
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number
): number?
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	if length < 1e-9 then
		return nil
	end
	local d = { dx / length, dy / length, dz / length }
	local o = { ox, oy, oz }
	local lo = { minX, minY, minZ }
	local hi = { maxX, maxY, maxZ }
	local near, far = -math.huge, math.huge
	for axis = 1, 3 do
		if math.abs(d[axis]) < 1e-12 then
			if o[axis] < lo[axis] or o[axis] > hi[axis] then
				return nil
			end
		else
			local t1, t2 = (lo[axis] - o[axis]) / d[axis], (hi[axis] - o[axis]) / d[axis]
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			near, far = math.max(near, t1), math.min(far, t2)
		end
	end
	if near > far or far < 0 then
		return nil
	end
	return math.max(near, 0)
end

export type Choice = "block" | "entity" | "fluid"

--[[
	What the panel names, from what lies on the aim (distances in blocks along it):
	  block   BlockInteraction's target (nil when no block is in reach), `mining` it or not;
	  entity  the nearest dropped item, mob or player in reach (nil: none);
	  wall    the first block on the aim at any distance, in reach or not (nil: none);
	  fluid   water in reach with nothing before it.
	An entity in front of the block wins, unless the block is being mined (its progress stays on
	screen) or a block hides the entity (also one out of reach: BlockInteraction can't target it,
	but it is still in the way). Water only shows when no block is in reach.
]]
function WailaInfo.choose(block: number?, mining: boolean, entity: number?, wall: number?, fluid: boolean): Choice?
	if entity and (wall == nil or entity < wall) and not (block and (mining or block <= entity)) then
		return "entity"
	elseif block then
		return "block"
	elseif fluid then
		return "fluid"
	end
	return nil
end

--[[ Placing the panel ]]

-- The screen the panel is placed on (screen pixels; `height` is below Roblox's top bar).
export type Screen = {
	width: number,
	height: number,
	-- The HUD's GUI scale (Ui/UiScale) and whether it is a touch screen (fractional scales).
	scale: number,
	touch: boolean,
	-- Pixels from the screen's top to the panel, and kept free inside every edge.
	top: number,
	margin: number,
	-- Pixels at the right the panel keeps out of (the minimap; 0 for none).
	rightReserve: number,
	-- With F3 open: the right edge of the debug text, which the panel keeps right of if it can.
	avoidLeft: number?,
}

--[[
	The scale to draw a `width` x `height` (GUI pixels) panel at and its shift right of the top
	centre (whole screen pixels). The panel gets the HUD's scale, drawn smaller (down to half
	size: whole scales on desktops, eighths on touch screens, like Ui/GuiScale.fit) when it does not
	fit between the margins, the minimap and the bottom. It stays centred unless that covers the
	minimap or the F3 text: the screen edges come first, then the minimap, then the F3 text.
	Where the room left of the minimap is too narrow to read the panel (it would be drawn below
	the HUD's scale and below 1, as on a phone held upright), it goes over the minimap's corner
	instead, as far left as it can.
]]
function WailaInfo.placement(screen: Screen, width: number, height: number): (number, number)
	local scale = screen.scale
	if width <= 0 or height <= 0 then
		return scale, 0
	end
	local leftLimit = screen.margin
	local beside = screen.width - math.max(screen.rightReserve, screen.margin)
	local right = beside
	if (beside - leftLimit) / width < math.min(scale, 1) then
		right = screen.width - screen.margin
	end
	local fit = math.min((right - leftLimit) / width, (screen.height - screen.top - screen.margin) / height)
	if scale > fit then
		scale = if fit >= 1 and not screen.touch then math.floor(fit) else math.floor(fit * 8) / 8
		scale = math.max(scale, 0.5)
	end
	local w = width * scale
	local centred = (screen.width - w) / 2
	local left = centred
	local avoid = screen.avoidLeft
	if avoid and left < avoid then
		left = avoid
	end
	if left + w > beside then
		left = beside - w
	end
	if left < leftLimit then
		left = leftLimit
	end
	return scale, math.floor(left - centred + 0.5)
end

--[[
	Minecraft's italics, drawn as `strips` horizontal strips 2 pixels tall: how far (whole GUI
	pixels) each strip is shifted. Minecraft shears a glyph 1 pixel right at its top and 1 pixel
	left at its bottom (BakedGlyph: 1 - 0.25 * y); a strip takes its middle row's share, rounded,
	because GUI offsets are whole pixels (UDim offsets are integers).
]]
function WailaInfo.italicShifts(strips: number): { number }
	local shifts = {}
	for k = 0, strips - 1 do
		local shift = math.round(1 - 0.25 * (2 * k + 1))
		-- (math.round(-0.25) is -0.)
		table.insert(shifts, if shift == 0 then 0 else shift)
	end
	return shifts
end

return WailaInfo
