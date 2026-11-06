-- tools/art/install_ready.py (standard library only): the producer's finished drawings go into assets/images by the
-- names the game reads, partial or wrong-sized sets are refused with a message, gen_art.py leaves installed files alone.

describe("tools/art/install_ready.py", function()
	it("passes its own self test", function()
		local p = io.popen("python3 -I tools/art/install_ready.py selftest 2>&1")
		assert_true(p ~= nil, "python3 did not start")
		local out = p:read("*a")
		p:close()
		assert_true(string.find(out, "install_ready selftest: ok", 1, true) ~= nil, out)
	end)

	it("asks for the frame counts the animation data has", function()
		local json = require("tools.lib.json")
		local f = assert(io.open("content/animations.json", "rb"))
		local data = json.decode(f:read("*a"))
		f:close()
		local py = assert(io.open("tools/art/install_ready.py", "rb"))
		local src = py:read("*a")
		py:close()
		for name, a in pairs(data.bit.anims) do -- order-free
			local anim = string.match(a.prefix or "", "^bit/(.-)_$")
			if anim then
				assert_true(string.find(src, '"' .. anim .. '": ' .. a.frames, 1, true) ~= nil, anim .. " " .. a.frames)
			end
		end
	end)

	it("is honoured by gen_art.py (it skips and keeps what is installed)", function()
		local f = assert(io.open("tools/art/gen_art.py", "rb"))
		local src = f:read("*a")
		f:close()
		assert_true(string.find(src, "installed.load()", 1, true) ~= nil)
		assert_true(string.find(src, "| kept", 1, true) ~= nil)
	end)
end)
