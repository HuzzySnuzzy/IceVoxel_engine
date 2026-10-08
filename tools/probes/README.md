# Studio probes

Developer tools that measure what Lune cannot: engine-side costs that only a real Roblox client
shows. They are **not in the Rojo tree** (`default.project.json` never sees `tools/`), so they never
ship with the place. Copy them into a test place by hand, run, read the Output or the Developer
Console (F9), and delete them again.

| Probe | Measures | Decides |
| --- | --- | --- |
| `RebaseProbe.client.luau` | One floating-origin move: the Luau gather, `workspace:BulkMoveTo` and the frames after it, at 17k, 35k, 80k and 140k parts | `Config.Origin.RebaseDistance` / `SoftDistance` and whether far meshes start at level 1 (below) |
| `UnionProbe.client.luau` + `UnionProbeSections.luau` | `GeometryService:UnionAsync` on real terrain sections: time, worst frame, triangles, a one-block edit's re-union, memory by category, draw calls by eye | Whether CSG unions could ever beat parts plus far meshes for chunk rendering (today: no) |

Run both on a PC **and on one phone**: phones are where both costs matter.

## RebaseProbe

The floating origin (`Shared/World/Origin`, client `Rendering/Rebase`) moves every client part on
screen in one `BulkMoveTo` when the camera gets `RebaseDistance` studs from the render origin.
The Luau side was measured in Lune (about 0.08 µs a part); the engine side (each part's CFrame
read, the move, the next frame's broadphase, render clusters and lighting) can only be measured
here.

1. Play in Studio (or a published test place), with nothing else heavy on screen.
2. Put `RebaseProbe.client.luau` in `StarterPlayer.StarterPlayerScripts` as a LocalScript (or
   paste its body into the command bar while playing).
3. It builds anchored parts like the terrain's (boxes 3-48 studs, about half CanCollide and
   CanQuery, 70% casting shadows) over the default view, looks over them from a fixed camera,
   lets them settle, and moves them and the camera together (as the game's `Rebase` does, so the
   frames after draw the same scene). It prints one line per count:

   ```
   [RebaseProbe] parts | gather ms | BulkMoveTo ms | before mean/max | after: 1st, 2nd, rest max | hitch ms
   ```

   The **hitch** is what the first two frames after the move took beyond the mean before. The
   gather and `BulkMoveTo` run inside a RenderStepped, so the first frame after already holds
   them (don't add them again); the second holds what the engine left for later. The two
   columns before it show the Luau and engine split. In the game itself, F3's `origin` line
   shows the same split for real moves (`gathered in`, `BulkMoveTo`).

**Decision rule** (the hitch at 35k parts, about the default view in the mountains or at the
spawn without far meshes):

| Hitch at 35k on PC | Action |
| --- | --- |
| ≤ 20 ms | Keep `Origin.RebaseDistance = 8192` and `SoftDistance = 3072` |
| 20-50 ms | `RebaseDistance = 16384` (still within 1/512 stud near the camera); keep soft moves; keep far meshes on by default |
| > 50 ms | Also start far meshes at level 1 (`Render.FarMeshes.MinLevel = 1`: about 47% fewer parts on screen); a hard move may then cover the screen for 2 frames so the hitch reads as a blink, not a stutter |

Phones get their own overrides if they need them (a `Config.Origin.Mobile` table, read the way
`Render.FarMeshes.Mobile` is).

## UnionProbe

The evaluation of CSG unions for chunks found them not worth building: they would cut the part
count 15-31x on levels 0-1, but each union is its own mesh (no part instancing, so likely more
draw calls), every block edit would wait on an asynchronous CSG job, and streaming would need
20-110 `UnionAsync` calls a second. Stable far terrain is already merged better by far meshes
(`Rendering/MeshOverlay`). The probe settles the estimates that rest on no published numbers.

1. `UnionProbeSections.luau` → a ModuleScript `ReplicatedStorage.UnionProbeSections` (8 real
   mountain sections, seed 12345 near (3200, -14600), 48-140 boxes each, by look).
2. `UnionProbe.client.luau` → a LocalScript in `StarterPlayer.StarterPlayerScripts` (CSG on the
   client needs client-made parts), in a copy of the IceVoxel place so `MaterialService.IceVoxel`
   exists.
3. Play, open the Developer Console and read the `[UnionProbe]` lines: per section and look the
   union time, the worst frame during it and its TriangleCount; one look re-unioned with a box
   removed (what a block edit would cost); client memory by category (Instances, BaseParts,
   GraphicsParts, GraphicsSolidModels, GeometryCSG, PhysicsCollision) with and without the parts.
   The parts stay on the left (x < 0) and the unions on the right: compare draw calls with
   Shift+F2 and check by eye whether textures still tile one per block on the unions.

Revisit unions only if a probe surprises: unions under about 5 ms each **and** their draw calls
batched. Even then, try far meshes from level 1 first (`Render.FarMeshes.MinLevel = 1`), which
does the same job with code that exists.
