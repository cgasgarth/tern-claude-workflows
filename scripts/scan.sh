#!/bin/sh
# Finds the Claude Code session that runs in one of the given Tern panes and lists its workflows.
# Luau has no stat and no process environment access, so the host half runs this through tern.process.run.
#
#   scan.sh PANE...
#
# Claude Code writes <config>/sessions/<pid>.json for each live process, and every process started in a
# Tern pane (TUI or ACP chat) inherits TERN_PANE. Panes are ranked by argument order (the focused pane
# first), then interactive sessions before background ones, then the session updated last.
#
# Output, tab-separated:
#   now     EPOCH
#   session PANE  SESSION_ID
#   dir     SESSION_DIR                                    one per project folder that holds the session
#   run     SESSION_DIR  WF  BIRTH  JOURNAL_MTIME           a workflow with no final state file yet
#   agent   SESSION_DIR  WF  AGENT_ID  META_MTIME  JSONL_MTIME  TOOL_CALLS
#   last    WF  AGENT_ID  JSON                              the agent's last assistant transcript entry
#   use     WF  AGENT_ID  JSON                              its last assistant entry with a tool call

set -u
claude=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
tab=$(printf '\t')

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
birth() {
	b=$(stat -f %B "$1" 2>/dev/null || stat -c %W "$1" 2>/dev/null || echo 0)
	[ "$b" -gt 0 ] 2>/dev/null && echo "$b" || mtime "$1"
}
field() { sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p" "$2" | head -n 1; }
pane_of() {
	if [ -r "/proc/$1/environ" ]; then
		tr '\0' '\n' <"/proc/$1/environ" | sed -n 's/^TERN_PANE=//p' | head -n 1
	else
		ps -E -ww -o command= -p "$1" 2>/dev/null | tr ' ' '\n' | sed -n 's/^TERN_PANE=//p' | head -n 1
	fi
}

now=$(date +%s)
echo "now${tab}$now"

# Claude processes that a session started (test harnesses, nested agents) inherit TERN_PANE too, so a
# candidate whose ancestor is another candidate is skipped: the outermost process is the pane's session.
cands=' '
for f in "$claude"/sessions/*.json; do
	pid=${f##*/}
	pid=${pid%.json}
	case $pid in '' | *[!0-9]*) continue ;; esac
	kill -0 "$pid" 2>/dev/null && cands="$cands$pid "
done
nested() {
	q=$1
	while :; do
		q=$(ps -o ppid= -p "$q" 2>/dev/null | tr -d ' ')
		case $q in '' | 0 | 1) return 1 ;; esac
		case $cands in *" $q "*) return 0 ;; esac
	done
}

best_rank='' best_upd=0 best_pane='' best_sid=''
for f in "$claude"/sessions/*.json; do
	[ -f "$f" ] || continue
	pid=${f##*/}
	pid=${pid%.json}
	case $pid in '' | *[!0-9]*) continue ;; esac
	kill -0 "$pid" 2>/dev/null || continue
	pane=$(pane_of "$pid")
	[ -n "$pane" ] || continue
	i=0 idx=''
	for p in "$@"; do
		if [ "$p" = "$pane" ]; then
			idx=$i
			break
		fi
		i=$((i + 1))
	done
	[ -n "$idx" ] || continue
	nested "$pid" && continue
	sid=$(field sessionId "$f")
	[ -n "$sid" ] || continue
	k=1
	[ "$(field kind "$f")" = interactive ] && k=0
	rank=$((idx * 2 + k))
	upd=$(field updatedAt "$f")
	case $upd in '' | *[!0-9]*) upd=0 ;; esac
	if [ -z "$best_rank" ] || [ "$rank" -lt "$best_rank" ] || { [ "$rank" -eq "$best_rank" ] && [ "$upd" -gt "$best_upd" ]; }; then
		best_rank=$rank best_upd=$upd best_pane=$pane best_sid=$sid
	fi
done

[ -n "$best_sid" ] || exit 0
printf 'session\t%s\t%s\n' "$best_pane" "$best_sid"

for d in "$claude"/projects/*/"$best_sid"; do
	[ -d "$d" ] || continue
	printf 'dir\t%s\n' "$d"
	for w in "$d"/subagents/workflows/wf_*; do
		[ -d "$w" ] || continue
		wf=${w##*/}
		[ -f "$d/workflows/$wf.json" ] && continue
		printf 'run\t%s\t%s\t%s\t%s\n' "$d" "$wf" "$(birth "$w")" "$(mtime "$w/journal.jsonl")"
		for m in "$w"/agent-*.meta.json; do
			[ -f "$m" ] || continue
			id=${m##*/agent-}
			id=${id%.meta.json}
			t="$w/agent-$id.jsonl"
			tools=0
			[ -f "$t" ] && tools=$(grep -o '"type":"tool_use"' "$t" | wc -l | tr -d ' ')
			tm=$(mtime "$t")
			printf 'agent\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$wf" "$id" "$(mtime "$m")" "$tm" "$tools"
			[ -f "$t" ] && [ $((now - tm)) -lt 1800 ] || continue
			# The last assistant entry carries the context size; the last tool call names what the agent does now.
			recent=$(tail -c 400000 "$t" | grep '"type":"assistant"')
			printf 'last\t%s\t%s\t%s\n' "$wf" "$id" "$(printf '%s\n' "$recent" | tail -n 1)"
			printf 'use\t%s\t%s\t%s\n' "$wf" "$id" "$(printf '%s\n' "$recent" | grep '"type":"tool_use"' | tail -n 1)"
		done
	done
done
