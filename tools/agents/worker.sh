#!/bin/bash
# worker.sh <name> <worktree dir (bash path)> <prompt file> <model> <budget usd>
# Runs one headless Claude Code worker on the producer's API key (WORKER_API_KEY in the Windows user environment).
# The key is read into the worker's process only and never printed.
name="$1"; dir="$2"; prompt="$3"; model="$4"; budget="$5"
out="${WORKER_OUT_DIR:-${TMPDIR:-/tmp}}/$name.json"
K=$(powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('WORKER_API_KEY','User')" | tr -d '\r\n')
[ -z "$K" ] && { echo "NO KEY"; exit 3; }
for v in $(env | grep -E '^(CLAUDE|ANTHROPIC)' | cut -d= -f1); do unset $v; done
cd "$dir" || exit 4
export PATH="/usr/bin:/mingw64/bin:$PATH:$(cygpath -u "$LOCALAPPDATA")/Programs/LuaJIT/bin"   # Git tools first: Windows find.exe/sort.exe break the test runner
export PYTHONIOENCODING=utf-8
ANTHROPIC_API_KEY="$K" claude -p "$(cat "$prompt")" --output-format json --model "$model" \
  --permission-mode acceptEdits --allowedTools "Bash Read Edit Write Glob Grep" \
  --max-budget-usd "$budget" > "$out" 2> "$out.err"
code=$?
python - "$out" <<'P'
import sys,json
t=open(sys.argv[1],encoding='utf-8',errors='replace').read()
try:
    d=json.loads(t.strip().splitlines()[-1])
    print('WORKER DONE is_error=%s subtype=%s cost=$%.2f turns=%s' % (d.get('is_error'),d.get('subtype'),d.get('total_cost_usd') or 0,d.get('num_turns')))
    print('--- REPORT ---'); print(d.get('result') or '')
except Exception as e:
    print('WORKER OUTPUT NOT JSON:',t[-1500:])
P
exit $code
