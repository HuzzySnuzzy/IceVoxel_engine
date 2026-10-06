--!strict
--[[
	Mekanism's machines (Shared/Machines): the framework is Machines/Core (see its header for the
	whole API: kinds, containers, data layout, slot rules, panels, energy maths, sustained data).
	Requiring this module loads every machine kind in Machines/Kinds and binds the BlockList
	blocks with `machine` to their kinds, so every lookup by block works. Require this, never Core
	(except from a kind module, which defines itself with it). Machines/Upgrades holds Mekanism's
	upgrade cards (their slots and maths), for kinds that take them.

	The kinds: Creative (the Creative Energy Cube), Generator (the Heat Generator: furnace fuel and
	lava), Smelter (the Electric Furnace), Solar (the Solar Panel), Battery (the Energy Cubes),
	Refinery (the Oil Refinery: oil into fuel) and Combustion (the Combustion Generator: fuel).

	A new machine:
	  1. BlockList: a block with `machine = { kind = "name" }` and `energy = { capacity, input?,
	     output? }` (appended at the end).
	  2. Machines/Kinds/<Name>.luau: `return Core.define("name", { slots, fields, keep, tanks,
	     panel, tick, status, ... })`.
	  3. One line below requiring it.
	The server ticks it, connects it to energy networks (and its tanks to Mechanical Pipes), keeps
	its energy and fluids in its item and replicates it; the client draws its panel, energy bar,
	tank gauges and WAILA lines. Nothing else to wire.
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
export type TankSpec = Core.TankSpec
export type Tank = Core.Tank
export type TankGauge = Core.TankGauge
export type TankContents = Core.TankContents

-- Every machine kind (append one line per kind module).
require(script.Kinds.Creative)
require(script.Kinds.Generator)
require(script.Kinds.Smelter)
require(script.Kinds.Solar)
require(script.Kinds.Battery)
require(script.Kinds.Refinery)
require(script.Kinds.Combustion)

Core.bindBlocks()

return Core
