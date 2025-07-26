local faq_text = ""
local filename = "faq.txt"

minetest.register_on_mods_loaded(function()
	local content = jma_greeter.load_file(filename)
	if content then
		faq_text = content
		minetest.log("action", "[jma_greeter]: faq: " .. filename ..  " loaded")
	end
end)

function jma_greeter.show_faq(pname)
	local fs = jma_greeter.get_base_formspec({
		title  = "Frequently Asked Questions",
		size = {x = 11, y = 11},
		bar_color = "#e08804",
	})
	.. "box[0,0.7;11,9.1;#00000055]"
	.. "hypertext[0.1,0.8;10.8,8.9;faq;" .. minetest.formspec_escape(faq_text) .. "]"
	.. "button_exit[3.5,10;4,0.8;ok;Okay]"

	minetest.show_formspec(pname, "jma_greeter:faq", fs)
end

minetest.register_chatcommand("faq", {
	description = "Show FAQ",
	func = function(pname)
		jma_greeter.show_faq(pname)
        return true, "FAQ shown."
	end
})

minetest.register_chatcommand("faq_editor", {
	description = "FAQ editor",
	privs = {server = true},
	func = function(pname)
		local actions = {
			on_save = function(fields)
				if fields.text and jma_greeter.write_file(filename, fields.text) then
					faq_text = fields.text
					minetest.chat_send_player(pname, "FAQ saved.")
				else
					minetest.chat_send_player(pname, "Failed to save")
				end
			end,
			on_cancel = function()
				minetest.chat_send_player(pname, "Cancelled")
				jma_greeter.editor_context[pname] = nil
			end
		}
		jma_greeter.show_editor(pname, faq_text, "FAQ", actions)
		return true, "FAQ editor shown"
	end
})
