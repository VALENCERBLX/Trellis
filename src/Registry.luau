--!strict
-- Trellis
-- Registry.luau
-- Valence
--
-- Dependency injection whose surface is DERIVED from the hierarchy you hand it.
-- Every direct child container of every root becomes a "bin", and every bin
-- generates its own getter from the singular of its name:
--
--   Root.Packages.Lume   ->   Registry:GetPackage("Lume")
--   Root.Utilities.Maid  ->   Registry:GetUtility("Maid")
--   Root.Services.Combat ->   Registry:GetService("Combat")
--
-- Only DIRECT children are scanned, so `Packages/Icon/Packages` stays Icon's own
-- private business and can never collide with yours. A name mounted twice across
-- two roots is a boot error naming both paths -- never a silent FindFirstChild win.
--
-- Modules are required lazily and cached; Bootstrap forces the lifecycle bins
-- (Controller / Manager / Service) eagerly so syntax errors surface at boot.

local Types = require(script.Parent.Types)

local Registry = {}
Registry.__index = Registry

-- Plural -> singular. Ordered; first match wins. A name that matches nothing is
-- already singular (Config -> GetConfig), which is the common case for config bins.
local PLURAL_RULES = {
	{ "ies$", "y" }, -- Utilities -> Utility
	{ "ches$", "ch" }, -- Batches   -> Batch
	{ "shes$", "sh" }, -- Meshes    -> Mesh
	{ "xes$", "x" }, -- Boxes     -> Box
	{ "([^s])s$", "%1" }, -- Packages  -> Package
}

local function singular(name: string): string
	for _, rule in PLURAL_RULES do
		local out, hits = string.gsub(name, rule[1], rule[2])
		if hits > 0 then
			return out
		end
	end
	return name
end

-- ===================================================================== mounting ===

-- A bin holds entries from one or more sources. `sources` keeps the origin of each
-- entry so a collision can name both full paths instead of just the loser.
type Entry = {
	Name: string,
	Source: any, -- ModuleScript | any (a table/resolver value)
	Origin: string, -- human-readable, for error messages
	Value: any?, -- populated on first resolve
	Loaded: boolean,
}

local function describe(instance: Instance): string
	local ok, full = pcall(function()
		return instance:GetFullName()
	end)
	return if ok then full else instance.Name
end

function Registry.new(roots: { Instance }, config: Types.RegistryConfig?): Types.Registry
	local self = setmetatable({
		_bins = {} :: { [string]: { [string]: Entry } },
		_resolvers = {} :: { [string]: (string) -> any },
		_aliases = (config and config.Aliases) or {},
		-- How a mounted source becomes a value. Overridable so a test environment can
		-- hand over plain tables, and so nothing here has to touch the real require.
		_loader = (config and config.Loader) or require,
		-- bin name (singular, drives the getter) -> container name (plural, drives Main)
		_containers = {} :: { [string]: string },
		-- bin -> name -> every entry claiming it. A duplicate is only fatal if it is
		-- still unreconciled when something asks for it, which lets Bootstrap pair a
		-- shared __Serve Service with its client __Recip host.
		_dupes = {} :: { [string]: { [string]: { Entry } } },
		-- the hierarchy as you wrote it: Main.Packages.Lume == :GetPackage("Lume")
		Main = {} :: { [string]: any },
	}, Registry)

	for _, root in roots do
		for _, container in root:GetChildren() do
			if not container:IsA("Folder") then
				continue
			end
			self:_mountContainer(container)
		end
	end

	-- Injected bins land alongside the discovered ones, so `Inject = { Package = {...} }`
	-- extends GetPackage rather than needing a separate lookup.
	if config and config.Inject then
		for binName, source in config.Inject do
			self:_mountValue(binName, source)
		end
	end

	self:_generate()

	return (self :: any) :: Types.Registry
end

function Registry:_binName(containerName: string): string
	return self._aliases[containerName] or singular(containerName)
end

function Registry:_bin(name: string, container: string?): { [string]: Entry }
	local bin = self._bins[name]
	if not bin then
		bin = {}
		self._bins[name] = bin
		self._containers[name] = container or name
	elseif container then
		self._containers[name] = container
	end
	return bin
end

-- Every entry registers under its own name, and additionally under its name minus
-- the bin's own suffix -- so a Service bin gives you both "CombatService" and
-- "Combat". The stripped alias never overwrites a real name.
function Registry:_add(binName: string, key: string, entry: Entry, alias: boolean?)
	local bin = self:_bin(binName)
	local existing = bin[key]

	if existing then
		if alias then
			return -- a real name always beats a derived alias; not a collision
		end

		-- Record rather than throw: Bootstrap gets one chance to reconcile this (a
		-- double-sided Service), and Resolve throws if it did not.
		local perBin = self._dupes[binName]
		if not perBin then
			perBin = {}
			self._dupes[binName] = perBin
		end
		local claims = perBin[key]
		if not claims then
			claims = { existing }
			perBin[key] = claims
		end
		table.insert(claims, entry)
		return
	end

	bin[key] = entry

	if not alias and key ~= binName then
		local stripped = string.match(key, "^(.+)" .. binName .. "$")
		if stripped and #stripped > 0 then
			self:_add(binName, stripped, entry, true)
		end
	end
end

function Registry:_mountContainer(container: Instance)
	local binName = self:_binName(container.Name)
	self:_bin(binName, container.Name)

	for _, child in container:GetChildren() do
		if not child:IsA("ModuleScript") then
			continue
		end
		self:_add(binName, child.Name, {
			Name = child.Name,
			Source = child,
			Origin = describe(child),
			Loaded = false,
		})
	end
