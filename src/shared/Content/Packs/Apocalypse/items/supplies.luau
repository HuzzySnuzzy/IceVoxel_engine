--!strict
--[[
	The zombie apocalypse's things (the pack's loot fills the ruins' and bunkers' crates and cabinets
	with them; its recipes make some). Box models in their colours until their icons are made (each
	entry's `icon` is blank, so each look is one id to paste). Nails, the Spiked Bat, the Machete and
	the Crowbar, the things of iron, are the Iron Age's (`age`), the rest the Stone Age's.

	Medical supplies (eaten through Shared/Items/Foods, server Apocalypse/Survival): a Bandage (a
	white roll), a Medkit (a red case with a white cross), Antibiotics (a pill bottle with an orange
	cap), Painkillers (a blister strip), and the Herbal Poultice, mint and ginger bound in a rag on a
	cloth pad: the renewable answer to a bite. Scavenged materials: a Rag (grey cloth from old wool),
	Duct Tape (a grey ring), Nails (three of them) and Scrap Metal (jagged rusty plates; a furnace
	makes Iron Nuggets of it). Food and drink from the ruins: Canned Beans and Canned Peaches (tin
	cans with their labels), Crackers (a tan box), a Chocolate Bar (in a purple wrapper), a Military
	Ration (an olive pouch), Bottled Water (a clear bottle with a blue cap) and Soda (a red can).
	Weapons: a Baseball Bat and its Spiked Bat (no tool, but they wear: a hit costs 1,
	Shared/Entities/Combat.wear), a Machete (a sword), a Crowbar (a pickaxe) and a Fire Axe (an
	axe), modelled upright and tilted like Minecraft's tools.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)
local models = require(script.Parent.Parent._models)

type ModelBox = Schema.ModelBox

local WHITE = { 245, 245, 240 }
local BANDAGE = { 236, 232, 220 }
local MEDKIT = { 196, 40, 40 }
local PILLS = { 232, 232, 226 }
local PILL_CAP = { 222, 120, 40 }
local BLISTER = { 210, 214, 220 }
local RAG = { 150, 146, 136 }
local TAPE = { 150, 154, 158 }
local NAIL = { 170, 172, 176 }
local SCRAP = { 128, 90, 64 }
local CRACKERS = { 206, 170, 110 }
local CHOCOLATE = { 92, 56, 36 }
local WRAPPER = { 120, 40, 120 }
local RATION = { 96, 104, 64 }
local BOTTLED = { 170, 210, 235 }
local SODA = { 200, 30, 40 }
local BLADE = { 190, 194, 198 }
local GRIP = { 30, 30, 32 }
local CROWBAR = { 170, 36, 30 }
local AXE_HEAD = { 200, 40, 30 }
local AXE_HANDLE = { 220, 190, 60 }
local POULTICE = { 96, 140, 70 }
local PAD = { 220, 214, 196 }

return function(define: Define.Context): { Schema.ItemSpec }
	local shade = define.shade
	local CAN, BAT, can, bat = models.CAN, models.BAT, models.can, models.bat
	local blister: { ModelBox } = { { size = { 12, 8, 1 }, offset = { 0, 0, 0 } } }
	for _, x in { -3.5, 0, 3.5 } do
		for _, y in { -2, 2 } do
			table.insert(blister, { size = { 2.5, 2.5, 1 }, offset = { x, y, 0.8 }, color = WHITE, shape = "Ball" })
		end
	end
	local nails: { ModelBox } = {}
	for index, x in { -3, 0, 3 } do
		local turn = (index - 2) * 8
		table.insert(nails, { size = { 1, 9, 1 }, offset = { x, -1, 0 }, rotation = turn })
		table.insert(nails, { size = { 2.5, 1, 1.5 }, offset = { x - turn / 30, 3.5, 0 }, rotation = turn })
	end
	local spiked = bat()
	for _, y in { 2.5, 5.5, 8.5 } do
		table.insert(spiked, { size = { 4.6, 0.6, 0.6 }, offset = { 0, y, 0 }, color = NAIL, material = "Metal" })
		table.insert(spiked, { size = { 0.6, 0.6, 4.6 }, offset = { 0, y + 1.2, 0 }, color = NAIL, material = "Metal" })
	end

	return {
		{
			name = "Bandage",
			maxStack = 16,
			color = BANDAGE,
			material = "Fabric",
			model = {
				{ size = { 10, 10, 6 }, offset = { 0, 1, 0 }, shape = "Cylinder" },
				{ size = { 4, 4, 6.2 }, offset = { 0, 1, 0 }, shape = "Cylinder", color = shade(BANDAGE, 0.8) },
				{ size = { 6, 3, 1 }, offset = { 3, -4.5, 2.4 }, rotation = -15 },
			},
			icon = "",
			lore = "Stops bleeding and closes small wounds.",
		},
		{
			name = "Medkit",
			maxStack = 4,
			color = MEDKIT,
			material = "SmoothPlastic",
			model = {
				{ size = { 12, 9, 5 }, offset = { 0, -1.5, 0 } },
				{ size = { 5, 1.5, 2 }, offset = { 0, 3.75, 0 }, color = shade(MEDKIT, 0.6) },
				{ size = { 12.1, 0.6, 5.1 }, offset = { 0, 1.5, 0 }, color = shade(MEDKIT, 0.75) },
				{ size = { 5, 1.6, 0.4 }, offset = { 0, -2, 2.6 }, color = WHITE },
				{ size = { 1.6, 5, 0.4 }, offset = { 0, -2, 2.6 }, color = WHITE },
			},
			icon = "",
			lore = "Stops bleeding, heals a lot and keeps healing for a while.",
		},
		{
			name = "Antibiotics",
			maxStack = 8,
			color = PILLS,
			material = "SmoothPlastic",
			model = {
				{ size = { 7, 9, 6 }, offset = { 0, -2, 0 } },
				{ size = { 7.4, 3, 6.4 }, offset = { 0, 4, 0 }, color = PILL_CAP },
				{ size = { 5, 4, 0.4 }, offset = { 0, -2, 3.1 }, color = shade(PILL_CAP, 0.9) },
			},
			icon = "",
			lore = "Cures a bite's infection, if you take it in time.",
		},
		{
			name = "Painkillers",
			maxStack = 16,
			color = BLISTER,
			material = "Foil",
			model = blister,
			icon = "",
			lore = "Takes the edge off: a little health now, more over time.",
		},
		{
			name = "Rag",
			color = RAG,
			material = "Fabric",
			model = {
				{ size = { 11, 7, 1.5 }, offset = { 0, -1, 0 }, rotation = 10 },
				{ size = { 7, 5, 1.5 }, offset = { -1, 3, 0.3 }, rotation = -15, color = shade(RAG, 0.88) },
				{ size = { 3, 4, 1.2 }, offset = { 5, -4.5, 0 }, rotation = 25, color = shade(RAG, 1.1) },
			},
			icon = "",
			lore = "A strip of cloth from old wool. Two make Bandages.",
		},
		{
			name = "DuctTape",
			maxStack = 16,
			color = TAPE,
			material = "Metal",
			model = {
				{ size = { 10, 10, 4 }, offset = { 0, 0, 0 }, shape = "Cylinder" },
				{
					size = { 5, 5, 4.2 },
					offset = { 0, 0, 0 },
					shape = "Cylinder",
					color = { 120, 96, 70 },
					material = "Wood",
				},
				{ size = { 3.5, 3, 1 }, offset = { 4, -5, 1.5 }, rotation = -30 },
			},
			icon = "",
			lore = "Holds anything together, for now. Medkits need it.",
		},
		{
			name = "Nails",
			color = NAIL,
			material = "Metal",
			model = nails,
			icon = "",
			lore = "For barricades, spiked bats and other bad days.",
			age = "iron",
		},
		{
			name = "ScrapMetal",
			displayName = "Scrap Metal",
			color = SCRAP,
			material = "CorrodedMetal",
			model = {
				{ size = { 9, 6, 1 }, offset = { -1, 1, 0 }, rotation = 20 },
				{ size = { 7, 4, 1 }, offset = { 2, -2.5, 0.6 }, rotation = -25, color = shade(SCRAP, 0.8) },
				{ size = { 4, 4, 1 }, offset = { -3.5, -3, -0.4 }, rotation = 45, color = shade(SCRAP, 1.15) },
			},
			icon = "",
			lore = "Twisted steel from wrecks. A furnace turns it into Iron Nuggets.",
		},
		{
			name = "CannedBeans",
			maxStack = 16,
			color = CAN,
			material = "Metal",
			model = can({ 170, 60, 40 }),
			icon = "",
			lore = "Beans in a dented can. Still good, mostly.",
		},
		{
			name = "CannedPeaches",
			maxStack = 16,
			color = CAN,
			material = "Metal",
			model = can({ 230, 150, 60 }),
			icon = "",
			lore = "Sweet peaches in syrup. A rare treat in the ruins.",
		},
		{
			name = "Crackers",
			color = CRACKERS,
			material = "SmoothPlastic",
			model = {
				{ size = { 11, 8, 3 }, offset = { 0, 0, 0 } },
				{ size = { 4.5, 4.5, 0.4 }, offset = { -2, 0, 1.6 }, color = shade(CRACKERS, 1.15) },
				{ size = { 0.8, 0.8, 0.4 }, offset = { -2.8, 0.8, 1.8 }, color = shade(CRACKERS, 0.7) },
				{ size = { 0.8, 0.8, 0.4 }, offset = { -1.2, -0.8, 1.8 }, color = shade(CRACKERS, 0.7) },
				{ size = { 3, 1.2, 0.4 }, offset = { 3, 2, 1.6 }, color = { 200, 50, 40 } },
			},
			icon = "",
			lore = "Dry and filling. You will want water after.",
		},
		{
			name = "ChocolateBar",
			color = CHOCOLATE,
			material = "SmoothPlastic",
			model = {
				{ size = { 12, 6, 2 }, offset = { 0, 0, 0 } },
				{ size = { 0.4, 6, 2.2 }, offset = { 4, 0, 0 }, color = shade(CHOCOLATE, 0.7) },
				{ size = { 7, 6.4, 2.4 }, offset = { -2.5, 0, 0 }, color = WRAPPER },
				{ size = { 4, 1.2, 0.4 }, offset = { -2.5, 0.5, 1.3 }, color = { 236, 200, 60 } },
			},
			icon = "",
			lore = "Quick energy for a quick escape.",
		},
		{
			name = "MilitaryRation",
			maxStack = 16,
			color = RATION,
			material = "Fabric",
			model = {
				{ size = { 10, 12, 2.5 }, offset = { 0, -1, 0 } },
				{ size = { 10, 1.5, 2.7 }, offset = { 0, 5.25, 0 }, color = shade(RATION, 0.75) },
				{ size = { 6, 3, 0.4 }, offset = { 0, -1, 1.4 }, color = shade(RATION, 1.4) },
			},
			icon = "",
			lore = "A sealed meal for one long day. Bunkers keep them.",
		},
		{
			name = "BottledWater",
			maxStack = 16,
			color = BOTTLED,
			material = "Glass",
			model = {
				{ size = { 6, 11, 5 }, offset = { 0, -2, 0 } },
				{ size = { 3, 2, 3 }, offset = { 0, 4.5, 0 } },
				{
					size = { 3.4, 1.5, 3.4 },
					offset = { 0, 6.25, 0 },
					color = { 40, 90, 200 },
					material = "SmoothPlastic",
				},
				{
					size = { 6.2, 3, 5.2 },
					offset = { 0, -2, 0 },
					color = { 60, 140, 220 },
					material = "SmoothPlastic",
				},
			},
			icon = "",
			lore = "Clean water in a sealed bottle. The bottle is kept.",
		},
		{
			name = "SodaCan",
			displayName = "Soda",
			maxStack = 16,
			color = SODA,
			material = "Metal",
			model = {
				{ size = { 7, 11, 6 }, offset = { 0, -1, 0 } },
				{ size = { 6, 0.8, 5 }, offset = { 0, 4.9, 0 }, color = CAN },
				{ size = { 7.2, 1.5, 6.2 }, offset = { 0, -1, 0 }, color = WHITE },
			},
			icon = "",
			lore = "Warm, flat and sugary. Puts a spring in your step.",
		},
		{
			name = "BaseballBat",
			attack = { damage = 5, speed = 1.0 },
			durability = 120,
			color = BAT,
			material = "Wood",
			model = bat(),
			tilt = -45,
			icon = "",
			lore = "A wooden bat. Swing for the head.",
		},
		{
			name = "SpikedBat",
			attack = { damage = 7, speed = 0.9 },
			durability = 160,
			color = BAT,
			material = "Wood",
			model = spiked,
			tilt = -45,
			icon = "",
			lore = "A bat with nails through it. Swing harder.",
			age = "iron",
		},
		{
			name = "Machete",
			tool = { kind = "sword", speed = 6, level = 2 },
			attack = { damage = 6, speed = 1.6 },
			durability = 350,
			color = BLADE,
			material = "Metal",
			model = {
				{ size = { 3.5, 13, 0.8 }, offset = { 0, 2.5, 0 } },
				{ size = { 1, 13, 0.9 }, offset = { -1.25, 2.5, 0 }, color = shade(BLADE, 1.15) },
				{ size = { 2.5, 2.5, 0.8 }, offset = { 0.4, 9, 0 }, rotation = 45 },
				{ size = { 2, 5, 1.6 }, offset = { 0, -6.5, 0 }, color = GRIP, material = "SmoothPlastic" },
				{ size = { 2.6, 1, 1.8 }, offset = { 0, -3.5, 0 }, color = GRIP, material = "SmoothPlastic" },
			},
			tilt = -45,
			icon = "",
			lore = "A long blade for brush, cobwebs and the dead alike.",
			age = "iron",
		},
		{
			name = "Crowbar",
			tool = { kind = "pickaxe", speed = 4, level = 1 },
			attack = { damage = 5, speed = 1.2 },
			durability = 500,
			color = CROWBAR,
			material = "Metal",
			model = {
				{ size = { 1.5, 16, 1.5 }, offset = { 0.5, -1, 0 } },
				{ size = { 4, 1.5, 1.5 }, offset = { -1, 7.25, 0 }, rotation = 20 },
				{ size = { 1.5, 2.5, 1.5 }, offset = { -2.75, 5.75, 0 }, rotation = -20 },
				{ size = { 2.5, 1.2, 1.5 }, offset = { 1.5, -9, 0 }, rotation = -30, color = shade(CROWBAR, 0.8) },
			},
			tilt = -45,
			icon = "",
			lore = "Pries, smashes and digs: a survivor's favourite.",
			age = "iron",
		},
		{
			name = "FireAxe",
			tool = { kind = "axe", speed = 6, level = 2 },
			attack = { damage = 9, speed = 0.9 },
			durability = 400,
			color = AXE_HEAD,
			material = "Metal",
			model = {
				{ size = { 1.5, 17, 1.25 }, offset = { 0, -1.5, 0 }, color = AXE_HANDLE, material = "Wood" },
				{ size = { 3, 3.5, 1.5 }, offset = { -0.75, 6.5, 0 }, color = shade(AXE_HEAD, 0.85) },
				{ size = { 2.25, 4.75, 1.5 }, offset = { -3.375, 5.875, 0 } },
				{ size = { 1.25, 6.5, 1.5 }, offset = { -5.125, 5, 0 }, color = BLADE },
				{ size = { 3, 1.5, 1.5 }, offset = { 2.5, 7, 0 }, rotation = -20, color = shade(AXE_HEAD, 0.85) },
			},
			tilt = -45,
			icon = "",
			lore = "A firefighter's axe. Chops wood and anything else.",
		},
		{
			name = "HerbalPoultice",
			maxStack = 16,
			color = POULTICE,
			material = "Fabric",
			model = {
				{ size = { 11, 9, 2 }, offset = { 0, 0, 0 }, color = PAD },
				{ size = { 11.4, 4, 2.4 }, offset = { 0, 0, 0 } },
				{ size = { 3, 2, 0.4 }, offset = { -2, 3, 1.1 }, rotation = 30, color = shade(POULTICE, 1.3) },
				{ size = { 2.5, 1.5, 0.4 }, offset = { 2.5, -3, 1.1 }, rotation = -20, color = { 206, 168, 112 } },
			},
			icon = "",
			lore = "Mint and ginger in a rag: slows a bite's infection. Only pills cure it.",
		},
	}
end
