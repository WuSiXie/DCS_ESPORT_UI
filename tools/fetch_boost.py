"""Download pinned official Boost headers for the standalone CMake build."""
from pathlib import Path
import hashlib
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / ".tools" / "boost_1_90_0"
ARCHIVE = ROOT / ".tools" / "boost_1_90_0.tar.bz2"
SHA256 = "49551aff3b22cbc5c5a9ed3dbc92f0e23ea50a0f7325b0d198b705e8ee3fc305"
if not (DEST / "boost" / "json" / "src.hpp").exists():
    ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    if not ARCHIVE.exists():
        urllib.request.urlretrieve(
            "https://archives.boost.io/release/1.90.0/source/boost_1_90_0.tar.bz2", ARCHIVE)
    if hashlib.file_digest(ARCHIVE.open("rb"), "sha256").hexdigest() != SHA256:
        raise SystemExit("Boost archive checksum mismatch")
    with tarfile.open(ARCHIVE) as archive:
        members = [m for m in archive if m.name.startswith("boost_1_90_0/boost/") or
                   m.name == "boost_1_90_0/LICENSE_1_0.txt"]
        archive.extractall(ROOT / ".tools", members=members, filter="data")
print(DEST)
