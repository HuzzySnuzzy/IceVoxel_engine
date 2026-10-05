# IceVoxel

A fast, Minecraft-style voxel engine for Roblox.

- **Client-side generation in parallel.** Terrain is generated from the world seed on every
  client, inside a pool of Actors (Parallel Luau). The server never sends terrain, only edits.
- **Level of detail.** A quadtree of chunk sizes gives a default view distance of 2048 blocks
  (128 chunks). Far chunks use cells up to 64 blocks wide (but at most 16 tall, so mountains keep
  their shape). LOD changes swap in place without holes or flicker.
- **Greedy box meshing.** Blocks become as few Parts as possible; blocks you can never see are
  merged into neighbouring boxes for free, and caves are only meshed when the camera is underground.
- **Terrain like JJThunder To The Max.** A 1024 block tall world in the style of the Minecraft
  datapack: mountain ranges up to ~900 blocks high with snowy peaks, eroded flanks and plateau
  hills, plains, wide river valleys and enclosed seas with islands. Its height functions are ported
  directly and scaled to fit. 18 biomes are picked by altitude band (lowland, forest, highland,
  meadow, alpine, snowy slopes, peaks), then by climate.
- **Caves, ores and structures.** Dry caves that grow with depth, from tunnels to huge stratified
  caverns, and the Underlands: a cavern hundreds of blocks tall under the highest mountains. Ores and
  stone varieties by altitude, and a deterministic structure system (trees and cacti, and jigsaw
  structures from the structure library: see Generated structures) that lets anything cross chunk
  borders.
- **Four game modes.** Minecraft's survival, creative, adventure and spectator, switched with
  `/gamemode <mode>` (`/gm s`, `c`, `a`, `sp`, or `0`–`3`) in the chat, `F3` + `N` (spectator and
  back) or the `F3` + `F4` game mode switcher.
  - **Survival:** blocks take Minecraft's time to mine, by hand or with tools, cracking as they
    go, and drop as items that bob on the ground until someone walks over them. Stone and ores need
    a pickaxe of the right tier to drop anything (iron and osmium ore a stone pickaxe, diamonds an iron one),
    and tools wear out. Placing uses items up. Players have a Minecraft inventory: 36 slots, armor
    slots on the left and a 2 × 2 crafting grid at the top right; chests, crafting tables and
    furnaces open above it. Clicks work as in Minecraft: shift-click, number keys, dragging to
    spread, double click. Items drop on death.
  - **Creative:** an old-school "Item selection" picker with a search bar, instant breaking, flying
    (double tap jump), and nothing hurts.
  - **Adventure:** survival without building: blocks can't be broken or placed and items can't be
    used on them (buckets, the Configurator), and no block is outlined; chests, furnaces, crafting
    tables and machines still open. Health, falls, pickups, the inventory and death drops are
    survival's.
  - **Spectator:** always flies, through blocks and water, from the bottom of the world to 64
    blocks above its top (the mouse wheel sets the flying speed); nothing hurts. Players who don't
    spectate neither see nor hear a spectator (other spectators see a translucent floating head).
    Spectators pick up and change nothing, look into chests, furnaces and machines read only, and
    keep their inventory if they die. Instead of the hotbar, a number key or the middle click
    opens Minecraft's spectator menu: `1` "Teleport to Player" lists the other players' heads (7
    on the first page, then 6 a page), a player's number pressed twice teleports there, `9`
    closes it. A left click on a player looks through their eyes until you sneak. Switching from
    spectator to survival or adventure inside a block suffocates you (half a heart every half
    second) until you get out, as in Minecraft.
- **Game mode switcher and debug keys.** Minecraft's `F3` + `F4` switcher: hold `F3`, press `F4`
  to step through Creative, Survival, Adventure and Spectator (or point at one) and let go of `F3`
  to switch. `F3` + `N` toggles spectator and the previous mode, `F3` + `Q` lists the keys in the
  chat, and `F3` alone opens the debug overlay when let go. Who may switch is
  `Gameplay.GameModeCommand`, as for `/gamemode`; without the permission the keys say so
  ("[Debug]: Unable to open game mode switcher; no permission").
- **Crafting and smelting.** Minecraft's recipes for everything the game has: planks, sticks,
  crafting tables, chests, furnaces, wooden to diamond tools, shears, iron, gold and diamond armor,
  storage blocks, stone bricks and polished stones. Shaped recipes fit anywhere in the grid and
  mirrored, shift-click crafts as many as possible, and two worn tools repair into one. Furnaces
  smelt raw ores, sand, cobblestone and logs with Minecraft's fuel times, and keep cooking while
  nobody watches.
- **Just Enough Items.** Next to every inventory screen (the inventory, chests, crafting tables,
  furnaces, the creative picker), a JEI-style list of every item, a page at a time, with a search
  box. Click an item, or press `R` over any item (in the list, a slot, the hotbar or a recipe), to
  see how it is made; right click or `U` shows what it is used for: crafting recipes on a 3 × 3
  grid (an ingredient any planks will do for cycles through them), smelting with its 10 seconds,
  and fuels with how many items they smelt. On a crafting table, a furnace, a Heat Generator or an Electric Furnace, `U` also lists every
  recipe made in it (JEI's catalysts). Items inside a recipe open their own recipes,
  `Backspace` goes back and `E` or `Escape` returns to the inventory. The `+` beside a crafting
  recipe moves its ingredients from the inventory into the open crafting grid (`Shift`: as many
  sets as you have); when it is greyed out, hovering it says why and shows what is missing. In
  creative, `Shift` + click gives a full stack.
- **Day and night.** Minecraft's 20 minute day (24000 ticks: sunrise 0, noon 6000, sunset 12000,
  midnight 18000), with the sun at Minecraft's angle for the time and light that always matches the
  sun on screen. Roblox's Future lighting with shadows replaces the old fullbright look: warm
  sunrises and sunsets, dark blue nights you can still find your way in (Minecraft's night sky
  light of 4), and caves and closed rooms that stay dark at any time of day unless you light them.
  A tunnel dug into a hillside darkens with the distance from its mouth, not the depth of the rock
  above it. `/time` and `/gamerule doDaylightCycle` work as in Minecraft.
- **Torches, lanterns and the Glow Block.** Light sources for the dark: torches (light 14) stand on
  blocks or hang on walls, leaning out like Minecraft's; lanterns (15) stand on a block or hang
  under one; the Glow Block (15, the game's blue stand-in for glowstone) is a glowing full block.
  Each gives off a Roblox PointLight. With `Config.Render.Shadows` on, a torch's or lantern's light
  stops at walls; the Glow Block casts a shadow like any full block (a roof of them keeps the sun
  out), so its own light has none and reaches
  through a wall within its range. Torches and lanterns need a sturdy block to hang on, as in
  Minecraft (not leaves, a chest or a cactus), pop off and drop when that block goes, and flowing
  water washes torches away. Players walk through lanterns (in Minecraft they bump into them), but
  a lantern can't be placed inside a player. Recipes: 4 torches from coal or charcoal over a stick,
  a lantern from 8 iron nuggets around a torch, a Glow Block from 4 Glow Dust (it breaks into 4
  again). **Glow Dust** is the game's blue glowing dust, in place of Minecraft's glowstone dust (the
  game has no Nether): glow lichen in caves drops it.
- **Foliage.** Minecraft 1.20.1's ground plants: short grass, ferns, tall grass and large ferns,
  dead bushes, twelve flowers (dandelion, poppy, blue orchid, allium, azure bluet, four tulips,
  oxeye daisy, cornflower, lily of the valley), four two-block tall flowers (sunflower, lilac,
  rose bush, peony) and brown and red mushrooms. Biomes grow them in full detail chunks as
  Minecraft's vegetal decoration does: patches of grass with clearings between them, ferns and
  large ferns in taigas, savanna grass tinted dry, flower patches of one or two species (plains,
  forests, meadows; blue orchids in jungles, as there are no swamps), dead bushes in deserts and
  mushrooms on mycelium and in old growth taigas. They stand on Minecraft's soils (grass, dirt,
  podzol, mycelium...; dead bushes also on sand; mushrooms on mycelium, podzol or any solid opaque
  block), break at once, pop off with their drops when their soil goes and wash away in flowing
  water; grass, ferns and dead bushes can be built over (but Short Grass clicked on short grass
  goes beside it). A tall plant needs room for its top and is placed and broken whole, with one
  drop. By hand grass and ferns drop nothing and a dead bush drops a stick; flowers and mushrooms
  drop themselves. Shears (2 iron ingots on a diagonal, 238 uses) harvest grass, ferns, dead
  bushes and leaves (tall grass gives 2 short grass, a large fern 2 ferns), cut leaves at once and
  wear on every block they break, once per tall plant.
  Each plant is a few thin boxes (at most 4 parts): splayed blades and fronds in shades of green,
  or a stem with a head in Minecraft's colours; grass and ferns take a savanna yellow-green on dry
  grass. Plants are drawn a few pixels off their cell's centre and turned, by a hash of their
  position, so fields don't look like grids (both halves of a tall plant alike; the sunflower
  always faces east); the outline stays on the cell. Every box is a part, so plants are drawn
  within 40 blocks (24 on phones): about 1,000-3,000 parts on grassland, at most 6,000.
  `Config.Render.Foliage = false` stops drawing them on slow devices; they are still there to aim
  at and break. Left out: Minecraft's light check for mushrooms, seeds from grass (there is no
  wheat) and the plants the game has no blocks for (saplings, sugar cane, berry bushes, lily pads,
  vines, seagrass); plants are sparser than in Minecraft, to keep the part count down.
