--!strict
-- Window half: how the block opens. Both ways pass a pane and the other shell and agent panes of its tab to
-- the block (that pane first), so the block shows the Claude session that runs in that tab. A tab gets at most
-- one workflows block.
--
-- - The palette command acts on the focused pane.
-- - `tern open "claude-workflows-<pane>"` opens it beside the pane it names (`--split down` puts it below), so a
--   script or an agent can open it next to itself or in another tab, whatever the window shows.

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

-- `tern open` exits 0 only when the route answers with a block, and that block opens beside the pane the
-- command runs in. So the route answers with the block and remembers which pane it is for; when the block
-- appears, `pane_created` moves it beside that pane (its tab and session) without changing what the window
-- shows, or closes it when that tab already has one.
type Pending = { target: number, dir: Dir, existing: number? }
local pending: { Pending } = {}

tern.route.open(function(req, cx)
	local id = string.match(req.path, "claude%-workflows%-(%d+)$")
	local pane = if id ~= nil then tonumber(id) else nil
	if pane == nil then
		return nil
	end
	local args, existing = plan(cx, pane)
	table.insert(pending, { target = pane, dir = if req.how == "below" then "down" else "right", existing = existing })
	return { block = KIND, args = args or { tostring(pane) } }
end)

tern.on("pane_created", function(ev: PaneEvent, cx: WindowCx)
	if #pending == 0 then
		return
	end
	local tabs: { [number]: number? } = {}
	local kind: string? = nil
	for _, p in cx.session:panes() do
		tabs[p.pane] = p.tab
		if p.pane == ev.pane then
			kind = p.block
		end
	end
	if kind ~= KIND then
		return
	end
	local job = table.remove(pending, 1) :: Pending
	if job.existing ~= nil then
		cx.layout:close(ev.pane)
	elseif tabs[ev.pane] ~= tabs[job.target] or tabs[job.target] == nil then
		cx.layout:move(ev.pane, job.target, job.dir, { focus = false })
	end
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
