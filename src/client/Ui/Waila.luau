--!strict
--[[
	WAILA, "What Am I Looking At", as the Jade mod draws it: a panel at the top centre of the screen
	naming what the crosshair points at, with more while the F3 overlay is open.

	  Target    the block BlockInteraction aims at (the highlighted one: the same reach and rules,
	            torches and lanterns by their outline), or something nearer on the same aim: a
	            dropped item (EntityRenderer.itemsNear), a mob (Entities/MobRenderer.mobsNear: its
	            box as drawn; its name, health and with F3 its kind and id) or another player
	            (their standing hull, Shared/Movement/Rig). Entities are only in reach like blocks
	            are (their centre within
	            Config.Interaction.Reach of the player), and never seen through a block, even one
	            too far to target. While survival mining, the mined block always wins. Water shows
	            only when no block is in reach (its surface, not the water the camera is in), so it
	            never hides the highlighted block (BlockInteraction mines and places through water).
	            The choice is WailaInfo.choose (tested). Spectators are never named, nor the player
	            being spectated, whose eyes the camera is in (Player/SpectatorRules.aimable). A
	            spectator sees only what it can aim at: blocks with a menu (BlockInteraction aims at
	            nothing else for spectators) and players, no dropped items or water. (Jade itself
	            names any block for spectators.)
	  Content   Ui/WailaInfo (pure, tested): the icon (the item's 3D icon; a colour box for blocks
	            that are no item, like bedrock; a player's head shot), the name, the harvest line (the
	            tool and tier a block needs, with a check or a cross for the held item), and
	            "IceVoxel" in blue italics. With F3 (Debug/DebugOverlay.isOpen) the extended lines:
	            id, position, chunk, biome (the generator's column), hardness, tool, drops, break
	            time, light, fluid level, render kind, menu. Mekanism's transmitters, tanks and
	            machines add what Rendering/TransmitterRenderer knows (the side the Configurator
	            points at, BlockInteraction.targetSide, and its mode; colour, items inside, water,
	            a cable's capacity; a machine's energy and status from its Machines record), and
	            with F3 their packed modes, connections and network, a machine's energy numbers.
	            Structure blocks add their mode and name, jigsaws their name, target and pool,
	            from Net/StructureNet's records (with F3 a structure block's region and LOAD
	            settings); operator blocks say "Creative only" where the harvest line goes.
	  Progress  survival mining progress (BlockInteraction.miningProgress) is Jade's white line
	            along the panel's bottom edge.
	  Look      Minecraft's tooltip, which is Jade's default theme: a dark translucent panel with cut
	            corners and a purple border fading to a darker purple, the pixel font with its shadow
	            (Ui/Style), in GUI pixels at the HUD's scale (Ui/UiScale). It fits its content.
	            Minecraft's italics are drawn by shearing: the text is cut into strips 2 pixels
	            tall, each shifted a whole pixel or none (the pixel font has no italic face).
	  Place     the top centre, kept out of the HUD's corner (the minimap or the Map button, and
	            its coordinates line once the panel reaches down that far: Ui/HudLayout's
	            `wailaRight` and `wailaLow`, through UiScale.hud) when that leaves room to read it,
	            and, while F3 is open, right of the debug text (`wailaAvoid`: Debug/DebugOverlay
	            reports its edge) when the screen allows; drawn smaller when it doesn't fit
	            (WailaInfo.placement, tested). Laid out again when the corner moves.
	  Hidden    while a screen is open (Ui/Screens), while the HUD is hidden (the world map), with
	            nothing aimed at, and with the WAILA setting off (`setEnabled`: then nothing is
	            picked either).

	Updates are cheap: every frame builds a short key of what would be shown (the target, the held
	item, F3) and rebuilds the text only when the key changes, at most every REBUILD_INTERVAL (also
	when the target flickers on and off: hiding keeps the text); the progress line only resizes.
	Items, players, water and the block hiding them are looked for every PICK_INTERVAL. On touch
	screens a finger aims only while breaking (BlockInteraction), so they show blocks only. The aim
	starts at the camera, in render studs, and is cast from world blocks as doubles (Shared/World/
	Origin); other players are Player/RemotePlayers' (their characters, or the server's relay:
	only those this client is sent), and their F3 position is in true world coordinates.

	The tunables are below (Config is shared with every other module, so they live here).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Fire = require(Shared.Fire)
local GameMode = require(Shared.GameMode)
local Origin = require(Shared.World.Origin)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)
local VoxelRaycast = require(Shared.World.VoxelRaycast)
local LightEstimate = require(Shared.World.LightEstimate)
local Mining = require(Shared.Mining)

