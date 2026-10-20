--!strict
-- Host half: the workflow block. It finds the Claude Code session that runs in the panes it was opened for
-- (scripts/scan.sh), reads that session's workflows from Claude Code's project folder and draws the selected
-- one the way Claude Code's workflow view does: one box per phase, agents as a tree, done agents folded into
-- one line unless verbose. It follows the newest workflow until the user picks another.

local ui = tern.ui

local TICK_MS = 2000
local STALE_S = 30 * 60 -- a workflow with no final state file and no writes for this long is shown as stopped
local IDLE_S = 30 -- a running agent with no writes for this long shows "idle"
local MAX_STATE_BYTES = 16 * 1024 * 1024
local NOTE_CHARS = 140

type Agent = {
	key: string,
	index: number,
	id: string?,
	label: string,
	phase: string,
	state: string, -- "running" | "queued" | "done" | "error" | "stopped" | "skipped"
	model: string?,
	kind: string?, -- the agent type, when the script set one
	started: number?, -- epoch seconds
	took: number?, -- milliseconds, when final
	last_at: number?, -- epoch seconds of the last progress
	tokens: number?,
	tools: number?,
	tool: string?, -- "Bash: cd …", the last tool call
	error: string?,
	result: string?,
	file: string?,
}

type Flow = {
	id: string,
	name: string,
	desc: string?,
	status: string, -- "running" | "stopped" | "completed" | "killed" | "failed"
	start: number, -- epoch seconds
	took: number?, -- milliseconds, final workflows only
	phases: { string },
	agents: { Agent },
}

type Digest = { meta: number, jsonl: number, tools: number, last: string?, use: string? }
type Run = { dir: string, id: string, birth: number, journal: number, agents: { [string]: Digest } }

type State = {
	panes: { string },
	sid: string?,
	title: string?,
	flows: { Flow },
	final: { [string]: Flow }, -- finished workflows by id; their state files never change
	sel: string?,
	follow: boolean,
	verbose: boolean,
	open: { [string]: boolean }, -- phases the user opened or closed, by "<wf>|<n>"
	now: number,
	mono: number,
	busy: boolean,
	loaded: boolean,
	error: string?,
}

