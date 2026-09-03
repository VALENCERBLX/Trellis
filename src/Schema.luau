--!nonstrict
-- Trellis
-- Schema.luau
-- Plinko Labs
--
-- Payload shapes, declared on a Junction entry and checked AT THE EDGE -- before any
-- fence, before any handler. The map already names every event; this lets it name
-- what the event carries, which deletes the `if type(payload) ~= "table"` prologue
-- from every server handler and rejects malformed traffic in one place.
--
--   Swing = { Destination = "CombatManager", Schema = {
--       Target = "Instance",
--       Combo  = { Type = "number", Min = 1, Max = 5 },
--       Style  = { Type = "string", One = { "Light", "Heavy" } },
--       Meta   = "table?",                                  -- optional
--       Origin = { Type = "table", Of = { X = "number" } },  -- nested
--   } }
--
-- A schema may also be a bare type string, for events whose payload is one value:
--
--   Ready = { Schema = "boolean" }
--
-- Errors name the field and what was expected, so a rejection is actionable rather
-- than "bad request".

local Schema = {}

-- typeof() knows Roblox datatypes; type() is the fallback outside Roblox (and in
-- the Lune harness), where Instance and Vector3 do not exist.
local function typeName(value: any): string
	if typeof then
		return typeof(value)
	end
	return type(value)
end

local PRIMITIVES = {
	any = true,
	number = true,
	string = true,
	boolean = true,
	table = true,
	["function"] = true,
	Instance = true,
	Vector3 = true,
	Vector2 = true,
	CFrame = true,
	Color3 = true,
	UDim2 = true,
	EnumItem = true,
	BrickColor = true,
	Ray = true,
	Region3 = true,
	buffer = true,
}

-- A table is a SPEC if it names a Type; otherwise it is a SHAPE, mapping fields to
-- their own schemas. That keeps the common case ({ Combo = "number" }) free of
-- ceremony while still allowing constraints where they are wanted.
local function isSpec(schema): boolean
	return type(schema) == "table" and type(schema.Type) == "string"
end

local function checkType(expected: string, value: any, path: string): (boolean, string?)
	local optional = string.sub(expected, -1) == "?"
	if optional then
		expected = string.sub(expected, 1, -2)
	end

	if value == nil then
		if optional then
			return true
		end
		return false, string.format("%s is required (%s)", path, expected)
	end

	if not PRIMITIVES[expected] then
		return false, string.format("%s declares unknown type %q", path, expected)
	end

	if expected == "any" then
		return true
	end

	local actual = typeName(value)
	if actual ~= expected then
		return false, string.format("%s should be %s, got %s", path, expected, actual)
	end

	return true
end

local function check(schema, value, path: string): (boolean, string?)
	if type(schema) == "string" then
		return checkType(schema, value, path)
	end

	if type(schema) ~= "table" then
		return false, string.format("%s has an invalid schema (%s)", path, type(schema))
	end

	if isSpec(schema) then
		local ok, err = checkType(schema.Type, value, path)
		if not ok then
			return false, err
		end
		if value == nil then
			return true -- optional and absent; constraints do not apply
		end

		if schema.Min and value < schema.Min then
			return false, string.format("%s must be >= %s, got %s", path, tostring(schema.Min), tostring(value))
		end
		if schema.Max and value > schema.Max then
			return false, string.format("%s must be <= %s, got %s", path, tostring(schema.Max), tostring(value))
		end

		if schema.One then
			local found = false
			for _, allowed in schema.One do
				if value == allowed then
					found = true
					break
				end
			end
			if not found then
				local list = {}
				for _, allowed in schema.One do
					table.insert(list, tostring(allowed))
				end
				return false, string.format("%s must be one of: %s (got %s)", path, table.concat(list, ", "), tostring(value))
			end
		end

		if schema.Of then
			return check(schema.Of, value, path)
		end

		return true
	end

	-- A shape. The value must be a table, and every declared field must check out.
	if type(value) ~= "table" then
		return false, string.format("%s should be a table, got %s", path, typeName(value))
	end

	for field, fieldSchema in schema do
		local ok, err = check(fieldSchema, value[field], if path == "" then field else path .. "." .. field)
		if not ok then
			return false, err
		end
	end

	return true
end

-- Returns (true) or (false, reason). `label` prefixes the reason so a rejection
-- names the event it came from.
function Schema.Check(schema, value, label: string?): (boolean, string?)
	if schema == nil then
		return true
	end
	local ok, err = check(schema, value, "")
	if ok then
		return true
	end
	local reason = string.gsub(err, "^ ", "")
	if reason == "" or string.sub(reason, 1, 1) == " " then
		reason = "payload" .. reason
	end
	if label then
		return false, string.format("%s: %s", label, reason)
	end
	return false, reason
end

-- Validate the SCHEMA itself at boot, so a typo'd type string is caught before it
-- silently rejects live traffic.
function Schema.Validate(schema, path: string, problems: { string })
	if schema == nil then
		return
	end

	if type(schema) == "string" then
		local bare = if string.sub(schema, -1) == "?" then string.sub(schema, 1, -2) else schema
		if not PRIMITIVES[bare] then
			table.insert(problems, string.format("%s: Schema names unknown type %q", path, schema))
		end
		return
	end

	if type(schema) ~= "table" then
		table.insert(problems, string.format("%s: Schema must be a string or a table", path))
		return
	end

	if isSpec(schema) then
		Schema.Validate(schema.Type, path, problems)
		if schema.Of then
			Schema.Validate(schema.Of, path, problems)
		end
		return
	end

	for field, fieldSchema in schema do
		Schema.Validate(fieldSchema, path .. "." .. field, problems)
	end
end

return Schema
