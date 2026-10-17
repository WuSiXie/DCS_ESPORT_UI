"""Run the dependency-free Lua test suite in Lua 5.1 (or LuaJIT 2.1).

Install the optional development runtime with:
  python -m pip install --target .tools/python -r requirements-dev.txt
Only the tests need Python/Lupa. DCS deployment has no Python dependency.
"""
from pathlib import Path
import argparse
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".tools" / "python"))
parser = argparse.ArgumentParser()
parser.add_argument("--runtime", choices=("lua51", "luajit21"), default="lua51")
args = parser.parse_args()
try:
    if args.runtime == "lua51":
        from lupa.lua51 import LuaRuntime
    else:
        from lupa.luajit21 import LuaRuntime
except ImportError as exc:
    raise SystemExit("Install requirements-dev.txt into .tools/python first") from exc

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().PROJECT_ROOT = ROOT.as_posix()
lua.execute((ROOT / "tests" / "suite.lua").read_text(encoding="utf-8"))