local BlockInteraction = require(script.Parent.Parent.Interaction.BlockInteraction)
local LightingController = require(script.Parent.Parent.Rendering.LightingController)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local SpectatorRules = require(script.Parent.Parent.Player.SpectatorRules)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local DebugOverlay = require(script.Parent.Parent.Debug.DebugOverlay)
local EffectState = require(script.Parent.Parent.Player.EffectState)
local ProgressionState = require(script.Parent.Parent.Player.ProgressionState)
local EntityRenderer = require(script.Parent.Parent.Entities.EntityRenderer)
local MobRenderer = require(script.Parent.Parent.Entities.MobRenderer)
local ItemIcon = require(script.Parent.ItemIcon)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local RemotePlayers = require(script.Parent.Parent.Player.RemotePlayers)
local TransmitterRenderer = require(script.Parent.Parent.Rendering.TransmitterRenderer)
local StructureNet = require(script.Parent.Parent.Net.StructureNet)
local StructureRecords = require(script.Parent.Parent.World.StructureRecords)
local Settings = require(Shared.Structures.Settings)
local Machines = require(Shared.Machines)
local Transmitters = require(Shared.Transmitters)
local Screens = require(script.Parent.Screens)
local Style = require(script.Parent.Style)
local UiScale = require(script.Parent.UiScale)
local WailaInfo = require(script.Parent.WailaInfo)

--[[ Tunables ]]

