--!strict
--[[
	Matches a section's old mesh boxes against its new ones (ChunkRenderer's in-place remesh).

	A box is GreedyMesher.BOX_BYTES (14) bytes: position, size and key (appearance plus surface:
	fluid level, plant tint, sparse light). Those bytes and the node fully decide the box's parts,
	so a new box whose 14 bytes equal an old box's can keep that box's parts untouched; only the
	unmatched boxes cost instance work. Boxes are matched as a multiset (equal boxes pair up one to
	one, first come first served), by their bytes as strings.

	An edit keeps ~98% of a section's boxes (perf/research_flicker 1.3): about 3 parts change
	instead of 90-140. Pure Luau, tested in tests/spec/RenderPipeline.
]]

local BOX = 14

local SectionDiff = {}

SectionDiff.BOX_BYTES = BOX

--[[
	Returns, for each new box i (0-based), `matched[i + 1]`: the old box (0-based) it keeps, or -1
	when it must be built; the old boxes nothing kept (0-based, ascending); and how many were kept.
]]
function SectionDiff.match(
	old: buffer,
	oldCount: number,
	new: buffer,
	newCount: number
): ({ number }, { number }, number)
	-- Old boxes by their bytes; equal boxes are chained (rare: the mesher's boxes do not overlap).
	local first: { [string]: number } = {}
	local nextSame: { number } = table.create(oldCount, -1)
	local readstring = buffer.readstring
	for i = oldCount - 1, 0, -1 do
		local key = readstring(old, i * BOX, BOX)
		local head = first[key]
		if head ~= nil then
			nextSame[i + 1] = head
		end
		first[key] = i
	end
	local matched: { number } = table.create(newCount, -1)
	local used: { boolean } = table.create(oldCount, false)
	local kept = 0
	for i = 0, newCount - 1 do
		local key = readstring(new, i * BOX, BOX)
		local j = first[key]
		if j ~= nil then
			matched[i + 1] = j
			used[j + 1] = true
			kept += 1
			local after = nextSame[j + 1]
			if after >= 0 then
				first[key] = after
			else
				first[key] = nil
			end
		end
	end
	local removed: { number } = table.create(oldCount - kept)
	for j = 0, oldCount - 1 do
		if not used[j + 1] then
			table.insert(removed, j)
		end
	end
	return matched, removed, kept
end

return SectionDiff
