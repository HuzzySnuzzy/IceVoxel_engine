--!strict
--[[
	Doors (Minecraft's DoorBlock; BlockList's doors, Blocks' door helpers): what opening one
	changes, its double door partner, and the side its panel is on. Pure: the server's DoorUse
	applies `use` and the client predicts it with the same answer.

	A door is two blocks, a lower and an upper half, one block id per facing (the way the player
	looked placing it), hinge side ("Left" / "Right" as that player sees it), open or closed and
	half. Its panel is 3 pixels thick: closed, across the cell's side nearest the player who
	placed it; open, swung on its hinge away from them, along the hinge's side (DoorBlock.getShape).

	Double doors: two doors side by side facing the same way with mirrored hinges, the left
	hinged one's right neighbour (Minecraft gives a door placed beside another the other hinge,
	DoorBlock.getHinge). Using either opens or closes both, when both are open or both closed (as
	Quark's double door opening; Minecraft itself moves only the one used). Doors of different
	woods pair too.
]]

local Blocks = require(script.Parent)

local Doors = {}

-- One block changed by a use: its cell and new block.
export type Change = { x: number, y: number, z: number, block: number }

local CLOCKWISE: { [string]: string } = { North = "East", East = "South", South = "West", West = "North" }
local COUNTER: { [string]: string } = { North = "West", West = "South", South = "East", East = "North" }

-- The direction a quarter turn clockwise (seen from above) of `facing`, and counter-clockwise.
function Doors.clockwise(facing: string): string
	return CLOCKWISE[facing]
end
function Doors.counterClockwise(facing: string): string
	return COUNTER[facing]
end

--[[
	The direction named by Minecraft's shape of a door facing `facing` with `hinge`, `open` or
	not (DoorBlock.getShape: closed, its facing's; open, a quarter turn counter-clockwise of it on
	a right hinge, clockwise on a left one). A door's panel lies against the cell's side opposite
	that direction: a closed door facing North has its panel on the south side.
]]
function Doors.shapeFacing(facing: string, hinge: string, open: boolean): string
	if not open then
		return facing
	end
	return if hinge == "Right" then COUNTER[facing] else CLOCKWISE[facing]
end

-- The cell side (a direction) a door's panel lies against.
function Doors.panelSide(facing: string, hinge: string, open: boolean): string
	return Blocks.opposite(Doors.shapeFacing(facing, hinge, open))
end

--[[
	Where the double door partner of the door half `block` at (x, y, z) would stand: beside it on
	the side away from its hinge (a left hinge's partner is a quarter turn clockwise of its
	facing). nil for anything not a door.
]]
function Doors.partnerAt(block: number, x: number, y: number, z: number): (number?, number?, number?)
	local facing, hinge = Blocks.doorState(block)
	if facing == nil or hinge == nil then
		return nil, nil, nil
	end
	local side = if hinge == "Left" then CLOCKWISE[facing] else COUNTER[facing]
	local d = Blocks.DIRECTIONS[side]
	return x + d[1], y, z + d[3]
end

-- Is `other` the double door partner of `block` (its partner's cell holding it): the same facing
-- and half, the other hinge, and opened or closed alike?
function Doors.pairs(block: number, other: number): boolean
	local facing, hinge, open, upper = Blocks.doorState(block)
	local f, h, o, u = Blocks.doorState(other)
	return facing ~= nil and facing == f and hinge ~= h and open == o and upper == u
end

--[[
	The lower half of the door whose half `block` is at (x, y, z), when the door is whole (its
	other half in place): its y and block. nil otherwise.
]]
local function lowerHalf(
	block: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): (number?, number?)
	local _, _, _, upper = Blocks.doorState(block)
	if upper == nil then
		return nil, nil
	end
	local lowerY = if upper then y - 1 else y
	local lower = if upper then Blocks.plantBottom(block) else block
	local top = if lower then Blocks.plantTop(lower) else nil
	if lower == nil or top == nil or getBlock(x, lowerY, z) ~= lower or getBlock(x, lowerY + 1, z) ~= top then
		return nil, nil
	end
	return lowerY, lower
end

-- Both halves of the whole door with its lower half `lower` at (x, y, z), opened or closed.
local function toggled(changes: { Change }, lower: number, x: number, y: number, z: number)
	local flipped = Blocks.doorToggled(lower) :: number
	table.insert(changes, { x = x, y = y, z = z, block = flipped })
	table.insert(changes, { x = x, y = y + 1, z = z, block = Blocks.plantTop(flipped) :: number })
end

--[[
	What using (right clicking) the door half `block` at (x, y, z) changes: both its halves opened
	or closed, and its double door partner's (`partnerAt`, whole, `pairs`) with them. Empty when
	the block is no door or the door is not whole. `getBlock` answers nil for unknown (unloaded)
	blocks, which pair with nothing. The first change is the lower half used.
]]
function Doors.use(
	block: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): { Change }
	local changes: { Change } = {}
	local lowerY, lower = lowerHalf(block, getBlock, x, y, z)
	if lowerY == nil or lower == nil then
		return changes
	end
	toggled(changes, lower, x, lowerY, z)
	local px, py, pz = Doors.partnerAt(lower, x, lowerY, z)
	if px and py and pz then
		local other = getBlock(px, py, pz)
		if other ~= nil and Doors.pairs(lower, other) then
			local partnerY, partner = lowerHalf(other, getBlock, px, py, pz)
			if partnerY == py and partner ~= nil then
				toggled(changes, partner, px, py, pz)
			end
		end
	end
	return changes
end

-- Does the change list open the door (rather than close it)? Its first change is the lower half.
function Doors.opens(changes: { Change }): boolean
	local first = changes[1]
	if first == nil then
		return false
	end
	local _, _, open = Blocks.doorState(first.block)
	return open == true
end

return Doors