---------------------------------------------------------------------------------------------------
-- Helpers

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function running(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function str(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

local function num(v: any): number?
	if type(v) == "number" then
		return v
	end
	return nil
end

local function one_line(v: any, max: number?): string?
	local s: string? = nil
	if type(v) == "string" then
		s = v
	elseif type(v) == "table" then
		s = str(v.message) or str(v.summary) or tern.json.encode(v)
	end
	if s == nil then
		return nil
	end
	local cap = max or NOTE_CHARS
	s = string.gsub(string.gsub(s, "[%*`#]", ""), "%s+", " ")
	s = string.match(s, "^%s*(.-)%s*$") or s
	if utf8.len(s) ~= nil and (utf8.len(s) :: number) > cap then
		s = string.sub(s, 1, (utf8.offset(s, cap) :: number) - 1) .. "…"
	end
	return if s == "" then nil else s
end

local function decode(text: string?): any
	if text == nil or text == "" then
		return nil
	end
	local ok, v = pcall(tern.json.decode, text)
	return if ok then v else nil
end

local function read(path: string, max: number?): string?
	local ok, text = pcall(tern.fs.read, path, max)
	return if ok then text else nil
end

local function list(path: string): { string }
	local ok, names = pcall(tern.fs.list, path)
	return if ok then names else {}
end

local function wall(state: State): number
	return state.now + (tern.now() - state.mono) / 1000
end

-- Claude Code's duration format: "0s", "45s", "7m 9s", "1h 4m 12s", "2d 3h 4m".
local function duration(ms: number): string
	if ms < 60000 then
		return math.floor(ms / 1000) .. "s"
	end
	local d = math.floor(ms / 86400000)
	local h = math.floor(ms % 86400000 / 3600000)
	local m = math.floor(ms % 3600000 / 60000)
	local s = math.floor(ms % 60000 / 1000 + 0.5)
	if s == 60 then
		s, m = 0, m + 1
	end
	if m == 60 then
		m, h = 0, h + 1
	end
	if d > 0 then
		return string.format("%dd %dh %dm", d, h, m)
	elseif h > 0 then
		return string.format("%dh %dm %ds", h, m, s)
	end
	return string.format("%dm %ds", m, s)
end

local function ago(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	if s < 60 then
		return s .. "s ago"
	elseif s < 3600 then
		return (s // 60) .. "m ago"
	elseif s < 86400 then
		return (s // 3600) .. "h ago"
	end
	return (s // 86400) .. "d ago"
end

-- Claude Code's compact token count: "950", "175.4k", "1.1m".
local function tokens(n: number): string
	local s: string
	if n >= 1e6 then
		s = string.format("%.1fm", n / 1e6)
	elseif n >= 1e3 then
		s = string.format("%.1fk", n / 1e3)
	else
		return tostring(math.floor(n))
	end
	return (string.gsub(s, "%.0([km])$", "%1"))
end

local function plural(n: number, word: string): string
	return n .. " " .. word .. (if n == 1 then "" else "s")
end

local function short_model(m: string?): string?
	if m == nil then
		return nil
	end
	return (string.gsub(string.match(m, "([^/]*)$") or m, "^claude%-", ""))
end

---------------------------------------------------------------------------------------------------
-- Reading workflows

local function transcript(dir: string, wf: string, agent: string?): string?
	if agent == nil then
		return nil
	end
	return dir .. "/subagents/workflows/" .. wf .. "/agent-" .. agent .. ".jsonl"
end

-- What a tool call does, in a few words: the command, path, pattern or URL it was given.
local function tool_summary(name: string, input: any): string
	local detail: string? = nil
	if type(input) == "table" then
		detail = str(input.command)
			or str(input.file_path)
			or str(input.notebook_path)
			or str(input.pattern)
			or str(input.query)
			or str(input.url)
			or str(input.description)
			or str(input.prompt)
		if detail == nil then
			for _, v in input do
				if type(v) == "string" and v ~= "" then
					detail = v
					break
				end
			end
		end
	end
	local short = string.gsub(name, "^mcp__([^_]+)__", "%1:")
	return if detail ~= nil then short .. ": " .. (one_line(detail, 100) or "") else short
end

-- Context size and last tool call from a transcript's last assistant entries (scan.sh's `last`/`use`).
local function digest(a: Agent, d: Digest)
	local last = decode(d.last)
	if type(last) == "table" and type(last.message) == "table" and type(last.message.usage) == "table" then
		local u = last.message.usage
		a.tokens = (num(u.input_tokens) or 0)
			+ (num(u.cache_creation_input_tokens) or 0)
			+ (num(u.cache_read_input_tokens) or 0)
			+ (num(u.output_tokens) or 0)
		a.model = a.model or str(last.message.model)
	end
	local use = decode(d.use)
	if type(use) == "table" and type(use.message) == "table" and type(use.message.content) == "table" then
		for _, c in use.message.content do
			if type(c) == "table" and c.type == "tool_use" and str(c.name) ~= nil then
				a.tool = tool_summary(c.name, c.input)
			end
		end
	end
end

-- A finished workflow from its state file `<session>/workflows/<wf>.json`.
local function final_flow(dir: string, wf: string): Flow?
	local j = decode(read(dir .. "/workflows/" .. wf .. ".json", MAX_STATE_BYTES))
	if type(j) ~= "table" then
		return nil
	end
	local titles: { [number]: string } = {}
	local by_index: { [number]: Agent } = {}
	local agents: { Agent } = {}
	local progress = if type(j.workflowProgress) == "table" then j.workflowProgress else {}
	for _, p in progress do
		if type(p) == "table" and p.type == "workflow_phase" and num(p.index) ~= nil then
			titles[p.index] = str(p.title) or ("Phase " .. p.index)
		end
	end
	for _, p in progress do
		if type(p) == "table" and p.type == "workflow_agent" and num(p.index) ~= nil then
			local state = str(p.state) or "done"
			local err = one_line(p.error)
			if p.cached == true then
				state = "done"
			elseif state == "start" or state == "progress" then
				state = "stopped"
			elseif state == "error" and err == "skipped by user" then
				state = "skipped"
			end
			local started = num(p.startedAt)
			local last_at = num(p.lastProgressAt)
			local a: Agent = {
				key = tostring(p.index),
				index = p.index,
				id = str(p.agentId),
				label = str(p.label) or "agent",
				phase = str(p.phaseTitle) or (if num(p.phaseIndex) ~= nil then titles[p.phaseIndex] else nil) or "",
				state = state,
				model = str(p.fallbackModel) or str(p.model),
				kind = str(p.agentType),
				started = if started ~= nil then started / 1000 else nil,
				took = num(p.durationMs),
				last_at = if last_at ~= nil then last_at / 1000 else nil,
				tokens = num(p.tokens),
				tools = num(p.toolCalls),
				tool = if str(p.lastToolName) ~= nil
					then (p.lastToolName :: string) .. (if str(p.lastToolSummary) ~= nil then ": " .. (one_line(p.lastToolSummary, 100) :: string) else "")
					else nil,
				error = if state == "error" then err else nil,
				result = one_line(p.resultPreview),
				file = transcript(dir, wf, str(p.agentId)),
			}
			-- progress events repeat per agent; the last one holds its final state
			if by_index[p.index] == nil then
				table.insert(agents, a)
			else
				for i, old in agents do
					if old == by_index[p.index] then
						agents[i] = a
					end
				end
			end
			by_index[p.index] = a
		end
	end
	table.sort(agents, function(x, y)
		return x.index < y.index
	end)
	local indexes: { number } = {}
	for i in titles do
		table.insert(indexes, i)
	end
	table.sort(indexes)
	local phases: { string } = {}
	for _, i in indexes do
		table.insert(phases, titles[i])
	end
	if #phases == 0 and type(j.phases) == "table" then
		for _, p in j.phases do
			if type(p) == "table" and str(p.title) ~= nil then
				table.insert(phases, p.title)
			end
		end
	end
	local start = num(j.startTime)
	local status = str(j.status) or "completed"
	return {
		id = wf,
		name = str(j.workflowName) or wf,
		desc = one_line(j.summary, 300),
		status = status,
		start = if start ~= nil then start / 1000 else 0,
		took = num(j.durationMs),
		phases = phases,
		agents = agents,
	}
end

-- Name, description and phase titles from the workflow's script `meta`, when the script file names the run.
local function script_meta(dir: string, wf: string): (string?, string?, { string })
	local phases: { string } = {}
	for _, name in list(dir .. "/workflows/scripts") do
		if string.find(name, wf, 1, true) ~= nil then
			local src = read(dir .. "/workflows/scripts/" .. name, 512 * 1024) or ""
			local meta = string.match(src, "export%s+const%s+meta%s*=%s*(%b{})") or ""
			local title = string.match(meta, "name%s*:%s*['\"]([^'\"]+)['\"]")
			local desc = string.match(meta, "description%s*:%s*['\"]([^'\"]+)['\"]")
			local list_src = string.match(meta, "phases%s*:%s*(%b[])") or ""
			for t in string.gmatch(list_src, "title%s*:%s*['\"]([^'\"]+)['\"]") do
				table.insert(phases, t)
			end
			return title, desc, phases
		end
	end
	return nil, nil, phases
end

-- A workflow with no state file yet, from its journal, agent meta files and the scan's transcript digests.
local function live_flow(state: State, run: Run): Flow
	local name, desc, phases = script_meta(run.dir, run.id)
	local seen: { [string]: boolean } = {}
	for _, p in phases do
		seen[p] = true
	end
	local base = run.dir .. "/subagents/workflows/" .. run.id
	local agents: { Agent } = {}
	local by_key: { [string]: Agent } = {}
	for line in string.gmatch(read(base .. "/journal.jsonl") or "", "[^\n]+") do
		local e = decode(line)
		if type(e) == "table" and str(e.key) ~= nil then
			local a = by_key[e.key]
			if e.type == "started" then
				if a == nil then
					a = {
						key = e.key,
						index = #agents + 1,
						label = str(e.label) or "agent",
						phase = str(e.phase) or "",
						state = "running",
					}
					by_key[e.key] = a
					table.insert(agents, a)
				end
				local started = a :: Agent
				started.state = "running"
				started.id = str(e.agentId) or started.id
				started.file = transcript(run.dir, run.id, started.id)
				started.error = nil
				if started.phase ~= "" and not seen[started.phase] then
					seen[started.phase] = true
					table.insert(phases, started.phase)
				end
			elseif a ~= nil and e.type == "result" then
				a.state = "done"
				local r = e.result
				a.result = if type(r) == "table" then one_line(r.summary) or one_line(r) else one_line(r)
			elseif a ~= nil and e.type == "failed" then
				a.state = "error"
				a.error = one_line(e.error) or one_line(e.reason) or "failed"
			end
		end
	end
	local now = wall(state)
	local active = run.journal
	for _, a in agents do
		local d = if a.id ~= nil then run.agents[a.id] else nil
		if d ~= nil then
			a.started = d.meta
			a.last_at = if d.jsonl > 0 then d.jsonl else nil
			a.tools = d.tools
			active = math.max(active, d.jsonl)
			local meta = decode(read(base .. "/agent-" .. (a.id :: string) .. ".meta.json", 64 * 1024))
			if type(meta) == "table" then
				a.model = str(meta.model)
				local kind = str(meta.agentType)
				a.kind = if kind ~= "workflow-subagent" then kind else nil
			end
			digest(a, d)
			if a.state ~= "running" and d.jsonl > 0 then
				a.took = math.max(0, d.jsonl - d.meta) * 1000
			end
		end
	end
	local stale = now - active > STALE_S
	if stale then
		for _, a in agents do
			if a.state == "running" then
				a.state = "stopped"
			end
		end
	end
	return {
		id = run.id,
		name = name or run.id,
		desc = desc,
		status = if stale then "stopped" else "running",
		start = run.birth,
		took = if stale then math.max(0, active - run.birth) * 1000 else nil,
		phases = phases,
		agents = agents,
	}
end

---------------------------------------------------------------------------------------------------
-- Scanning

local function ensure_sel(state: State)
	if not state.follow then
		for _, f in state.flows do
			if f.id == state.sel then
				return
			end
		end
	end
	local first = state.flows[1]
	state.sel = if first ~= nil then first.id else nil
end

local function apply(state: State, out: string)
	local runs: { Run } = {}
	local by_id: { [string]: Run } = {}
	local dirs: { string } = {}
	state.sid = nil
	for line in string.gmatch(out, "[^\n]+") do
		local f = string.split(line, "\t")
		local kind = f[1]
		if kind == "now" then
			state.now = tonumber(f[2]) or state.now
			state.mono = tern.now()
		elseif kind == "session" then
			state.sid = f[3]
		elseif kind == "dir" and f[2] ~= nil then
			table.insert(dirs, f[2])
		elseif kind == "run" and f[3] ~= nil then
			local r: Run = { dir = f[2], id = f[3], birth = tonumber(f[4]) or 0, journal = tonumber(f[5]) or 0, agents = {} }
			by_id[r.id] = r
			table.insert(runs, r)
		elseif kind == "agent" and f[4] ~= nil then
			local r = by_id[f[3]]
			if r ~= nil then
				r.agents[f[4]] = { meta = tonumber(f[5]) or 0, jsonl = tonumber(f[6]) or 0, tools = tonumber(f[7]) or 0 }
			end
		elseif (kind == "last" or kind == "use") and f[3] ~= nil then
			local r = by_id[f[2]]
			local d = if r ~= nil then r.agents[f[3]] else nil
			if d ~= nil then
				-- the JSON holds no raw tabs, but rejoin in case a field had one
				local json = table.concat(f, "\t", 4)
				if kind == "last" then
					d.last = json
				else
					d.use = json
				end
			end
		end
	end

	state.title = nil
	local flows: { Flow } = {}
	local seen: { [string]: boolean } = {}
	for _, dir in dirs do
		local t = decode(read(dir .. "/custom-title.json", 64 * 1024))
		if type(t) == "table" and str(t.customTitle) ~= nil then
			state.title = t.customTitle
		end
		for _, name in list(dir .. "/workflows") do
			local wf = string.match(name, "^(wf_.+)%.json$")
			if wf ~= nil and not seen[wf] then
				local f = state.final[wf] or final_flow(dir, wf)
				if f ~= nil then
					state.final[wf] = f
					seen[wf] = true
					table.insert(flows, f)
				end
			end
		end
	end
	for _, r in runs do
		if not seen[r.id] then
			seen[r.id] = true
			table.insert(flows, live_flow(state, r))
		end
	end
	table.sort(flows, function(a, b)
		return a.start > b.start
	end)
	state.flows = flows
	ensure_sel(state)
end

local function scan(state: State, cb: () -> ())
	local argv = { "sh", tern.plugin.dir .. "/scripts/scan.sh" }
	for _, p in state.panes do
		table.insert(argv, p)
	end
	tern.process.run(argv, { timeout_ms = 15000 }, function(r)
		if r.status ~= 0 then
			state.error = if r.stderr ~= "" then r.stderr else "scan.sh exited " .. tostring(r.status)
		else
			state.error = nil
			local ok, err: any = pcall(apply, state, r.stdout)
			if not ok then
				state.error = tostring(err)
			end
		end
		state.loaded = true
		cb()
	end)
end

---------------------------------------------------------------------------------------------------
-- Views
--
-- `main` holds the selected workflow: a summary card, then its phases as one numbered list. A phase is one
-- line; the running or failed one (or any the user opens) shows its agents as Claude Code's tree. `dock`
-- holds the session's workflow list in its own scroll area, so a long history never pushes the detail away.

local STATUS_TONE: { [string]: string } = {
	running = "live",
	completed = "ok",
	killed = "warn",
	stopped = "warn",
	failed = "error",
}

local ICON: { [string]: string } = {
	running = "◐",
	queued = "○",
	done = "✓",
	completed = "✓",
	error = "✗",
	failed = "✗",
	stopped = "■",
	killed = "■",
	skipped = "–",
}

local PHASE_WORD: { [string]: string } = {
	running = "running",
	queued = "waiting",
	done = "done",
	error = "failed",
	stopped = "stopped",
}

local function selected(state: State): Flow?
	for _, f in state.flows do
		if f.id == state.sel then
			return f
		end
	end
	return nil
end

local function span_text(text: string, style: string?, role: string?): Node
	return with(ui.text({ ui.span(text, style) }), { role = role })
end

local function icon(status: string): Node
	return with(ui.text({ ui.span(ICON[status] or "○") }), { role = "cw.icon", mark = status })
end

local function is_live(a: Agent): boolean
	return a.state == "running" or a.state == "queued"
end

local function flow_took(state: State, f: Flow): number?
	if f.took ~= nil then
		return f.took
	end
	if f.status == "running" and f.start > 0 then
		return (wall(state) - f.start) * 1000
	end
	return nil
end

local function agent_took(state: State, a: Agent): number?
	if a.took ~= nil then
		return a.took
	end
	if a.state == "running" and a.started ~= nil then
		return math.max(0, wall(state) - a.started) * 1000
	end
	return nil
end

-- A table cell; numeric cells align right.
local function cell(text: string, style: string?, num: boolean?): Node
	return with(span_text(text, style, "cw.cell"), { mark = if num then "num" else nil })
end

local function head_row(role: string, cols: { string }, nums: { [number]: boolean }): Node
	local cells: { Node } = {}
	for i, c in cols do
		table.insert(cells, cell(c, "dim", nums[i]))
	end
	return with(ui.row(cells), { key = "th", role = role })
end

-- The state column of an agent: "idle 45s" when a running agent has not written for IDLE_S.
local function agent_state(state: State, a: Agent): string
	if a.state == "running" then
		local idle = if a.last_at ~= nil then wall(state) - a.last_at else 0
		return if idle >= IDLE_S then "idle " .. duration(idle * 1000) else "running"
	end
	return if a.state == "error" then "failed" elseif a.state == "done" then "" else a.state
end

local AGENT_COLS = { "", "", "Agent", "Model", "Tokens", "Tools", "State", "Time" }
local AGENT_NUMS = { [5] = true, [6] = true, [8] = true }

local function agent_row(state: State, a: Agent, last: boolean, typed: boolean): Node
	local took = agent_took(state, a)
	local line: { Node } = {
		span_text(if last then "└─" else "├─", "dim", "cw.branch"),
		icon(a.state),
		cell(a.label, "strong"),
	}
	if typed then
		table.insert(line, cell(a.kind or "", "muted"))
	end
	local st = agent_state(state, a)
	table.insert(line, cell(short_model(a.model) or "", "muted"))
	table.insert(line, cell(if a.tokens ~= nil then tokens(a.tokens) else "", "muted", true))
	table.insert(line, cell(if a.tools ~= nil and a.tools > 0 then tostring(a.tools) else "", "muted", true))
	table.insert(line, with(cell(st, if a.state == "error" then "error" else "muted"), { role = "cw.state", mark = if string.sub(st, 1, 4) == "idle" then "idle" else nil }))
	table.insert(line, cell(if took ~= nil then duration(took) else "", "dim", true))
	local kids: { Node } = { with(ui.row(line), { role = "cw.line" }) }
	if a.error ~= nil then
		table.insert(kids, span_text(a.error, "error", "cw.sub"))
	elseif a.state == "running" and a.tool ~= nil then
		table.insert(kids, span_text(a.tool, "muted", "cw.sub"))
	end
	local tip = a.result or a.tool
	return with(ui.col(kids), {
		key = "a_" .. a.key,
		role = "cw.agent",
		mark = a.state,
		actions = if a.file ~= nil then { click = "open=" .. a.file } else nil,
		title = if tip ~= nil then tip .. (if a.file ~= nil then "\n\nClick to open the transcript." else "") else nil,
	})
end

-- The workflow's time span in epoch seconds: start to end, or to now while it runs.
local function flow_span(state: State, f: Flow): (number, number)
	local took = flow_took(state, f)
	local stop = if took ~= nil then f.start + took / 1000 else wall(state)
	return f.start, math.max(stop, f.start + 1)
end

-- When a phase ran inside the workflow's span, as TIMELINE cells: idle "─", running "━". Phases of one
-- workflow can run at the same time, so this shows overlap that the list order alone cannot.
local TIMELINE = 24

local function timeline(state: State, f: Flow, first: number?, last: number?, status: string): Node
	local pre, on = TIMELINE, 0
	if first ~= nil and f.start > 0 then
		local from, to = flow_span(state, f)
		local span = to - from
		local stop = last or first
		local a = math.clamp(math.floor((first - from) / span * TIMELINE), 0, TIMELINE - 1)
		local b = math.clamp(math.ceil((stop - from) / span * TIMELINE), a + 1, TIMELINE)
		pre, on = a, b - a
	end
	return with(
		ui.row({
			span_text(string.rep("─", pre), nil, "cw.tl_off"),
			with(span_text(string.rep("━", on), nil, "cw.tl_on"), { mark = status }),
			span_text(string.rep("─", TIMELINE - pre - on), nil, "cw.tl_off"),
		}),
		{
			role = "cw.timeline",
			key = "tl",
			title = if first ~= nil
				then "Ran " .. os.date("%H:%M", math.floor(first)) .. " – " .. (if status == "running" then "now" else os.date("%H:%M", math.floor(last or first)))
				else "Not started",
		}
	)
end

-- One phase: "Cleanup  ✓ done  1/1 · sol  ──━━━━─────  12m 3s"; open, its agents follow as a tree, done
-- agents folded into "✓ N done" unless verbose.
local function phase_node(state: State, f: Flow, n: number, title: string, agents: { Agent }): Node
	local done, failed, live = 0, 0, 0
	local first: number? = nil
	local last: number? = nil
	for _, a in agents do
		if a.state == "done" then
			done += 1
		elseif a.state == "error" then
			failed += 1
		elseif is_live(a) then
			live += 1
		end
		if a.started ~= nil then
			first = math.min(first or a.started, a.started)
			local took = agent_took(state, a)
			if took ~= nil then
				last = math.max(last or 0, a.started + took / 1000)
			end
		end
	end
	local total = #agents
	local status = if total == 0
		then "queued"
		elseif live > 0 then (if f.status == "running" then "running" else "stopped")
		elseif failed > 0 then "error"
		elseif done < total then "stopped"
		else "done"
	local model = if total > 0 then agents[1].model else nil
	for _, a in agents do
		if a.model ~= model then
			model = nil
		end
	end
	local counts = if total > 0 then done .. "/" .. total else ""
	local short = short_model(model)
	if short ~= nil then
		counts ..= " · " .. short
	end
	if failed > 0 then
		counts ..= " · " .. failed .. " failed"
	end
	local key = f.id .. "|" .. n
	local forced = state.open[key]
	local open = total > 0 and (if forced ~= nil then forced else (state.verbose or status == "running" or status == "error"))
	local head = with(
		ui.row({
			icon(status),
			span_text(if title == "" then "Agents" else title, "strong", "cw.phase"),
			span_text(PHASE_WORD[status] or status, "muted", "cw.word"),
			span_text(counts, "muted", "cw.stats"),
			timeline(state, f, first, if status == "running" then wall(state) else last, status),
			span_text(if first ~= nil and last ~= nil then duration((last - first) * 1000) else "", "dim", "cw.time"),
		}),
		{
			key = "head",
			role = "cw.phasehead",
			mark = if open then "open" else nil,
			actions = if total > 0 then { click = "phase=" .. key .. "|" .. (if open then "1" else "0") } else nil,
		}
	)
	local rows: { Node } = { head }
	if open then
		local shown: { Agent } = {}
		for _, a in agents do
			if state.verbose or forced == true or a.state ~= "done" then
				table.insert(shown, a)
			end
		end
		local typed = false
		for _, a in agents do
			typed = typed or a.kind ~= nil
		end
		local cols, nums = AGENT_COLS, AGENT_NUMS
		if typed then
			cols = { "", "", "Agent", "Type", "Model", "Tokens", "Tools", "State", "Time" }
			nums = { [6] = true, [7] = true, [9] = true }
		end
		local table_rows: { Node } = {}
		if #shown > 0 then
			table.insert(table_rows, head_row("cw.agenthead", cols, nums))
		end
		local folded = done - (if state.verbose or forced == true then done else 0)
		if folded > 0 then
			table.insert(table_rows, with(ui.row({ icon("done"), span_text(folded .. " done", "muted") }), { role = "cw.folded", key = "folded" }))
		end
		for i, a in shown do
			table.insert(table_rows, agent_row(state, a, i == #shown, typed))
		end
		table.insert(rows, with(ui.col(table_rows), { key = "agents", role = "cw.agents", mark = if typed then "typed" else nil }))
	end
	return with(ui.col(rows), { key = "p_" .. n, role = "cw.phaseitem", mark = status })
end

local function summary_card(state: State, f: Flow): Node
	local done, total, tok, tools = 0, #f.agents, 0, 0
	for _, a in f.agents do
		if a.state == "done" then
			done += 1
		end
		tok += a.tokens or 0
		tools += a.tools or 0
	end
	local took = flow_took(state, f)
	local facts: { string } = {}
	if took ~= nil then
		table.insert(facts, duration(took) .. (if f.status == "running" then " elapsed" else ""))
	end
	if tok > 0 then
		table.insert(facts, tokens(tok) .. " tokens")
	end
	if tools > 0 then
		table.insert(facts, plural(tools, "tool"))
	end
	if f.start > 0 then
		table.insert(facts, "started " .. ago(wall(state) - f.start) .. " (" .. os.date("%b %d %H:%M", math.floor(f.start)) .. ")")
	end
	local kids: { Node } = {
		with(ui.row({
			icon(f.status),
			span_text(f.name, "strong", "cw.flowname"),
			with(ui.badge(f.status, STATUS_TONE[f.status] or "neutral"), { role = "cw.status" }),
		}), { key = "title", role = "cw.titlerow" }),
	}
	if f.desc ~= nil then
		table.insert(kids, with(span_text(f.desc, "muted", "cw.desc"), { key = "desc" }))
	end
	table.insert(kids, with(ui.progress(if total > 0 then done / total else 0, { ui.span(done .. "/" .. plural(total, "agent") .. " done", "muted") }), { key = "progress" }))
	table.insert(kids, with(span_text(table.concat(facts, "  ·  "), "dim", "cw.facts"), { key = "facts" }))
	return with(ui.col(kids), { key = "card", role = "cw.card", mark = f.status })
end

local function flow_detail(state: State, f: Flow): { Node }
	local nodes: { Node } = { summary_card(state, f) }
	local groups: { string } = table.clone(f.phases)
	local known: { [string]: boolean } = {}
	for _, p in groups do
		known[p] = true
	end
	for _, a in f.agents do
		if not known[a.phase] then
			known[a.phase] = true
			table.insert(groups, a.phase)
		end
	end
	if #groups == 0 then
		table.insert(nodes, span_text("No agents have started yet.", "muted"))
		return nodes
	end
	local items: { Node } = {}
	for i, phase in groups do
		local agents: { Agent } = {}
		for _, a in f.agents do
			if a.phase == phase then
				table.insert(agents, a)
			end
		end
		table.insert(items, phase_node(state, f, i, phase, agents))
	end
	table.insert(nodes, with(span_text("Phases", "dim", "cw.caption"), { key = "phases_caption" }))
	table.insert(nodes, with(ui.col(items), { key = "phases", role = "cw.phases" }))
	return nodes
end

local function flow_row(state: State, f: Flow): Node
	local took = flow_took(state, f)
	local done, tok, tools = 0, 0, 0
	for _, a in f.agents do
		if a.state == "done" then
			done += 1
		end
		tok += a.tokens or 0
		tools += a.tools or 0
	end
	return with(
		ui.row({
			icon(f.status),
			cell(f.name, "strong"),
			cell(done .. "/" .. #f.agents, "muted", true),
			cell(if tok > 0 then tokens(tok) else "", "muted", true),
			cell(if tools > 0 then tostring(tools) else "", "muted", true),
			cell(if took ~= nil then duration(took) else "", "muted", true),
			cell(if f.start > 0 then ago(wall(state) - f.start) else "", "dim", true),
		}),
		{
			key = "f_" .. f.id,
			role = "cw.flow",
			mark = if f.id == state.sel then "pick" else nil,
			actions = { click = "pick=" .. f.id },
		}
	)
end

local function toggle(label: string, on: boolean, act: string): Node
	return with(ui.badge(label, if on then "accent" else "neutral"), { key = act, role = "cw.button", mark = if on then "on" else nil, actions = { click = act } })
end

local function view(state: State): BlockView
	local bar = with(
		ui.row({
			span_text("Claude workflows", "strong", "cw.brand"),
			span_text(state.title or (if state.sid ~= nil then string.sub(state.sid, 1, 8) else ""), "muted", "cw.session"),
			span_text("", nil, "cw.spacer"),
			toggle(if state.follow then "Following latest" else "Follow latest", state.follow, "follow"),
			toggle(if state.verbose then "All agents" else "Active agents", state.verbose, "verbose"),
		}),
		{ key = "bar", role = "cw.bar" }
	)
	local body: { Node } = { bar }
	local dock: Node? = nil
	if state.error ~= nil then
		table.insert(body, ui.text({ ui.span("Scan failed: ", "error"), ui.span(state.error, "muted") }))
	elseif not state.loaded then
		table.insert(body, ui.node("spinner", { style = "dots", label = { ui.span("Finding the Claude session", "muted") } }))
	elseif state.sid == nil then
		table.insert(body, span_text("No Claude Code session runs in this tab.", "muted"))
		table.insert(body, span_text("Start claude in a pane of this tab. This block finds it by itself.", "dim"))
	elseif #state.flows == 0 then
		table.insert(body, span_text("This session has no workflows yet. A new one shows here when it starts.", "muted"))
	else
		local f = selected(state)
		if f ~= nil then
			table.insert(body, with(ui.col(flow_detail(state, f)), { key = "detail_" .. f.id, role = "cw.detail" }))
		end
		local rows: { Node } = {}
		for _, fl in state.flows do
			table.insert(rows, flow_row(state, fl))
		end
		dock = ui.col({
			with(ui.row({
				span_text("Workflows in this session", "strong", "cw.caption"),
				span_text(tostring(#state.flows), "muted"),
				span_text("↑↓ select · f follow · v agents · r refresh", "dim", "cw.keys"),
			}), { key = "head", role = "cw.dockhead" }),
			head_row("cw.flowhead", { "", "Workflow", "Agents", "Tokens", "Tools", "Time", "Started" }, { [3] = true, [4] = true, [5] = true, [6] = true, [7] = true }),
			with(ui.col(rows), { key = "flows", role = "cw.flows" }),
		})
	end
	return {
		main = ui.col(body),
		dock = dock,
	}
end

---------------------------------------------------------------------------------------------------
-- Block

local function step(state: State, by: number)
	local at = 0
	for i, f in state.flows do
		if f.id == state.sel then
			at = i
		end
	end
	local nxt = state.flows[math.clamp(at + by, 1, math.max(1, #state.flows))]
	if nxt ~= nil then
		state.sel = nxt.id
	end
end

local block: BlockDef<State> = {
	init = function(cx, args, saved)
		local panes: { string } = {}
		for _, a in args do
			table.insert(panes, a)
		end
		local old = if type(saved) == "table" then saved else {}
		if #panes == 0 and type(old.panes) == "table" then
			for _, p in old.panes do
				if type(p) == "string" then
					table.insert(panes, p)
				end
			end
		end
		local state: State = {
			panes = panes,
			sid = nil,
			title = nil,
			flows = {},
			final = {},
			sel = str(old.sel),
			follow = old.follow ~= false,
			verbose = old.verbose == true,
			open = {},
			now = os.time(),
			mono = tern.now(),
			busy = false,
			loaded = false,
			error = nil,
		}
		local function tick()
			if not running(cx.pane) then
				return
			end
			if state.busy then
				tern.timer(TICK_MS, tick)
				return
			end
			state.busy = true
			scan(state, function()
				state.busy = false
				if running(cx.pane) then
					cx:render()
					tern.timer(TICK_MS, tick)
				end
			end)
		end
		tick()
		return state
	end,

	title = function(state)
		local f = selected(state)
		return if f ~= nil then "Workflows · " .. f.name else "Claude workflows"
	end,

	view = function(state, _cx)
		return view(state)
	end,

	key = function(state, key, cx)
		if key.ctrl or key.alt or key.meta then
			return false
		end
		if key.name == "j" or key.name == "down" or key.name == "k" or key.name == "up" then
			step(state, if key.name == "j" or key.name == "down" then 1 else -1)
			state.follow = false
			local sel = state.sel
			if sel ~= nil then
				tern.timer(30, function()
					if running(cx.pane) then
						cx:frame({ { "reveal", "dock.flows.f_" .. sel, "nearest" } })
					end
				end)
			end
		elseif key.name == "f" then
			state.follow = not state.follow
			ensure_sel(state)
		elseif key.name == "v" then
			state.verbose = not state.verbose
			state.open = {}
		elseif key.name == "r" then
			state.final = {}
			scan(state, function()
				cx:render()
			end)
			return false
		else
			return false
		end
		return true
	end,

	event = function(state, ev, cx)
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "pick" and type(ev.value) == "string" then
			state.sel = ev.value
			state.follow = false
		elseif ev.act == "follow" then
			state.follow = not state.follow
			ensure_sel(state)
		elseif ev.act == "verbose" then
			state.verbose = not state.verbose
			state.open = {}
		elseif ev.act == "phase" and type(ev.value) == "string" then
			-- "<wf>|<n>|<1 when shown open now>": a click flips what the phase shows
			local key, shown = string.match(ev.value, "^(.*)|([01])$")
			if key ~= nil then
				state.open[key] = shown ~= "1"
			end
		elseif ev.act == "open" and type(ev.value) == "string" then
			cx:open(ev.value)
			return
		end
		cx:render()
	end,

	save = function(state)
		return { panes = state.panes, sel = state.sel, follow = state.follow, verbose = state.verbose }
	end,
}

tern.block.define("view", block)
