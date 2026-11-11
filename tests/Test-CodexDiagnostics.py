"""Run the same offline diagnostic contract from the repository test profile."""
from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).resolve().parents[1] / 'managed/host-diagnostics/Test-CodexDiagnostics.py'), run_name='__main__')
