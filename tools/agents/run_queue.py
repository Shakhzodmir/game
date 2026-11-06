#!/usr/bin/env python3
"""Queue runner for headless Claude Code workers that use the producer's own API key.

Every task of queue.json is done by one `claude -p` run (a "worker") in its own git worktree and branch
(agent/<id>). The worker bills the key in WORKER_API_KEY, not the plan of the session that started the runner. When
a worker is done the runner checks its work itself (tests, linters), merges the branch into agent/integration
and goes on with the next task. Nothing is pushed unless --push is given; the session that started the runner takes
agent/integration, runs the full checks and opens a pull request.

  python3 tools/agents/run_queue.py check-key             # one tiny call: does the key work, what does it cost
  python3 tools/agents/run_queue.py run --max-wave 1      # work through the queue (use nohup, it takes hours)
  python3 tools/agents/run_queue.py status                # table of the tasks
  python3 tools/agents/run_queue.py stop [--now]          # no new tasks (--now: kill the running workers too)
  python3 tools/agents/run_queue.py reset WP-3            # a task goes back to "pending" (branch and worktree removed)
  python3 tools/agents/run_queue.py final-check           # all checks on agent/integration
  python3 tools/agents/run_queue.py selftest              # the runner against a fake claude in a temp repository

State (worktrees, logs, reports, state.json) lives in $AGENT_STATE_DIR (default /tmp/glow-agents).
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

# Variables of the parent session that a worker must not inherit: they would tie it to that session (its billing, its
# GitHub access) instead of the producer's key. Proxy and CA variables stay: the worker needs the network.
DROP_PREFIXES = ("ANTHROPIC_", "CLAUDE", "CCR_", "AI_AGENT", "GH_", "GITHUB_", "AWS_", "CLOUDSDK_", "SESSION_INGRESS",
                 "SBX_", "ENVRUNNER", "ENV_MANAGER", "TRACEPARENT", "MCP_", "USE_SHTTP", "DOCUMENTS_MCP", "GCM_",
                 "GIT_ASKPASS", "WORKER_API_KEY")

# Files that are generated from others: a merge conflict in them is solved by generating them again.
GENERATED = ("client/assets_index.lua",)

# The producer allows these two models and no others (03.11.2026). Short names are accepted and expanded.
ALLOWED_MODELS = ("claude-sonnet-5-5", "claude-haiku-5-5")
MODEL_ALIASES = {"sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5"}


def normalize_model(name):
    name = MODEL_ALIASES.get(name, name)
    if name not in ALLOWED_MODELS:
        raise SystemExit("model %r is not allowed: only %s" % (name, " and ".join(ALLOWED_MODELS)))
    return name


DEFAULTS = {
    "model": "claude-sonnet-5-5",
    "max_budget_usd": 10.0,
    "max_minutes": 90,
    "retries": 1,
    "regen": ["python3", "tools/gen_defold.py"],
    "verify": [
        ["lua5.1", "tools/test/run.lua"],
        ["luajit", "tools/test/run.lua"],
        ["luajit", "tools/check_refs.lua"],
        ["python3", "tools/gen_defold.py", "--check"],
        ["sh", "tools/check_syntax.sh"],
    ],
}


def now():
    return time.strftime("%H:%M:%S")


def log(msg):
    print("[%s] %s" % (now(), msg), flush=True)


def trailers():
    sid = os.environ.get("CLAUDE_CODE_REMOTE_SESSION_ID", "")
    lines = ["Co-Authored-By: Claude <noreply@anthropic.com>"]
    if sid:
        body = sid[4:] if sid.startswith("cse_") else sid
        lines.append("Claude-Session: https://claude.ai/code/session_" + body)
    return "\n".join(lines)


def worker_env(key):
    env = {k: v for k, v in os.environ.items() if not k.startswith(DROP_PREFIXES)}
    env["ANTHROPIC_API_KEY"] = key
    env["IS_SANDBOX"] = "1"  # lets --dangerously-skip-permissions run as root inside the container
    env["DISABLE_AUTOUPDATER"] = "1"
    env["CLAUDE_CODE_SUBAGENT_MODEL"] = "claude-sonnet-5-5"  # sub-agents of a worker are Sonnet too
    return env


def parse_result(out):
    """The result object of `claude -p --output-format json` (one object, or a list of events)."""
    out = (out or "").strip()
    data = None
    try:
        data = json.loads(out)
    except ValueError:
        for line in reversed(out.splitlines()):
            try:
                data = json.loads(line)
                break
            except ValueError:
                continue
    if isinstance(data, list):
        data = next((x for x in reversed(data) if isinstance(x, dict) and x.get("type") == "result"),
                    data[-1] if data else {})
    return data if isinstance(data, dict) else {}


class Runner:
    def __init__(self, repo, queue_path, state_dir, claude_bin=None, key=None, push=False):
        self.repo = repo
        self.queue_path = queue_path
        with open(queue_path, encoding="utf-8") as f:
            self.queue = json.load(f)
        self.defaults = dict(DEFAULTS)
        self.defaults.update(self.queue.get("defaults", {}))
        self.tasks = self.queue["tasks"]
        for t in self.tasks:  # a model outside the allowed two stops the runner before anything is spent
            t["model"] = normalize_model(t.get("model", self.defaults["model"]))
        self.by_id = {t["id"]: t for t in self.tasks}
        self.state_dir = state_dir
        self.claude = claude_bin or os.environ.get("CLAUDE_BIN", "claude")
        self.key = key if key is not None else os.environ.get("WORKER_API_KEY", "")
        self.push = push
        self.lock = threading.RLock()      # the state
        self.git_lock = threading.RLock()  # git administration (worktrees, merges); re-entrant: integration() is called under it
        self.procs = {}
        for sub in ("worktrees", "logs", "reports"):
            os.makedirs(os.path.join(state_dir, sub), exist_ok=True)
        self.state_path = os.path.join(state_dir, "state.json")
        self.state = {"spent": 0.0, "tasks": {}}
        if os.path.exists(self.state_path):
            with open(self.state_path, encoding="utf-8") as f:
                self.state = json.load(f)

    # -- state ---------------------------------------------------------------------------------------------------
    def save(self):
        with self.lock:
            tmp = self.state_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.state, f, indent=1, ensure_ascii=False)
            os.replace(tmp, self.state_path)

    def st(self, tid):
        with self.lock:
            return self.state["tasks"].setdefault(tid, {"status": "pending", "cost": 0.0})

    def set(self, tid, **kw):
        with self.lock:
            self.st(tid).update(kw)
            self.save()

    def flag(self, name):
        return os.path.exists(os.path.join(self.state_dir, name))

    # -- git -----------------------------------------------------------------------------------------------------
    def git(self, *args, cwd=None, check=True):
        r = subprocess.run(["git", *args], cwd=cwd or self.repo, capture_output=True, text=True)
        if check and r.returncode != 0:
            raise RuntimeError("git %s: %s" % (" ".join(args), (r.stderr or r.stdout).strip()[:500]))
        return r

    def wt(self, name):
        return os.path.join(self.state_dir, "worktrees", name)

    def branch_exists(self, branch):
        return self.git("rev-parse", "--verify", "--quiet", "refs/heads/" + branch, check=False).returncode == 0

    def ensure_worktree(self, name, branch, base):
        path = self.wt(name)
        with self.git_lock:
            if os.path.isdir(path):
                return path
            self.git("worktree", "prune", check=False)
            if self.branch_exists(branch):
                self.git("worktree", "add", path, branch)
            else:
                self.git("worktree", "add", "-b", branch, path, base)
        return path

    def drop_worktree(self, name, branch):
        with self.git_lock:
            path = self.wt(name)
            if os.path.isdir(path):
                self.git("worktree", "remove", "--force", path, check=False)
                shutil.rmtree(path, ignore_errors=True)
            self.git("worktree", "prune", check=False)
            if self.branch_exists(branch):
                self.git("branch", "-D", branch, check=False)

    def integration(self):
        return self.ensure_worktree("integration", "agent/integration", "HEAD")

    def head(self, ref, cwd=None):
        return self.git("rev-parse", ref, cwd=cwd).stdout.strip()

    # -- one task ------------------------------------------------------------------------------------------------
    def conf(self, t, key):
        return t.get(key, self.defaults[key])

    RESUME_NOTE = ("ПРОДОЛЖЕНИЕ ПРЕРВАННОЙ РАБОТЫ. Прошлый запуск этой задачи оборвался (контейнер перезапустился), а рабочая "
                   "копия сохранилась: в ней могут лежать твои неоконченные правки и коммиты. Сначала посмотри `git status`, "
                   "`git diff --stat` и `git log --oneline`, пойми, что уже сделано, и продолжай с этого места: не начинай заново "
                   "и не откатывай сделанное без причины. Остальные правила и сама задача ниже без изменений.")

    def prompt(self, t, path, base, resume=False):
        with open(os.path.join(HERE, t["spec"]) if not os.path.isabs(t["spec"]) else t["spec"], encoding="utf-8") as f:
            spec = f.read()
        note = self.RESUME_NOTE + "\n\n" if resume else ""
        return ("ЗАДАЧА: %s: %s\nВетка: agent/%s. Рабочая копия: %s. Базовый коммит: %s.\n\n%s%s"
                % (t["id"], t["title"], t["id"], path, base[:10], note, spec))

    def rules(self):
        p = os.path.join(HERE, "worker_rules.md")
        return open(p, encoding="utf-8").read() if os.path.exists(p) else ""

    def run_worker(self, t, path, prompt, cap, log_name):
        cmd = [self.claude, "-p", prompt, "--output-format", "json", "--model", normalize_model(self.conf(t, "model")),
               "--dangerously-skip-permissions", "--max-budget-usd", "%.2f" % cap,
               "--append-system-prompt", self.rules()]
        if t.get("effort"):
            cmd += ["--effort", t["effort"]]
        proc = subprocess.Popen(cmd, cwd=path, env=worker_env(self.key), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.procs[t["id"]] = proc
        try:
            out, err = proc.communicate(timeout=self.conf(t, "max_minutes") * 60)
            timed_out = False
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            out, err = proc.communicate()
            timed_out = True
        finally:
            self.procs.pop(t["id"], None)
        with open(os.path.join(self.state_dir, "logs", log_name + ".json"), "w", encoding="utf-8") as f:
            f.write(out or "")
        with open(os.path.join(self.state_dir, "logs", log_name + ".err"), "w", encoding="utf-8") as f:
            f.write(err or "")
        data = parse_result(out)
        cost = float(data.get("total_cost_usd") or 0)
        with self.lock:
            self.st(t["id"])["cost"] = round(self.st(t["id"])["cost"] + cost, 4)
            self.state["spent"] = round(self.state["spent"] + cost, 4)
            self.save()
        failed = timed_out or proc.returncode != 0 or bool(data.get("is_error"))
        note = ""
        if timed_out:
            note = "timeout"
        elif failed:
            note = (str(data.get("result") or data.get("subtype") or err or "worker failed").strip().splitlines() or [""])[0][:200]
        return data, failed, note

    def commit_leftovers(self, path):
        """Whatever the worker left uncommitted is committed, so that nothing is lost (and the checks see it)."""
        if self.git("status", "--porcelain", cwd=path).stdout.strip():
            self.git("add", "-A", cwd=path)
            self.git("commit", "-q", "-m", "Changes the worker left uncommitted\n\n" + trailers(), cwd=path)
            return True
        return False

    def verify(self, t, path):
        """-> (ok, failing step, log path). The runner's own checks: the worker's word is not enough."""
        regen = self.conf(t, "regen")
        if regen:
            subprocess.run(regen, cwd=path, capture_output=True, text=True)
            if self.git("status", "--porcelain", cwd=path).stdout.strip():
                self.git("add", "-A", cwd=path)
                self.git("commit", "-q", "-m", "Regenerate generated resources\n\n" + trailers(), cwd=path)
        for argv in self.conf(t, "verify"):
            name = os.path.basename(argv[0]) + "-" + os.path.basename(argv[-1])
            logp = os.path.join(self.state_dir, "logs", "%s.verify.%s.log" % (t["id"], name))
            try:
                r = subprocess.run(argv, cwd=path, capture_output=True, text=True, timeout=1800)
                text, code = r.stdout + r.stderr, r.returncode
            except subprocess.TimeoutExpired:
                text, code = "timeout after 30 min", 1
            with open(logp, "w", encoding="utf-8") as f:
                f.write(text)
            if code != 0:
                return False, " ".join(argv), logp
        return True, None, None

    def merge(self, t):
        """agent/<id> into agent/integration. -> (ok, note)"""
        tid = t["id"]
        ipath = self.integration()
        msg = "Merge agent/%s: %s\n\n%s" % (tid, t["title"], trailers())
        with self.git_lock:
            r = self.git("merge", "--no-ff", "-m", msg, "agent/" + tid, cwd=ipath, check=False)
            if r.returncode == 0:
                return True, ""
            conflicted = [x for x in self.git("diff", "--name-only", "--diff-filter=U", cwd=ipath).stdout.split() if x]
            if conflicted and all(x in GENERATED for x in conflicted):
                for x in conflicted:
                    self.git("checkout", "--ours", x, cwd=ipath)
                regen = self.conf(t, "regen")
                if regen:
                    subprocess.run(regen, cwd=ipath, capture_output=True, text=True)
                self.git("add", "-A", cwd=ipath)
                self.git("commit", "-q", "--no-edit", cwd=ipath)
                return True, "generated files regenerated"
            self.git("merge", "--abort", cwd=ipath, check=False)
            return False, "conflict in " + ", ".join(conflicted or ["?"])

    def write_report(self, t, data):
        with open(os.path.join(self.state_dir, "reports", t["id"] + ".md"), "w", encoding="utf-8") as f:
            f.write("# %s: %s\n\n%s\n" % (t["id"], t["title"], data.get("result") or "(no report)"))

    def run_task(self, t):
        tid = t["id"]
        try:
            resume = bool(self.st(tid).get("resume")) and os.path.isdir(self.wt(tid))
            with self.git_lock:
                self.integration()
                base = (self.st(tid).get("base") if resume else None) or self.head("agent/integration")
            path = self.ensure_worktree(tid, "agent/" + tid, base)
            self.set(tid, status="running", started=time.time(), branch="agent/" + tid, base=base, resume=False)
            log("%s: worker %s (%s, cap $%.2f)" % (tid, "continues the interrupted work" if resume else "starts",
                                                  self.conf(t, "model"), self.conf(t, "max_budget_usd")))
            data, failed, note = self.run_worker(t, path, self.prompt(t, path, base, resume), self.conf(t, "max_budget_usd"),
                                                 tid + (".resume" if resume else ".1"))
            self.write_report(t, data)
            if failed:
                self.commit_leftovers(path)
                self.set(tid, status="failed", note=note, finished=time.time())
                log("%s: FAILED (%s)" % (tid, note))
                return
            self.commit_leftovers(path)
            ok, step, logp = self.verify(t, path)
            tries = 0
            while not ok and tries < self.conf(t, "retries") and not self.flag("STOP") and not self.flag("KILL"):
                tries += 1
                tail = "".join(open(logp, encoding="utf-8", errors="replace").readlines()[-60:])
                log("%s: check failed (%s), the worker fixes it (%d)" % (tid, step, tries))
                fix = ("Проверка runner-а упала на шаге `%s`. Последние строки журнала:\n\n%s\n\nИсправь причину так, чтобы "
                       "все проверки прошли (тесты не отключать и не пропускать), закоммить и ответь коротким отчётом."
                       % (step, tail))
                data, failed, note = self.run_worker(t, path, fix, min(5.0, self.conf(t, "max_budget_usd")), "%s.fix%d" % (tid, tries))
                if failed:
                    break
                self.commit_leftovers(path)
                ok, step, logp = self.verify(t, path)
            if not ok:
                self.set(tid, status="verify_failed", note="%s (%s)" % (step, logp), finished=time.time())
                log("%s: checks FAILED at %s" % (tid, step))
                return
            merged, mnote = self.merge(t)
            if not merged:
                self.set(tid, status="conflict", note=mnote, finished=time.time())
                log("%s: merge CONFLICT: %s" % (tid, mnote))
                return
            self.set(tid, status="merged", note=mnote, finished=time.time(), commits=int(
                self.git("rev-list", "--count", base + "..agent/" + tid).stdout.strip() or 0))
            log("%s: merged into agent/integration ($%.2f)" % (tid, self.st(tid)["cost"]))
            if self.push:
                self.git("push", "-q", "origin", "agent/integration:agent/integration", "agent/%s:agent/%s" % (tid, tid), check=False)
        except Exception as e:  # a bug of the runner or of git must not take the other workers down
            self.set(tid, status="failed", note="runner error: %s" % e, finished=time.time())
            log("%s: runner error: %s" % (tid, e))

    # -- the queue -----------------------------------------------------------------------------------------------
    def selected(self, max_wave, only):
        out = [t for t in self.tasks if t.get("wave", 1) <= max_wave and (not only or t["id"] in only)]
        return out

    @staticmethod
    def pid_is_runner(pid):
        """Is pid a live run_queue process? (After a container restart a stale PID may belong to anything.)"""
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                return b"run_queue" in f.read()
        except OSError:
            return True      # no /proc here: the process exists, assume it is a runner

    def lock_path(self):
        return os.path.join(self.state_dir, "run.lock")

    def acquire_lock(self):
        """One runner per state directory; a lock left by a dead runner (or by a PID that now belongs to something else) is replaced."""
        path = self.lock_path()
        if os.path.exists(path):
            try:
                with open(path) as f:
                    pid = int(f.read().split()[0])
            except (ValueError, IndexError, OSError):
                pid = 0
            if pid and pid != os.getpid() and self.pid_is_runner(pid):
                sys.exit("another runner is alive (PID %d): `stop` it first or wait for it" % pid)
        with open(path, "w") as f:
            f.write("%d %d\n" % (os.getpid(), time.time()))

    def release_lock(self):
        try:
            os.remove(self.lock_path())
        except OSError:
            pass

    def recover(self):
        """A task that is still 'running' while this runner holds the lock has lost its worker (container restart, kill -9).
        It goes back to the queue; its working copy, with whatever the dead worker left in it, is kept and the next worker
        is told to continue from it. The cost of the lost run is not in state.json (the claude JSON arrives only at the end):
        the real figure is in the Console."""
        for tid, s in list(self.state["tasks"].items()):
            if s.get("status") == "running":
                keep = os.path.isdir(self.wt(tid))
                self.set(tid, status="pending", resume=keep,
                         note="recovered after an interruption" + ("" if keep else " (working copy lost)"))
                log("%s: was running when the runner died, back to the queue%s" % (tid, "; working copy kept, the next worker continues from it" if keep else ""))

    def run(self, parallel, budget, max_wave, only=None):
        self.acquire_lock()
        try:
            self.recover()
            self._run(parallel, budget, max_wave, only)
        finally:
            self.release_lock()

    def _run(self, parallel, budget, max_wave, only=None):
        order = self.selected(max_wave, only)
        self.integration()
        pool = ThreadPoolExecutor(max_workers=parallel)
        running = {}
        log("queue: %d task(s), %d parallel, budget $%.2f, spent so far $%.2f" % (len(order), parallel, budget, self.state["spent"]))
        try:
            while True:
                if self.flag("KILL"):
                    log("KILL: stopping the workers")
                    self.kill_all()
                    break
                for f in [f for f in running if f.done()]:
                    running.pop(f)
                stop = self.flag("STOP")
                launched = False
                over = self.state["spent"] >= budget
                if not stop and not over:
                    for t in order:
                        if len(running) >= parallel:
                            break
                        s = self.st(t["id"])
                        if s["status"] != "pending":
                            continue
                        deps = [self.st(d)["status"] for d in t.get("depends_on", [])]
                        if any(d in ("failed", "verify_failed", "conflict", "skipped") for d in deps):
                            self.set(t["id"], status="skipped", note="dependency not merged")
                            continue
                        if any(d != "merged" for d in deps):
                            continue
                        self.set(t["id"], status="running")
                        running[pool.submit(self.run_task, t)] = t["id"]
                        launched = True
                left = [t["id"] for t in order if self.st(t["id"])["status"] == "pending"]
                if not running and not launched:
                    if stop:
                        log("STOP: no new tasks, nothing is running")
                    elif over:
                        log("budget $%.2f is spent: %d task(s) wait" % (budget, len(left)))
                    elif left:
                        log("blocked: %s wait for tasks that are not merged" % ", ".join(left))
                    else:
                        log("queue is done")
                    break
                time.sleep(2)
        finally:
            pool.shutdown(wait=True)
        self.save()
        self.print_status()

    def kill_all(self):
        for proc in list(self.procs.values()):
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except OSError:
                pass

    def print_status(self):
        print("%-8s %-14s %7s  %s" % ("task", "status", "cost$", "note"))
        for t in self.tasks:
            s = self.st(t["id"])
            print("%-8s %-14s %7.2f  %s" % (t["id"], s["status"], s.get("cost", 0), (s.get("note") or "")[:90]))
        print("spent $%.2f" % self.state["spent"])

    def reset(self, tid):
        self.drop_worktree(tid, "agent/" + tid)
        with self.lock:
            cost = self.st(tid).get("cost", 0.0)
            self.state["tasks"][tid] = {"status": "pending", "cost": cost}
            self.save()

    def final_check(self):
        path = self.integration()
        t = {"id": "integration"}
        ok, step, logp = self.verify(t, path)
        print("final check: %s" % ("OK" if ok else "FAILED at %s (%s)" % (step, logp)))
        return ok

    def check_key(self):
        if not self.key:
            print("WORKER_API_KEY is not set in this session (add it to the environment settings and start a new session)")
            return False
        proc = subprocess.run([self.claude, "-p", "Reply with the single word: ok", "--output-format", "json",
                               "--model", "claude-haiku-5-5", "--max-budget-usd", "0.05"], env=worker_env(self.key),
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=180)
        data = parse_result(proc.stdout)
        ok = proc.returncode == 0 and not data.get("is_error")
        print("check-key: %s, answer %r, cost $%s" % ("OK" if ok else "FAILED", str(data.get("result"))[:60], data.get("total_cost_usd")))
        if not ok:
            print((proc.stderr or proc.stdout)[:400])
        return ok


# -- self test ----------------------------------------------------------------------------------------------------------
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
prompt = sys.argv[sys.argv.index("-p") + 1]
tid = prompt.split("ЗАДАЧА: ", 1)[1].split(":", 1)[0] if "ЗАДАЧА: " in prompt else "fix"
assert os.environ.get("ANTHROPIC_API_KEY") == "sk-test", "the worker must get the producer's key"
model = sys.argv[sys.argv.index("--model") + 1]
assert model in ("claude-sonnet-5-5", "claude-haiku-5-5"), "model outside the allowed two: " + model
assert os.environ.get("CLAUDE_CODE_SUBAGENT_MODEL") == "claude-sonnet-5-5", "sub-agent model not pinned"
assert "CLAUDE_CODE_REMOTE_SESSION_ID" not in os.environ and "GITHUB_TOKEN" not in os.environ, "session variables leaked"
if tid == "T-bad":
    print(json.dumps({"type": "result", "is_error": True, "result": "could not do it", "total_cost_usd": 0.4}))
    sys.exit(1)
if "ПРОДОЛЖЕНИЕ ПРЕРВАННОЙ РАБОТЫ" in prompt:
    open("resumed.txt", "w").write(os.getcwd() + "\n")
if "Проверка runner-а упала" in prompt:
    open("fixed.txt", "w").write("fixed\n")
else:
    open(tid + ".txt", "w").write(tid + "\n")
    if tid == "T-flaky":
        open("broken.txt", "w").write("x\n")      # the check fails until the fix run removes it
    if tid in ("T-c1", "T-c2"):
        open("shared.txt", "w").write(tid + "\n")  # both change the same file: a conflict
subprocess.run(["git", "add", "-A"]); subprocess.run(["git", "commit", "-q", "-m", "work of " + tid])
if "Проверка runner-а упала" in prompt:
    os.remove("broken.txt")
    subprocess.run(["git", "add", "-A"]); subprocess.run(["git", "commit", "-q", "-m", "fix"])
print(json.dumps([{"type": "system"}, {"type": "result", "is_error": False, "result": "done " + tid, "total_cost_usd": 0.5}]))
'''


def selftest():
    tmp = tempfile.mkdtemp(prefix="agents-selftest-")
    try:
        repo = os.path.join(tmp, "repo")
        os.makedirs(os.path.join(repo, "specs"))
        run = lambda *a: subprocess.run(a, cwd=repo, check=True, capture_output=True, text=True)
        run("git", "init", "-q", "-b", "main")
        run("git", "config", "user.email", "t@t")
        run("git", "config", "user.name", "t")
        for name in ("T-a", "T-b", "T-bad", "T-after-bad", "T-flaky", "T-c1", "T-c2", "T-late", "T-crash"):
            with open(os.path.join(repo, "specs", name + ".md"), "w") as f:
                f.write("Do " + name + "\n")
        with open(os.path.join(repo, "shared.txt"), "w") as f:
            f.write("base\n")
        run("git", "add", "-A")
        run("git", "commit", "-q", "-m", "init")
        fake = os.path.join(tmp, "fake_claude.py")
        with open(fake, "w") as f:
            f.write(FAKE_CLAUDE)
        os.chmod(fake, 0o755)
        queue = {
            "defaults": {"regen": None, "retries": 1, "max_budget_usd": 5,
                         "verify": [["sh", "-c", "test ! -e broken.txt"]]},
            "tasks": [
                {"id": "T-a", "title": "first", "spec": os.path.join(repo, "specs", "T-a.md")},
                {"id": "T-b", "title": "second", "spec": os.path.join(repo, "specs", "T-b.md"), "depends_on": ["T-a"]},
                {"id": "T-bad", "title": "fails", "spec": os.path.join(repo, "specs", "T-bad.md")},
                {"id": "T-after-bad", "title": "needs the failed one", "spec": os.path.join(repo, "specs", "T-after-bad.md"), "depends_on": ["T-bad"]},
                {"id": "T-flaky", "title": "check fails once", "spec": os.path.join(repo, "specs", "T-flaky.md")},
                {"id": "T-c1", "title": "conflict one", "spec": os.path.join(repo, "specs", "T-c1.md"), "depends_on": ["T-a"]},
                {"id": "T-c2", "title": "conflict two", "spec": os.path.join(repo, "specs", "T-c2.md"), "depends_on": ["T-b"]},
                {"id": "T-late", "title": "wave two", "wave": 2, "spec": os.path.join(repo, "specs", "T-late.md")},
                {"id": "T-crash", "title": "was running when the container died", "wave": 3,
                 "spec": os.path.join(repo, "specs", "T-crash.md")},
            ],
        }
        qp = os.path.join(tmp, "queue.json")
        with open(qp, "w") as f:
            json.dump(queue, f)
        # the environment of this (parent) session must not reach the worker
        os.environ["CLAUDE_CODE_REMOTE_SESSION_ID"] = "cse_test"
        os.environ["GITHUB_TOKEN"] = "secret"
        r = Runner(repo, qp, os.path.join(tmp, "state"), claude_bin=fake, key="sk-test")
        r.run(parallel=2, budget=100, max_wave=1)
        s = lambda tid: r.st(tid)["status"]
        problems = []
        expect = {"T-a": "merged", "T-b": "merged", "T-bad": "failed", "T-after-bad": "skipped", "T-flaky": "merged",
                  "T-late": "pending"}
        for tid, want in expect.items():
            if s(tid) != want:
                problems.append("%s is %s, expected %s (%s)" % (tid, s(tid), want, r.st(tid).get("note")))
        both = sorted([s("T-c1"), s("T-c2")])
        if both != ["conflict", "merged"]:
            problems.append("the two tasks that change shared.txt ended %s, expected one merged and one conflict" % both)
        ipath = r.wt("integration")
        for fn in ("T-a.txt", "T-b.txt", "T-flaky.txt", "fixed.txt"):
            if not os.path.exists(os.path.join(ipath, fn)):
                problems.append("agent/integration lacks " + fn)
        if os.path.exists(os.path.join(ipath, "broken.txt")):
            problems.append("the flaky task was merged with its broken file")
        if abs(r.state["spent"] - (0.5 * 6 + 0.4)) > 1e-6:
            problems.append("cost accounting: spent %.2f" % r.state["spent"])
        # budget and STOP
        r.reset("T-late")
        r.state["spent"] = 100.0
        r.run(parallel=2, budget=100, max_wave=2, only=["T-late"])
        if s("T-late") != "pending":
            problems.append("a task was started although the budget is spent")
        r.state["spent"] = 0.0
        open(os.path.join(r.state_dir, "STOP"), "w").close()
        r.run(parallel=2, budget=100, max_wave=2, only=["T-late"])
        if s("T-late") != "pending":
            problems.append("a task was started although STOP exists")
        os.remove(os.path.join(r.state_dir, "STOP"))
        r.run(parallel=2, budget=100, max_wave=2, only=["T-late"])
        if s("T-late") != "merged":
            problems.append("wave 2 did not run when asked for: %s" % s("T-late"))
        # recovery after a container restart: T-crash was running, its working copy holds an unfinished file, the lock is stale
        base = r.head("agent/integration")
        cpath = r.ensure_worktree("T-crash", "agent/T-crash", base)
        with open(os.path.join(cpath, "partial.txt"), "w") as f:
            f.write("half done\n")
        r.set("T-crash", status="running", base=base)
        with open(r.lock_path(), "w") as f:
            f.write("999999 0\n")
        r.run(parallel=2, budget=100, max_wave=3, only=["T-crash"])
        if s("T-crash") != "merged":
            problems.append("an interrupted task was not continued: %s (%s)" % (s("T-crash"), r.st("T-crash").get("note")))
        for fn in ("partial.txt", "resumed.txt"):
            if not os.path.exists(os.path.join(ipath, fn)):
                problems.append("after the recovery agent/integration lacks " + fn)
        if os.path.exists(r.lock_path()):
            problems.append("the lock was not released after the run")
        # a live runner holds the lock: a second one refuses; after it dies the stale lock is replaced
        sleeper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "run_queue_selftest_sleeper"])
        try:
            with open(r.lock_path(), "w") as f:
                f.write("%d 0\n" % sleeper.pid)
            try:
                r.run(parallel=2, budget=100, max_wave=3, only=["T-crash"])
                problems.append("a second runner started while another one holds the lock")
            except SystemExit:
                pass
        finally:
            sleeper.kill()
            sleeper.wait()
        r.run(parallel=2, budget=100, max_wave=3, only=["T-crash"])
        if os.path.exists(r.lock_path()):
            problems.append("a stale lock was not replaced and released")
        bad = dict(queue)
        bad["tasks"] = queue["tasks"] + [{"id": "T-opus", "title": "opus", "model": "opus",
                                          "spec": os.path.join(repo, "specs", "T-a.md")}]
        bq = os.path.join(tmp, "bad_queue.json")
        with open(bq, "w") as f:
            json.dump(bad, f)
        try:
            Runner(repo, bq, os.path.join(tmp, "state2"), claude_bin=fake, key="sk-test")
            problems.append("a task with the model opus was accepted")
        except SystemExit:
            pass
        print("selftest:", "OK" if not problems else "FAILED")
        for p in problems:
            print("  -", p)
        return not problems
    finally:
        os.environ.pop("CLAUDE_CODE_REMOTE_SESSION_ID", None)
        os.environ.pop("GITHUB_TOKEN", None)
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["run", "status", "stop", "reset", "final-check", "check-key", "selftest"])
    ap.add_argument("arg", nargs="?", help="task id for reset")
    ap.add_argument("--queue", default=os.path.join(HERE, "queue.json"))
    ap.add_argument("--parallel", type=int, default=2)
    ap.add_argument("--budget-usd", type=float, default=60.0, help="stop starting tasks when this much is spent")
    ap.add_argument("--max-wave", type=int, default=1)
    ap.add_argument("--only", help="comma-separated task ids")
    ap.add_argument("--push", action="store_true", help="push agent/integration and the task branches to origin after each merge")
    ap.add_argument("--now", action="store_true", help="stop: kill the running workers too")
    a = ap.parse_args()
    if a.cmd == "selftest":
        sys.exit(0 if selftest() else 1)
    state_dir = os.environ.get("AGENT_STATE_DIR", "/tmp/glow-agents")
    r = Runner(REPO, a.queue, state_dir, push=a.push)
    if a.cmd == "status":
        r.print_status()
    elif a.cmd == "stop":
        open(os.path.join(state_dir, "KILL" if a.now else "STOP"), "w").close()
        print("%s is set: %s" % ("KILL" if a.now else "STOP", "the workers are killed" if a.now else "no new tasks start; running ones finish"))
    elif a.cmd == "reset":
        r.reset(a.arg)
    elif a.cmd == "final-check":
        sys.exit(0 if r.final_check() else 1)
    elif a.cmd == "check-key":
        sys.exit(0 if r.check_key() else 1)
    else:
        if not r.key:
            sys.exit("WORKER_API_KEY is not set: add it to the environment settings and start a new session")
        for flag in ("STOP", "KILL"):
            p = os.path.join(state_dir, flag)
            if os.path.exists(p):
                os.remove(p)
        r.run(a.parallel, a.budget_usd, a.max_wave, a.only.split(",") if a.only else None)


if __name__ == "__main__":
    main()
