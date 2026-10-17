"""Exercise the packaged Hook entry point, isolated mission, timers and real files.

This is an offline DCS API simulation, not a claim of an in-game test.
"""
from pathlib import Path
import argparse
import collections
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".tools" / "python"))
parser = argparse.ArgumentParser()
parser.add_argument("--runtime", choices=("lua51", "luajit21"), default="lua51")
parser.add_argument("--host-io-no-results", action="store_true", help="Verify byte-readback compatibility with resultless host I/O")
parser.add_argument("--diagnostic-failure-after-write", action="store_true", help="Write bytes but fail result verification; collection must still advance")
args = parser.parse_args()
if args.runtime == "lua51":
    from lupa.lua51 import LuaRuntime
else:
    from lupa.luajit21 import LuaRuntime
from package import HOOK_RELATIVE, build

bundle = build()
captures = ROOT / "runtime" / "single-file-smoke"
captures.mkdir(parents=True, exist_ok=True)
# A fresh profile per run proves old companion files cannot satisfy dependencies.
run_number = 1
while (captures / f"run-{run_number}").exists():
    run_number += 1
profile = captures / f"run-{run_number}" / "profile"
output = profile / "Logs" / "DcsEsport"
output.mkdir(parents=True)

import shutil
target = profile / HOOK_RELATIVE
target.parent.mkdir(parents=True)
shutil.copyfile(bundle / HOOK_RELATIVE, target)
assert list((profile / "Scripts").rglob("*.lua")) == [target]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().PROJECT_ROOT = ROOT.as_posix()
lua.globals().SMOKE_PROFILE = profile.as_posix() + "/"
lua.globals().SMOKE_OUTPUT = output.as_posix()
lua.globals().SMOKE_RUNTIME = args.runtime
lua.globals().SMOKE_IO_NO_RESULTS = args.host_io_no_results
lua.globals().SMOKE_DIAGNOSTIC_FAILURE = args.diagnostic_failure_after_write
summary = json.loads(lua.execute((ROOT / "tests" / "smoke.lua").read_text(encoding="utf-8")))
# Check emitted files with a second, independent JSON implementation.
for name in ("initialized.json", "latest-state.json", "status.json"):
    json.loads((output / name).read_text(encoding="utf-8"))
batch_count = 0
event_copies = collections.Counter()
for line in (output / "events.jsonl").read_text(encoding="utf-8").splitlines():
    batch = json.loads(line)
    assert batch["missionSessionId"] == summary["source"]["missionSessionId"]
    for event in batch["eventLog"]["events"]:
        event_copies[event["eventSeq"]] += 1
    batch_count += 1
assert batch_count > 0
assert event_copies and max(event_copies.values()) == 1, "Unexpected duplicate delivery in a clean smoke run"
summary["maxEventCopies"] = max(event_copies.values())
(output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"output": str(output), "result": summary}, ensure_ascii=False, indent=2))
