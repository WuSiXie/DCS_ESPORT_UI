"""Check single-file packaging and exact Lua-source embedding."""
from pathlib import Path
import hashlib
import json
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / ".tools" / "python"))
from lupa.lua51 import LuaRuntime
from tools.package import HOOK_RELATIVE, build, lua_long_string, render


class SingleFilePackageTests(unittest.TestCase):
    def test_embedded_text_cannot_close_its_own_lua_literal(self):
        lua = LuaRuntime()
        samples = (
            "", "\nfirst newline\n", "-- 中文注释\nreturn 'value'\n",
            "nested ]] ]=] ]==] delimiters", "trailing ]", "trailing ]=", "trailing ]==",
        )
        for text in samples:
            with self.subTest(text=text):
                self.assertEqual(lua.execute("return " + lua_long_string(text)), text)

    def test_render_is_deterministic_and_compiles_in_lua51(self):
        first = render()
        self.assertEqual(first, render())
        load = LuaRuntime().eval("function(source) local chunk, err=loadstring(source); return chunk ~= nil, err end")
        compiled, error = load(first)
        self.assertTrue(compiled, error)
        self.assertIn("-- BEGIN CONFIG (editable)", first)
        for removed in ['StatusBarDialog','LoSetCommand','camera_control','camera_gui',"loadModule('camera')"]:
            self.assertNotIn(removed, first)
        self.assertIn('bridge:tick();players:tick();pump()',first)

    def test_package_contains_one_runtime_lua_file_and_matching_hash(self):
        destination = build()
        runtime_files = sorted(path.relative_to(destination).as_posix() for path in destination.rglob("*.lua"))
        self.assertEqual(runtime_files, [HOOK_RELATIVE])
        manifest = json.loads((destination / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["layout"], "single_hook")
        self.assertEqual(set(manifest["sha256"]), {HOOK_RELATIVE})
        self.assertEqual(manifest["sha256"][HOOK_RELATIVE], hashlib.sha256((destination / HOOK_RELATIVE).read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
