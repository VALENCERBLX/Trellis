-- Lune harness for Schema.luau — payload shapes declared on a Junction entry.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local Schema = luau.load(fs.readFile("../src/Schema.luau"), {
	environment = {
		string = string,
		table = table,
		type = type,
		typeof = nil, -- outside Roblox; Schema falls back to type()
	},
})()

local passed, failed = 0, 0
local function check(label, ok, detail)
	if ok then
		passed += 1
		print(string.format("  ok   %s", label))
	else
		failed += 1
		print(string.format("  FAIL %s%s", label, detail and ("  -> " .. tostring(detail)) or ""))
	end
end

local function accepts(label, schema, value)
	local ok, err = Schema.Check(schema, value, "Ev")
	check(label, ok, err)
end

local function rejects(label, schema, value, fragment)
	local ok, err = Schema.Check(schema, value, "Ev")
	if ok then
		check(label, false, "expected a rejection")
		return
	end
	check(label, string.find(tostring(err), fragment, 1, true) ~= nil, err)
end

print("\nSchema\n")

-- bare types ---------------------------------------------------------------------
accepts("a bare type string", "number", 5)
rejects("...and its mismatch", "number", "5", "should be number, got string")
accepts("any accepts anything", "any", { 1 })
rejects("a required field that is nil", "number", nil, "is required (number)")
accepts("optional with ?", "number?", nil)
accepts("optional when present", "number?", 3)
rejects("optional still type-checks", "number?", "x", "should be number")

-- shapes -------------------------------------------------------------------------
local SWING = {
	Target = "table",
	Combo = { Type = "number", Min = 1, Max = 5 },
	Style = { Type = "string", One = { "Light", "Heavy" } },
	Meta = "table?",
}

accepts("a full shape", SWING, { Target = {}, Combo = 3, Style = "Light" })
rejects("a missing field names it", SWING, { Combo = 3, Style = "Light" }, "Ev: Target is required (table)")
rejects("a wrong type names the field", SWING, { Target = {}, Combo = "3", Style = "Light" }, "Combo should be number, got string")
rejects("below Min", SWING, { Target = {}, Combo = 0, Style = "Light" }, "Combo must be >= 1, got 0")
rejects("above Max", SWING, { Target = {}, Combo = 9, Style = "Light" }, "Combo must be <= 5, got 9")
rejects("outside One", SWING, { Target = {}, Combo = 1, Style = "Spicy" }, "Style must be one of: Light, Heavy (got Spicy)")
accepts("an absent optional", SWING, { Target = {}, Combo = 1, Style = "Heavy" })
rejects("a payload that isn't a table", SWING, 7, "should be a table, got number")

-- nesting ---------------------------------------------------------------------------
local NESTED = {
	Origin = { Type = "table", Of = { X = "number", Y = "number" } },
}
accepts("nested Of", NESTED, { Origin = { X = 1, Y = 2 } })
rejects("nested failure names the path", NESTED, { Origin = { X = 1, Y = "2" } }, "Origin.Y should be number")

-- extra fields ---------------------------------------------------------------------
accepts("undeclared fields are ignored", SWING, { Target = {}, Combo = 1, Style = "Light", Junk = true })

-- no schema ---------------------------------------------------------------------------
accepts("nil schema accepts everything", nil, { anything = true })

-- label ---------------------------------------------------------------------------------
do
	local _, err = Schema.Check("number", "x", "Network.Combat.Swing")
	check("the reason is prefixed by the event", string.sub(tostring(err), 1, 21) == "Network.Combat.Swing:", err)
end

-- boot-time validation of the schema ITSELF -----------------------------------------------
do
	local problems = {}
	Schema.Validate({ A = "number", B = "flooat" }, "Network.X.Y", problems)
	check("a typo'd type is caught at boot", #problems == 1, #problems)
	check("...naming the field and the type", string.find(problems[1] or "", 'Network.X.Y.B: Schema names unknown type "flooat"', 1, true) ~= nil, problems[1])

	local clean = {}
	Schema.Validate({ A = { Type = "number", Min = 0 }, B = "string?" }, "Network.X.Y", clean)
	check("a valid schema raises nothing", #clean == 0)

	local nested = {}
	Schema.Validate({ A = { Type = "table", Of = { B = "nubmer" } } }, "P", nested)
	check("nested schemas are validated too", #nested == 1, #nested)
end

print(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then
	process.exit(1)
end
