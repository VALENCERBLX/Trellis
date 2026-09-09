--!nonstrict
-- Trellis
-- Trove.luau
-- Valence
--
-- A cleanup container, granted by Req "Trove" and destroyed on :Stop. Put anything
-- with a teardown in it and you often need no :Stop at all. The Trove IS the
-- teardown.
--
--   VfxController.Req = { "Trove" }
--   function VfxController:Start()
--       self.Trove:Add(Instance.new("Beam"))
--       self.Trove:Add(workspace.ChildAdded:Connect(fn))
--       self.Trove:Add(function() print("bye") end)
--   end
--
-- Handles instances (:Destroy), connections (:Disconnect), functions, other Troves,
-- and any table with :Destroy or :Disconnect. Cleanup runs in REVERSE order, so
-- things tear down in the opposite order they were built.

local Trove = {}
Trove.__index = Trove

function Trove.new()
	return setmetatable({ _items = {}, _cleaning = false }, Trove)
end

-- Reading a member a Roblox Instance does not have RAISES, rather than returning
-- nil the way a table does. So `type(item.Disconnect)` on a Part throws before
-- anything gets as far as :Destroy, and every instance ever added to a Trove
-- errored on cleanup instead of being destroyed.
--
-- The Lune suite stubs Instance with plain tables, where that probe is harmless,
-- which is exactly why this survived a green test run and only appeared in Studio.
local function probe(item, member: string): boolean
	local ok, value = pcall(function()
		return item[member]
	end)
	return ok and type(value) == "function"
end

local function teardown(item)
	local kind = type(item)

	if kind == "function" then
		item()
		return
	end

	if kind ~= "table" and kind ~= "userdata" then
		return
	end

	-- Ask what it IS before asking what it can do. typeof is absent outside Roblox,
	-- so this falls through to the probes under Lune.
	if typeof then
		local roblox = typeof(item)
		if roblox == "Instance" then
			item:Destroy()
			return
		end
		if roblox == "RBXScriptConnection" then
			item:Disconnect()
			return
		end
	end

	-- Disconnect still wins over Destroy for anything else, since a connection that
	-- also has :Destroy should be disconnected.
	if probe(item, "Disconnect") then
		item:Disconnect()
		return
	end
	if probe(item, "Destroy") then
		item:Destroy()
		return
	end
	if probe(item, "Clean") then
		item:Clean()
		return
	end
end

function Trove:Add(item: any): any
	if item == nil then
		return nil
	end
	if self._cleaning then
		-- Adding during teardown would either leak or loop; clean it immediately
		-- instead, which is what the caller meant.
		teardown(item)
		return item
	end
	table.insert(self._items, item)
	return item
end

-- Add an item and get a function that removes just that one, for the cases where a
-- single connection outlives its usefulness before the module does.
function Trove:Track(item: any): () -> ()
	self:Add(item)
	return function()
		self:Remove(item)
	end
end

function Trove:Remove(item: any): boolean
	local index = table.find(self._items, item)
	if not index then
		return false
	end
	table.remove(self._items, index)
	teardown(item)
	return true
end

-- A nested Trove, cleaned with its parent.
function Trove:Extend()
	return self:Add(Trove.new())
end

function Trove:Clean()
	if self._cleaning then
		return
	end
	self._cleaning = true

	for i = #self._items, 1, -1 do
		local item = self._items[i]
		self._items[i] = nil
		local ok, err = pcall(teardown, item)
		if not ok then
			warn("[Trellis] Trove cleanup errored: " .. tostring(err))
		end
	end

	self._cleaning = false
end

Trove.Destroy = Trove.Clean

function Trove:Count(): number
	return #self._items
end

return Trove
