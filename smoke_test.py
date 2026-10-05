# Build check, run with the bundled interpreter:  build\python\python.exe smoke_test.py
# 1. Every library students use imports in ONE process: catches DLL clashes such as
#    PyQt5 / panda3d shipping an old msvcp140.dll that breaks tensorflow imported after them.
# 2. PyQt5 opens a real window through the "windows" platform plugin. A broken plugin setup
#    makes Qt abort with a non-zero exit code; rerun with QT_DEBUG_PLUGINS=1 to see the search paths.
import importlib
import sys

MODULES = """tkinter turtle pygame pymunk PyQt5.QtWidgets kivy numpy pandas matplotlib.pyplot sklearn scipy
cv2 PIL panda3d.core tensorflow keras vosk pyttsx3 pydub flask requests bs4 lxml rich termcolor
colorama tqdm wave pylint play win32api""".split()

failed = []
for name in MODULES:
    try:
        importlib.import_module(name)
    except Exception as e:
        failed.append(f"{name}: {type(e).__name__}: {e}")
print(f"imports: {len(MODULES) - len(failed)} of {len(MODULES)} ok", *failed, sep="\n")

from PyQt5.QtCore import QTimer
from PyQt5.QtWidgets import QApplication, QLabel

app = QApplication(sys.argv)
assert app.platformName() == "windows", app.platformName()
label = QLabel("PyQt5 OK")
label.show()
QTimer.singleShot(500, app.quit)
app.exec_()
print("PyQt5 window: ok")
sys.exit(1 if failed else 0)
