--!strict
--[[
	The base item tags ("#planks" in a recipe, Minecraft's item tags), which recipes of every pack
	may name. Other packs add to them (a `tags` module of their own, or an entry's `tags = {
	"planks" }`): a tag is the union of every pack's.
]]

return {
	planks = { "Planks", "BirchPlanks", "SprucePlanks", "AcaciaPlanks", "JunglePlanks" },
	logs = { "OakLog", "BirchLog", "SpruceLog", "AcaciaLog", "JungleLog" },
	stone_tool_materials = { "Cobblestone" },
	stone_crafting_materials = { "Cobblestone" },
	coals = { "Coal", "Charcoal" },
	leaves = { "OakLeaves", "BirchLeaves", "SpruceLeaves", "AcaciaLeaves", "JungleLeaves" },
	-- (Potions: any tulip brews Weakness, as any gives it in Minecraft's suspicious stew.)
	tulips = { "RedTulip", "OrangeTulip", "WhiteTulip", "PinkTulip" },
} :: { [string]: { string } }
