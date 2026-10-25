--!strict
--[[
	Doors (Minecraft's DoorBlock: oak, spruce, birch, jungle and acacia, one per planks), each all
	32 halves (Content/Define's `door` says how they are made: one block per facing, hinge side,
	open or closed and half; the lower half facing North, hinged left, closed, is the item).
	Placing picks the facing and hinge (Blocks.doorPlacement, DoorBlock.getStateForPlacement) and
	sets both halves; breaking either removes both with one drop (server Network/EditRules, as
	tall plants'); a half left alone, or a lower half without a sturdy block under it, pops (server
	Behaviours/Door). Right clicking either half opens or closes the door, and its double door
	partner with it (`menu` "Door": Shared/Blocks/Doors, server World/DoorUse), in every game mode
	but spectator. Strength 3, an axe mines it fast, wood sounds; Minecraft's wooden doors never
	catch fire from fire nearby (they are not in FireBlock.bootStrap). Three doors from six planks
	of a wood (Crafting/Recipes), 200 ticks of fuel each.

	Each wood's upper half is a frame around its windows (oak two, birch four, jungle two small
	ones, acacia one, spruce none: Minecraft's door pictures' windows, see-through here too), made
	of `doorPiece` boxes; the texture pack's door pictures go on the door's plate, both sides
	(each wood's `texture` and `topTexture` Front, the lower and upper halves': blank, so the boxes
	show).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.BlockSpec }
	local piece, darker = define.doorPiece, define.darker
	-- Each wood: its planks' colour, the door's own fields (its halves' pictures, its lore, its
	-- burn ticks: the item's) and the frame around its upper half's windows (left and right
	-- stiles, rails and mullions; the windows are what they leave open).
	local woods: { Define.DoorWood } = {
		{
			wood = "Oak",
			color = { 170, 134, 84 },
			texture = { Front = "oak door bottom" },
			topTexture = { Front = "oak door top" },
			lore = "Right click to open. Two side by side open together.",
			fuel = 200,
			upper = function(_c)
				return {
					piece(-8, -5, -8, 8),
					piece(5, 8, -8, 8),
					piece(-1, 1, -1, 5),
					piece(-5, 5, 5, 8),
					piece(-5, 5, -8, -1),
				}
			end,
		},
		{
			wood = "Spruce",
			color = { 114, 84, 48 },
			texture = { Front = "spruce door bottom" },
			topTexture = { Front = "spruce door top" },
			lore = "A solid spruce door. Two side by side open together.",
			fuel = 200,
			upper = function(c)
				return { piece(-8, 8, -8, 8), piece(-5, 5, -5, 5, 4, darker(c, 0.85)) }
			end,
		},
		{
			wood = "Birch",
			color = { 196, 178, 123 },
			texture = { Front = "birch door bottom" },
			topTexture = { Front = "birch door top" },
			lore = "A birch door with four little windows. Opens with a right click.",
			fuel = 200,
			upper = function(_c)
				return {
					piece(-8, -5, -8, 8),
					piece(5, 8, -8, 8),
					piece(-5, 5, 5, 8),
					piece(-5, 5, -8, -3),
					piece(-5, 5, 0.5, 2),
					piece(-1, 1, -3, 5),
				}
			end,
		},
		{
			wood = "Jungle",
			color = { 160, 115, 80 },
			texture = { Front = "jungle door bottom" },
			topTexture = { Front = "jungle door top" },
			lore = "A jungle wood door with small windows. Opens with a right click.",
			fuel = 200,
			upper = function(_c)
				return {
					piece(-8, -5, -8, 8),
					piece(5, 8, -8, 8),
					piece(-1, 1, 2, 5),
					piece(-5, 5, 5, 8),
					piece(-5, 5, -8, 2),
				}
			end,
		},
		{
			wood = "Acacia",
			color = { 168, 90, 50 },
			texture = { Front = "acacia door bottom" },
			topTexture = { Front = "acacia door top" },
			lore = "An acacia door with one window. Opens with a right click.",
			fuel = 200,
			upper = function(_c)
				return {
					piece(-8, -4, -8, 8),
					piece(4, 8, -8, 8),
					piece(-4, 4, 5, 8),
					piece(-4, 4, -8, 0),
				}
			end,
		},
	}
	local list: { Schema.BlockSpec } = {}
	for _, wood in woods do
		define.append(list, define.door(wood))
	end
	return list
end