end

function Registry:_mountValue(binName: string, source: any)
	if type(source) == "function" then
		self._resolvers[binName] = source
		self:_bin(binName) -- so the getter is generated even if nothing is mounted
		return
	end

	if type(source) ~= "table" then
		error(string.format("[Trellis] Inject.%s must be a table or a resolver function", binName), 0)
	end

	for key, value in source do
		self:_add(binName, key, {
			Name = key,
			Source = value,
			Origin = string.format("Inject.%s.%s", binName, key),
			Value = value,
			Loaded = true,
		})
	end
end

-- ==================================================================== resolving ===

function Registry:_load(entry: Entry): any
	if entry.Loaded then
		return entry.Value
	end

	local ok, result = pcall(self._loader, entry.Source)
	if not ok then
		error(string.format("[Trellis] failed to require %s\n    %s", entry.Origin, tostring(result)), 0)
	end

	entry.Value = result
	entry.Loaded = true
	return result
end

-- Every entry claiming this name, when more than one did. Bootstrap uses it to pair
-- a double-sided Service; anything else it finds here is a genuine collision.
function Registry:Claims(binName: string, name: string): { Entry }?
	local perBin = self._dupes[binName]
	return perBin and perBin[name]
end

function Registry:ClaimedNames(binName: string): { string }
	local names = {}
	for name in self._dupes[binName] or {} do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- Collapse a reconciled duplicate down to one value. The suffix alias has to move
-- with it: it points at the SAME entry object, so leaving it behind would make
-- Names() report the module twice under one name.
function Registry:Reconcile(binName: string, name: string, value: any)
	local perBin = self._dupes[binName]
	if perBin then
		perBin[name] = nil
	end

	local bin = self:_bin(binName)
	local replacement = {
		Name = name,
		Source = value,
		Origin = string.format("reconciled %s.%s", binName, name),
		Value = value,
		Loaded = true,
	}

	local previous = bin[name]
	bin[name] = replacement

	for key, entry in bin do
		if entry == previous and key ~= name then
			bin[key] = replacement
		end
	end
end

function Registry:Load(entry: Entry): any
	return self:_load(entry)
end

function Registry:Resolve(binName: string, name: string, optional: boolean?): any
	local claims = self:Claims(binName, name)
	if claims then
		local origins = {}
		for _, claim in claims do
			table.insert(origins, "\n    " .. claim.Origin)
		end
		error(
			string.format("[Trellis] duplicate %s %q, mounted from:%s", binName, name, table.concat(origins)),
			0
		)
	end

	local bin = self._bins[binName]

	if not bin then
		error(
			string.format(
				"[Trellis] no %q here. bins on this side: %s",
				binName,
				table.concat(self:Bins(), ", ")
			),
			0
		)
	end

	local entry = bin[name]
	if entry then
		return self:_load(entry)
	end

	local resolver = self._resolvers[binName]
	if resolver then
		local value = resolver(name)
		if value ~= nil then
			return value
		end
	end

	if optional then
		return nil
	end

	local known = {}
	for key in bin do
		table.insert(known, key)
	end
	table.sort(known)
	error(
		string.format("[Trellis] no %s named %q. known: %s", binName, name, table.concat(known, ", ")),
		0
	)
end

function Registry:Bins(): { string }
	local names = {}
	for binName in self._bins do
		table.insert(names, binName)
	end
	table.sort(names)
	return names
end

function Registry:Names(binName: string): { string }
	local bin = self._bins[binName]
	if not bin then
		return {}
	end

	-- One entry can appear twice (real name + stripped alias); report each once.
	local seen, names = {}, {}
	for key, entry in bin do
		if not seen[entry] then
			seen[entry] = true
			table.insert(names, entry.Name)
		end
		-- keep `key` referenced for strict mode
		local _ = key
	end
	table.sort(names)
	return names
end

-- Force-require every entry in a bin. Bootstrap calls this for the lifecycle bins so
-- a syntax error in any module surfaces at boot rather than on first use.
function Registry:Preload(binName: string): { [string]: any }
	local loaded = {}
	for _, name in self:Names(binName) do
		loaded[name] = self:Resolve(binName, name)
	end
	return loaded
end

-- =================================================================== generation ===

-- The point of the whole module: one getter per bin, named from the hierarchy --
-- plus Main, the same bins reachable exactly as you wrote them in the tree.
--
--   Src.Main.Packages.Lume   ==   Src:GetPackage("Lume")
--
-- Main is keyed by the CONTAINER name (plural, as it appears in the hierarchy);
-- the getter is keyed by the BIN name (singular). Both resolve lazily through the
-- same cache, so neither view requires a module the other already loaded.
function Registry:_generate()
	for binName in self._bins do
		self["Get" .. binName] = function(_, name: string)
			return self:Resolve(binName, name)
		end
		self["Has" .. binName] = function(_, name: string): boolean
			return self:Resolve(binName, name, true) ~= nil
		end
		self["List" .. binName] = function(_): { string }
			return self:Names(binName)
		end

		self.Main[self._containers[binName]] = setmetatable({}, {
			__index = function(_, name: string)
				return self:Resolve(binName, name)
			end,
			__newindex = function()
				error("[Trellis] Src.Main is read-only", 0)
			end,
			__iter = function()
				local names = self:Names(binName)
				local i = 0
				return function()
					i += 1
					local name = names[i]
					if name then
						return name, self:Resolve(binName, name)
					end
					return nil
				end
			end,
		})
	end

	table.freeze(self.Main)
end

return Registry
