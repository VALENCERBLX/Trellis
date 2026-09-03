--!nonstrict
-- Trellis
-- Reg.luau
-- Valence
--
-- The global cache. A TREE, not a flat store: Cat is CATEGORY.
--
--   local Reg = Src:Reg("Round")
--   Reg:New("Scores", {})              Reg:Access("Scores")
--   Reg:Edit("Scores", { red = 3 })    Reg:Bubble("Scores", fn)
--   Reg:Swap("Scores", fresh)          Reg:Rem("Scores")
--   local Stats = Reg:Cat("Stats")     -- scopes in, like Src:Local(domain)
--
-- The five mutation verbs ARE the replication protocol: each one is a path-shaped
-- delta { Op, Reg, Owner, Path, Value }. Reads never leave the local mirror, which
-- is why Access and Bubble sit outside that set.
--
-- ONLY Cat creates a category. Access and Edit traverse existing ones and error on
-- a path that does not resolve, naming the segment that failed and listing its real
-- siblings. Otherwise Reg:Edit("Comabt.Health", 5) grows a phantom branch and you are
-- back to a bag of strings.
--
-- Authority: a client mutation is a REQUEST. The server validates it against the
-- register's Policies, applies it, and echoes the authoritative delta. Every verb
-- returns a thenable on BOTH sides (already-resolved on the server) so a side-split
-- Service can move sides without a rewrite.

local Reaction = require(script.Parent.Reaction)

local Reg = {}
Reg.__index = Reg

local Register = {}
Register.__index = Register

local function fail(...)
	error("[Trellis] " .. string.format(...), 0)
end

local function split(path: string): { string }
	local parts = {}
	for segment in string.gmatch(path, "[^%.]+") do
		table.insert(parts, segment)
	end
	if #parts == 0 then
		fail("empty path")
	end
	return parts
end

local function join(prefix: string, name: string): string
	return if prefix == "" then name else prefix .. "." .. name
end

-- Dots separate segments, so a key containing one would be ambiguous forever after.
local function checkKey(name: string)
	if type(name) ~= "string" then
		fail("a register key must be a string, got %s", type(name))
	end
	if string.find(name, ".", 1, true) then
		fail("register key %q contains a dot -- dots separate path segments", name)
	end
end

-- ================================================================= categories ===

local function newCategory(name: string, path: string, declared)
	local cat = {
		Name = name,
		Path = path,
		Values = {},
		Cats = {},
		Dynamic = declared and declared.Dynamic == true or false,
	}

	for child, spec in (declared and declared.Cats) or {} do
		cat.Cats[child] = newCategory(child, join(path, child), spec)
	end

	return cat
end

local function siblings(cat): string
	local names = {}
	for name in cat.Cats do
		table.insert(names, name)
	end
	table.sort(names)
	return if #names == 0 then "(none)" else table.concat(names, ", ")
end