- **Structure blocks.** Minecraft 1.20.1's structure blocks, to save what you build as text and
  place it again. They, structure voids and jigsaw blocks are operator blocks: only creative players
  may place, use and break them, and only the game's owner, `Gameplay.Admins`, Studio sessions and
  the user ids in `Config.Structures.Permission` (none by default); survival players can't mine them
  and they never drop. Right click opens Minecraft's screen, whose mode button cycles Save, Load,
  Corner and Data; the block is its mode (its faces show the mode's sigil), so everyone sees it.
  **Save** has a name (`mything/houses/hut`: letters, digits and `_ . / : -`), a relative position
  (-48..48 from the block, default 0, 1, 0), a size (up to 48 × 48 × 48) and "Show Invisible Blocks"
  (blue markers on the region's air); the region is outlined, with the name over the block. DETECT
  fits the region between two Corner blocks of the same name within 80 blocks (the inside of their
  box); SAVE captures it: air is saved as air (it clears the world where the structure goes), a
  **structure void** (a small translucent cube, not solid, saved as "keep") leaves whatever is
  there, Data blocks become data markers with their string, jigsaws keep their settings, blocks with
  slots their items (item data, such as a tank's water, is not kept), and cave air and generated
  glow lichen are saved as their surface forms. **Load** places a structure by name (saved this
  session, or in the structure library) or from data pasted into its screen, with a rotation (0, 90,
  180, 270), a mirror, an integrity (the share of blocks placed, drawn from a seed; 0 picks one) and
  "Show Bounding Box". As in Minecraft the first LOAD of a template of another size only sets the
  size ("position prepared": the outline shows where it goes) and the next places it, a couple of
  thousand blocks a frame, turning torches, lichen and jigsaws with it. **Corner** is a name,
  **Data** a marker string. Unlike Minecraft the screen stays open after DETECT, SAVE and LOAD and
  repeats the answer on its status line; Done keeps the fields and closes, Cancel, `Escape` and `E`
  drop them. Outlines and labels show only in creative. WAILA names a structure block's mode and
  name.
- **Structure data.** SAVE turns a structure into compact text, "IVS1:" and base64url (letters,
  digits, `-` and `_`), which pastes into chat and into a Luau string as it is: the palette by block
  name (so it survives new blocks; an unknown name loads as air, with a warning), the cells as runs
  or bit-packed, jigsaws, data markers, container items and a checksum, so a cut or damaged paste
  says so ("The structure data is cut off: ... Copy all of it"). A 7 × 5 × 7 hut is about 250
  characters, a 16 × 10 × 16 house about 1,150, and any 48 × 48 × 48 structure fits a StringValue
  (~150,000 at most; `Structures.MaxDataChars`). The chat says "Saved structure '<name>' (N blocks,
  M characters)" and the text appears in a read only box in the Save screen: click it and press
  `Ctrl` + `C` (`Cmd` + `C`) to copy it (Roblox scripts can't write the clipboard). Long data comes
  in parts of 16,000 characters ("part 2 of 9"), copied in order. Each save is also kept for the
  session by name (256 saves, 32 MB at most) and, while kept, as a StringValue named after it in
  `ServerStorage.IceVoxelSavedStructures`, to copy during a Studio playtest. Text pasted into a Load
  screen is checked as you paste (its name, size and block count, or what is wrong with it) and
  uploaded in pieces. `lune run tests/structure decode` prints any data as ASCII layers (see
  Extending).
- **Jigsaw blocks.** Minecraft's jigsaw blocks join structure pieces. One faces out of the clicked
  face (a jigsaw facing up or down has its top towards the player); its front shows the puzzle piece
  with its knob towards the top, the face towards the top a bar (the lock) and the other three faces
  around the front arrows pointing at it, so the orientation reads from any side. Its screen sets
  the target pool (where the pieces attached here come from), its name, the target name (the jigsaw
  of a piece that attaches here), "Turns into" (the block it becomes once generated, default air)
  and, for vertical fronts, the joint (rollable or aligned). Generate builds from the pool right
  there, Minecraft's JigsawPlacement up to Levels (0..7) deep, and Keep Jigsaws (on by default, as
  in Minecraft) leaves the jigsaws in place; pieces saved minutes ago are already in their pools.
  Pools need no code: pieces named `mything/houses/a` and `mything/houses/b` make the pool
  `mything/houses`. Data made to waste time stops with "the structure is too big". WAILA names a
  jigsaw's name, target and pool.
- **Generated structures.** Templates in the structure library (`src/shared/StructureLibrary/`, or
  StringValues in the place's `ReplicatedStorage.IceVoxelStructures` folder) generate in the world
  as Minecraft's jigsaw structures do: one start per region of `spacing` × `spacing` chunks, at
  least `separation` apart (random_spread), kept when the start piece's centre is in one of the
  structure's biomes and on dry land that is not bare rock, then assembled from its pools: the start
  piece stands on the ground at its centre, rigid pieces line up with the jigsaw they attach to,
  terrain matching ones (paths) follow the ground column by column, and air or water under a rigid
  piece's floor becomes a foundation of the ground's filler (12 blocks at most). Like trees they are
  stateless and cross chunk borders, show from afar up to `Config.StructureMaxLevel`, keep trees out
  of their way, clear the ground with their air and leave it where they hold structure voids; their
  chests start with the template's items (filled the first time they are opened, read by a pipe or
  broken). The example **outpost** is a watchtower plaza (or its overgrown ruin, with a forgotten
  chest) with lantern posts, paths that follow the ground and end in a lamp post or fade out, and
  along them a hut, a storehouse with a chest of supplies, an open forge and a woodpile: at most one
  per 896 × 896 blocks, in plains, savannas, meadows and forests. With `Config.Structures.Generate`
  false none generate.
- **Glow lichen.** Minecraft's glow lichen grows in patches on cave walls and ceilings 13 blocks or
  more below the surface (about 3% of them, some 20 per chunk), with light 7 in a cool yellow green.
  Each is a thin plate on its face with a glowing Neon speck: 2 parts. One lichen per 8 × 8 × 8
  blocks carries a PointLight, which shines at any distance, so a revealed cave holds a few hundred
  lights instead of thousands (`Caves.LichenLightDistance` can switch far ones off on slow devices).
  It drops 2 Glow Dust (by hand or with any tool; an axe breaks it fastest), or itself with Shears;
  it is replaceable, washes away in flowing water, and placed by hand it lies on the floor or hangs
  on a ceiling or wall like a torch (one face per block). Generated lichen counts as cave air while
  caves are hidden, so a cave's lichen costs nothing until you are in it.
- **Seeing caves further.** Underground, caves are revealed 64 blocks around the camera and up to
  128 in big caverns such as the Underlands (was 48 to 96), and full detail chunks, the only ones
  with caves, reach about 128 blocks instead of 96 while the camera is below the surface and for 5
  seconds after it comes up (`Lod.UndergroundSplitDistanceL1`), so walking in and out of a cave
  mouth doesn't rebuild the chunks around it. Phones reveal 48 to 96 blocks, with full detail to
  about 96. In a cave near the spawn that is 268 full detail chunks instead of 164, and about 57,000
  parts instead of 47,000 before far meshes. F3 shows how far caves are revealed and how many lichen
  lights there are.
- **Mekanism pipes.** Mekanism 10's transmitters, for what the game has. Logistical Transporters
  (Basic, Advanced, Elite, Ultimate) carry items between chests, furnaces and machines, and you see
  them move: a side set to pull with the Configurator takes 1 / 16 / 32 / 64 items every half
  second, which travel at 1 / 2 / 4 / 10 blocks a second along the cheapest route (faster
  transporters cost less) to an inventory that takes them. Furnaces and machines follow Mekanism's
  machine rules on every side: transporters put ore and fuel in through any side (what smelts into
  the input, fuel into the fuel slot, logs into the input first and then the fuel; nothing else
  goes in) and only ever take the results out (and an empty bucket left in a fuel slot), never the
  ore or fuel you put in. Furnaces and machines push their results out on their own every half
  second, a stack at a time (Mekanism's ejector): into a chest next to them, or into a transporter
  next to them whose side is normal or pull (never push or none), which only takes them when they
  have somewhere to go (never back in) and colours them; never straight into another furnace or
  machine, though transporters can lead them there. Restrictive Transporters are only used when
  there is no other way. Transporters coloured with the Configurator (Minecraft's 16 dyes) only
  join their own colour or uncoloured ones, and the items they pull keep their colour: they travel
  through uncoloured transporters and ones of their colour only (items pulled by an uncoloured
  transporter stay off coloured ones), to keep lines apart. Mechanical Pipes move water between
  Fluid Tanks (32 000 to 256 000 mB) at Mekanism's rates, and Minecraft's Bucket and Water Bucket
  carry it to and from tanks and the world. The Configurator cycles a side between normal, push,
  pull and none (right click) and a transporter's colour (sneak + right click). Recipes follow
  Mekanism's shapes with the game's materials (gold, diamond and emerald stand for its alloys).
  Players walk through transmitters, as through lanterns; their state and the tanks' water live in
  memory, like chests. Pressurized Tubes and Thermodynamic Conductors are not included: the game
  has no gas or heat (Universal Cables: see Electricity).
  Items that no inventory takes go back to the one they came from (a furnace's or machine's results
  never do), or wait in their transporter until one turns up; a broken transporter drops what is in
  it. Pipes join into networks that share their water (breaking a pipe loses its share), and both
  keep working where no player is, like furnaces.
  You see how they are set: transmitters grow arms towards what they connect to, ending in a
  collar between two of them and in a plate on a chest, furnace or tank; where a side pulls from
  or pushes into one of those the arm has a blue (pull) or orange (push) band, and coloured
  transporters are tinted their colour. Items glide through the transporters; pipes and tanks
  show their water. The Configurator acts on the arm you point at (or the face of the core);
  WAILA names that side's mode, a transporter's colour and the items inside it, and the water in
  a pipe or tank.
- **Electricity.** Mekanism's energy, counted in joules (J, kJ, MJ, GJ). Universal Cables (Basic,
  Advanced, Elite, Ultimate) join machines into energy networks; a network moves at most the sum
  of its cables' capacities a tick (8 kJ, 128 kJ, 1.02 MJ and 8.19 MJ per cable, Mekanism's
  numbers), and machines that touch each other need no cable at all. Every tick, generators give
  what they hold up to their output rate, shared out evenly among the machines that need it (up
  to their input rates, Mekanism's even split); what is left over charges batteries, and when the
  generators fall short the batteries cover the rest: backup power. Energy is counted exactly and
  never made or lost on the way. The Configurator cuts a cable's side (none) as on pipes; push and
  pull act as normal (WAILA says "Push (as Normal)"). Right click opens a machine's panel with
  Mekanism's energy bar (red when empty to green when full, full only when it is, "stored /
  capacity" on hover); WAILA shows a machine's energy and what it is doing ("Producing 200 J/t",
  "Using 50 J/t", "No power", "Night") and a cable's capacity. A machine broken in survival keeps
  its energy in its item ("Energy: 1.2 MJ") and gets it back when placed; its slots drop like a
  chest's. The Creative Energy Cube (creative only, no recipe) gives infinite energy for trying
  machines out.
  Recipes: 8 Basic Universal Cables from an osmium ingot, glow dust and an osmium ingot in a
  row (Mekanism: steel, redstone, steel); 8 cables around a gold ingot, a diamond or an emerald
  make 8 of the next tier. Like chests, energy lives in memory.
- **Heat Generator.** Mekanism Generators' Heat Generator burns furnace fuel for electricity: put
  coal, charcoal, wood or anything else a furnace burns in its fuel slot (by hand, shift-click or a
  transporter, through any side; transporters never take it back out) and for as long as the item
  would burn in a furnace it makes 200 J a tick (Mekanism's numbers), so a coal is 320 kJ and a
  plank 60 kJ. It stores 160 kJ and gives up to 400 J/t to the cables and machines around it. It
  burns only as much as it has room for, so a machine using less than 200 J/t still gets all of
  each item's energy; full, it stops, keeping what is left of the item, and goes on as soon as
  energy is taken. Its panel shows the fuel slot under a flame (the burn time left),
  "Producing 200 J/t" or "Idle", and the energy bar; WAILA says the same, and while it burns the
  window on its sides glows and it crackles like a lit furnace. Broken with a pickaxe it keeps its
  energy and what is left burning in its item ("Energy: 80 kJ", "Fuel: 60 s"). Recipe: Mekanism's
  with iron for its copper, three iron ingots over planks, an osmium ingot and planks, over iron, a
  furnace and iron. JEI lists every fuel under its uses. Mekanism's lava and nether bonuses don't
  apply.
- **Electric Furnace.** Mekanism's Energized Smelter, named the Electric Furnace, smelts what a
  furnace smelts on electricity instead of fuel: 50 J a tick for 200 ticks an item (Mekanism's
  numbers), so an item takes a furnace's 10 seconds and costs 10 kJ, and a coal burnt in a Heat
  Generator smelts 32. It stores 20 kJ and takes as much as its network gives it in a tick (as
  fast as the cables carry). It works only with a whole tick's energy: without power, or with no
  room in its output, it stops where it is and goes on when that changes; taking its input out,
  or putting something else in, starts the item over. What smelts goes into its input by hand,
  shift-click or a transporter through any side, and the results come out of its output by hand,
  shift-click or a transporter pulling from any side, and it pushes them out on its own into a
  chest or transporter next to it (Mekanism's machine rules, as furnaces have them). Its panel
  shows the input, the arrow, the output and the energy bar with "Using 50
  J/t", "No power", "Output full" or "Idle"; WAILA says the same. While it smelts the heating
  chamber on its sides glows, steadily even when too little power makes it stop and start
  (Mekanism's 3-second deactivation delay). Broken with a pickaxe it keeps its energy in its
  item ("Energy: 12 kJ"); its slots drop. Recipe: Mekanism's shape with glow dust for the
  redstone, osmium ingots for the control circuits and a furnace for the steel casing: glow
  dust, an osmium ingot and glow dust, over glass, a furnace and glass, over the top row
  again. JEI lists every smelting recipe under its uses. It takes Speed and Energy Upgrades (below).
- **Solar Panel.** Mekanism Generators' Solar Generator, named the Solar Panel: a thin panel of four
  dark blue cells on a short post (no full cube, as Mekanism's; players walk through it, as through
  a cable). While nothing opaque stands anywhere above it (glass, torches, cables, other panels and,
  unlike Minecraft, water let the sun through; leaves and ice don't) and it is day on the server's
  clock (Minecraft's isDay: from a little after sunrise to a little before sunset), it makes up to
  50 J a tick, scaled by how high the sun stands (Mekanism's sun brightness: all of it from mid
  morning to mid afternoon, a little under half just before night), about 620 kJ a day. It stores
  96 kJ and gives up to 100 J/t to the cables and machines around it. Its panel and WAILA say
  "Producing 50 J/t", "Full", "Night" or "No sky"; its panel also has its upgrade slots. Broken
  with a pickaxe it keeps its energy in its item. Recipe: Mekanism's shape with glass for the
  solar cells, gold ingots for the alloy, osmium ingots for the osmium dust and glow dust for
  the energy tablet: three glass, over a gold ingot, an iron ingot and a gold ingot, over an osmium
  ingot, glow dust and an osmium ingot. Mekanism's biome and rain factors don't apply (the
  game has no weather).
- **Upgrade cards.** Mekanism's Speed Upgrade and Energy Upgrade, which stack to 8 here (the most a
  machine takes of each; Mekanism's stack to 64). Recipes: Mekanism's shape with the ingots for its
  dusts and gold for its alloy: glass, over a gold ingot, an osmium ingot (speed) or a gold ingot
  (energy) and a gold ingot, over glass. The Electric Furnace and the Solar Panel take up to 8 of
  each in two slots at the lower left of their panels, by hand or shift-click (transporters never
  touch them); an empty slot shows the card's outline. Mekanism's maths: with n Speed and e Energy
  Upgrades an Electric Furnace takes 200 x 10^(-n/8) ticks an item (149 with one card, 20 with 8)
  at 50 x 10^((2n - e)/8) J a tick and stores 20 kJ x 10^(e/8), so 8 Speed Upgrades smelt ten
  times as fast for ten times the energy an item, and 8 of each ten times as fast for the usual
  10 kJ. A Solar Panel (Mekanism's take none) makes and gives out 10^(n/8) times as much (8 cards:
  500 J/t in full sun) and stores 96 kJ x 10^(e/8) (8 cards: 960 kJ). Taking cards out applies at
  once: energy over a smaller store is lost. The cards drop when the machine is broken (Mekanism
  keeps them in its item), so a machine placed again holds at most its base store.
- **Batteries.** Mekanism's Energy Cubes, named Batteries: Basic, Advanced, Elite and Ultimate
  store 4, 16, 64 and 256 MJ and take in and give out up to 4, 16, 64 and 256 kJ a tick
  (Mekanism's numbers). They are the backup power: every tick, what the generators have left after
  the machines took what they need charges the batteries on the network, and when the generators
  fall short (a Heat Generator out of fuel, a Solar Panel at night) the batteries cover what the
  machines still need, so an Electric Furnace on a battery smelts on through the night and the
  battery charges again when the sun comes up or the generator gets fuel. Batteries never charge
  each other. Joined like any machine, by Universal Cables or touching (a network moves no more a
  tick than its cables carry together: on a single Basic cable a battery charges at 8 kJ/t at
  most). Its panel shows the energy bar with "Charging 150 J/t", "Discharging 50 J/t", "Full",
  "Empty" or "Idle" and what went in and out last tick; WAILA says the same, and the gauge on each
  of its sides fills with its charge, red when nearly empty to green when full. Broken with a
  pickaxe it keeps its charge in its item ("Energy: 1.23 MJ", and an energy bar where a tool's
  durability bar goes), so batteries stack to 1, and placed again it has it back. Recipes:
  Mekanism's shapes with glow dust for the redstone, Glow Blocks for the energy tablets, a
  block of iron for the steel casing and gold ingots, diamonds and emeralds for the alloys: the
  Basic Battery is glow dust, a Glow Block and glow dust, over an iron ingot, a block of
  iron and an iron ingot, over the top row again; each next tier puts the tier below in the
  middle, Glow Blocks above and below it, osmium ingots, gold ingots or diamonds beside it and gold
  ingots, diamonds or emeralds in the corners, and keeps its charge (Mekanism's upgrade recipes
  do). Mekanism's charge and discharge slots and side configuration are not in.
- **Osmium.** Mekanism's metal: Osmium Ore (blue-grey speckled stone, hardness 3) needs a stone
  pickaxe or better and drops Raw Osmium, which smelts into an Osmium Ingot (the ore smelts too).
  Nine nuggets make an ingot, nine ingots a Block of Osmium and nine raw osmium a Block of Raw
  Osmium (both hardness 7.5, as in Mekanism), and each unpacks again. The ore generates in small
  veins in all rock, plus Mekanism's "middle" veins concentrated around y 100: about as much as
  iron below y 197 and about half as much in the mountains above.
- **Item data.** Items carry a little data of their own, Minecraft's item NBT kept flat: up to 16
  named numbers, strings or flags. A Fluid Tank broken in survival keeps its water in its item
  ("Water: 12,000 mB" under its name in the inventory) and gets it back when placed again, as in
  Mekanism; in creative, placing a tank item that holds water fills the new tank too. Items with
  different data never stack, and wherever a stack goes (clicks, chests, furnaces, transporters,
  the ground, death drops) its data goes with it.
- **Items drawn in 3D.** Every icon (hotbar, inventory, creative picker) is a small 3D model in a
  ViewportFrame with the same look as the block in the world. Dropped items and the item in a
  character's hand are drawn the same way.
- **WAILA (What Am I Looking At).** A panel at the top of the screen names what the crosshair
  points at, like the Jade mod: the block's icon and name, the tool and tier it needs with a
  green check or red cross for the item in hand ("Requires Iron Pickaxe"), the mining progress
  as a line along its bottom edge, and "IceVoxel" as the mod name. It also names dropped items,
  other players (health, game mode) and water when no block is in reach. While `F3` is open it
  shows everything the game knows about the block: id, position and chunk, biome, hardness,
  tool, drops with the held item and by hand, break time, light, fluid level, render kind,
  friction and menu.
- **Sounds.** Minecraft's sound events for everything that should make a sound: breaking, placing
  and mining blocks (by material: stone, wood, gravel, grass, sand, glass, snow, metal, wool,
  water), footsteps every 1.67 blocks (yours and other players'), hurting landings, splashing and
  swimming, chest lids, the furnace you are using crackling while it burns, items picked up, tools
  breaking, armor put on, getting hurt and dying, interface clicks and a rare rumble deep in caves.
  They are stand-ins made from the sounds every Roblox client ships, told apart by pitch, so
  nothing has to be uploaded, and players hear what others do within 16 blocks. Each one can be
  replaced by your own sound (see Extending).
- **Server-authoritative interaction.** Mining, placing and every inventory click are predicted on
  the client and validated by the server: timing, reach, what the player holds. Block updates power
  falling sand and gravel (which break into an item on a torch or a flower, Minecraft's torch
  trick), flowing water (Minecraft rules, including infinite sources), grass turning into dirt and
  plants popping off when their soil goes.
- **Minecraft movement.** Players are a 0.6 × 1.8 block hull moved through the block data with
  Minecraft Java Edition's physics, tick for tick at 20 ticks per second: walking, sprinting
  (Ctrl toggles it, or double tap forward) with Minecraft's widening field of view, sneaking that
  never walks off edges, crouching and crawling under low ceilings, 1.25-block jumps, sprint
  jumping, slippery ice, swimming (sprint under water, steered by the view), currents, hopping out
  of water and fall damage. Steps up to just over a block are walked up without jumping, so the
  steep terrain is walkable (`Config.Movement.StepHeight`; Minecraft's is 0.6). The Roblox
  character is purely cosmetic: it is drawn on the hull (interpolated) and never collides with
  anything.
- **Water that finds the way down.** Like Minecraft, water spreads only towards the nearest drop
  up to 5 blocks away, so it runs down slopes instead of flooding the ground around it. Flowing water
  steps down level by level, and its current pushes the player downstream.
- **Minimap and world map.** Painted straight from the generator, so the map shows the whole world.
  Right click the map to add waypoints (saved between sessions), teleport, or center the view.
- **Safe spawns.** Spawns and teleports never land in water, on leaves or next to cacti; the rules
  live in `SpawnUnsafeBlocks`.
- **Textures.** Optional per-block textures through MaterialVariants, tiled once per block.
- **Far meshes.** Regions of distant chunks that stopped changing are merged into a few MeshParts
  built with EditableMesh ("superchunks"), replacing thousands of parts: at the default view,
  81k parts become 35k parts + 90 meshes in the mountains. Parts stay the fallback, so nothing breaks
  where the Mesh APIs are unavailable.

## Getting started

1. Install the toolchain with [Rokit](https://github.com/rojo-rbx/rokit):
   ```sh
   rokit install
   ```
2. Either live-sync into Studio:
   ```sh
   rojo serve
   ```
   and connect with the Rojo Studio plugin, or build a place file and open it:
   ```sh
   rojo build -o IceVoxel.rbxlx
   ```
3. Press Play.

Studio tips:
- Delete the template's `Baseplate`; the world starts at y = 0 and the baseplate only sits under it.
- New places come with an `Atmosphere` in Lighting, which adds haze to the far LOD chunks. Without
  one, IceVoxel uses distance fog at the edge of the view distance instead.
- How far parts are drawn is up to the engine, not the script: it depends on the graphics quality
  level and how many objects are on screen. Studio ignores that limit, so judge long views in the
  Roblox player with a high graphics level. Phones draw far less (a few hundred studs), which is why
  they get a shorter view distance (`Lod.Mobile`).

## Controls

| Action        | Mouse / keyboard            | Gamepad | Touch      |
| ------------- | --------------------------- | ------- | ---------- |
| Break block   | Hold left click (survival mines, creative breaks at once; adventure and spectator break nothing) | R2 | Hold |
| Place / use   | Right click (opens chests, crafting tables, furnaces, machines; adventure and spectator only open them) | L2 | Tap |
| Select slot   | `1`–`9`, mouse wheel, or click a slot (spectator: the spectator menu) | L1 / R1 | Tap a slot |
| Place a torch / lantern | Right click: the top of a block stands it, a side hangs a wall torch, the underside hangs a lantern | L2 | Tap |
| Configure a pipe | Right click a transmitter's arm or core face with the Configurator: normal → push → pull → none (Universal Cables only tell none apart); `Shift` + right click a transporter: next colour | L2 | Tap |
| Buckets       | Right click water or a fluid tank with a bucket to fill it; right click a block or tank with a water bucket to empty it | L2 | Tap |
| Structure / jigsaw block (creative) | Right click: its screen; `E` / `Escape` close it (Cancel), Done keeps the fields; click the saved data box, then `Ctrl` + `C` (`Cmd` + `C`) copies it | L2; B closes | Tap |
| Place a jigsaw | Right click a face: the jigsaw faces out of it (on a top or bottom face, its top points back at you) | L2 | Tap |
| Pick block    | Middle click (spectator: the spectator menu) |  |      |
| Drop item     | `Q` (`Ctrl` + `Q`: the whole stack; not while `F3` is held) | D-pad down |    |
| Inventory     | `E` (creative: the item picker; spectator: none) | Y   | `…` button |
| Fly (creative) | Double tap `Space`; `Space` / `Shift` up / down | double tap A | double tap jump |
| Fly (spectator) | Always, through blocks; `Space` / `Shift` up / down, sprinting (`Ctrl`) twice as fast; mouse wheel (spectator menu closed): flying speed | A / B | Jump / Sneak |
| Spectator menu | `1`–`9` or middle click open it, then a number selects and the same number again (or middle click) uses; the wheel moves the selection | L1 / R1 open and move, D-pad up uses | `…` button; tap a slot |
| Spectate a player (spectator) | Left click them; `Shift` leaves | R2; B leaves | Hold on them; Sneak button leaves |
| Game mode     | `/gamemode survival` / `creative` / `adventure` / `spectator` (or `/gm s` / `c` / `a` / `sp`, `0`–`3`) in the chat; `F3` + `N`: spectator ↔ the previous mode | | |
| Game mode switcher | Hold `F3`, press `F4` (each further `F4`: the next mode; or point at one), let go of `F3` to switch; `Escape` cancels | | |
| Sprint        | `Ctrl` turns it on / off, or double tap `W` | L3 (stick press) | Sprint button (toggle) |
| Sneak         | Hold `Shift` (never walks off edges) | B | Sneak button (toggle) |
| Jump          | `Space` (hold to keep jumping) | A    | Jump button |
| Swim up / down | Hold `Space` / `Shift` in water | A / B | Jump / Sneak |
| Swim fast     | Sprint under water; look where to go | L3 | Sprint button |
| Climb out     | Swim at a ledge just above the water | stick | move |
| In the inventory | Left / right click, `Shift` + click, `1`–`9` swap with the hotbar, `Q` drop, double click to collect, drag to spread | A / X / Y, B closes | tap / long press |
| Recipes / uses (JEI) | Click / right click an item in the list, or `R` / `U` over any item; `Backspace` back, `E` / `Escape` back to the inventory | A / X on a list item, B leaves the recipes | Tap / long press |
| Move a recipe (JEI) | `+` beside a crafting recipe (`Shift`: as many as possible) | A | Tap |
| Full stack (JEI, creative) | `Shift` + click or middle click an item in the list | Y | |
| World map     | `M`, or click the minimap   |         | Tap minimap |
| Map menu      | Right click the map         | R3      | Long press |
| Minimap zoom  | `-` / `=`                   |         |            |
| Debug overlay | `F3`, when let go (also WAILA's extended view); not after a combination such as `F3` + `N` | | |
| Debug keys    | `F3` + `Q` lists them in the chat (`F3` + `N`, `F3` + `Q`, `F3` + `F4`) | | |
| Time          | `/time set day` (`noon`, `night`, `midnight`, `6000`, `0.5d`), `/time add 1000`, `/time query daytime`; `/gamerule doDaylightCycle false` stops the clock (admins, the owner, Studio) | | |

## Project layout

```
src/shared   -> ReplicatedStorage.IceVoxel          (used by server, client and worker actors)
  Config                    every tunable setting
  Blocks/  BlockList        block definitions -> ids, appearances, lookup tables (hardness, tools,
                            drops, menus), plants (soil sets, tall halves, foliage tints)
  Items/                    the item registry, stacks and item data (validation, tooltip lines,
                            Mekanism's energy and fluid formats); ItemList (items that are not blocks)
  Transmitters/             Mekanism pipes and cables: Tiers (Mekanism's numbers), sides,
                            connection modes, colours, the connection rule, route costs,
                            Inventories (sided slots, insert / extract, what furnaces and
                            machines push out)
  Machines/                 Mekanism machines: Core (kinds, the machine container and its data,
                            slot rules, panels and their lines, energy maths and the even split,
                            state codes, sustained data), Upgrades (Mekanism's upgrade cards:
                            their slots and maths), Kinds/ (a module per kind: Creative, the
                            Creative Energy Cube; Generator, the Heat Generator; Smelter, the
                            Electric Furnace; Solar, the Solar Panel; Battery, the Batteries)
  Crafting/                 Recipes (Minecraft's and Mekanism's recipes, smelting and fuel; a
                            recipe may keep an ingredient's data), Crafting (grid matching),
                            Smelting (the furnace tick)
  Inventory/                Types (inventory, window, action shapes), Menu (Minecraft's inventory
                            clicks, used by the server and for client prediction)
  Structures/               structure blocks' data and jigsaw structures: Template (the IVS1
                            text, SAVE's capture, ASCII tables), Settings (structure block and
                            jigsaw fields, ranges, wire format), Transform (rotation and mirror),
                            Jigsaw (Minecraft's JigsawPlacement), Library (templates, pools and
                            generated structures from the modules below and the place)
  StructureLibrary/         the structure library: Templates/ (IVS1 modules; Outpost, the
                            example), Pools (explicit template pools), Structures (what generates)
  Entities/ItemPhysics      dropped item movement (server and client)
  GameMode, Mining          the four game modes and what each allows, mining times by hand and
                            with tools
  Sounds/  SoundList        sound events (Minecraft's names) -> built-in sounds, block sound types
  DayCycle                  Minecraft's day: celestial angle, sky light, isDay and the sun's
                            brightness (solar panels), /time arguments, lighting blends
  Biomes/  BiomeList        biome definitions and altitude bands
  Generation/
    TerrainGenerator        biomes, surfaces, filling chunks at any LOD
    Relief                  terrain heights (JJThunder To The Max style)
    Noise                   seeded noise on top of math.noise
    Caves, Ores             full detail only (Ores: every ore feature, Mekanism's osmium included)
    Structures/             placement + Trees (builders) + Writer (clipping, LOD)
    StructureGen            library structures in chunks (random_spread starts, assembly cache,
                            pieces, foundations, generated chests)
    CaveDecor               glow lichen on cave walls (full detail only)
    Foliage                 ground plants by biome (full detail only)
  Meshing/GreedyMesher      blocks -> boxes (parts)
  Meshing/Scatter           plants' offset and turn per position (Minecraft's OffsetType)
  Meshing/QuadMesher        blocks -> faces (meshes); MeshGeometry: faces -> mesh arrays
  Map/MapPainter            map tile colours from the generator (runs in the workers)
  World/                    ChunkLayout, Coords, LodTree, VoxelRaycast, FluidFlow
  Movement/                 Hull (box vs blocks collision), PlayerPhysics (Minecraft movement
                            tick, spectators' flight through blocks), Rig (hull <-> cosmetic
                            character)
  Net/                      Protocol (buffer encoding), Remotes
  Util/Hash                 deterministic hashing and RNG

src/server   -> ServerScriptService.IceVoxel
  IceVoxel_Server           boot: seed, world, ticker, network, players
  Api                       require this from your own server scripts
  World/                    WorldServer (chunks + edits), BlockTicker, Simulation, TimeOfDay (the
                            day clock, published as workspace attributes)
  Behaviours/               Gravity, Fluid, Grass, Attached (torches and lanterns need support),
                            Plant (plants need their soil and their other half), Drops (block
                            update logic)
  Audio/Sounds              plays sounds to the players near them (Sound messages)
  Network/ServerNet         edit lists, edit validation (EditRules: mining time, tools, drops,
                            sustained data hooks, both halves of tall plants), replication
  Entities/                 EntityWorld (item rules: pickup, merging, despawn), Entities
                            (spawning, replication)
  Transmitters/             Mekanism pipes on the server: TransmitterWorld (states, networks, tanks;
                            pure), Transport (items in transporters), Fluids (water in pipes),
                            Eject (furnaces and machines push their results into chests; pure),
                            UseRules (buckets, Configurator), Transmitters (ticks, replication)
  Machines/                 Mekanism machines and energy on the server: MachineWorld (machines,
                            their ticks, sustained data, records, the cached sky look; pure),
                            EnergyNet (energy networks over Universal Cables and touching
                            machines; pure), SkyCheck (does a cell see the sky: loaded chunks,
                            else edits over the generator's ground, never generating; pure),
                            Machines (20 Hz ticks, viewers' snapshots, replication)
  Structures/               structure blocks and jigsaws: StructureBlocks (messages, rate limits,
                            replication, ServerStorage), StructureServer (SAVE, LOAD, DETECT,
                            Generate; pure), StructureStore (their settings), Placement (LOAD and
                            Generate plans, placed over frames), Permission (who may use them)
  Players/ItemUse           the Configurator and buckets used on blocks (UseItem)
  Players/                  GameModes + GameModeCommand (/gamemode, the switcher's requests,
                            permissions, the previous mode), GameModeRules (what each mode may
                            do on the server; pure), TimeCommands + TimeCommand (/time,
                            /gamerule), Inventories + InventoryState (authoritative inventories),
                            Containers (chests, furnaces, generated structures' chests),
                            Characters (cosmetic characters: collision group, teleports, fall
                            damage, invulnerability, suffocation), Spawning, SafeSpot +
                            SpawnUnsafeBlocks (safety rules), Teleport (map, spectators),
                            WaypointStore (DataStore)

src/client   -> StarterPlayerScripts.IceVoxel
  IceVoxel_Client           boot
  World/ClientWorld         nearby block data, edit lists, prediction
  World/StructureRecords    structure blocks' and jigsaws' settings, their regions, pasted data
                            going out and SAVE's data coming back
  Streaming/                ChunkStreamer (LOD + scheduling, the cave view), WorkerPool,
                            ChunkWorker (actor), CaveReach (how far caves are revealed, caps)
  Rendering/                ChunkRenderer (boxes -> parts), PartPool, ViewSettings,
                            LightingController (day, night and cave lighting), SkyExposure (how
                            much sky light reaches the camera), MeshOverlay + MeshRegions (far
                            meshes)
  Interaction/              BlockInteraction (mining, placing, using), CrackOverlay
  Inventory/                ClientInventory + Prediction (predicted inventory)
  Ui/                       Screens, Hud (hotbar, hearts), InventoryScreen (with the crafting,
                            chest, furnace and machine panels laid out by MenuLayout, machines'
                            energy bar, empty armor and upgrade slots' outlines), CreativeScreen,
                            ItemIcon (viewport icons, durability and energy bars), SlotClicks
                            (Minecraft clicks), Style, Waila + WailaInfo (what the crosshair
                            points at), Jei/ (Just Enough Items: item list, recipe view, recipe
                            transfer), StructureScreen + StructureForm (the structure block and
                            jigsaw screens and their model), FormWidgets (Minecraft's fields and
                            buttons), SpectatorGui + SpectatorMenu (the spectator menu and its
                            model), GameModeSwitcher + ModeSwitch (the F3 + F4 switcher and its
                            model)
  Audio/                    SoundPlayer (pooled 3D / interface sounds, the server's Sound messages,
                            overrides), MovementSounds (footsteps, swimming, landings), Ambience
                            (furnaces and Heat Generators crackling, caves), SoundRules (the pure
                            rules)
  Entities/EntityRenderer   dropped items
  Map/                      MapLayer (EditableImage ring), MapView, Minimap, WorldMap,
                            Waypoints, ContextMenu
  Net/ClientNet             routes server messages; Notices shows server messages in the chat;
                            StructureNet (structure blocks' and jigsaws' messages and screens)
  Player/                   MovementController (the hull, input, the cosmetic character,
                            spectating a player), CharacterAnimator (avatar animations from the
                            hull), HeldItems, SpectatorView + SpectatorRules (who sees, hears and
                            aims at spectators)
  Rendering/TransmitterRenderer  Mekanism pipes, cables and machines: arms, water in pipes and
                            tanks, items moving through transporters, the windows of a burning
                            Heat Generator and a smelting Electric Furnace, Batteries' charge
                            gauges, machines' records (WAILA, Ambience); TransmitterModel (their
                            geometry, aiming, item paths)
  Rendering/ItemModels      3D models of items (icons, drops, hands); BlockDecor (the faces of
                            chests, crafting tables, furnaces, Mekanism's machines, structure
                            blocks and jigsaws)
  Rendering/StructureBoxes  structure blocks' outlines, names and air markers
  Debug/DebugOverlay        F3 stats and time of day (also WAILA's extended view); DebugKeys
                            (Minecraft's debug keys: F3 when let go, F3 + N, F3 + F4, F3 + Q)

tests/       Lune scripts: unit tests, benchmark, terrain preview, structure (structure data on the
             command line), build_structures (the example outpost's builder)
docs/        ARCHITECTURE.md (how everything fits together)
```

How the pieces work together is described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Configuration

Everything lives in `src/shared/Config.luau`. The settings that matter most for performance:

| Setting                   | Default | Effect                                                              |
| ------------------------- | ------- | ------------------------------------------------------------------- |
| `Lod.ViewDistance`        | 2048    | How far terrain is drawn (blocks).                                  |
| `Lod.Mobile`              | 512 / 2 / 24 / 3 | View / split / foliage / underground split distance on phones and tablets. |
| `Lod.SplitDistance`       | 3       | Detail falloff. LOD 0 radius is roughly `2 × SplitDistance` chunks. |
| `Lod.SplitDistanceL1`     | 3       | Same for full detail only; 2 = ~12% fewer parts in mountains.       |
| `Lod.UndergroundSplitDistanceL1` | 4 | `SplitDistanceL1` while the camera is underground (phones 3): full detail, and so caves, reach ~128 blocks. |
| `Lod.UndergroundSeconds`  | 5       | How long that lasts after the camera comes up (no rebuilding at cave mouths). |
| `Lod.Levels`              | 7       | Coarsest level covers `16 × 2^(Levels-1)` blocks per chunk.         |
| `Lod.MaxVerticalStep`     | 16      | Tallest LOD cell in blocks (keeps far mountains shaped).            |
| `Lod.FoliageDistance`     | 40      | How far plants are drawn (blocks; every box of a plant is a part).  |
| `Workers.Count`           | 6       | Actors generating / meshing in parallel.                            |
| `Render.BuildBudgetMs`    | 4       | Main thread time per frame spent creating parts.                    |
| `Render.Shadows`          | true    | Shadows on full detail chunks and of torch and lantern light (far chunks never cast shadows). |
| `Render.Foliage`          | true    | Draw plants (up to 4 parts each); false saves those parts, plants can still be aimed at and broken. |
| `Caves.RevealRadius`      | 64      | How far around an underground camera caves are meshed (phones 48: `Caves.Mobile`). |
| `Caves.RevealRadiusMax`   | 128     | Same in big caverns (the radius follows the open space around you; phones 96). |
| `Caves.LichenLightDistance` | math.huge | Glow lichen's lights shine at any distance; a number switches off those farther from the camera (the lichen still glows). |
| `StructureMaxLevel`       | 2       | Highest LOD level that still shows trees and library structures.   |
| `Structures.Permission`   | {}      | Who may use structure blocks and jigsaws in creative besides the owner, `Gameplay.Admins` and Studio: user ids, or true (anyone in creative) / false. |
| `Structures.MaxSize` / `MaxOffset` | 48 / 48 | A structure block's largest size and relative position per axis (Minecraft's). |
| `Structures.DetectRange`  | 80      | How far DETECT looks for Corner blocks of the same name.            |
| `Structures.LoadBlocksPerFrame` | 2000 | Blocks LOAD and Generate place per frame (and at most 6 ms of it). |
| `Structures.MaxDataChars` | 200000  | Longest structure text saved or pasted (what a StringValue holds).  |
| `Structures.DataPieceChars` | 16000 | Structure text travels in pieces of this many characters, `DataPiecesPerSecond` (20) a second. |
| `Structures.Generate`     | true    | Library structures generate in the world; false: none do.          |
| `Render.Textures`         | true    | Use block textures (MaterialVariants / face images) when defined.   |
| `Render.FarMeshes`        | on (PC) | Merge stable far regions into meshes (see Far meshes below).        |
| `Map.Teleport`            | true    | Who may teleport from the map: everyone, nobody, or a user id list. |
| `Map.SaveWaypoints`       | true    | Keep waypoints between sessions (DataStore).                        |
| `Gameplay.DefaultGameMode` | Survival | Game mode of players when they join: Survival, Creative, Adventure or Spectator. |
| `Gameplay.GameModeCommand` | true   | Who may change their own game mode (`/gamemode`, `F3` + `N`, `F3` + `F4`): everyone, nobody, or a user id list (`Gameplay.Admins`, the owner and Studio always may). |
| `Gameplay.Admins`         | {}      | User ids who may change other players' game modes (and their own) and the time (`/time set\|add`, `/gamerule`). |
| `Gameplay.KeepInventory`  | false   | Keep the inventory on death instead of dropping it (spectators always keep theirs). |
| `Entities.ItemLifetime`   | 300     | Seconds before a dropped item disappears.                           |
| `Entities.MaxItems`       | 1000    | Most dropped items at once (the oldest go first).                   |
| `Sounds.Enabled`          | true    | false turns every sound off (server and clients).                   |
| `Sounds.Volume`           | 1       | Master volume; `Sounds.Sources` per kind (blocks, players, ambient, ui). |
| `Sounds.PlayerRate`       | 8       | Sounds a player's inventory clicks and chest opening may cause per second (anti-spam). |
| `Sounds.OverrideFolder`   | IceVoxelSounds | Folder (SoundService / ReplicatedStorage) of replacement Sounds. |
| `Sounds.Sources`          | 1 each  | Volume of blocks, players, ambient and ui sounds.                   |
| `Sounds.Footsteps`        | true    | Footsteps of everyone (swimming and splashes still play).           |
| `Sounds.Interface`        | true    | Clicks of buttons and tabs.                                         |
| `Sounds.Ambient`          | true    | The rare cave rumble deep underground.                              |
| `Time.DayLength`          | 1200    | Real seconds per in-game day (Minecraft's 20 minutes).              |
| `Time.StartTime`          | 1000    | Day time when the server starts (ticks; 6000 noon, 13000 night).    |
| `Time.Cycle`              | true    | Minecraft's doDaylightCycle (false: the time stands still).         |
| `Lighting.CaveAmbient`    | 26, 26, 32 | How dark caves are; raise it like Minecraft's Brightness slider. |
| `Lighting.Enabled`        | true    | false leaves Lighting to the place (only the sun moves; the cave rumble still plays). |

Lighting comes from `default.project.json`: Future technology, shadows and a dark ambient light. With
`rojo serve` into an existing place, check that `Lighting.Technology` is Future (or LightingStyle
Realistic in newer Studios). An Atmosphere or Sky you add is left alone, and
`Lighting.GeographicLatitude` sets how high the sun climbs; the lighting follows the sun wherever
Roblox draws it.

Part count depends on the terrain: flat land costs ~35 parts per full detail chunk, steep
mountains ~110. Most parts are near the player; doubling the view distance adds comparatively
few. Measured views (`lune run tests/bench <seed> <viewDistance> [splitDistance] [splitL1] [x z]`,
seed 12345; "mountains" is inside a range at 3200, -14600):

| View from         | 512 (mobile) | 1024 | 2048 (default) | 4096 |
| ----------------- | ------------ | ---- | -------------- | ---- |
| spawn (hills)     | 14k          | 28k  | 34k            | 46k  |
| mountains         | 29k          | 68k  | 81k            | 97k  |

With far meshes, once every region near the player has settled (the bench prints this too):

| View from         | 2048 (default)          | 4096                     |
| ----------------- | ----------------------- | ------------------------ |
| spawn (hills)     | 16.7k parts + 88 meshes | 20.6k parts + 187 meshes |
| mountains         | 34.8k parts + 90 meshes | 39.5k parts + 191 meshes |

What remains are the near levels (full detail and level 1), which stay parts. In the mountains,
`Lod.SplitDistanceL1 = 2` or a shorter view on weaker devices brings that down.

Plants add parts of their own, only within `Lod.FoliageDistance`: about 1,000-3,000 on grassland,
at most 6,000 (half that on phones); `Render.Foliage = false` saves them.

Keep the playable area within about ±16,000 studs (±5,000 blocks) of the origin: further out,
float precision makes parts and characters jitter.

`Seed = nil` gives every server a random world; set a number for a fixed one.

## Extending

**A block.** Append an entry to `src/shared/Blocks/BlockList.luau` (at the end: ids are list
positions and saved edits depend on them):

```lua
table.insert(list, { name = "Marble", color = { 235, 235, 230 }, material = "Marble" })
```

It is immediately an item: it shows up in the creative picker, and survival players get it by
mining it (`hardness = 1.5` for stone-like mining time, `tool = "pickaxe"` and `toolLevel = 0` to
need a pickaxe to drop anything, `drops = "Cobblestone"` or `false` to drop something else or
nothing, `container = 27, menu = "Chest"` for a chest-like block, `maxStack = 1` for an item that doesn't stack). Blocks that look identical
share one part template.

**Sounds.** Every sound is a Minecraft sound event (`block.stone.break`, `entity.item.pickup`,
`ui.button.click`...; the full list is `src/shared/Sounds/SoundList.luau`) played with one of the
sounds every Roblox client ships (`rbxasset://sounds/...`: the character's footsteps, landing,
get-up rustle (chest lids, armor), free-fall wind (the cave rumble), swimming and splash, the
explosion, `oof`, `ouch` and the volume slider's tick; the jump sound is unused), as stand-ins
told apart by pitch. To use your own, add a Folder named `IceVoxelSounds` to SoundService
(or ReplicatedStorage) and put Sound instances in it, named like the event they replace:

```
SoundService
  IceVoxelSounds            Folder
    block.stone.break       Sound (SoundId = rbxassetid://...)
    block.stone.break       another Sound: a variant, one is picked at random
    block.break             every other block type's break sound
    item.armor.equip        every armor material
    entity.item.pickup
```

A Sound named like the event wins; otherwise one named like its category, the event with the
variant left out (`block.break` for every `block.<type>.break`, `item.armor.equip` for every
`item.armor.equip_<material>`). Several Sounds with one name are Minecraft's variants. They play
with their own Volume and PlaybackSpeed (times the volume settings, varied a little like the
built-in ones), heard as far as the event (16 blocks). To change the defaults instead, edit `id`,
`volume` and `pitch` in SoundList: block types have a `dig` clip (breaking, placing) and a `step`
clip (walking, mining hits, falls), scaled per action like Minecraft. A block's sound type is its
`sound` in BlockList (`sound = "metal"`), else its material's. Server scripts can play any event
to the players near a point:

```lua
local Sounds = require(game.ServerScriptService.IceVoxel.Audio.Sounds)
Sounds.play("block.glass.break", x + 0.5, y + 0.5, z + 0.5) -- block coordinates
```

Client scripts can play any event for the local player alone:

```lua
local SoundPlayer = require(game.Players.LocalPlayer.PlayerScripts.IceVoxel.Audio.SoundPlayer)
SoundPlayer.play("entity.generic.splash", x, y, z) -- blocks
SoundPlayer.click()                                -- ui.button.click
```

Sounds are heard from the camera, but never more than 4 blocks from the player's eyes
(`SoundRules.LISTENER_REACH`, Minecraft's third person distance), so zooming out does not
silence the world; a Scriptable camera hears from where it is.

**Pipes and tanks.** A transmitter is a block with `transmitter = { kind = "item" | "fluid", tier =
1..4, restrictive = true? }` and a tank one with `tank = { tier, capacity }` in BlockList; the
per-tier numbers are Mekanism's, in `src/shared/Transmitters/Tiers.luau`. Any block with
`container` slots is an inventory transporters connect to (all slots from every side, unless it is
a furnace, `menu = "Furnace"`).

**A machine.** A machine is a block with `machine = { kind = "name" }` and `energy = { capacity =
J, input = J/t?, output = J/t? }` in BlockList (output only: a generator; input only: a machine
that uses energy; both: a battery). Its kind is a module in `src/shared/Machines/Kinds/`,
required from `Machines/init.luau`:

    return Core.define("generator", {
        slots = { { x = 80, y = 53, accepts = function(item) return Smelting.fuel(item) > 0 end } },
        fields = { "burnTime", "burnTotal" },            -- data after energy and the shared header
        keep = { "burnTime" },                           -- kept in the item with its energy
        panel = { flame = { x = 80, y = 36, value = "burnTime", total = "burnTotal" } },
        tick = function(container, ctx) ... Core.produce(container, 200) ... end,
    })

The server ticks it 20 times a second, joins it to cables and touching machines, keeps its energy
in its item and replicates it; the client draws its panel (slots, gauges, energy bar) and WAILA
lines. Tests bind test-only kinds to spare blocks with `Machines.bind`.
The Heat Generator (`src/shared/Machines/Kinds/Generator.luau`) is the complete version of this
example; the Electric Furnace (`Kinds/Smelter.luau`) is a machine that uses energy, with a
progress arrow, sided slots for transporters, a `rates` override and a `state` field: a code
saying why it is idle ("No power") that Machines records carry to WAILA.
The Solar Panel (`Kinds/Solar.luau`) reads the server's day time and whether its cell sees the sky
from its tick context (`ctx.dayTime`, `ctx.sky(x, y, z)`: cached, never generating terrain), and
`Machines/Upgrades` gives any kind Mekanism's upgrade slots (`Upgrades.slots(x, y)`) and maths
(`ticks`, `energyPerTick`, `capacity`, `production`, `setCapacity`).
Batteries (`Kinds/Battery.luau`) are storage: the same `input` and `output`, no slots and no tick;
EnergyNet does the rest. A kind's `lines(view)` adds lines under its status line (`panel.lines =
{ x, y }`), and a shaped recipe's `keep` (a key character used once) makes its result take that
ingredient's item data, as a battery's tier upgrade keeps its charge.

**Item data.** A stack may carry `data`, a flat table: at most 16 keys (letters, digits, `_`), values
numbers, strings up to 64 bytes or booleans. Data tables are frozen and shared by copies, so make
a new stack instead of changing one: `Items.withData(stack, { energy = 5000 })`; read it back with
`Items.dataNumber(stack.data, "energy")`. A data key gets a tooltip line with a describer:

```lua
Items.addDescriber("charge", function(data) return `Charge: {data.charge}%` end)
```

A block that keeps its state in its item when broken (Mekanism's sustained data) registers hooks
with the server, the way the Fluid Tank does (`TransmitterWorld.blockDataHooks`):

```lua
serverNet.addBlockData({
	save = function(x, y, z, block) return { energy = 5000 } end, -- just before a survival break
	placed = function(player, x, y, z, block, stack) end, -- right after placing; stack.data intact
})
```

**A light or a shaped block.** `light = 0..15` gives a block one PointLight; `shape = { { size,
offset, rotation?, color?, material?, glow? } }` (pixels from the cell's centre) draws it from
boxes, and `bounds` is the box players aim at. `support = "Down"` (or "Up", "North"...) makes it
need a sturdy block there, and with `behaviour = "Attached"` it pops off and drops when that block
goes; `brokenByFluid = true` lets flowing water wash it away. `item = "Torch"` with `placeable =
false` makes it a variant placed by and dropping another item (the name must be a block item:
checked at load); without `placeable = false` it is an item of its own and drops itself.
`obstructs = true` keeps a block that is not `solid` (a lantern) from being placed inside a
player and lets falling sand land on it; `sturdy = false` keeps torches and lanterns off a solid
cube (leaves, chests, cactus).

**A plant.** Add it through BlockList's `plant()` helper with `plant = { soil = "dirt" }` (or
`"deadbush"`, `"mushroom"`: the soil set it stands on, `Blocks.mayPlaceOn`); the helper fills in
the rest (not solid, instant, grass sounds, `support = "Down"`, `brokenByFluid`, `behaviour =
"Plant"`, `scatter`). A tall plant is two entries: the lower half with `plant = { soil = "dirt",
top = "MyPlantTop" }`, the upper with `plant = { bottom = "MyPlant" }`, which the helper makes the
lower half's variant (no item, no drops, not placeable); give both halves full block `bounds`, as
DoublePlantBlock has. `tinted = true` colours its boxes by the soil's `foliageColor`;
`shearDrops = true` (or an item name, with `shearCount`) is what Shears harvest. Keep the shape
to 4 boxes inside the outline whichever way it turns: tests/spec/Plants checks it. From your own
server scripts place a tall plant with `EditRules.setPlaced(world, x, y, z, block)`:
`world:setBlock` sets only the half you give it, and a half alone pops on the next tick.

**An item.** Items that are not blocks (armor, tools, materials) live in
`src/shared/Items/ItemList.luau` (again appended at the end). They are drawn from boxes measured
in pixels (1/16 block), so icons, dropped items and hands show them without any assets.

**A recipe.** `src/shared/Crafting/Recipes.luau` lists them by item name, like Minecraft's data
files:

```lua
shape({ "##", "##" }, { ["#"] = "Marble" }, "MarbleBricks", 4) -- shaped, anywhere in the grid
mix({ "Marble", "Coal" }, "DarkMarble")                       -- shapeless
smelt("Marble", "SmoothMarble")                               -- furnace
```

**Block textures.** Blocks already use Roblox materials (Slate, Grass, Sand...), which have
built-in textures. For your own, per-block textures use a MaterialVariant per block:

1. In Studio open the Material Manager (Model tab) and create a variant, e.g. `IV_Stone`, with the
   block's material as Base Material (Stone uses `Slate`), your uploaded images as Color (and
   optionally Normal / Roughness) maps, **Studs Per Tile = 3** (the block size, so one tile covers
   one block face) and **Pattern = Regular**. Scripts cannot create textured variants at runtime;
   they have to be authored in Studio (or synced by Rojo, below).
2. Point the block at it in `BlockList.luau`:
   ```lua
   { name = "Stone", color = { 125, 125, 128 }, material = "Slate", texture = "IV_Stone" },
   ```
   `color` still colours the map; the part is tinted with `tint` (default white, i.e. the
   texture's own colours). A missing variant just prints a warning and keeps the plain material.
3. Different faces, e.g. a grass top on a dirt-textured block: `faces = { Top = "rbxassetid://..." }`.
   Each face image is one extra instance per part, so it is only drawn on full detail chunks.

With Rojo the variants can live in the project instead:

```json
"MaterialService": {
  "IV_Stone": {
    "$className": "MaterialVariant",
    "$properties": {
      "BaseMaterial": "Slate",
      "ColorMap": "rbxassetid://YOUR_IMAGE_ID",
      "StudsPerTile": 3,
      "MaterialPattern": "Regular"
    }
  }
}
```

(add it inside `"tree"` in `default.project.json`; Rojo 7.5+ also accepts `ColorMapContent`). Check
the tile alignment once in Studio: a 9-stud and three 3-stud parts next to each other should show
identical tiles.

**Spawn safety.** `src/server/Players/SpawnUnsafeBlocks.luau` lists what a player must not stand on
(`Floor`), stand in (`Body`, fluids by name) or touch (`Hazards`), plus the headroom and search
radius. Spawns and map teleports search outward for the closest spot that passes, and never put
players below the natural surface (caves).

**The map.** The minimap and world map draw terrain with EditableImage. That API works in Studio
right away, but **published games** need the experience owner to be 13+ and ID verified and to turn
on *Enable Mesh / Image APIs* (Creator Dashboard, experience settings). Without it the maps still
show players and waypoints, and the right click menu still works. Teleporting is controlled by
`Config.Map.Teleport` and checked by the server.

**Far meshes (EditableMesh superchunks).** Distant terrain (LOD level 2 and up, about 200 blocks
and further) is merged per region of 4 × 4 chunks into MeshParts once the region has not changed
for 2 seconds. About the "8 EditableMesh limit": it is not a count but a memory budget. A PC
client gets 80 MiB for editable objects and every growable EditableMesh is charged a flat 10 MiB,
whatever it holds. IceVoxel therefore keeps one EditableMesh for the whole session as a scratch
buffer: each region is written into it, *baked* into static content with
`AssetService:CreateDataModelContentAsync` (which does not count against that budget), cleared,
and shown with `CreateMeshPartAsync`. So any number of regions can be merged.

- Like EditableImage, it needs the Mesh / Image APIs enabled for published games (see The map).
- A few seconds after joining, a probe builds a few test meshes and times them against the usual
  frame time; press **F3** to see the status, how many regions and chunks are merged, and how long
  builds take. Meshes stay off (parts only, with their normal look) when the Mesh APIs are
  unavailable, the probe fails, or building makes frames more than `MaxBlockingMs` longer.
- Merged levels use a plain look for their parts too (SmoothPlastic in the block colour, opaque
  water), so swapping between parts and a mesh is invisible.
- Phones keep parts by default (`FarMeshes.Mobile`).
- Not yet measured on live servers: how long builds take on real clients, whether baked content
  is reclaimed over long sessions (a bake that hits the engine's storage limit switches meshes
  off; meshes in the world are capped at `MaxLiveTriangles`), and how far the engine then
  actually draws. Check F3 and the MicroProfiler in a published test place before relying on it.

**A biome.** Add an entry to `src/shared/Biomes/BiomeList.luau` with the altitude bands it appears
in, a climate position (temperature, humidity), surface blocks (optionally patches of another
block and a block for steep slopes) and vegetation. The terrain shape comes from `Relief`, so a
biome only decides what grows and what the ground is made of. Its ground plants are `foliage`: an
average `density`, the share of the ground in patches (`cover`), weighted `plants` and optional
`flowers` (see the BiomeList header); keep within the parts budget tests/spec/FoliageGeneration
checks.

**A tree or another small feature.** Write a builder in `Generation/Structures/` (see
`Trees.luau`), register it in `Structures.registry` with the blocks it may grow on, and list it in
a biome's `features`. Builders write in world coordinates; chunk clipping, cross-chunk consistency
and LOD are handled for you.

**A structure**, from building it to seeing it generate. Structure blocks and jigsaws need
creative and permission: the game's owner, Studio, `Gameplay.Admins` or a user id in
`Config.Structures.Permission`.

1. **Build it** in creative. Air you leave inside the region is saved as air and clears whatever
   is there when the structure is placed; put a Structure Void (creative picker) where the world
   should stay as it is instead (around a ruin, under a path). For a piece of a bigger structure,
   put Jigsaw blocks where other pieces attach (step 5).
2. **Mark the region.** Place a Structure Block (it starts in Save mode) and right click it. Give
   it a name with slashes, Minecraft style: `mything/houses/hut` (the part before the last slash
   is its pool, step 5). Set the relative position (from the block to the region's lowest
   north-west corner, default one block above it) and the size; the outline shows the box. Or put
   two Corner structure blocks named alike at opposite corners just outside the region and press
   DETECT.
3. **Save** (SAVE). The chat says `Saved structure 'mything/houses/hut' (N blocks, M characters)`
   and the data, `IVS1:...`, appears in the box under the size: click it and press `Ctrl` + `C`
   (`Cmd` + `C`). Long data comes in parts of 16,000 characters ("part 2 of 9"): copy every part in
   order and put them together.
4. **Keep it**, any of these ways:
   - **Send it to Claude** in a chat message (words around it are fine): it goes into
     `src/shared/StructureLibrary/Templates/` as a module.
   - **Put it in the repo yourself**: a ModuleScript (any name, any folder depth) in
     `src/shared/StructureLibrary/Templates/` returning the text, or a list of texts:
     ```lua
     return "IVS1:..."
     ```
     A `.txt` file holding the text works too (Rojo makes it a StringValue). The name inside the
     data counts, not the module's.
   - **Keep it in the place**: during a Studio playtest every save is a StringValue named after the
     structure in `ServerStorage.IceVoxelSavedStructures`. Copy it, stop the playtest and paste it
     into a Folder named `IceVoxelStructures` in ReplicatedStorage (make it; Folders inside are
     fine). Saves only last for the session: nothing is written anywhere else.

   To place it again by hand, use a Structure Block in Load mode with its name (this session's
   saves and the library), or paste the data into Paste Data: a LOAD whose size differs from the
   structure's only sets the size (the outline shows where it goes), the next places it, turned
   and mirrored as set. The library is read once when the server and each client start (every
   machine must generate the same structures), so new templates are seen from the next start or
   playtest on.
5. **Join pieces with jigsaws** for a structure like a Minecraft village:
   - Name the pieces by pool: `mything/centres/plaza`, `mything/houses/a`, `mything/houses/b`,
     `mything/streets/straight`... A pool needs no code: `mything/houses` is every template named
     `mything/houses/...` (weight 1, rigid), and a pool named like one template is that template.
   - On a piece, a jigsaw whose front faces out of it marks where a child attaches: its **target
     pool** is where the child comes from, its **target name** the name of the child's jigsaw that
     attaches here, and **Turns into** what it becomes once generated (air, or `Planks` to close a
     wall). On the child, a jigsaw facing out with that **name**. Two jigsaws attach when they face
     each other, the names match and, for jigsaws facing up or down, their tops match unless the
     source's joint is rollable. Each child must fit beside what is already there.
   - Try it at once: a jigsaw's Generate builds from its pool right there, Levels deep, and this
     session's saves are already in their pools (Keep Jigsaws leaves the jigsaws to look at).
   - `src/shared/StructureLibrary/Pools.luau` adds weights (1..150), empty elements (a plot left
     empty), a fallback pool (tried after the elements, and alone at the last level: end caps) and
     terrain matching pieces, which follow the ground column by column (paths). In the place, the
     attribute `TerrainMatching = true` on a StringValue makes its templates terrain matching in
     the pools made from their names.
6. **Make it generate.** In the repo, add an entry to `src/shared/StructureLibrary/Structures.luau`
   (its header lists the fields: `name`, `startPool`, `size` (jigsaw depth 0..7), `maxDistance`,
   `biomes`, `spacing` / `separation`, `salt`, `startHeight`, `projectToHeightmap`, `onLand`,
   `foundation`). In the place, set the attribute `Generate = true` on the StringValue whose
   (first) template is the start, and optionally `Biomes` (`"plains, forest"`: BiomeList names;
   case, spaces, underscores and `minecraft:` are ignored), `Spacing` and `Separation` (one start
   per Spacing × Spacing chunks, at least Separation apart; default 34 / 8, Minecraft's villages),
   `Size`, `Foundation`, `OnLand`, `StartHeight` and `MaxDistance`. Problems (an unknown pool,
   biome or block, a bad attribute) are warned in the output as `[Structures] ...` and skipped;
   nothing errors.
7. **See it.** Structures generate in terrain nobody has edited, wherever a start lands: while
   testing, a small spacing (`Spacing = 4`: one start per 64 × 64 blocks) finds one quickly. From a
   server script, every generated structure with a piece in a rectangle:
   ```lua
   local IceVoxel = require(game.ServerScriptService.IceVoxel.Api)
   local world = IceVoxel.waitForWorld()
   for _, s in world.generator.structures(-1000, -1000, 1000, 1000) do
       print(s.name, s.x, s.z) -- the start position (blocks)
   end
   ```
8. **Look inside the data** without the game:
   `lune run tests/structure decode <file | IVS1:... | ->` prints every structure in a file (a
   pasted chat message, a library module) or the text given: name, size, palette, every y layer as
   ASCII, jigsaws, data markers, containers. `--lua hut.luau` writes an editable table ("." air,
   " " keep), and `lune run tests/structure encode hut.luau --module` turns it back into a library
   module.

The example outpost is a complete jigsaw structure to copy: its pieces are built in code by
`tests/build_structures.luau` into `Templates/Outpost.luau` (`lune run tests/build_structures`;
`--check` tells whether that file is up to date, `--print` shows every piece), its pools are in
`Pools.luau` and its entry in `Structures.luau`.

**A block behaviour.** Create a module in `src/server/Behaviours/` (see `Grass.luau`) with
`onTick(world, ticker, x, y, z, block)` and set `behaviour = "YourModule"` on the block.

**Server-side world access** from your own scripts:

```lua
local IceVoxel = require(game.ServerScriptService.IceVoxel.Api)
local Blocks = require(game.ReplicatedStorage.IceVoxel.Blocks)

local world = IceVoxel.waitForWorld()
world:setBlock(10, 80, 10, Blocks.id.Stone) -- replicated to every client, triggers block updates
print(world:getBlock(10, 80, 10))
```

## Development

The engine's core is pure Luau, so most of it runs and is tested outside Roblox with
[Lune](https://github.com/lune-org/lune):

```sh
lune run tests/run                    # unit tests (generation, meshing, LOD, protocol, block updates)
lune run tests/bench [seed]           # generation / meshing speed and part count estimate
lune run tests/preview [seed] [blocksPerPixel] [pixels]   # top-down map in tests/out/preview.ppm
lune run tests/structure decode <file | IVS1:... | -> [--lua t.luau]   # structure data, as ASCII
lune run tests/structure encode t.luau [--out file] [--module]        # an edited table to IVS1
lune run tests/build_structures [--check] [--print]   # rebuild (or check) the example outpost
```

Formatting, linting and type checking:

```sh
stylua src tests
selene src
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json \
    --definitions=@roblox=path/to/globalTypes.d.luau src
```

(`globalTypes.d.luau` comes from the [luau-lsp repository](https://github.com/JohnnyMorganz/luau-lsp/tree/main/scripts).)

## Roadmap

Natural next steps, roughly in order:

- **Persistence.** Edits, inventories and chest contents live in memory (`WorldServer.edits`,
  `Players/InventoryState`, `Players/Containers`), as do transmitter states, network water, tank
  contents and items in transit (`Transmitters/TransmitterWorld`), structure blocks' and jigsaws'
  settings and the session's saved structures (`Structures/StructureStore`, `StructureServer`);
  save them to DataStores (edits per region of 32 × 32 chunks, see "regions" in
  docs/ARCHITECTURE.md).
- **More of Mekanism.** Machines on the machine framework, side configuration for machines, energy
  items and the Energy Cubes' charge slots, gases (Pressurized Tubes), heat (Thermodynamic
  Conductors) and the Logistical Sorter.
- **Combat.** Swords exist and armor is worn, but nothing deals damage yet besides falling and
  suffocating inside a block (`Items.damageAfterArmor` is ready for it).
- **Block orientation.** Blocks have no facing yet, so furnaces and chests show their fronts on
  every side and furnaces don't light up while burning.
- **More plants.** Saplings (dropped by leaves, growing into the existing tree builders), bone
  meal, sugar cane, seagrass and kelp, lily pads, vines, sweet berry bushes, and wheat, so grass
  can drop seeds. Plants are drawn only within `Lod.FoliageDistance`; Minecraft draws them to the
  render distance, which would need them merged into far fewer parts or meshes.
- **Edits in LOD chunks and on the map.** Far chunks and the map show generated terrain only; player
  builds appear once in full detail range.
- **Exact cave culling.** Replace the "camera below the surface" rule with Minecraft-style section
  connectivity (docs/ARCHITECTURE.md, "Hidden caves, octrees and regions").
- **The Underlands at a distance.** Caves only exist in full detail chunks, so a big cavern ends
  where they do (~128 blocks underground, `Lod.UndergroundSplitDistanceL1`). Carving the
  Underlands (mostly an analytic interval per column, cheap at any level) into far chunks and
  meshing those with caves visible while the camera is inside would show them whole.
- **More structures.** Villages and dungeons for the structure library; loot tables for generated
  chests (they hold their template's items); Minecraft's beard terrain adaptation instead of the
  foundations; structure sets and exclusion zones, so different structures keep apart; glow
  lichen on several faces of a block, as Minecraft's multiface block.
- **Parallel server generation.** The server generates chunks on its main thread (one per frame).
- **Mesher.** Try both X-first and Z-first growth and keep the smaller result.
- **Floating origin** for play far beyond ±16k studs, where float precision starts to show.
