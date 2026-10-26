"""Run the maintained retro overlay's public-CLI behavior tests."""
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
tests = root / "modules/skill-supply-chain/overlays/retro/scripts/test_transcripts.py"
if __name__ == "__main__":
    raise SystemExit(subprocess.call([sys.executable, "-B", "-X", "utf8", str(tests)]))
