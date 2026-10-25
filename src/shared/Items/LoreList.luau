--!strict
--[[
	Every item's lore: one short line under its name in the tooltip (Items/Tooltip, Minecraft's
	dark purple lore), saying what the item is for in this game first and its flavour second, as
	Terraria's tooltips do ("Allows the holder to double jump"). Data only, keyed by item name
	(Items.id: blocks' items by their block name, the other items by theirs), from the content
	packs (Shared/Content): each entry's `lore`, the packs' `lore` (lines for items a registry
	makes), and the side table below, for the items whose entries carry none yet. A name with a
	line both on its entry (or in a pack's `lore`) and in the side table is an error.

	  * Every item has one (tests/spec/Tooltips checks there are no gaps), and every key is an
	    item's (Items/Tooltip asserts it as it loads, so a renamed item can't keep stale lore).
	  * Keep a line short: the tooltip wraps it to a few rows. Numbers belong to the stat lines
	    (Items/Tooltip works them out from the item's data), so a line here says what no number
	    says: where the item comes from, what it is made into, what using it does.
	  * A new item gets its line on its entry (`lore = "..."`).
]]

local Content = require(script.Parent.Parent.Content)

-- The side table, by name (the old lists' order; the twelve turrets' from a loop below).
local lore: { [string]: string } = {
	-- Blocks (BlockList order) --------------------------------------------------------------------
	Stone = "Common rock. Breaks into Cobblestone.",
	Cobblestone = "Rough stone for tools, furnaces and walls. Smelts back into Stone.",
	Dirt = "Soil that plants grow on.",
	Grass = "Dirt with a grassy top. Breaks into Dirt.",
	DryGrass = "Sun-baked savanna turf. Breaks into Dirt.",
	Snow = "Packed snow. Dig it with a shovel for Snowballs. Chills you when close.",
	Sand = "Loose sand that falls. Smelts into Glass; four make Sandstone.",
	Sandstone = "Sand pressed into stone. Cut or smelt it for a finer face.",
	Gravel = "Loose stones that fall. Sometimes gives Flint.",
	Ice = "Slippery frozen water. Chills you when close.",
	OakLog = "Wood from an oak. Makes planks and charcoal.",
	OakLeaves = "Drops saplings and sticks now and then. Shears keep the leaves.",
	BirchLog = "Pale wood from a birch. Makes planks and charcoal.",
	BirchLeaves = "Drops saplings and sticks now and then. Shears keep the leaves.",
	SpruceLog = "Dark wood from a spruce. Makes planks and charcoal.",
	SpruceLeaves = "Drops saplings and sticks now and then. Shears keep the leaves.",
	AcaciaLog = "Orange wood from an acacia. Makes planks and charcoal.",
	AcaciaLeaves = "Drops saplings and sticks now and then. Shears keep the leaves.",
	JungleLog = "Wood from a jungle tree. Makes planks and charcoal.",
	JungleLeaves = "Drops saplings and sticks now and then. Shears keep the leaves.",
	Cactus = "A desert plant, all spines and water.",
	CoalOre = "Stone veined with coal: fuel for furnaces, torches and generators.",
	IronOre = "Gives Raw Iron. Smelting iron opens the way to the Iron Age.",
	GoldOre = "Gives Raw Gold, for golden tools and Mekanism's alloys.",
	DiamondOre = "Deep and rare. Gives a Diamond.",
	Planks = "Oak boards for building, sticks, tables and chests.",
	Brick = "Sturdy fired bricks.",
	Glass = "Clear as air. Breaks into nothing.",
	Water = "A water source. Fill bottles and buckets from it.",
	PackedIce = "Ice packed hard. Chills you when close.",
	Calcite = "Pale stone from mountain sides.",
	PackedMud = "Dried mud, firm enough to build with.",
	Mycelium = "Mushroom soil from far-off fields. Breaks into Dirt.",
	Podzol = "Forest floor of needles. Mushrooms grow on it.",
	CoarseDirt = "Dirt mixed with gravel.",
	Andesite = "Gray igneous stone. Polish four into tiles.",
	Diorite = "Speckled white stone. Polish four into tiles.",
	Granite = "Pink-red stone. Polish four into tiles.",
	EmeraldOre = "Gives an Emerald, for staffs, anklets and elite gear.",
	Chest = "Stores your things. Breaking it drops what's inside.",
	BirchPlanks = "Birch boards for building, sticks, tables and chests.",
	SprucePlanks = "Spruce boards for building, sticks, tables and chests.",
	AcaciaPlanks = "Acacia boards for building, sticks, tables and chests.",
	JunglePlanks = "Jungle boards for building, sticks, tables and chests.",
	CraftingTable = "Opens a 3 x 3 crafting grid for bigger recipes.",
	Furnace = "Smelts ores, cooks food and purifies water with fuel.",
	CoalBlock = "Nine coal in one block. Burns ten times as long.",
	IronBlock = "Nine iron ingots in one solid block.",
	GoldBlock = "Nine gold ingots in one gleaming block.",
	DiamondBlock = "Nine diamonds in one block.",
	EmeraldBlock = "Nine emeralds in one block.",
	RawIronBlock = "Nine Raw Iron, kept compact.",
	RawGoldBlock = "Nine Raw Gold, kept compact.",
	StoneBricks = "Neatly cut stone for walls and halls.",
	CrackedStoneBricks = "Stone bricks cracked by a furnace's heat.",
	SmoothStone = "Stone smelted smooth.",
	PolishedAndesite = "Polished andesite tiles.",
	PolishedDiorite = "Polished diorite tiles.",
	PolishedGranite = "Polished granite tiles.",
	CutSandstone = "Sandstone cut into a clean face.",
	SmoothSandstone = "Sandstone smelted smooth.",
	BlueIce = "The slipperiest ice there is.",
	Torch = "Lights the dark. Place it on the ground or a wall.",
	GlowBlock = "A block of glowing dust: a bright, steady light.",
	Lantern = "A torch in iron: stands on the ground or hangs from a ceiling.",
	ShortGrass = "Wild grass. Breaking it by hand may give Straw.",
	Fern = "A shady little fern.",
	TallGrass = "Grass two blocks tall. Breaking it by hand gives Straw.",
	LargeFern = "A fern two blocks tall.",
	DeadBush = "A dry desert shrub. Breaks into sticks.",
	Dandelion = "A cheerful yellow flower.",
	Poppy = "A bright red flower.",
	BlueOrchid = "A rare swamp flower.",
	Allium = "A tall purple flower.",
	AzureBluet = "A tiny white flower.",
	RedTulip = "A tulip. Brews a Potion of Weakness.",
	OrangeTulip = "A tulip. Brews a Potion of Weakness.",
	WhiteTulip = "A tulip. Brews a Potion of Weakness.",
	PinkTulip = "A tulip. Brews a Potion of Weakness.",
	OxeyeDaisy = "A meadow daisy. Brews a Potion of Regeneration.",
	Cornflower = "A blue flower. Brews a Potion of Leaping.",
	LilyOfTheValley = "Pretty, and poisonous. Brews a Potion of Poison.",
	Sunflower = "A tall flower that faces the sunrise.",
	Lilac = "A tall flowering shrub.",
	RoseBush = "A tall bush of red roses.",
	Peony = "A tall pink flower.",
	BrownMushroom = "Grows in the shade, on mycelium and podzol.",
	RedMushroom = "A toadstool. Brews a Potion of Harming.",
	StructureBlock = "Saves and loads structures. Creative only.",
	StructureVoid = "Marks cells a structure leaves as they are. Creative only.",
	Jigsaw = "Joins structure pieces together. Creative only.",
	GlowLichen = "A faintly glowing cave growth. Gives Glow Dust.",
	Lava = "Molten rock. Burns anything that touches it.",
	Obsidian = "Cooled lava, all but unbreakable. Needs a diamond pickaxe.",
	OakSapling = "Plant it on dirt and it grows into an oak.",
	BirchSapling = "Plant it on dirt and it grows into a birch.",
	SpruceSapling = "Plant it on dirt and it grows into a spruce.",
	AcaciaSapling = "Plant it on dirt and it grows into an acacia.",
	JungleSapling = "Plant it on dirt and it grows into a jungle tree.",
	Tnt = "Light it with Flint and Steel, then run.",
	Nuke = "Wails for ten seconds, then leaves a crater. Stand well back.",
	WhiteWool = "Soft wool, from sheep or four String.",
	Ladder = "Climb it up and down.",
	Rope = "Hangs down from a ceiling. Climb it, or slide down safely.",
	Rail = "A straight piece of track.",
	OakFence = "A wooden fence post.",
	Cobweb = "Slows anything caught in it. Gives String.",
	MossBlock = "Soft green moss. Makes mossy cobblestone and carpets.",
	MossCarpet = "A thin layer of moss.",
	Vine = "Climbable greenery that hangs from walls.",
	HangingRoots = "Roots poking down from a cave ceiling.",
	MossyCobblestone = "Cobblestone overgrown with moss.",
	OakDoor = "Right click to open. Two side by side open together.",
	SpruceDoor = "A solid spruce door. Two side by side open together.",
	BirchDoor = "A birch door with four little windows. Opens with a right click.",
	JungleDoor = "A jungle wood door with small windows. Opens with a right click.",
	AcaciaDoor = "An acacia door with one window. Opens with a right click.",
	-- (The twelve turrets: the loop at the end.)
	MetalMiner = "Copies the ore block under it forever, for power. Pushes it out.",
	AmmoPress = "Presses brass, lead and gunpowder into 9mm, 5.56 or .308 rounds.",

	-- Mekanism and more -------------------------------------------------------------------------

	-- Terraria ----------------------------------------------------------------------------------
	HermesBoots = "The wearer can run super fast.",
	CloudInABottle = "Allows the holder to double jump.",
	ShinyRedBalloon = "Increases jump height.",
	LuckyHorseshoe = "Negates fall damage.",
	Aglet = "The wearer moves a little faster.",
	AnkletOfTheWind = "The wearer moves faster.",
	BandOfRegeneration = "Slowly heals the wearer.",
	BandOfStarpower = "Increases maximum mana.",
	ObsidianSkull = "Walk over campfires unhurt.",
	Flipper = "Swim faster.",
	CobaltShield = "Absorbs knockback.",
	FeralClaws = "Swing melee weapons faster. Found in ruins and bunkers.",
	FallenStar = "Falls from the night sky. Five make a Mana Crystal.",
	ManaCrystal = "Use it to raise your maximum mana for good.",
	LesserManaPotion = "Restores a little mana, with a moment of Mana Sickness.",
	ManaPotion = "Restores mana, with a moment of Mana Sickness.",
	WandOfSparking = "Shoots a small spark that may set foes alight.",
	EmeraldStaff = "Shoots an emerald bolt.",
	WaterBolt = "Casts a bolt of water.",
	TopHat = "A dapper hat. Wear it in a vanity slot.",
	TuxedoShirt = "Formal wear. Wear it in a vanity slot.",
	TuxedoPants = "Formal wear. Wear it in a vanity slot.",

	-- Turret parts ------------------------------------------------------------------------------
	SmgBarrel = "A turret part: an SMG turret's 9mm barrel.",
	RifleBarrel = "A turret part: a rifle turret's 5.56 barrel.",
	SniperBarrel = "A turret part: a sniper turret's .308 barrel.",
	BeltFeeder = "A turret part: takes the rounds a transporter brings into the gun.",
	Receiver = "A turret part: the action that chambers and fires each round.",
	ServoMotor = "A turret part: turns the gun towards its target.",
	TargetingModule = "A turret part: finds targets and tells the gun when to fire.",
	LaserSight = "Mount it on a turret: tighter shots, quicker to find a target.",
}

-- The twelve turrets (BlockList "<Tier><Type>Turret"): one line for each type's calibre.
for type, calibre in { Smg = "9mm", Rifle = "5.56", Sniper = ".308" } do
	for _, tier in { "Basic", "Advanced", "Elite", "Ultimate" } do
		lore[`{tier}{type}Turret`] = `Shoots zombies with {calibre} rounds a transporter feeds it. Needs power.`
	end
end

-- The packs' lines: their `lore`, then each entry's.
local content = Content.default
local function add(name: string, line: string, where: string)
	assert(lore[name] == nil, `LoreList: {where} has a lore line, and so has LoreList's side table`)
	lore[name] = line
end
for name, line in content.lore do
	add(name, line, content.where("lore", name))
end
for _, entry in content.entries do
	local line = entry.lore
	if line then
		add(entry.name, line, content.where(if content.block(entry.name) then "block" else "item", entry.name))
	end
end

return table.freeze(lore)
