--!nonstrict
-- Trellis
-- Log.luau
-- Plinko Labs
--
-- Every event crosses the Junction, so a ring buffer per path is nearly free -- and
-- dumping it when a module errors turns "it broke somehow" into a transcript.
--
--   Configure({ Log = true })   -- keep the last 64 per path
--   Configure({ Log = 256 })    -- or say how many
--
--   app:Inspect().Log           -- counts, rates and refusals per path
--   Log:Tail("Network.Combat.Swing", 10)
--   Log:Dump()                  -- the whole session, newest last, ready to paste
--
-- Payloads are stored by SHAPE, not by value: a summary string rather than the table
-- itself. Holding the real payload would pin every table the game ever sent and turn
-- a debug aid into a memory leak.

local Log = {}
Log.__index = Log

local DEFAULT_DEPTH = 64

local function summarize(value: any, depth: number?): string
	local d = depth or 0
	local t = type(value)

	if value == nil then
		return "nil"
	elseif t == "number" or t == "boolean" then
		return tostring(value)
	elseif t == "string" then
		if #value > 32 then
			return string.format("%q..", string.sub(value, 1, 32))
		end
		return string.format("%q", value)
	elseif t ~= "table" then
		return "<" .. t .. ">"
	end

	if d >= 2 then
		return "{...}"
	end

	local parts, count = {}, 0
	for key, inner in value do
		count += 1
		if count > 4 then
			table.insert(parts, "...")
			break
		end
		table.insert(parts, string.format("%s=%s", tostring(key), summarize(inner, d + 1)))
	end
	return "{" .. table.concat(parts, " ") .. "}"
end

Log.Summarize = summarize

function Log.new(depth: (number | boolean)?, clock: (() -> number)?)
	return setmetatable({
		Depth = if type(depth) == "number" then depth else DEFAULT_DEPTH,
		Clock = clock or os.clock,
		Started = (clock or os.clock)(),
		Paths = {}, -- path -> { Entries, Count, Refused, First, Last }
		Seq = 0,
	}, Log)
end

function Log:_path(path: string)
	local record = self.Paths[path]
	if not record then
		record = { Entries = {}, Count = 0, Refused = 0, First = self.Clock() }
		self.Paths[path] = record
	end
	return record
end

function Log:_push(path: string, kind: string, payload: any, from: any, reason: string?)
	local record = self:_path(path)
	self.Seq += 1

	local entry = {
		Seq = self.Seq,
		At = self.Clock(),
		Kind = kind,
		Payload = summarize(payload),
		From = if from then (from.Name or tostring(from)) else nil,
		Reason = reason,
	}

	table.insert(record.Entries, entry)
	if #record.Entries > self.Depth then
		table.remove(record.Entries, 1)
	end

	record.Last = entry.At
	return entry
end

function Log:Event(path: string, payload: any, from: any)
	local record = self:_path(path)
	record.Count += 1
	self:_push(path, "event", payload, from)
end

function Log:Refused(path: string, payload: any, from: any, reason: string?)
	local record = self:_path(path)
	record.Refused += 1
	self:_push(path, "refused", payload, from, reason)
end

-- Anything worth seeing in the transcript that is not itself an event: a module
-- erroring, a boot step, a register delta.
function Log:Note(path: string, text: string)
	self:_push(path, "note", text, nil)
end

function Log:Tail(path: string, count: number?): { any }
	local record = self.Paths[path]
	if not record then
		return {}
	end
	local n = count or 10
	local out = {}
	for i = math.max(1, #record.Entries - n + 1), #record.Entries do
		table.insert(out, record.Entries[i])
	end
	return out
end

-- Per-path totals, for the panel and for Inspect.
function Log:Stats(): { any }
	local stats = {}
	local elapsed = math.max(self.Clock() - self.Started, 0.001)

	for path, record in self.Paths do
		table.insert(stats, {
			Path = path,
			Count = record.Count,
			Refused = record.Refused,
			Rate = record.Count / elapsed,
			Last = record.Last,
		})
	end

	table.sort(stats, function(a, b)
		return a.Count > b.Count
	end)
	return stats
end

-- The whole session in sequence, newest last. This is the thing you paste into a
-- bug report.
function Log:Dump(limit: number?): string
	local all = {}
	for path, record in self.Paths do
		for _, entry in record.Entries do
			table.insert(all, { Path = path, Entry = entry })
		end
	end

	table.sort(all, function(a, b)
		return a.Entry.Seq < b.Entry.Seq
	end)

	local lines = { "[Trellis] event log" }
	local start = if limit then math.max(1, #all - limit + 1) else 1

	for i = start, #all do
		local row = all[i]
		local e = row.Entry
		table.insert(
			lines,
			string.format(
				"  %6.2fs  %-8s %-38s %s%s%s",
				e.At - self.Started,
				e.Kind,
				row.Path,
				e.Payload,
				if e.From then "  from=" .. e.From else "",
				if e.Reason then "  (" .. e.Reason .. ")" else ""
			)
		)
	end

	return table.concat(lines, "\n")
end

return Log
