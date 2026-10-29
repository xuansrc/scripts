--[[
    MeowX Dump v2  (Violence District)
    Exports what YOUR client can see: scripts, remotes, attributes, tags, config data and a live log.
    Run it once (lobby or round, any role). It saves by itself; F8 = full save now, F9 = drop a MARK in the logs.

    What you get in <executor workspace>/MeowX_Dump/ (<Role> = Survivors_Veil, Killer_Abysswalker, ...):
      <Role>_Scripts/                one file per script, named by its FULL path (ReplicatedStorage.Modules.Killers.Butcher.TrapButton.lua)
      <Role>_Scripts/_Index.txt      every script: path | class | origin | lines | hash | note
      <Role>_Scripts.txt             all scripts in one file ("-- Script Path: ..." format)
      <Role>_RuntimeScripts/         scripts that appeared later (e.g. cloned into you when trapped / when you become killer)
      <Role>_Remotes.txt             every remote with class + full path
      <Role>_RemoteXRef.txt          for each remote: which scripts use it and the exact code line (with the argument shape)
      <Role>_AttributeNames.txt      every attribute name used by scripts (get / set / signal counts)
      <Role>_Tags.txt                every CollectionService tag (from scripts + live counts)
      <Role>_Census.txt              live attribute names + sample values found in the world
      <Role>_ModuleData.txt          values of already-loaded config/data modules (exact numbers, no decompile needed)
      <Role>_Extra.txt               trees: character, killers, perks, items, GUI, players
      <Role>_RemoteLog.txt           ordered timeline: your remote calls, server events, attribute changes, tag changes, MARKs
      <Role>_RemoteStats.txt         your remote calls grouped by argument shape (shows exact args like "begin" / "succes")
      <Role>_ServerEvents.txt        server -> client events grouped by argument shape
]]
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local CS = game:GetService("CollectionService")
local StarterGui = game:GetService("StarterGui")
local LP = Players.LocalPlayer

assert(type(writefile) == "function", "executor has no writefile")

local CONFIG = {
	PerScriptFiles = true,
	CombinedFile = true,
	ModuleDataPatterns = {"config", "data", "settings", "constants", "stats", "tuning", "balance", "tiers", "perks"},
	LogInterval = 10,
	MaxTimeline = 8000,
	MaxSigsPerRemote = 30,
}

local ROOT = "MeowX_Dump"
local decomp = type(decompile) == "function" and decompile or nil
if not decomp then
	warn("[MeowX Dump] decompile() not available: scripts will only be listed by path")
end

local function ensureFolder(path)
	pcall(function()
		if type(makefolder) == "function" and not (type(isfolder) == "function" and isfolder(path)) then
			makefolder(path)
		end
	end)
end
ensureFolder(ROOT)

local function write(name, text)
	local ok = pcall(writefile, name, text)
	return ok
end

local function fileSafe(s)
	return (tostring(s):gsub("[^%w%._%-]", "_"))
end

local function notify(text)
	print("[MeowX Dump] " .. text)
	pcall(function()
		StarterGui:SetCore("SendNotification", {Title = "MeowX Dump", Text = text, Duration = 5})
	end)
end

local function role()
	local team = LP.Team and LP.Team.Name or "NoTeam"
	local killer = LP:GetAttribute("SelectedKiller")
	return ((killer and (team .. "_" .. tostring(killer)) or team):gsub("[^%w_]", ""))
end

