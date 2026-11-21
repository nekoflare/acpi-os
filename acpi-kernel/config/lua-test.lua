print("Lua interpreter works: " .. _VERSION)

local numbers = {2, 3, 5}
local total = 0
for _, number in ipairs(numbers) do
    total = total + number
end

print("2 + 3 + 5 = " .. total)
