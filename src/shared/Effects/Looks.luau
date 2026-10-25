--!strict
--[[
	What a status effect may look like: the closed sets its `icon` and `view` name one of (the
	content packs' `effects`, Content/Schema checks them as packs load). The client draws these
	and nothing else, but its modules are out of the shared loader's reach, so the names live here,
	pure, and the client's modules check themselves against them as they load:

	  ICONS  the HUD glyphs, 9 x 9 pixel art in the effect's colour: client Ui/EffectIcons has one
	         for each of these and no other (it asserts so at load). A new look is a glyph there
	         and its name here.
	  VIEWS  what an effect does to the view: "nightVision", "blindness", "nausea" (client
	         Rendering/EffectView), "glowing" (an outline everyone sees through walls: the server's
	         Highlight, Players/Effects).
]]

local Looks = {}

Looks.ICONS = table.freeze({
	"speed",
	"slowness",
	"pickaxe",
	"sword",
	"heart",
	"broken",
	"jump",
	"spiral",
	"shield",
	"flame",
	"eye",
	"drop",
	"skull",
	"star",
	"drumstick",
	"snowflake",
	"radiation",
})

Looks.VIEWS = table.freeze({ "nightVision", "blindness", "nausea", "glowing" })

return Looks
