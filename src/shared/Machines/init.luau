--!strict
--[[
	Mekanism's machines (Shared/Machines): the framework is Machines/Core (see its header for the
	whole API: kinds, containers, data layout, slot rules, panels, energy maths, sustained data).
	Requiring this module loads every machine kind in Machines/Kinds and binds the BlockList
	blocks with `machine` to their kinds, so every lookup by block works. Require this, never Core
	(except from a kind module, which defines itself with it).

	A new machine:
	  1. BlockList: a block with `machine = { kind = "name" }` and `energy = { capacity, input?,
	     output? }` (appended at the end).
	  2. Machines/Kinds/<Name>.luau: `return Core.define("name", { slots, fields, keep, panel,
	     tick, status, ... })`.
	  3. One line below requiring it.
	The server ticks it, connects it to energy networks, keeps its energy in its item and
	replicates it; the client draws its panel, energy bar and WAILA lines. Nothing else to wire.
]]

local Core = require(script.Core)

export type Kind = Core.Kind
export type KindSpec = Core.KindSpec
export type SlotSpec = Core.SlotSpec
export type PanelSpec = Core.PanelSpec
export type Gauge = Core.Gauge
export type View = Core.View
export type TickContext = Core.TickContext
export type EnergySpec = Core.EnergySpec
export type Role = Core.Role

-- Every machine kind (append one line per kind module).
require(script.Kinds.Creative)

Core.bindBlocks()

return Core
