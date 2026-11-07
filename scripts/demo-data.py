"""Writes invented Claude Code transcripts into a demo home. Nothing here comes from a real user."""
import json
import sys
import uuid
from pathlib import Path

ROOT = Path(sys.argv[1])
PROJECTS = {
    "shop-api": "/Users/demo/projects/shop-api",
    "web-dashboard": "/Users/demo/projects/web-dashboard",
}
VERSION = "2.1.0"


def encode(path):
    return path.replace("/", "-")


class Transcript:
    def __init__(self, cwd, session_id, start):
        self.cwd = cwd
        self.session_id = session_id
        self.clock = start
        self.lines = []
        self.parent = None

    def _stamp(self):
        self.clock += 7
        minutes, seconds = divmod(self.clock, 60)
        return f"2026-11-02T10:{minutes:02d}:{seconds:02d}.000Z"

    def _base(self, kind):
        return {
            "parentUuid": self.parent,
            "isSidechain": False,
            "type": kind,
            "uuid": str(uuid.uuid4()),
            "timestamp": self._stamp(),
            "cwd": self.cwd,
            "sessionId": self.session_id,
            "version": VERSION,
            "gitBranch": "main",
        }

    def user(self, text):
        record = self._base("user")
        record["message"] = {"role": "user", "content": text}
        self.parent = record["uuid"]
        self.lines.append(record)

    def assistant(self, message_id, blocks):
        record = self._base("assistant")
        record["message"] = {"id": message_id, "role": "assistant", "model": "claude-opus-demo", "content": blocks,
                             "usage": {"input_tokens": 120, "output_tokens": 240}}
        self.parent = record["uuid"]
        self.lines.append(record)

    def tool_result(self, tool_use_id, output):
        record = self._base("user")
        record["message"] = {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_use_id, "content": [{"type": "text", "text": output}], "is_error": False}]}
        self.parent = record["uuid"]
        self.lines.append(record)

    def title(self, text):
        self.lines.append({"type": "custom-title", "customTitle": text, "sessionId": self.session_id})

    def write(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(json.dumps(line, ensure_ascii=False) for line in self.lines) + "\n", encoding="utf-8")


def tool(name, **inputs):
    return {"type": "tool_use", "id": "toolu_" + uuid.uuid4().hex[:12], "name": name, "input": inputs}


def rate_limit_session():
    cwd = PROJECTS["shop-api"]
    sid = str(uuid.uuid4())
    t = Transcript(cwd, sid, 0)
    t.user("Add rate limiting to the checkout endpoint. Limit each API key to 60 requests per minute.")
    read = tool("Read", file_path=f"{cwd}/src/middleware/auth.ts")
    t.assistant("msg_rl_1", [{"type": "text", "text": "I'll look at the existing auth middleware first."}, read])
    t.tool_result(read["id"], "export function requireApiKey(req, res, next) { ... }")
    edit = tool("Edit", file_path=f"{cwd}/src/middleware/rateLimit.ts", old_string="", new_string="export const limiter = ...")
    t.assistant("msg_rl_2", [{"type": "thinking", "thinking": "A sliding window keyed by API key is simpler than a token bucket here."},
                             {"type": "text", "text": "A sliding window keyed by API key fits here. Adding the limiter."}, edit])
    t.tool_result(edit["id"], "File created successfully.")
    test = tool("Bash", command="npm test -- rateLimit", description="Run the rate limiter tests")
    t.assistant("msg_rl_3", [test])
    t.tool_result(test["id"], "PASS  src/middleware/rateLimit.test.ts (8 tests)")
    t.user("Also return Retry-After when the limit is hit.")
    t.assistant("msg_rl_4", [{"type": "text", "text": "Done. Requests over the limit now get 429 with a Retry-After header. All 8 tests pass."}])
    t.title("Add rate limiting to the checkout API")

    sub = Transcript(cwd, sid, 300)
    sub.user("Find every place that authenticates API keys and summarise how they are checked.")
    grep = tool("Bash", command="grep -rn 'apiKey' src", description="Search for API key checks")
    sub.assistant("sub_rl_1", [grep])
    sub.tool_result(grep["id"], "src/middleware/auth.ts:12  requireApiKey\nsrc/routes/checkout.ts:8  apiKey header read")
    sub.assistant("sub_rl_2", [{"type": "text", "text": "Two places check API keys: the auth middleware and the checkout route."}])
    t.write(ROOT / ".claude/projects" / encode(cwd) / f"{sid}.jsonl")
    sub.write(ROOT / ".claude/projects" / encode(cwd) / sid / "subagents" / "agent-a1b2c3d4e5f60718.jsonl")
    (ROOT / ".claude/projects" / encode(cwd) / sid / "subagents" / "agent-a1b2c3d4e5f60718.meta.json").write_text(
        json.dumps({"agentType": "Explore", "description": "Find API key checks"}), encoding="utf-8")


def n_plus_one_session():
    cwd = PROJECTS["shop-api"]
    sid = str(uuid.uuid4())
    t = Transcript(cwd, sid, 0)
    t.user("The order listing page is slow. Find out why.")
    grep = tool("Grep", pattern="orders.find", path="src")
    t.assistant("msg_np_1", [{"type": "text", "text": "Searching for the query that loads orders."}, grep])
    t.tool_result(grep["id"], "src/services/orders.ts:31  orders.find({ userId })")
    t.assistant("msg_np_2", [{"type": "text", "text": "The loop calls `customers.findById` once per order. That is an N+1 query. I'll batch the lookups."}])
    t.user("Go ahead and fix it.")
    edit = tool("Edit", file_path=f"{cwd}/src/services/orders.ts", old_string="for (const o of orders)", new_string="const customers = await batchLoad(...)")
    t.assistant("msg_np_3", [edit])
    t.tool_result(edit["id"], "The file has been updated.")
    t.assistant("msg_np_4", [{"type": "text", "text": "Fixed. The listing now runs two queries instead of N+1."}])
    t.title("Fix N+1 query in order listing")
    t.write(ROOT / ".claude/projects" / encode(cwd) / f"{sid}.jsonl")


def chart_session():
    cwd = PROJECTS["web-dashboard"]
    sid = str(uuid.uuid4())
    t = Transcript(cwd, sid, 0)
    t.user("The revenue chart ignores the selected date range. Make it respect the range picker.")
    read = tool("Read", file_path=f"{cwd}/src/components/RevenueChart.tsx")
    t.assistant("msg_ch_1", [read])
    t.tool_result(read["id"], "export function RevenueChart({ data }) { ... }")
    edit = tool("Edit", file_path=f"{cwd}/src/components/RevenueChart.tsx", old_string="data", new_string="filtered")
    t.assistant("msg_ch_2", [{"type": "text", "text": "The chart renders the full dataset. I'll filter it by the range first."}, edit])
    t.tool_result(edit["id"], "The file has been updated.")
    t.title("Revenue chart respects the date range")
    t.write(ROOT / ".claude/projects" / encode(cwd) / f"{sid}.jsonl")


rate_limit_session()
n_plus_one_session()
chart_session()
print("wrote transcripts to", ROOT / ".claude/projects")
