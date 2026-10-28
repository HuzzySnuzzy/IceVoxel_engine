--!strict
--[[
	The seasons' blocks (Shared/Seasons; Config.Seasons): snow layers, the stoves, heaters and
	coolers, and insulation.

	  * Snow layers (Minecraft's SnowLayerBlock; Content/Define's `layers`): SnowLayer1 ..
	    SnowLayer8, 2 pixels a layer. SnowLayer1 is the item ("Snow Layer"); 2..8 drop and are
	    placed as it, and the Snow Layer used on a layer below 8 adds one (Shared/Seasons/SnowLayers
	    .stackOnto). Each drops n Snowballs by hand; a shovel digs it fast. Walking in deep snow is
	    slower (`speedFactor`: 1 for 1-2 layers, 0.9 for 3-4, 0.8 for 5-6, 0.75 for 7-8); a full
	    layer of 8 is a wall face (`insulation` 0.02), fewer let a room's air through. The server's
	    SnowLayer behaviour drops a layer whose support goes, and Seasons/SnowWorld piles and melts
	    them. Not a Tough As Nails cold source: the season brings the cold. They take the
	    Minecraft pack's "snow" texture, which layer 1's entry gives every layer (`layers` keeps
	    what is said of the item, its texture and lore, on layer 1).
	  * Heaters, coolers and stoves (Shared/Machines kinds "stove", "oilheater", "heater" and
	    "cooler"; their room heat: server Seasons/RoomWorld through Players/Climate's room sources):
	    Mekanism style machine blocks (Content/Define's `machine`), drawn with their BlockDecor
	    faces and window panes (never textured), which zombies never break.
	      Wood Stove        fuel only (no energy: `capacity = 0`): furnace fuel burns 4 times its
	                        furnace time for 30 HU; radiant.
	      Oil Heater        fuel only: a tank of Oil or Fuel, a thermostat, up to 35 HU; radiant.
	      Electric Heater   4 J a tick per HU, up to 40 HU, a thermostat (16 kJ, 400 J/t in).
	      Air Conditioner   5 J a tick per HU, down to -40 HU, a thermostat (20 kJ, 500 J/t in).
	      Electric Fan      30 J a tick while it runs: -10 HU in a room (2 kJ, 100 J/t in).
	  * Insulation (Shared/Seasons/Rooms): Insulated Planks (planks and wool, U 0.006: a room of
	    them keeps its heat four times longer than planks; they burn like planks), Insulated Glass
	    (double panes in an iron frame, U 0.04: a window that loses a third of glass's) and the
	    Insulated Door (Content/Define's `door`: 32 halves of a padded oak door, U 0.03 closed; its
	    item's lore, Age and picture are `item`'s, its upper halves' picture `top`'s).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type BlockSpec = Schema.BlockSpec
type ShapeBox = Schema.ShapeBox

local SNOW_SPEED = { 1, 1, 0.9, 0.9, 0.8, 0.8, 0.75, 0.75 }

return function(define: Define.Context): { BlockSpec }
	local list = define.layers({
		name = "SnowLayer",
		displayName = "Snow Layer",
		color = { 238, 242, 248 },
		material = "Snow",
		sound = "snow",
		hardness = 0.1,
		tool = "shovel",
		blastResistance = 0.1,
		drops = "Snowball" :: string,
		insulation = 0.02,
		behaviour = "SnowLayer",
		texture = { All = "snow" },
		lore = "A thin cover of snow. Use it on snow to pile it higher; deep snow slows you.",
	}, SNOW_SPEED)

	define.append(list, {
		define.machine({
			name = "WoodStove",
			color = { 56, 54, 54 },
			machine = { kind = "stove" },
			energy = { capacity = 0 },
			workSound = "block.wood_stove.crackle",
			lore = "Burns furnace fuel four times as long to heat the room it stands in.",
			age = "iron",
		}),
		define.machine({
			name = "OilHeater",
			color = { 120, 64, 44 },
			machine = { kind = "oilheater" },
			energy = { capacity = 0 },
			workSound = "block.oil_heater.burn",
			lore = "Burns oil or fuel to hold a room at its set point.",
			age = "industrial",
		}),
		define.machine({
			name = "ElectricHeater",
			color = { 150, 154, 162 },
			machine = { kind = "heater" },
			energy = { capacity = 16000, input = 400 },
			workSound = "block.electric_heater.hum",
			lore = "Holds a room at its set point on power. Outdoors it warms whoever stands close.",
			age = "electric",
		}),
		define.machine({
			name = "AirConditioner",
			color = { 196, 204, 210 },
			machine = { kind = "cooler" },
			energy = { capacity = 20000, input = 500 },
			workSound = "block.air_conditioner.hum",
			lore = "Cools a room to its set point on power. Useless outdoors.",
			age = "electric",
		}),
		define.machine({
			name = "ElectricFan",
			color = { 132, 138, 146 },
			machine = { kind = "cooler" },
			energy = { capacity = 2000, input = 100 },
			workSound = "block.fan.loop",
			lore = "Takes the edge off a hot room. Cheap to run.",
			age = "electric",
		}),
	})

	define.append(list, {
		{
			name = "InsulatedPlanks",
			displayName = "Insulated Planks",
			color = { 214, 196, 160 },
			material = "WoodPlanks",
			sound = "wood",
			hardness = 2,
			tool = "axe",
			insulation = 0.006,
			flammable = { ignite = 5, burn = 20 },
			texture = { All = "insulated planks" },
			lore = "Wool-lined boards. A room of them keeps its warmth far longer.",
		},
		{
			name = "InsulatedGlass",
			displayName = "Insulated Glass",
			render = "Transparent",
			color = { 196, 222, 232 },
			material = "Glass",
			transparency = 0.5,
			hardness = 0.6,
			tool = "pickaxe",
			insulation = 0.04,
			texture = { All = "insulated glass" },
			lore = "Double panes in iron: a window that keeps the cold out.",
			age = "iron",
		},
	})
	define.append(
		list,
		define.door({
			wood = "Insulated",
			color = { 206, 196, 172 },
			insulation = 0.03,
			upper = function(c: { number }): { ShapeBox }
				-- (No windows: a padded panel in a frame.)
				return {
					define.doorPiece(-8, 8, -8, 8),
					define.doorPiece(
						-5,
						5,
						-5,
						5,
						4,
						{ math.floor(c[1] * 0.9), math.floor(c[2] * 0.9), math.floor(c[3] * 0.9) }
					),
				}
			end,
			lore = "A padded door. Closed, it keeps a room's warmth in.",
			age = "iron",
			texture = { Front = "insulated door bottom" },
			topTexture = { Front = "insulated door top" },
		})
	)
	return list
end
