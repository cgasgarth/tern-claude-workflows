--!strict
-- Window half: how the block opens. Both ways pass a pane and the other shell and agent panes of its tab to
-- the block (that pane first), so the block shows the Claude session that runs in that tab. When the tab
-- already shows a workflows block, it is focused instead of opening another one.
--
-- - The palette command acts on the focused pane.
-- - `tern open --split right "claude-workflows-$TERN_PANE"` acts on the pane it names and opens the block beside
--   the pane the command runs in, so a script or an agent can open it next to itself whatever the window shows.

local KIND = "claude-workflows.view"

-- The block's args for `pane`, or the workflows block already in its tab.
local function plan(cx: WindowCx, pane: number): ({ string }?, number?)
	local panes = cx.session:panes()
	local tab: number? = nil
	for _, p in panes do
		if p.pane == pane then
			tab = p.tab
		end
	end
	local args: { string } = { tostring(pane) }
	for _, p in panes do
		if tab ~= nil and p.tab == tab then
			if p.block == KIND then
				return nil, p.pane
			end
			if p.pane ~= pane and (p.kind == "terminal" or p.kind == "agent") then
				table.insert(args, tostring(p.pane))
			end
		end
	end
	return args, nil
end

tern.route.open(function(req, cx)
	local id = string.match(req.path, "claude%-workflows%-(%d+)$")
	local pane = if id ~= nil then tonumber(id) else nil
	if pane == nil then
		return nil
	end
	local args, existing = plan(cx, pane)
	if existing ~= nil then
		cx.layout:focus(existing)
		return { handled = true }
	end
	return { block = KIND, args = args }
end)

tern.command({
	id = "show",
	title = "View Claude workflows",
	icon = "workflow",
	keys = { "ctrl+alt+w" },
	run = function(cx)
		local focused = cx.session:focused()
		if focused == nil then
			cx:toast("error", "Claude workflows: no focused pane")
			return
		end
		local args, existing = plan(cx, focused)
		if existing ~= nil then
			cx.layout:focus(existing)
		elseif cx:new_block(KIND, args, "beside") == nil then
			cx:toast("error", "Claude workflows: could not open the block")
		end
	end,
})