-- What WAILA names besides blocks.
local SHOW_ITEMS = true
local SHOW_MOBS = true
local SHOW_PLAYERS = true
local SHOW_FLUIDS = true
-- How often (seconds) the aim is checked for items, players and water, and the text may change
-- (Jade's tick: sweeping the crosshair over many blocks rebuilds it at most this often).
local PICK_INTERVAL = 0.05
local REBUILD_INTERVAL = 0.05
-- The box a dropped item is aimed at (blocks, around its position): its model floats and bobs
-- above the position (Entities/EntityRenderer).
local ITEM_WIDTH = 0.5
local ITEM_HEIGHT = 0.8
-- Screen pixels between Roblox's top bar and the panel, and kept free inside the screen's edges.
local TOP_GAP = 4
local SCREEN_MARGIN = 8
-- Minecraft's tooltip colours (Jade's default theme). The background is a little more
-- see-through than a tooltip's; the border is Minecraft's 0x50 alpha.
local BACKGROUND = Color3.fromRGB(16, 0, 16)
local BACKGROUND_TRANSPARENCY = 0.15
local BORDER_TOP = Color3.fromRGB(80, 0, 255)
local BORDER_BOTTOM = Color3.fromRGB(40, 0, 127)
local BORDER_TRANSPARENCY = 0.69
local PROGRESS_COLOUR = Color3.fromRGB(255, 255, 255)
-- Minecraft's chat colours, by WailaInfo's names.
local COLOURS: { [string]: Color3 } = {
	white = Color3.fromRGB(255, 255, 255),
	gray = Color3.fromRGB(170, 170, 170),
	darkGray = Color3.fromRGB(85, 85, 85),
	blue = Color3.fromRGB(85, 85, 255),
	green = Color3.fromRGB(85, 255, 85),
	red = Color3.fromRGB(255, 85, 85),
	yellow = Color3.fromRGB(255, 255, 85),
	gold = Color3.fromRGB(255, 170, 0),
}
-- Layout (GUI pixels): the padding inside the panel (Minecraft's tooltip: 4), the icon and the gap
-- after it, the line pitch, and the room a check or cross takes before its text.
local PADDING = 4
local ICON = 16
local ICON_GAP = 4
local LINE = 10
local MARK = 9
-- The icon is centred on at most this many lines (the normal view's), so it stays at the top of
-- the long F3 view.
local ICON_LINES = 3
-- The GUI scale comes from the HUD's size (the hotbar's; with its two buttons on touch screens,
-- Ui/Hud), so both are drawn at the same scale.
local SCALE_WIDTH, SCALE_WIDTH_TOUCH, SCALE_HEIGHT = 182, 182 + 2 * (22 + 2), 70
-- Strips (2 pixels each) the italic text is cut into: the 8 pixel glyphs and their shadow.
local ITALIC_STRIPS = 5

-- 7 x 7 pixel art of the check and the cross, drawn with a shadow like the text.
local CHECK_ART = {
	"......#",
	".....##",
	"#...##.",
	"##.##..",
	".###...",
	"..#....",
	".......",
}
local CROSS_ART = {
	"#.....#",
	".#...#.",
	"..#.#..",
	"...#...",
	"..#.#..",
	".#...#.",
	"#.....#",
}

local BLOCK = Config.BlockSize
local REACH = Config.Interaction.Reach
-- Other players are aimed at by their standing hull (as the server's EditRules and Minecraft's).
local PLAYER_WIDTH = PlayerPhysics.STANDING.width
local PLAYER_HEIGHT = PlayerPhysics.STANDING.height

-- An item or a player under the aim, `distance` blocks along it.
type Entity = { distance: number, item: EntityRenderer.ItemView?, player: Player?, mob: MobRenderer.MobView? }

-- A point in world blocks as doubles (the aim's origin, the body: exact far from 0).
type Point = { X: number, Y: number, Z: number }

local Waila = {}

local started = false
-- The WAILA setting.
local enabled = true

-- The WAILA setting: off hides the panel and stops looking for what is aimed at.
function Waila.setEnabled(value: boolean)
	enabled = value
end

--[[
	Starts the panel. `world` gives the blocks water is looked for in, `generator` (optional) the
	biome shown in the extended view.
]]
function Waila.start(world: ClientWorld.ClientWorld, generator: TerrainGenerator.Generator?)
	assert(not started, "Waila.start was already called")
	started = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	--[[ The panel ]]

	-- (Below Roblox's top bar and inside the safe area. Under the screens and the HUD; hidden anyway
	-- while either covers the screen.)
	local gui = UiScale.screenGui("IceVoxelWaila", "Waila", { inset = false, kind = "scaled" })

	local root = Instance.new("Frame")
	root.Name = "Waila"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.Position = UDim2.new(0.5, 0, 0, TOP_GAP)
	root.Visible = false
	root.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = root

	-- Minecraft's tooltip background: a rectangle with one pixel more on each side but the corners.
	local main = Style.frame(root, 0, 0, 0, 0, BACKGROUND, 1)
	local edges = {
		Style.frame(root, 0, 0, 0, 0, BACKGROUND, 1),
		Style.frame(root, 0, 0, 0, 0, BACKGROUND, 1),
		Style.frame(root, 0, 0, 0, 0, BACKGROUND, 1),
		Style.frame(root, 0, 0, 0, 0, BACKGROUND, 1),
	}
	main.BackgroundTransparency = BACKGROUND_TRANSPARENCY
	for _, edge in edges do
		edge.BackgroundTransparency = BACKGROUND_TRANSPARENCY
	end
	-- The border, one pixel in: the top colour above, the bottom one below, fading on the sides.
	local borderTop = Style.frame(root, 0, 0, 0, 0, BORDER_TOP, 2)
	local borderBottom = Style.frame(root, 0, 0, 0, 0, BORDER_BOTTOM, 2)
	local borderSides = {
		Style.frame(root, 0, 0, 0, 0, Color3.new(1, 1, 1), 2),
		Style.frame(root, 0, 0, 0, 0, Color3.new(1, 1, 1), 2),
	}
	for _, frame in { borderTop, borderBottom, borderSides[1], borderSides[2] } do
		frame.BackgroundTransparency = BORDER_TRANSPARENCY
	end
	for _, side in borderSides do
		local fade = Instance.new("UIGradient")
		fade.Rotation = 90
		fade.Color = ColorSequence.new(BORDER_TOP, BORDER_BOTTOM)
		fade.Parent = side
	end

	-- Icons: an item's, a colour box, a player's head.
	local itemIcon = ItemIcon.new(root, PADDING, PADDING, 3)
	itemIcon.root.Visible = false
	-- (A block's colour with a darker rim, for blocks that are no item.)
	local box = Style.frame(root, PADDING + 1, PADDING + 1, ICON - 2, ICON - 2, Color3.new(0, 0, 0), 3)
	box.Visible = false
	local boxFace = Style.frame(box, 1, 1, ICON - 4, ICON - 4, Color3.new(0, 0, 0), 1)
	local head = Instance.new("ImageLabel")
	head.BackgroundTransparency = 1
	head.BorderSizePixel = 0
	head.Size = UDim2.fromOffset(ICON, ICON)
	head.ZIndex = 3
	head.Visible = false
	head.Parent = root

	-- The text, rebuilt when what is shown changes.
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1)
	content.ZIndex = 4
	content.Parent = root

	-- Jade's mining progress line, over the bottom border.
	local progressLine = Style.frame(root, 1, 0, 0, 1, PROGRESS_COLOUR, 5)
	progressLine.Visible = false

	gui.Parent = playerGui

	local panelWidth, panelHeight = 0, 0
	local extendedShown = false

	-- Scale and place the panel (WailaInfo.placement): the HUD's scale (smaller if it doesn't fit),
	-- at the top centre, out of the HUD's corner, moved right of the F3 text while that is open.
	-- (Ui/HudLayout's edges are screen pixels; this GUI starts below the top bar, in the safe area.)
	local function layout()
		local viewport = UiScale.viewport()
		local area = gui.AbsoluteSize
		if area.X <= 0 or area.Y <= 0 then
			area = viewport
		end
		local origin = UiScale.origin(gui)
		local insets = UiScale.insets()
		local touch = UiScale.touch()
		local base = UiScale.fit(
			if touch then SCALE_WIDTH_TOUCH else SCALE_WIDTH,
			SCALE_HEIGHT,
			Vector2.new(viewport.X - insets.left - insets.right, viewport.Y - insets.top - insets.bottom)
		)
		local corner = UiScale.hud()
		local right = corner.wailaRight
		local low = corner.wailaLow
		if low and origin.Y + TOP_GAP + panelHeight * base > low.y then
			right = math.min(right, low.right)
		end
		local avoid = corner.wailaAvoid
		local value, shift = WailaInfo.placement({
			width = area.X,
			height = area.Y,
			scale = base,
			touch = touch,
			top = TOP_GAP,
			margin = SCREEN_MARGIN,
			rightReserve = math.max(origin.X + area.X - right, 0),
			avoidLeft = if extendedShown and avoid then avoid - origin.X else nil,
		}, panelWidth, panelHeight)
		if scale.Scale ~= value then
			scale.Scale = value
		end
		local position = UDim2.new(0.5, shift, 0, TOP_GAP)
		if root.Position ~= position then
			root.Position = position
		end
	end

	local function place(frame: GuiObject, x: number, y: number, w: number, h: number)
		frame.Position = UDim2.fromOffset(x, y)
		frame.Size = UDim2.fromOffset(math.max(w, 0), math.max(h, 0))
	end

	-- Sizes the background and border for a panel of `w` x `h`.
	local function resize(w: number, h: number)
		panelWidth, panelHeight = w, h
		root.Size = UDim2.fromOffset(w, h)
		local k, l = w - 2, h - 2
		place(main, 1, 1, k, l)
		place(edges[1], 1, 0, k, 1)
		place(edges[2], 1, h - 1, k, 1)
		place(edges[3], 0, 1, 1, l)
		place(edges[4], w - 1, 1, 1, l)
		place(borderTop, 1, 1, k, 1)
		place(borderBottom, 1, l, k, 1)
		place(borderSides[1], 1, 2, 1, l - 2)
		place(borderSides[2], k, 2, 1, l - 2)
		layout()
	end

	-- A check or a cross at (x, y) of a line, with its shadow.
	local function mark(x: number, y: number, ok: boolean)
		local art = if ok then CHECK_ART else CROSS_ART
		local colour = if ok then COLOURS.green else COLOURS.red
		Style.pixelArt(content, x + 1, y + 1, art, { ["#"] = Style.shadowOf(colour) }, 1)
		Style.pixelArt(content, x, y, art, { ["#"] = colour }, 2)
	end

	-- Text in Minecraft's italics: Minecraft shears each glyph a pixel right at the top and a pixel
	-- left at the bottom; here every 2 pixel strip of the label is shifted by its middle's share,
	-- in whole pixels (WailaInfo.italicShifts; UDim offsets are integers).
	local italicShifts = WailaInfo.italicShifts(ITALIC_STRIPS)
	local function italic(text: string, x: number, y: number, width: number, colour: Color3)
		for k = 0, ITALIC_STRIPS - 1 do
			local strip = Instance.new("Frame")
			strip.BackgroundTransparency = 1
			strip.BorderSizePixel = 0
			strip.ClipsDescendants = true
			strip.Position = UDim2.fromOffset(x - 2, y + 2 * k)
			strip.Size = UDim2.fromOffset(width + 6, 2)
			strip.ZIndex = 1
			strip.Parent = content
			Style.shadowText(strip, text, 2 + italicShifts[k + 1], -2 * k, width + 2, Style.TEXT_SIZE, colour, 1)
		end
	end

	local function showIcon(icon: WailaInfo.Icon?, y: number)
		local item = icon and icon.item
		itemIcon:set(item, 1)
		itemIcon.root.Visible = item ~= nil
		itemIcon.root.Position = UDim2.fromOffset(PADDING, y)
		local colour = if icon and item == nil then icon.colour else nil
		box.Visible = colour ~= nil
		if colour then
			local face = Color3.fromRGB(colour[1], colour[2], colour[3])
			boxFace.BackgroundColor3 = face
			box.BackgroundColor3 = Color3.new(face.R * 0.6, face.G * 0.6, face.B * 0.6)
			box.Position = UDim2.fromOffset(PADDING + 1, y + 1)
		end
		local userId = if icon and item == nil and colour == nil then icon.userId else nil
		head.Visible = userId ~= nil
		if userId then
			head.Image = `rbxthumb://type=AvatarHeadShot&id={userId}&w=48&h=48`
			head.Position = UDim2.fromOffset(PADDING, y)
		end
	end

	-- Draws `info`'s icon and text and fits the panel to them.
	local function render(info: WailaInfo.Info)
		content:ClearAllChildren()
		local lines = info.lines
		local textWidth = 0
		for _, line in lines do
			local width = 0
			for _, s in line do
				if s.mark ~= nil then
					width += MARK
				end
				if s.text ~= "" then
					width += Style.textWidth(s.text)
				end
			end
			textWidth = math.max(textWidth, width)
		end
		local icon = info.icon
		local textX = PADDING + (if icon then ICON + ICON_GAP else 0)
		local linesHeight = math.max(#lines * LINE - (LINE - Style.TEXT_SIZE), 0)
		local height = math.max(linesHeight, if icon then ICON else 0)
		-- Short text is centred on the icon, the icon on the first lines.
		local top = PADDING + math.max(0, (ICON - linesHeight) // 2)
		local iconTop = PADDING + math.max(0, (math.min(linesHeight, ICON_LINES * LINE - 2) - ICON) // 2)
		if icon == nil then
			top = PADDING
		end

		local y = top
		for _, line in lines do
			local x = textX
			for _, s in line do
				if s.mark ~= nil then
					mark(x, y, s.mark)
					x += MARK
				end
				if s.text ~= "" then
					local width = Style.textWidth(s.text)
					local colour = COLOURS[s.colour] or COLOURS.white
					if s.italic then
						italic(s.text, x, y, width, colour)
					else
						Style.shadowText(content, s.text, x, y, width + 2, Style.TEXT_SIZE, colour, 1)
					end
					x += width
				end
			end
			y += LINE
		end
		showIcon(icon, iconTop)
		resize(textX + textWidth + PADDING, height + 2 * PADDING)
	end

	-- The progress shown and the panel size it was drawn for.
	local shownProgress: number? = nil
	local progressSize = Vector2.zero
	local function setProgress(progress: number?)
		local size = Vector2.new(panelWidth, panelHeight)
		if progress == shownProgress and size == progressSize then
			return
		end
		shownProgress, progressSize = progress, size
		progressLine.Visible = progress ~= nil
		if progress then
			place(progressLine, 1, panelHeight - 2, math.floor((panelWidth - 2) * math.clamp(progress, 0, 1)), 1)
		end
	end

	--[[ What is shown ]]

	-- The key of the text drawn (kept while hidden: aiming off and back on the same thing, e.g. at
	-- the edge of reach, only shows it again) and when it was drawn.
	local shownKey = ""
	local renderedAt = -math.huge

	local function show(key: string, extended: boolean, build: () -> WailaInfo.Info)
		if key ~= shownKey then
			local now = os.clock()
			if now - renderedAt < REBUILD_INTERVAL then
				-- (The last text stays a moment longer; a hidden panel waits hidden, rather than
				-- showing the old text. Flickering between targets rebuilds at most this often.)
				return
			end
			shownKey = key
			renderedAt = now
			extendedShown = extended
			render(build())
		end
		if not root.Visible then
			root.Visible = true
		end
	end

	local function hide()
		if root.Visible then
			root.Visible = false
		end
		setProgress(nil)
	end

	local function heldItem(): number?
		local stack = ClientInventory.selectedStack()
		return if stack then stack.item else nil
	end

	local function biomeAt(x: number, z: number): string?
		if generator == nil then
			return nil
		end
		local _, biome = generator.column(x, z)
		return WailaInfo.biomeName(biome)
	end

	-- What the client knows about a transmitter, a tank or a machine, and a key that changes with it.
	local function pipeFacts(
		hit: VoxelRaycast.Hit,
		extended: boolean
	): (WailaInfo.TransmitterFacts?, WailaInfo.TankFacts?, WailaInfo.MachineFacts?, string)
		local x, y, z = hit.x, hit.y, hit.z
		if Transmitters.isTransmitter(hit.block) then
			local modes, colour, fluid, fluidId = TransmitterRenderer.state(x, y, z)
			local linked, acceptors = TransmitterRenderer.connections(x, y, z)
			local items, stacks = TransmitterRenderer.itemsIn(x, y, z)
			-- (The network walk only for what shows it: a pipe's water, the F3 lines.)
			local size, capacity, complete = 0, 0, true
			if extended or Transmitters.kindOf(hit.block) == "fluid" then
				size, capacity, complete = TransmitterRenderer.network(x, y, z)
			end
			local side = BlockInteraction.targetSide()
			local facts: WailaInfo.TransmitterFacts = {
				modes = modes,
				colour = colour,
				fluid = fluid,
				fluidId = fluidId,
				side = side,
				items = items,
				stacks = stacks,
				transmitters = linked,
				acceptors = acceptors,
				networkSize = size,
				networkCapacity = capacity,
				networkComplete = complete,
			}
			local key =
				`{modes} {colour} {fluid} {fluidId} {side or -1} {items} {stacks} {linked} {acceptors} {size} {capacity} {complete}`
			return facts, nil, nil, key
		elseif Transmitters.isTank(hit.block) then
			local fluid, amount = TransmitterRenderer.tank(x, y, z)
			return nil, { fluid = fluid, amount = amount }, nil, `{fluid} {amount}`
		elseif Machines.isMachine(hit.block) then
			local record = TransmitterRenderer.machine(x, y, z)
			local facts: WailaInfo.MachineFacts = if record
				then {
					energy = record.energy,
					capacity = record.capacity,
					input = record.input,
					output = record.output,
					rate = record.rate,
					active = record.active,
					state = record.state,
					-- (The record's tanks in order, Machines.tankContents; nil for a kind without.)
					tanks = record.tanks,
				}
				else WailaInfo.machineDefaults(hit.block)
			local tankKey = ""
			local tanks = facts.tanks
			if tanks then
				for _, tank in tanks do
					tankKey ..= ` {tank.fluid}:{tank.amount}`
				end
			end
			local key =
				`{facts.energy} {facts.capacity} {facts.input} {facts.output} {facts.rate} {facts.active} {facts.state}{tankKey}`
			return nil, nil, facts, key
		end
		return nil, nil, nil, ""
	end

	-- A structure block's or jigsaw's settings (the server's records), and a key that changes with them.
	local function structureFacts(
		hit: VoxelRaycast.Hit
	): (Settings.StructureSettings?, Settings.JigsawSettings?, string)
		local records = StructureNet.records()
		if Blocks.isStructureBlock(hit.block) then
			local settings = StructureRecords.structure(records, hit.x, hit.y, hit.z)
			return settings, nil, `s{records.version}`
		elseif Blocks.isJigsaw(hit.block) then
			local settings = StructureRecords.jigsaw(records, hit.x, hit.y, hit.z)
			return nil, settings, `j{records.version}`
		end
		return nil, nil, ""
	end

	local function blockAt(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end

	-- The light where a mob would stand on the block hit (WailaInfo.lightLine): on top of an opaque
	-- block, else in its own cell. Nil where that cell isn't loaded.
	local function lightFacts(hit: VoxelRaycast.Hit): (WailaInfo.LightFacts?, string)
		local y = if Blocks.isOpaque(hit.block) then hit.y + 1 else hit.y
		local sky = LightingController.skyLight(hit.x, y, hit.z)
		if sky == nil or world:getBlock(hit.x, y, hit.z) == nil then
			return nil, "-"
		end
		local block = LightEstimate.blockLight(blockAt, hit.x, y, hit.z)
		return { block = block, sky = sky }, `{block},{sky}`
	end

	local function showBlock(hit: VoxelRaycast.Hit, progress: number?, extended: boolean)
		local held = heldItem()
		local transmitter, tank, machine, facts = pipeFacts(hit, extended)
		local structure, jigsaw, structureKey = structureFacts(hit)
		local light, lightKey = lightFacts(hit)
		-- (The break time at the player's own speed, as BlockInteraction mines: Haste, Mining
		-- Fatigue, the mining perks.)
		local factor = Mining.playerFactor(EffectState.levels(), ProgressionState.perks(), held)
		local key =
			`b {hit.x} {hit.y} {hit.z} {hit.block} {held or 0} {extended} {facts} {structureKey} {lightKey} {factor}`
		show(key, extended, function()
			local biome = if extended then biomeAt(hit.x, hit.z) else nil
			return WailaInfo.block(hit.block, held, hit.x, hit.y, hit.z, extended, {
				miningFactor = factor,
				progress = progress,
				biome = biome,
				transmitter = transmitter,
				tank = tank,
				machine = machine,
				structure = structure,
				jigsaw = jigsaw,
				light = light,
			})
		end)
		setProgress(progress)
	end

	local function showEntity(entity: Entity, extended: boolean)
		local view, other, mob = entity.item, entity.player, entity.mob
		if mob then
			local position = if extended then `{math.floor(mob.x)} {math.floor(mob.y)} {math.floor(mob.z)}` else ""
			local key = `m {mob.id} {mob.health} {extended} {position}`
			show(key, extended, function()
				return WailaInfo.mob({
					kind = mob.kind,
					variant = mob.variant,
					id = mob.id,
					health = mob.health,
					x = mob.x,
					y = mob.y,
					z = mob.z,
				}, extended)
			end)
		elseif view then
			local position = if extended then string.format("%.2f %.2f %.2f", view.x, view.y, view.z) else ""
			local key = `i {view.id} {view.item} {view.count} {extended} {position}`
			show(key, extended, function()
				return WailaInfo.item(view.item, view.count, extended, view.id, view.x, view.y, view.z)
			end)
		elseif other then
			local character = other.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local health = if humanoid then humanoid.Health else 0
			local maxHealth = if humanoid then humanoid.MaxHealth else 0
			-- (World blocks: Player/RemotePlayers.)
			local fx, fy, fz = nil, 0, 0
			if extended then
				fx, fy, fz = RemotePlayers.feet(other)
			end
			local mode = GameMode.of(other)
			local points = WailaInfo.healthPoints(health, maxHealth)
			local position = if fx then `{math.floor(fx)} {math.floor(fy)} {math.floor(fz)}` else ""
			local key = `p {other.UserId} {other.DisplayName} {points} {mode} {extended} {position}`
			show(key, extended, function()
				return WailaInfo.player({
					displayName = other.DisplayName,
					name = other.Name,
					userId = other.UserId,
					health = health,
					maxHealth = maxHealth,
					gameMode = mode,
					x = fx,
					y = if fx then fy else nil,
					z = if fx then fz else nil,
				}, extended)
			end)
		end
		setProgress(nil)
	end

	local function showFluid(hit: VoxelRaycast.Hit, extended: boolean)
		local light, lightKey = lightFacts(hit)
		local key = `f {hit.x} {hit.y} {hit.z} {hit.block} {extended} {lightKey}`
		show(key, extended, function()
			local biome = if extended then biomeAt(hit.x, hit.z) else nil
			return WailaInfo.block(hit.block, nil, hit.x, hit.y, hit.z, extended, { biome = biome, light = light })
		end)
		setProgress(nil)
	end

	--[[ Aiming at items, players and water ]]

	local function getBlock(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end
	-- (Aimed at like BlockInteraction does: a fire by the slabs of the walls it clings to.)
	local outlineAt = Fire.outlineAt(getBlock)

	local function isFluid(id: number): boolean
		return buffer.readu8(Blocks.fluidHeightLut, id) > 0
	end

	-- Where the player aims, in viewport pixels, as BlockInteraction does: the free mouse, else the
	-- screen centre; nil on touch screens (a finger aims only while breaking).
	local function aimPoint(): Vector2?
		local preferred = UserInputService.PreferredInput
		if preferred == Enum.PreferredInput.Touch then
			return nil
		end
		if
			preferred == Enum.PreferredInput.KeyboardAndMouse
			and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter
		then
			return UserInputService:GetMouseLocation()
		end
		local size = UiScale.viewport()
		return Vector2.new(size.X / 2, size.Y / 2)
	end

	--[[
		The nearest item or player on the ray from `origin` (world blocks, doubles: {x, y, z}) within
		`maxDistance` and in reach of `body` (likewise) (no spectators, nor the player spectated; a
		spectator only players).
	]]
	local function pickEntity(
		origin: Point,
		direction: Vector3,
		maxDistance: number,
		body: Point,
		spectating: boolean
	): Entity?
		local best: Entity? = nil
		local bestDistance = maxDistance
		if SHOW_ITEMS and not spectating then
			local half = ITEM_WIDTH / 2
			for _, view in EntityRenderer.itemsNear(body.X, body.Y, body.Z, REACH) do
				local t = WailaInfo.rayBox(
					origin.X,
					origin.Y,
					origin.Z,
					direction.X,
					direction.Y,
					direction.Z,
					view.x - half,
					view.y,
					view.z - half,
					view.x + half,
					view.y + ITEM_HEIGHT,
					view.z + half
				)
				if t and t < bestDistance then
					best, bestDistance = { distance = t, item = view, player = nil }, t
				end
			end
		end
		if SHOW_MOBS and not spectating then
			for _, mob in MobRenderer.mobsNear(body.X, body.Y, body.Z, REACH) do
				local half = mob.kind.width / 2
				local t = WailaInfo.rayBox(
					origin.X,
					origin.Y,
					origin.Z,
					direction.X,
					direction.Y,
					direction.Z,
					mob.x - half,
					mob.y,
					mob.z - half,
					mob.x + half,
					mob.y + mob.kind.height,
					mob.z + half
				)
				if t and t < bestDistance then
					best, bestDistance = { distance = t, item = nil, player = nil, mob = mob }, t
				end
			end
		end
		if SHOW_PLAYERS then
			local spectated = MovementController.spectating()
			local half, height = PLAYER_WIDTH / 2, PLAYER_HEIGHT
			-- (The players this client knows of, where Player/RemotePlayers has them.)
			for other, remote in RemotePlayers.each() do
				if SpectatorRules.aimable(GameMode.of(other), other == spectated) then
					-- Their standing hull's centre within reach of the body.
					local dx, dy, dz = remote.x - body.X, remote.y + height / 2 - body.Y, remote.z - body.Z
					if dx * dx + dy * dy + dz * dz <= REACH * REACH then
						local t = WailaInfo.rayBox(
							origin.X,
							origin.Y,
							origin.Z,
							direction.X,
							direction.Y,
							direction.Z,
							remote.x - half,
							remote.y,
							remote.z - half,
							remote.x + half,
							remote.y + height,
							remote.z + half
						)
						if t and t < bestDistance then
							best, bestDistance = { distance = t, item = nil, player = other }, t
						end
					end
				end
			end
		end
		return best
	end

	--[[
		Water on the ray, in reach: the first fluid after the ray has left any fluid it started in
		(looking out of a lake shows the next one, not the water around the camera).
	]]
	local function pickFluid(origin: Point, direction: Vector3, maxDistance: number, body: Point): VoxelRaycast.Hit?
		local outside = false
		local hit = VoxelRaycast.cast(
			origin.X,
			origin.Y,
			origin.Z,
			direction.X,
			direction.Y,
			direction.Z,
			maxDistance,
			getBlock,
			function(id: number): boolean
				if isFluid(id) then
					return outside
				end
				outside = true
				return Blocks.isTargetable(id)
			end,
			outlineAt
		)
		if hit == nil or not isFluid(hit.block) then
			return nil
		end
		local dx, dy, dz = hit.x + 0.5 - body.X, hit.y + 0.5 - body.Y, hit.z + 0.5 - body.Z
		if dx * dx + dy * dy + dz * dz > REACH * REACH then
			return nil
		end
		return hit
	end

	local pickedEntity: Entity? = nil
	local pickedFluid: VoxelRaycast.Hit? = nil
	-- The first block on the aim, in reach or not (it hides the entities behind it).
	local pickedWall: number? = nil
	local lastPick = -math.huge
	-- The aim's origin and the body (world blocks, doubles), refilled at every pick.
	local origin: Point = { X = 0, Y = 0, Z = 0 }
	local body: Point = { X = 0, Y = 0, Z = 0 }

	local function pick()
		pickedEntity, pickedFluid, pickedWall = nil, nil, nil
		if not (SHOW_ITEMS or SHOW_PLAYERS or SHOW_FLUIDS) then
			return
		end
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		local point = aimPoint()
		if point == nil or rootPart == nil or not rootPart:IsA("BasePart") then
			return
		end
		local ray = workspace.CurrentCamera:ViewportPointToRay(point.X, point.Y)
		-- (The camera and the root are render studs: world blocks from them, as doubles.)
		origin.X, origin.Y, origin.Z = Origin.renderToBlocks(ray.Origin)
		local direction = ray.Direction
		body.X, body.Y, body.Z = Origin.renderToBlocks(rootPart.Position)
		local spectating = GameMode.isSpectator(ClientInventory.mode())
		-- (BlockInteraction's limit: the camera's distance to the player plus the reach.)
		local maxDistance = (ray.Origin - rootPart.Position).Magnitude / BLOCK + REACH
		if SHOW_ITEMS or SHOW_PLAYERS then
			-- BlockInteraction's ray without its reach check: a block too far to target still hides
			-- what is behind it.
			local wall = VoxelRaycast.cast(
				origin.X,
				origin.Y,
				origin.Z,
				direction.X,
				direction.Y,
				direction.Z,
				maxDistance,
				getBlock,
				Blocks.isTargetable,
				outlineAt
			)
			pickedWall = if wall then wall.distance else nil
			pickedEntity = pickEntity(origin, direction, maxDistance, body, spectating)
		end
		if SHOW_FLUIDS and not spectating then
			pickedFluid = pickFluid(origin, direction, maxDistance, body)
		end
	end

	--[[ Every frame ]]

	-- (The GUI's size follows the viewport's; the corner follows the scale, the minimap, F3.)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	UiScale.hudChanged:Connect(layout)

	-- The world map hides the HUD (Hud.setVisible); WAILA is part of the HUD, so it hides with it.
	local function hudShown(): boolean
		return UiScale.hudShown()
	end

	RunService.RenderStepped:Connect(function()
		if not enabled or Screens.isOpen() or not hudShown() then
			hide()
			return
		end
		local now = os.clock()
		if now - lastPick >= PICK_INTERVAL then
			lastPick = now
			pick()
		end
		local extended = DebugOverlay.isOpen()
		local hit = BlockInteraction.target()
		local progress = BlockInteraction.miningProgress()
		local entity = pickedEntity
		if entity and entity.player and entity.player.Parent == nil then
			-- (Left the game since the last pick.)
			entity = nil
		end
		local fluid = pickedFluid
		local choice = WailaInfo.choose(
			if hit then hit.distance else nil,
			progress ~= nil,
			if entity then entity.distance else nil,
			pickedWall,
			fluid ~= nil
		)
		if choice == "entity" and entity then
			showEntity(entity, extended)
		elseif choice == "block" and hit then
			showBlock(hit, progress, extended)
		elseif choice == "fluid" and fluid then
			showFluid(fluid, extended)
		else
			hide()
		end
	end)
end

return Waila