----------------------------------------------------------------------
-- serialisers
----------------------------------------------------------------------
local function ser(v, depth)
	depth = depth or 0
	local t = typeof(v)
	if t == "Instance" then
		return "Instance<" .. v.ClassName .. ">(" .. v:GetFullName() .. ")"
	elseif t == "string" then
		return string.format("%q", v)
	elseif t == "number" or t == "boolean" or t == "nil" then
		return tostring(v)
	elseif t == "buffer" then
		return "buffer(" .. tostring(pcall(buffer.len, v) and buffer.len(v) or "?") .. ")"
	elseif t == "table" then
		if depth >= 2 then
			return "{...}"
		end
		local parts, n = {}, 0
		for k, x in pairs(v) do
			n += 1
			if n > 12 then
				parts[#parts + 1] = "..."
				break
			end
			parts[#parts + 1] = "[" .. ser(k, depth + 1) .. "]=" .. ser(x, depth + 1)
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return t .. "(" .. tostring(v) .. ")"
end

local function serDeep(v, depth, maxDepth, seen)
	local t = typeof(v)
	if t == "string" then
		return string.format("%q", v)
	elseif t == "number" or t == "boolean" or t == "nil" then
		return tostring(v)
	elseif t == "function" then
		return "function"
	elseif t == "Instance" then
		return "Instance<" .. v.ClassName .. ">(" .. v:GetFullName() .. ")"
	elseif t == "table" then
		if depth >= maxDepth then
			return "{...}"
		end
		seen = seen or {}
		if seen[v] then
			return "{<cycle>}"
		end
		seen[v] = true
		local keys = {}
		for k in pairs(v) do
			keys[#keys + 1] = k
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		local pad = string.rep("  ", depth + 1)
		local parts = {}
		for i, k in ipairs(keys) do
			if i > 300 then
				parts[#parts + 1] = pad .. "..."
				break
			end
			parts[#parts + 1] = pad .. "[" .. serDeep(k, depth + 1, maxDepth, seen) .. "] = " .. serDeep(v[k], depth + 1, maxDepth, seen)
		end
		seen[v] = nil
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("  ", depth) .. "}"
	end
	return t .. "(" .. tostring(v) .. ")"
end

local function sigOf(a)
	local t = {}
	for i = 1, a.n do
		local ty = typeof(a[i])
		if ty == "string" and #a[i] <= 20 then
			ty = 'string"' .. a[i] .. '"'
		end
		t[i] = ty
	end
	return table.concat(t, ",")
end

----------------------------------------------------------------------
-- ordered timeline + per-remote stats
----------------------------------------------------------------------
local t0 = os.clock()
local function stamp()
	return string.format("%.2f", os.clock() - t0)
end

local timeline = {}
local function tl(line)
	if #timeline < CONFIG.MaxTimeline then
		timeline[#timeline + 1] = "[" .. stamp() .. "] " .. line
	end
end

local NOISY = {
	updatecharacterlook = true, netremote = true, lookvectorgiver = true, syncposition = true,
	progressupdateevent = true, animationhandler = true, soundplayer = true, fovevent = true,
}

local outStats, inStats = {}, {}
local function record(stats, remote, method, a, example)
	local key = remote:GetFullName()
	local st = stats[key]
	if not st then
		st = {count = 0, method = method, first = stamp(), last = stamp(), sigs = {}, order = {}}
		stats[key] = st
	end
	st.count += 1
	st.last = stamp()
	local sig = sigOf(a)
	local s = st.sigs[sig]
	if not s then
		if #st.order >= CONFIG.MaxSigsPerRemote then
			return key
		end
		s = {n = 0, ex = {}}
		st.sigs[sig] = s
		st.order[#st.order + 1] = sig
	end
	s.n += 1
	if #s.ex < 3 then
		s.ex[#s.ex + 1] = "[" .. stamp() .. "] " .. example
	end
	return key
end

local function serArgs(a)
	local parts = {}
	for i = 1, a.n do
		parts[i] = ser(a[i])
	end
	return table.concat(parts, ", ")
end

local function formatStats(stats, title)
	local keys = {}
	for k in pairs(stats) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	local out = {title}
	for _, k in ipairs(keys) do
		local st = stats[k]
		out[#out + 1] = string.format("\n%s  [%s]  count=%d  first=%s  last=%s", k, st.method, st.count, st.first, st.last)
		for _, sig in ipairs(st.order) do
			local s = st.sigs[sig]
			out[#out + 1] = string.format("  args(%s) x%d", sig, s.n)
			for _, ex in ipairs(s.ex) do
				out[#out + 1] = "     " .. ex
			end
		end
	end
	return table.concat(out, "\n")
end

-- outgoing: your own FireServer / InvokeServer calls (the game's calls, not the executor's)
local logger = false
if type(hookmetamethod) == "function" and type(newcclosure) == "function" and type(getnamecallmethod) == "function" then
	local old
	old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		local method = getnamecallmethod()
		if (method == "FireServer" or method == "InvokeServer") and typeof(self) == "Instance" and not (checkcaller and checkcaller()) then
			local a = table.pack(...)
			pcall(function()
				local text = self.Name .. ":" .. method .. "(" .. serArgs(a) .. ")"
				local key = record(outStats, self, method, a, text)
				if not NOISY[self.Name:lower()] then
					tl("-> " .. key .. ":" .. method .. "(" .. serArgs(a) .. ")")
				end
			end)
		end
		return old(self, ...)
	end))
	logger = true
else
	warn("[MeowX Dump] hookmetamethod unavailable: outgoing remote logging disabled (use Cobalt instead)")
end

-- incoming: server -> client events
local hooked = setmetatable({}, {__mode = "k"})
local function hookIncoming(r)
	if hooked[r] or not (r:IsA("RemoteEvent") or r:IsA("UnreliableRemoteEvent")) then
		return
	end
	hooked[r] = true
	r.OnClientEvent:Connect(function(...)
		local a = table.pack(...)
		pcall(function()
			local key = record(inStats, r, "OnClientEvent", a, "(" .. serArgs(a) .. ")")
			if not NOISY[r.Name:lower()] then
				tl("<- " .. key .. "(" .. serArgs(a) .. ")")
			end
		end)
	end)
end
task.spawn(function()
	local remotes = RS:WaitForChild("Remotes", 30)
	if not remotes then
		return
	end
	for _, r in ipairs(remotes:GetDescendants()) do
		hookIncoming(r)
	end
	remotes.DescendantAdded:Connect(hookIncoming)
end)

----------------------------------------------------------------------
-- live attribute + tag watcher (shows exactly when Trapped / EscapingTrap / isHealing etc. change)
----------------------------------------------------------------------
local watched = setmetatable({}, {__mode = "k"})
local function watch(inst, label)
	if not inst or watched[inst] then
		return
	end
	watched[inst] = true
	pcall(function()
		for k, v in pairs(inst:GetAttributes()) do
			tl("ATTR " .. label .. "." .. k .. " = " .. tostring(v) .. " (initial)")
		end
		inst.AttributeChanged:Connect(function(name)
			tl("ATTR " .. label .. "." .. name .. " -> " .. tostring(inst:GetAttribute(name)))
		end)
	end)
end

local function bindCharacter(plr, char)
	local label = (plr == LP) and "ME" or plr.Name
	task.spawn(function()
		watch(char, label .. ".char")
		local hrp = char:WaitForChild("HumanoidRootPart", 10)
		watch(hrp, label .. ".hrp")
		watch(char:WaitForChild("Humanoid", 10), label .. ".humanoid")
		local ci = char:WaitForChild("CheckInterractable", 10)
		watch(ci, label .. ".check")
	end)
end

local function bindPlayer(plr)
	if plr == LP then
		watch(plr, "ME.player")
	end
	if plr.Character then
		bindCharacter(plr, plr.Character)
	end
	plr.CharacterAdded:Connect(function(c)
		bindCharacter(plr, c)
	end)
end
for _, p in ipairs(Players:GetPlayers()) do
	bindPlayer(p)
end
Players.PlayerAdded:Connect(bindPlayer)

task.spawn(function()
	local last = {}
	while true do
		task.wait(0.25)
		local char = LP.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		for label, inst in pairs({char = char, hrp = hrp}) do
			if inst then
				local now, prev = {}, last[inst] or {}
				local okTags, tags = pcall(CS.GetTags, CS, inst)
				if okTags then
					for _, tag in ipairs(tags) do
						now[tag] = true
						if not prev[tag] then
							tl("TAG+ ME." .. label .. " " .. tag)
						end
					end
					for tag in pairs(prev) do
						if not now[tag] then
							tl("TAG- ME." .. label .. " " .. tag)
						end
					end
					last[inst] = now
				end
			end
		end
	end
end)

----------------------------------------------------------------------
-- 1) scripts (everything the client can reach, one file each, full-path names)
----------------------------------------------------------------------
local SKIP_LIB = {"SmartBone", "PlayerModule", "Moonlite", "CameraShaker", "RbxCharacterSounds"}
local function isLib(path)
	for _, k in ipairs(SKIP_LIB) do
		if path:find(k, 1, true) then
			return true
		end
	end
	return false
end

local function scriptPath(inst)
	local ok, full = pcall(inst.GetFullName, inst)
	if not ok then
		return "unknown." .. tostring(inst.Name)
	end
	if not inst:IsDescendantOf(game) then
		return "nil." .. full
	end
	return full
end

local function readSource(inst)
	if not decomp then
		return nil, "decompile unavailable"
	end
	local ok, res = pcall(decomp, inst)
	if ok and type(res) == "string" and #res > 0 then
		return res
	end
	return nil, ok and "empty result" or tostring(res)
end

local function hashOf(inst)
	if type(getscripthash) == "function" then
		local ok, h = pcall(getscripthash, inst)
		if ok and h then
			return tostring(h)
		end
	end
	return "-"
end

local function isScriptClass(inst)
	local cn = inst.ClassName
	return cn == "LocalScript" or cn == "ModuleScript" or cn == "Script"
end

local function collectScripts()
	local list, seen = {}, {}
	local function add(inst, origin)
		if typeof(inst) ~= "Instance" or seen[inst] or not isScriptClass(inst) then
			return
		end
		seen[inst] = true
		list[#list + 1] = {inst = inst, origin = origin}
	end
	local n = 0
	for _, d in ipairs(game:GetDescendants()) do
		n += 1
		if n % 4000 == 0 then
			task.wait()
		end
		add(d, "game")
	end
	if type(getscripts) == "function" then
		pcall(function()
			for _, s in ipairs(getscripts()) do
				add(s, "getscripts")
			end
		end)
	end
	if type(getloadedmodules) == "function" then
		pcall(function()
			for _, s in ipairs(getloadedmodules()) do
				add(s, "getloadedmodules")
			end
		end)
	end
	if type(getnilinstances) == "function" then
		pcall(function()
			for _, s in ipairs(getnilinstances()) do
				add(s, "nil-parent")
			end
		end)
	end
	return list
end

local knownKeys = {} -- path:length of everything dumped in the full save (runtime watcher skips these)

local function dumpScripts(prefix)
	local list = collectScripts()
	local dir = ROOT .. "/" .. prefix .. "_Scripts"
	if CONFIG.PerScriptFiles then
		ensureFolder(dir)
	end
	local entries, combined, index, used = {}, {}, {}, {}
	for i, item in ipairs(list) do
		local inst = item.inst
		local path = scriptPath(inst)
		if not (path:find("^CoreGui") or path:find("^CorePackages") or path:find("^nil%.CoreGui")) then
			local lib = isLib(path)
			local src, err
			if not lib then
				src, err = readSource(inst)
			end
			local note = lib and "library (not decompiled)" or (err or "")
			local lines = 0
			if src then
				for _ in src:gmatch("\n") do
					lines += 1
				end
			end
			local entry = {path = path, class = inst.ClassName, origin = item.origin, src = src, lib = lib}
			entries[#entries + 1] = entry
			index[#index + 1] = string.format("%s | %s | %s | %d lines | %s | %s", path, inst.ClassName, item.origin, lines, hashOf(inst), note)
			knownKeys[path .. ":" .. tostring(src and #src or 0)] = true

			local body = src or ("-- (no source: " .. note .. ")")
			if CONFIG.PerScriptFiles then
				local name = fileSafe(path)
				if #name > 150 then
					name = name:sub(1, 150)
				end
				used[name] = (used[name] or 0) + 1
				if used[name] > 1 then
					name = name .. "_" .. used[name]
				end
				write(dir .. "/" .. name .. ".lua", "-- Script Path: " .. path .. "\n-- Class: " .. inst.ClassName .. " | Origin: " .. item.origin .. "\n" .. body)
			end
			if CONFIG.CombinedFile then
				combined[#combined + 1] = "-- Script Path: " .. path .. "\n" .. body .. "\n\n"
			end
		end
		if i % 8 == 0 then
			task.wait()
		end
	end
	table.sort(index)
	if CONFIG.PerScriptFiles then
		write(dir .. "/_Index.txt", "path | class | origin | lines | hash | note\n" .. table.concat(index, "\n"))
	end
	if CONFIG.CombinedFile then
		write(ROOT .. "/" .. prefix .. "_Scripts.txt", table.concat(combined))
	end
	return entries
end

----------------------------------------------------------------------
-- 2) remotes list + cross reference (which script uses which remote, and with which arguments)
----------------------------------------------------------------------
local function remoteCatalog()
	local full, byShort = {}, {}
	local root = RS:FindFirstChild("Remotes")
	if root then
		for _, r in ipairs(root:GetDescendants()) do
			if r:IsA("RemoteEvent") or r:IsA("RemoteFunction") or r:IsA("UnreliableRemoteEvent") then
				local fn = r:GetFullName()
				full[fn] = r.ClassName
				byShort[r.Name] = byShort[r.Name] or {}
				table.insert(byShort[r.Name], fn)
			end
		end
	end
	return full, byShort
end

local function dumpRemotes(prefix, full)
	local names = {}
	for fn, cls in pairs(full) do
		names[#names + 1] = cls .. "  " .. fn
	end
	table.sort(names)
	write(ROOT .. "/" .. prefix .. "_Remotes.txt", table.concat(names, "\n"))
	return #names
end

local function analyze(prefix, entries, remoteFull, byShort)
	local xref, attrs, tags = {}, {}, {}
	local function addRef(key, text)
		xref[key] = xref[key] or {}
		if #xref[key] < 40 then
			table.insert(xref[key], text)
		end
	end
	local function bump(map, name, kind, path)
		local e = map[name]
		if not e then
			e = {get = 0, set = 0, signal = 0, scripts = 0, sample = path, last = nil}
			map[name] = e
		end
		e[kind] += 1
		if e.last ~= path then
			e.scripts += 1
			e.last = path
		end
	end

	for _, entry in ipairs(entries) do
		if entry.src then
			local varMap = {}
			local ln = 0
			for line in (entry.src .. "\n"):gmatch("([^\n]*)\n") do
				ln += 1
				local where = entry.path .. ":L" .. ln

				-- full dotted remote paths: Remotes.Killers.Butcher.FreeTrap
				for chain in line:gmatch("Remotes%.([%w_%.]+)") do
					local segs = {}
					for s in chain:gmatch("[%w_]+") do
						segs[#segs + 1] = s
					end
					for n = #segs, 1, -1 do
						local candidate = "ReplicatedStorage.Remotes." .. table.concat(segs, ".", 1, n)
						if remoteFull[candidate] then
							addRef(candidate, where .. "   " .. line:gsub("^%s+", ""))
							break
						end
					end
				end

				-- WaitForChild("Name") / FindFirstChild("Name") on a known remote name, plus the variable it is stored in
				for name in line:gmatch('WaitForChild%("([^"]+)"') do
					local cands = byShort[name]
					if cands then
						local label
						if #cands == 1 then
							label = cands[1]
						else
							for _, fnm in ipairs(cands) do
								local folder = line:match("([%w_]+):WaitForChild%(\"" .. name .. "\"")
								if folder and fnm:find("%." .. folder .. "%." .. name .. "$") then
									label = fnm
								end
							end
							label = label or ("?" .. name .. " (one of: " .. table.concat(cands, ", ") .. ")")
						end
						local var = line:match("^%s*local%s+([%w_]+)%s*=") or line:match("^%s*([%w_]+)%s*=[^=]")
						if var then
							varMap[var] = label
						end
						addRef(label, where .. "   " .. line:gsub("^%s+", ""))
					end
				end

				for var, label in pairs(varMap) do
					if line:find(var .. ":FireServer(", 1, true) or line:find(var .. ":InvokeServer(", 1, true)
						or line:find(var .. ".OnClientEvent", 1, true) or line:find(var .. ".OnClientInvoke", 1, true) then
						addRef(label, where .. "   " .. line:gsub("^%s+", ""))
					end
				end

				for n in line:gmatch('GetAttribute%("([^"]+)"%)') do
					bump(attrs, n, "get", entry.path)
				end
				for n in line:gmatch('SetAttribute%("([^"]+)"') do
					bump(attrs, n, "set", entry.path)
				end
				for n in line:gmatch('GetAttributeChangedSignal%("([^"]+)"%)') do
					bump(attrs, n, "signal", entry.path)
				end
				for n in line:gmatch('GetTagged%("([^"]+)"%)') do
					bump(tags, n, "get", entry.path)
				end
				for n in line:gmatch('HasTag%([^%)]-"([^"]+)"%)') do
					bump(tags, n, "get", entry.path)
				end
				for n in line:gmatch('AddTag%([^%)]-"([^"]+)"%)') do
					bump(tags, n, "set", entry.path)
				end
				for n in line:gmatch('GetInstanceAddedSignal%("([^"]+)"%)') do
					bump(tags, n, "signal", entry.path)
				end
			end
		end
	end

	-- RemoteXRef
	local keys = {}
	for k in pairs(xref) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	local out = {"== Remote cross reference: script:line   code ==\n"}
	for _, k in ipairs(keys) do
		out[#out + 1] = "\n### " .. k .. (remoteFull[k] and ("  (" .. remoteFull[k] .. ")") or "")
		for _, ref in ipairs(xref[k]) do
			out[#out + 1] = "  " .. ref
		end
	end
	out[#out + 1] = "\n\n== Remotes with no reference found in client scripts (server-only, dynamic names, or unused) =="
	local unref = {}
	for fn in pairs(remoteFull) do
		if not xref[fn] then
			unref[#unref + 1] = fn
		end
	end
	table.sort(unref)
	out[#out + 1] = table.concat(unref, "\n")
	write(ROOT .. "/" .. prefix .. "_RemoteXRef.txt", table.concat(out, "\n"))

	local function dumpNames(map, file, title)
		local names = {}
		for n in pairs(map) do
			names[#names + 1] = n
		end
		table.sort(names)
		local o = {title}
		for _, n in ipairs(names) do
			local e = map[n]
			o[#o + 1] = string.format("%s   get=%d set=%d signal=%d   scripts=%d   e.g. %s", n, e.get, e.set, e.signal, e.scripts, e.sample)
		end
		write(file, table.concat(o, "\n"))
		return names
	end
	dumpNames(attrs, ROOT .. "/" .. prefix .. "_AttributeNames.txt", "== Attribute names used by scripts ==")

	-- tags: scripts + live world
	local tagNames = dumpNames(tags, ROOT .. "/" .. prefix .. "_Tags.txt", "== Tags used by scripts ==")
	local live = {"\n\n== Live tags in the world (CollectionService) =="}
	local okT, allTags = pcall(CS.GetAllTags, CS)
	if okT then
		table.sort(allTags)
		for _, tag in ipairs(allTags) do
			local tagged = CS:GetTagged(tag)
			local sample = {}
			for i = 1, math.min(3, #tagged) do
				sample[#sample + 1] = tagged[i]:GetFullName()
			end
			live[#live + 1] = string.format("%s  x%d  e.g. %s", tag, #tagged, table.concat(sample, " | "))
		end
	else
		for _, n in ipairs(tagNames) do
			local tagged = CS:GetTagged(n)
			live[#live + 1] = string.format("%s  x%d", n, #tagged)
		end
	end
	pcall(appendfile, ROOT .. "/" .. prefix .. "_Tags.txt", table.concat(live, "\n"))
end

----------------------------------------------------------------------
-- 3) live census of attribute names (what is actually set in the world right now)
----------------------------------------------------------------------
local function dumpCensus(prefix)
	local names = {}
	local function scan(inst)
		local ok, at = pcall(inst.GetAttributes, inst)
		if not ok then
			return
		end
		for k, v in pairs(at) do
			local e = names[k]
			if not e then
				e = {n = 0, samples = {}, where = inst:GetFullName()}
				names[k] = e
			end
			e.n += 1
			local sv = typeof(v) .. "=" .. tostring(v)
			if #e.samples < 3 then
				local dup = false
				for _, s in ipairs(e.samples) do
					if s == sv then
						dup = true
					end
				end
				if not dup then
					e.samples[#e.samples + 1] = sv
				end
			end
		end
	end
	scan(LP)
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			scan(p.Character)
			for _, d in ipairs(p.Character:GetDescendants()) do
				scan(d)
			end
		end
	end
	local n = 0
	for _, d in ipairs(workspace:GetDescendants()) do
		n += 1
		if n % 3000 == 0 then
			task.wait()
		end
		scan(d)
	end
	local keys = {}
	for k in pairs(names) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	local out = {"== Live attribute names (name  x count  samples  first seen at) =="}
	for _, k in ipairs(keys) do
		local e = names[k]
		out[#out + 1] = string.format("%s  x%d  [%s]  %s", k, e.n, table.concat(e.samples, ", "), e.where)
	end
	write(ROOT .. "/" .. prefix .. "_Census.txt", table.concat(out, "\n"))
end

----------------------------------------------------------------------
-- 4) exact values of loaded config / data modules
----------------------------------------------------------------------
local function dumpModuleData(prefix)
	if type(getloadedmodules) ~= "function" then
		return 0
	end
	local out, count = {}, 0
	local okList, mods = pcall(getloadedmodules)
	if not okList then
		return 0
	end
	for _, m in ipairs(mods) do
		local lname = m.Name:lower()
		local hit = false
		for _, p in ipairs(CONFIG.ModuleDataPatterns) do
			if lname:find(p, 1, true) then
				hit = true
				break
			end
		end
		local path = scriptPath(m)
		if hit and not isLib(path) then
			-- already loaded by the game, so require() only returns the cached value
			local ok, data = pcall(require, m)
			if ok and type(data) == "table" then
				count += 1
				out[#out + 1] = "-- Module: " .. path .. "\n" .. serDeep(data, 0, 5) .. "\n"
			end
		end
	end
	write(ROOT .. "/" .. prefix .. "_ModuleData.txt", table.concat(out, "\n"))
	return count
end

----------------------------------------------------------------------
-- 5) trees (character, backpack, killers, perks, items, GUI, players)
----------------------------------------------------------------------
local function tree(inst, depth, lines, maxd)
	if depth > maxd then
		return
	end
	local at = {}
	pcall(function()
		for k, v in pairs(inst:GetAttributes()) do
			table.insert(at, k .. "=" .. tostring(v))
		end
	end)
	local tg = {}
	pcall(function()
		for _, t in ipairs(CS:GetTags(inst)) do
			table.insert(tg, t)
		end
	end)
	table.insert(lines, string.rep("  ", depth) .. inst.Name .. " [" .. inst.ClassName .. "]"
		.. (#at > 0 and (" {" .. table.concat(at, ", ") .. "}") or "")
		.. (#tg > 0 and (" tags:" .. table.concat(tg, ",")) or ""))
	for _, c in ipairs(inst:GetChildren()) do
		tree(c, depth + 1, lines, maxd)
	end
end

local function dumpExtra(prefix)
	local L = {}
	local function sec(t)
		table.insert(L, "\n===== " .. t .. " =====")
	end
	sec("LocalPlayer attributes")
	pcall(function()
		for k, v in pairs(LP:GetAttributes()) do
			table.insert(L, k .. " = " .. tostring(v))
		end
	end)
	sec("Character tree")
	if LP.Character then
		tree(LP.Character, 0, L, 5)
	end
	sec("Backpack")
	local bp = LP:FindFirstChildOfClass("Backpack")
	if bp then
		tree(bp, 0, L, 3)
	end
	sec("ReplicatedStorage top level (depth 2)")
	pcall(function()
		tree(RS, 0, L, 2)
	end)
	sec("ReplicatedStorage.Killers (every killer: abilities, numbers) depth 5")
	pcall(function()
		if RS:FindFirstChild("Killers") then
			tree(RS.Killers, 0, L, 5)
		end
	end)
	sec("ReplicatedStorage.Perks depth 3")
	pcall(function()
		if RS:FindFirstChild("Perks") then
			tree(RS.Perks, 0, L, 3)
		end
	end)
	sec("ReplicatedStorage.Items depth 3")
	pcall(function()
		if RS:FindFirstChild("Items") then
			tree(RS.Items, 0, L, 3)
		end
	end)
	sec("Pumpkins (workspace.Map.Pumpkins)")
	pcall(function()
		local p = workspace.Map.Pumpkins
		local n = 0
		for _, c in ipairs(p:GetChildren()) do
			n += 1
			if n <= 3 then
				tree(c, 0, L, 3)
			end
		end
		table.insert(L, "total pumpkins: " .. n)
	end)
	sec("StarterGui prompts (ZIndex)")
	for _, gname in ipairs({"consoleprompts", "pcprompts"}) do
		pcall(function()
			local g = StarterGui[gname]
			for _, d in ipairs(g:GetDescendants()) do
				if d:IsA("GuiObject") then
					table.insert(L, gname .. ": " .. d:GetFullName() .. " ZIndex=" .. d.ZIndex .. " Visible=" .. tostring(d.Visible))
				end
			end
		end)
	end
	sec("PlayerGui (live) tree, depth 4")
	pcall(function()
		tree(LP.PlayerGui, 0, L, 4)
	end)
	sec("Workspace top level")
	for _, c in ipairs(workspace:GetChildren()) do
		table.insert(L, c.Name .. " [" .. c.ClassName .. "]")
	end
	sec("Players (team/attributes)")
	for _, p in ipairs(Players:GetPlayers()) do
		local at = {}
		pcall(function()
			for k, v in pairs(p:GetAttributes()) do
				table.insert(at, k .. "=" .. tostring(v))
			end
		end)
		table.insert(L, p.Name .. " team=" .. tostring(p.Team and p.Team.Name) .. " " .. table.concat(at, ", "))
	end
	write(ROOT .. "/" .. prefix .. "_Extra.txt", table.concat(L, "\n"))
end

----------------------------------------------------------------------
-- logs
----------------------------------------------------------------------
local function writeLogs(prefix)
	write(ROOT .. "/" .. prefix .. "_RemoteLog.txt", table.concat(timeline, "\n"))
	write(ROOT .. "/" .. prefix .. "_RemoteStats.txt", formatStats(outStats, "== Your remote calls, grouped by argument shape =="))
	write(ROOT .. "/" .. prefix .. "_ServerEvents.txt", formatStats(inStats, "== Server -> client events, grouped by argument shape =="))
end

----------------------------------------------------------------------
-- full save + runtime script watcher
----------------------------------------------------------------------
local lastRole, saving, fullDone = nil, false, false

local function fullSave()
	if saving then
		return
	end
	saving = true
	local prefix = role()
	local entries = {}
	local okScripts, res = pcall(dumpScripts, prefix)
	if okScripts then
		entries = res
	else
		warn("[MeowX Dump] scripts failed: " .. tostring(res))
	end
	local remoteFull, byShort = {}, {}
	pcall(function()
		remoteFull, byShort = remoteCatalog()
	end)
	local nRemotes = 0
	pcall(function()
		nRemotes = dumpRemotes(prefix, remoteFull)
	end)
	pcall(analyze, prefix, entries, remoteFull, byShort)
	local nMods = 0
	pcall(function()
		nMods = dumpModuleData(prefix)
	end)
	pcall(dumpExtra, prefix)
	pcall(dumpCensus, prefix)
	pcall(writeLogs, prefix)
	lastRole = prefix
	fullDone = true
	saving = false
	notify(string.format("saved %s: %d scripts, %d remotes, %d config modules, logger %s", prefix, #entries, nRemotes, nMods, logger and "ON" or "OFF"))
end

-- scripts that show up later (cloned into you when trapped / when you become a killer, etc.)
local runtimeQueue = {}
game.DescendantAdded:Connect(function(d)
	local cn = d.ClassName
	if cn == "LocalScript" or cn == "ModuleScript" then
		runtimeQueue[#runtimeQueue + 1] = d
	end
end)
task.spawn(function()
	local dumpedRuntime = {}
	while true do
		task.wait(1)
		while fullDone and #runtimeQueue > 0 do
			local inst = table.remove(runtimeQueue, 1)
			task.wait(0.4)
			local path = scriptPath(inst)
			if not (path:find("^CoreGui") or path:find("^CorePackages") or isLib(path)) then
				local src, err = readSource(inst)
				local key = path .. ":" .. tostring(src and #src or 0)
				if not knownKeys[key] and not dumpedRuntime[key] then
					dumpedRuntime[key] = true
					local dir = ROOT .. "/" .. role() .. "_RuntimeScripts"
					ensureFolder(dir)
					write(dir .. "/" .. fileSafe(path) .. "_t" .. stamp():gsub("%.", "_") .. ".lua",
						"-- Script Path: " .. path .. "\n-- Added at t=" .. stamp() .. "\n" .. (src or ("-- (no source: " .. tostring(err) .. ")")))
					tl("SCRIPT+ " .. path)
				end
			end
		end
	end
end)

task.spawn(function()
	task.wait(5)
	fullSave()
	local tick = 0
	while true do
		task.wait(CONFIG.LogInterval)
		tick += 1
		if role() ~= lastRole then
			fullSave()
		else
			pcall(writeLogs, role())
			if tick % 6 == 0 then
				pcall(dumpExtra, role())
			end
		end
	end
end)

local marks = 0
UIS.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F8 then
		task.spawn(fullSave)
	elseif input.KeyCode == Enum.KeyCode.F9 then
		marks += 1
		tl("=== MARK " .. marks .. " ===")
		notify("MARK " .. marks .. " saved in the timeline")
	end
end)

print("[MeowX Dump v2] running (outgoing logger " .. (logger and "ON" or "OFF") .. "). Play normally; files save by themselves. F8 = full save, F9 = mark.")
