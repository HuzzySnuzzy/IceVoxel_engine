--!strict
--[[
	Every block type in the game: the content packs' block entries (Shared/Content), merged, in id
	order (a block's id is its place minus one). The list itself moved into the packs (Core's Air
	and Cave Air, then the Minecraft, Mekanism, Survival, Apocalypse, Turrets and Ores packs'
	blocks); this module keeps `Blocks.BlockList` and its types for the code and specs that read
	them. The fields are Content/Schema's.
]]

local Content = require(script.Parent.Parent.Content)
local Schema = require(script.Parent.Parent.Content.Schema)

export type ShapeBox = Schema.ShapeBox
export type Bounds = Schema.Bounds
export type TransmitterSpec = Schema.TransmitterSpec
export type TankSpec = Schema.TankSpec
export type MachineSpec = Schema.MachineSpec
export type EnergySpec = Schema.EnergySpec
export type PlantSpec = Schema.PlantSpec
export type DoorSpec = Schema.DoorSpec
export type JigsawSpec = Schema.JigsawSpec
export type FlammableSpec = Schema.FlammableSpec
export type ToggleSpec = Schema.ToggleSpec
export type BlockSpec = Schema.BlockSpec

return Content.default.blocks
