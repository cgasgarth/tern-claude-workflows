--!strict
-- Window half: the palette command. It passes the focused pane and the other shell and agent panes of the
-- same tab to the block (focused first), so the block shows the Claude session that runs in this tab.
-- When the tab already shows a workflows block, the command focuses it instead of opening another one.

local KIND = "claude-workflows.view"

tern.command({
	id = "show",
	title = "View Claude workflows",
	icon = "workflow",
	keys = { "ctrl+alt+w" },
	run = function(cx)
		local focused = cx.session:focused()
		local panes = cx.session:panes()
		local tab: number? = nil
		for _, p in panes do
			if p.pane == focused then
				tab = p.tab
			end
		end
		local args: { string } = {}
		if focused ~= nil then
			table.insert(args, tostring(focused))
		end
		for _, p in panes do
			if tab ~= nil and p.tab == tab then
				if p.block == KIND then
					cx.layout:focus(p.pane)
					return
				end
				if p.pane ~= focused and (p.kind == "terminal" or p.kind == "agent") then
					table.insert(args, tostring(p.pane))
				end
			end
		end
		if cx:new_block(KIND, args, "beside") == nil then
			cx:toast("error", "Claude workflows: could not open the block")
		end
	end,
})
