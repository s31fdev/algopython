"""Point the prebuilt Python at the folder it will be installed to.

pip bakes the absolute python.exe path into Scripts\\*.exe launchers. We build in
build\\python but run from Program Files, so the launchers are regenerated for the
final location; the whole Lib is also precompiled so the first start isn't slow.
Run it with the build interpreter:

    build\\python\\python.exe relocate.py "C:\\Program Files\\Algoritmika\\python"

Afterwards the launchers no longer work from build\\python: use `python -m pip` there.
"""
import compileall
import sys
from importlib.metadata import distributions
from pathlib import Path

from pip._vendor.distlib.scripts import ScriptMaker

if __name__ == "__main__":  # compileall workers re-import this file on Windows
    target = sys.argv[1]
    here = Path(sys.prefix)

    maker = ScriptMaker(None, str(here / "Scripts"))
    # distlib quotes only paths it picked itself; ours has a space in "Program Files"
    maker.executable = f'"{Path(target) / "python.exe"}"'
    maker.clobber = True
    maker.variants = {""}
    for dist in distributions():
        for ep in dist.entry_points:
            if ep.group in ("console_scripts", "gui_scripts"):
                maker.make(f"{ep.name} = {ep.value}", {"gui": ep.group == "gui_scripts"})

    # a few packages ship deliberately broken .py files (templates, py2 tests); compileall reports them
    compileall.compile_dir(here / "Lib", quiet=1, workers=0)