-- Walk every segment but the last as a CATEGORY. A missing category is a structural
-- typo and throws; a missing value is legitimate and comes back nil.
local function descend(root, parts: { string })
	local cat = root
	for i = 1, #parts - 1 do
		local next_ = cat.Cats[parts[i]]
		if not next_ then
			fail(
				"no category %q under %q. categories there: %s",
				parts[i],
				if cat.Path == "" then "(root)" else cat.Path,
				siblings(cat)
			)
		end
		cat = next_
	end
	return cat, parts[#parts]
end

-- ================================================================== the store ===

function Reg.new(registers, side: string, transport, opts)
	local self = setmetatable({
		_side = side,
		_declared = registers or {},
		_transport = transport,
		_store = opts and opts.Store,
		_log = opts and opts.Log,
		_instances = {}, -- "Name" or "Name/ownerId" -> { Root, Watchers }
		_dirty = {},
	}, Reg)

	if transport and transport.OnDelta then
		transport.OnDelta(function(delta)
			self:_apply(delta, true)
		end)
	end

	if transport and transport.OnRequest then
		transport.OnRequest(function(delta, from)
			return self:_serve(delta, from)
		end)
	end

	return self
end

local function keyOf(name: string, owner): string
	return if owner then name .. "/" .. tostring(owner.UserId) else name
end

function Reg:_instance(name: string, owner)
	local declared = self._declared[name]
	if not declared then
		local known = {}
		for register in self._declared do
			table.insert(known, register)
		end
		table.sort(known)
		fail("no register %q. declared: %s", name, table.concat(known, ", "))
	end

	if declared.Replicate == "Owner" and not owner then
		fail('register %q replicates to "Owner", so it needs one: Src:Reg(%q, player)', name, name)
	end

	local key = keyOf(name, owner)
	local instance = self._instances[key]
	if not instance then
		instance = {
			Name = name,
			Owner = owner,
			Key = key,
			Declared = declared,
			Root = newCategory("", "", declared),
			Watchers = {},
		}
		self._instances[key] = instance

		if declared.Persist and self._side == "Server" then
			self:_hydrate(instance)
		end
	end
	return instance
end

-- ================================================================ persistence ===

-- Only VALUES are saved. The category shape comes from the declaration, so a stored
-- blob can never resurrect a category you have since removed from the map, and a
-- category you have since ADDED simply appears empty.
local function harvest(cat)
	local out = { V = {}, C = {} }
	for key, value in cat.Values do
		out.V[key] = value
	end
	for name, child in cat.Cats do
		out.C[name] = harvest(child)
	end
	return out
end

local function plant(cat, blob, declared)
	if type(blob) ~= "table" then
		return
	end
	for key, value in blob.V or {} do
		cat.Values[key] = value
	end
	for name, childBlob in blob.C or {} do
		local child = cat.Cats[name]
		if not child and cat.Dynamic then
			child = newCategory(name, join(cat.Path, name), nil)
			cat.Cats[name] = child
		end
		if child then
			plant(child, childBlob, nil)
		end
	end
end

function Reg:_hydrate(instance)
	if not self._store then
		fail(
			"register %q is Persist, but Configure was given no Store backend",
			instance.Name
		)
	end

	local ok, blob = pcall(self._store.Load, instance.Key)
	if not ok then
		warn(string.format("[Trellis] register %s failed to load: %s", instance.Key, tostring(blob)))
		return
	end
	plant(instance.Root, blob, instance.Declared)
	instance.Loaded = true
end

-- Write one register through to the backend. Safe to call often: it no-ops unless
-- something actually changed.
function Reg:Flush(name: string?, owner: any?): boolean
	if not self._store or self._side ~= "Server" then
		return false
	end

	local wrote = false
	for key, instance in self._instances do
		local match = (name == nil) or (instance.Name == name and instance.Owner == owner)
		if match and instance.Declared.Persist and self._dirty[key] then
			local ok, err = pcall(self._store.Save, key, harvest(instance.Root))
			if ok then
				self._dirty[key] = nil
				wrote = true
			else
				warn(string.format("[Trellis] register %s failed to save: %s", key, tostring(err)))
			end
		end
	end
	return wrote
end

function Reg:Dirty(): { string }
	local keys = {}
	for key in self._dirty do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- Src:Reg lands here. Returns a Register rooted at the top of that register.
function Reg:Open(name: string, owner)
	local instance = self:_instance(name, owner)
	return setmetatable({
		_reg = self,
		_instance = instance,
		_cat = instance.Root,
	}, Register)
end

-- A player left: flush anything of theirs that persists, release the backend's hold
-- on it, and forget the tree. Flushing BEFORE dropping is the whole point.
function Reg:Drop(owner)
	for key, instance in self._instances do
		if instance.Owner == owner then
			if instance.Declared.Persist then
				self:Flush(instance.Name, owner)
				if self._store and self._store.Release then
					pcall(self._store.Release, key)
				end
			end
			self._instances[key] = nil
			self._dirty[key] = nil
		end
	end
end

-- A shallow census for Inspect: what exists, how big, and whether it is waiting to
-- be written. Deliberately not the contents; the panel renders those on demand.
function Reg:Census(): { any }
	local rows = {}
	local function countCat(cat)
		local values, cats = 0, 0
		for _ in cat.Values do
			values += 1
		end
		for _, child in cat.Cats do
			cats += 1
			local v, c = countCat(child)
			values += v
			cats += c
		end
		return values, cats
	end

	for key, instance in self._instances do
		local values, cats = countCat(instance.Root)
		table.insert(rows, {
			Key = key,
			Name = instance.Name,
			Owner = instance.Owner and (instance.Owner.Name or tostring(instance.Owner)) or nil,
			Replicate = instance.Declared.Replicate,
			Persist = instance.Declared.Persist == true,
			Dirty = self._dirty[key] == true,
			Values = values,
			Cats = cats,
		})
	end

	table.sort(rows, function(a, b)
		return a.Key < b.Key
	end)
	return rows
end

-- ================================================================ replication ===

-- Who may write this path. No matching policy means server-only: deny by default,
-- since a cache anyone can write is not a cache, it's an exploit surface.
local function authority(declared, path: string): string
	local best, bestLen = "Server", -1
	for pattern, who in declared.Policies or {} do
		local prefix = string.match(pattern, "^(.-)%.%*$")
		if prefix then
			if path == prefix or string.sub(path, 1, #prefix + 1) == prefix .. "." then
				if #prefix > bestLen then
					best, bestLen = who, #prefix
				end
			end
		elseif pattern == path and #pattern > bestLen then
			best, bestLen = who, #pattern
		end
	end
	return best
end

function Reg:_audience(instance)
	local mode = instance.Declared.Replicate
	if mode == "All" then
		return "All"
	elseif mode == "Owner" then
		return instance.Owner
	end
	return nil -- Replicate = false: server-only, never leaves
end

function Reg:_emit(instance, delta)
	if self._side ~= "Server" or not self._transport then
		return
	end
	local audience = self:_audience(instance)
	if audience == "All" then
		self._transport.Broadcast(delta)
	elseif audience then
		self._transport.To(audience, delta)
	end
end

-- A client's request, arriving on the server.
function Reg:_serve(delta, from)
	local instance = self:_instance(delta.Reg, delta.Owner)
	local who = authority(instance.Declared, delta.Path)

	if who == "Server" then
		return false, string.format("%s.%s is server-authoritative", delta.Reg, delta.Path)
	end
	if who == "Owner" and instance.Owner ~= from then
		return false, string.format("%s.%s is the owner's to write", delta.Reg, delta.Path)
	end

	local ok, err = pcall(function()
		self:_apply(delta, false)
	end)
	if not ok then
		return false, tostring(err)
	end

	self:_emit(instance, delta)
	return true
end

-- ==================================================================== applying ===

local function merge(into, patch)
	for key, value in patch do
		if type(value) == "table" and type(into[key]) == "table" then
			merge(into[key], value)
		else
			into[key] = value
		end
	end
	return into
end

-- A change notifies the EXACT path and every ancestor category, so a watcher on
-- "Stats" fires for "Stats.Health" and can tell which by the path it is handed.
function Reg:_notify(instance, path: string, value, op: string)
	local parts = split(path)
	local prefix = ""

	for i = 1, #parts do
		prefix = join(prefix, parts[i])
		for _, watcher in instance.Watchers[prefix] or {} do
			task.spawn(watcher, value, path, op)
		end
	end
end

function Reg:_apply(delta, remote: boolean)
	local instance = self:_instance(delta.Reg, delta.Owner)
	local parts = split(delta.Path)
	local cat, key = descend(instance.Root, parts)

	if delta.Op == "Cat" then
		if not cat.Cats[key] then
			-- `remote` means this delta is the server's authoritative echo, which is
			-- trusted. A LOCAL apply of a Cat is a client's request arriving on the
			-- server, and it must obey Dynamic -- otherwise a client could conjure
			-- categories anywhere and grow the tree without limit.
			if not remote and not cat.Dynamic then
				fail(
					"%s.%s is not Dynamic, so %q cannot be created here",
					delta.Reg,
					if cat.Path == "" then "(root)" else cat.Path,
					key
				)
			end
			cat.Cats[key] = newCategory(key, delta.Path, nil)
		end
	elseif delta.Op == "New" then
		if cat.Values[key] ~= nil and not remote then
			fail("%s.%s already exists -- use :Swap or :Edit", delta.Reg, delta.Path)
		end
		cat.Values[key] = delta.Value
	elseif delta.Op == "Swap" then
		cat.Values[key] = delta.Value
	elseif delta.Op == "Edit" then
		local current = cat.Values[key]
		if type(current) ~= "table" or type(delta.Value) ~= "table" then
			cat.Values[key] = delta.Value
		else
			merge(current, delta.Value)
		end
	elseif delta.Op == "Rem" then
		cat.Values[key] = nil
	else
		fail("unknown register op %q", tostring(delta.Op))
	end

	if instance.Declared.Persist then
		self._dirty[instance.Key] = true
	end
	if self._log then
		self._log:Note("Reg." .. delta.Reg .. "." .. delta.Path, delta.Op)
	end

	self:_notify(instance, delta.Path, cat.Values[key], delta.Op)
end

-- =============================================================== the Register ===

function Register:_path(path: string): string
	return join(self._cat.Path, path)
end

-- Scope into a category, or create one when the parent was declared Dynamic. Cat is
-- the ONLY thing that creates a category. That is what stops a typo'd Access from
-- silently growing a branch.
function Register:Cat(name: string)
	checkKey(name)
	local child = self._cat.Cats[name]

	if not child then
		if not self._cat.Dynamic then
			fail(
				"no category %q under %q, and it is not Dynamic. categories there: %s",
				name,
				if self._cat.Path == "" then "(root)" else self._cat.Path,
				siblings(self._cat)
			)
		end
		child = newCategory(name, join(self._cat.Path, name), nil)
		self._cat.Cats[name] = child

		local reg = self._reg
		if reg._side == "Server" then
			reg:_emit(self._instance, {
				Op = "Cat",
				Reg = self._instance.Name,
				Owner = self._instance.Owner,
				Path = child.Path,
			})
		end
	end

	return setmetatable({ _reg = self._reg, _instance = self._instance, _cat = child }, Register)
end

-- Read. Synchronous, local mirror, never yields, never replicates. A missing
-- CATEGORY throws (structural typo); a missing VALUE is nil (it may just be unset).
function Register:Access(path: string)
	local cat, key = descend(self._cat, split(path))
	return cat.Values[key]
end

function Register:Bubble(path: string, handler)
	local full = self:_path(path)
	local watchers = self._instance.Watchers[full]
	if not watchers then
		watchers = {}
		self._instance.Watchers[full] = watchers
	end
	table.insert(watchers, handler)

	return function()
		local index = table.find(watchers, handler)
		if index then
			table.remove(watchers, index)
		end
	end
end

-- Every mutation funnels through here, so authority and the wire shape are decided
-- in exactly one place.
function Register:_mutate(op: string, path: string, value, options)
	local parts = split(path)
	checkKey(parts[#parts])

	local reg = self._reg
	local full = self:_path(path)
	local delta = {
		Op = op,
		Reg = self._instance.Name,
		Owner = self._instance.Owner,
		Path = full,
		Value = value,
	}

	if reg._side == "Server" then
		reg:_apply(delta, false)
		reg:_emit(self._instance, delta)
		return Reaction.resolve(true)
	end

	-- Client: this is a request, not a write. The mirror does not move until the
	-- server echoes -- unless you opted into prediction and accept the rollback.
	local previous, predicted
	if options and options.Predict then
		local cat, key = descend(self._cat, parts)
		previous = cat.Values[key]
		predicted = true
		reg:_apply(delta, true)
	end

	return Reaction.new(function(resolve, reject)
		reg._transport.Request(delta):Next(function(result)
			if result.Ok then
				resolve(true)
			else
				if predicted then
					reg:_apply({
						Op = "Swap",
						Reg = delta.Reg,
						Owner = delta.Owner,
						Path = full,
						Value = previous,
					}, true)
				end
				reject(result.Reason)
			end
		end):Toss(reject)
	end)
end

function Register:New(path: string, value)
	return self:_mutate("New", path, value)
end

function Register:Edit(path: string, patch, options)
	return self:_mutate("Edit", path, patch, options)
end

function Register:Swap(path: string, value, options)
	return self:_mutate("Swap", path, value, options)
end

function Register:Rem(path: string, options)
	return self:_mutate("Rem", path, nil, options)
end

return Reg
