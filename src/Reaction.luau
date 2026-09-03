--!nonstrict
-- Trellis
-- Reaction.luau
-- Valence
--
-- The deferred handle returned by :Resolve and :Await. PascalCase throughout, so it
-- reads like the rest of the framework:
--
--   Src:Network("Session"):Resolve("Get", query)
--       :Timeout(5)
--       :Next(function(state) end)
--       :Toss(function(err) end)
--
-- This is a small self-contained implementation so the framework has no hard
-- dependency. Accede can replace it wholesale; the surface is deliberately the
-- same set of verbs, PascalCased.

local Reaction = {}
Reaction.__index = Reaction

local PENDING, DONE, FAILED = "Pending", "Done", "Failed"

local function settle(self, state: string, value: any)
	if self.State ~= PENDING then
		return
	end

	self.State = state
	self.Value = value

	local queue = self._queue
	self._queue = {}

	for _, waiter in queue do
		local handler = if state == DONE then waiter.OnDone else waiter.OnFailed
		if handler then
			task.spawn(handler, value)
		end
	end
end

function Reaction.new(executor: (((any) -> ()), ((any) -> ())) -> ())
	local self = setmetatable({ State = PENDING, Value = nil, _queue = {} }, Reaction)

	local ok, err = pcall(executor, function(value)
		settle(self, DONE, value)
	end, function(reason)
		settle(self, FAILED, reason)
	end)

	if not ok then
		settle(self, FAILED, err)
	end

	return self
end

function Reaction.resolve(value: any)
	local self = setmetatable({ State = DONE, Value = value, _queue = {} }, Reaction)
	return self
end

function Reaction.reject(reason: any)
	local self = setmetatable({ State = FAILED, Value = reason, _queue = {} }, Reaction)
	return self
end

-- A settled Reaction runs the handler immediately, so a late :Next is never lost --
-- which is what makes Src:Await safe to call after the event already happened.
function Reaction:_when(onDone, onFailed)
	if self.State == DONE then
		if onDone then
			task.spawn(onDone, self.Value)
		end
	elseif self.State == FAILED then
		if onFailed then
			task.spawn(onFailed, self.Value)
		end
	else
		table.insert(self._queue, { OnDone = onDone, OnFailed = onFailed })
	end
	return self
end

function Reaction:Next(handler)
	return self:_when(handler, nil)
end

function Reaction:Toss(handler)
	return self:_when(nil, handler)
end

Reaction.Catch = Reaction.Toss

function Reaction:Conclude(handler)
	return self:_when(handler, handler)
end

-- Transform into a new Reaction. A handler that errors fails the chain rather than
-- taking down the caller.
function Reaction:Map(transform)
	local mapped = Reaction.new(function() end)

	self:_when(function(value)
		local ok, result = pcall(transform, value)
		settle(mapped, if ok then DONE else FAILED, result)
	end, function(reason)
		settle(mapped, FAILED, reason)
	end)

	return mapped
end

function Reaction:Timeout(seconds: number, reason: string?)
	task.delay(seconds, function()
		settle(self, FAILED, reason or "timeout")
	end)
	return self
end

function Reaction:Cancel(reason: string?)
	settle(self, FAILED, reason or "cancelled")
	return self
end

-- Yield for the value. Errors on failure, so use it where an error is what you want.
function Reaction:Await(): any
	while self.State == PENDING do
		task.wait()
	end
	if self.State == FAILED then
		error(tostring(self.Value), 2)
	end
	return self.Value
end

return Reaction
