import subprocess
from pathlib import Path
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'image-builder/audio/build-packages.py'


class AudioPackageGuardsTests(unittest.TestCase):
    def test_source_and_unit_drift_checks_survive_optimized_python(self):
        code = '''import runpy,sys
m = runpy.run_path(sys.argv[1])
for operation in [lambda: m['require'](False, 'wrong pin'),
                  lambda: m['replace_once']('changed unit', 'ExecStart=old', 'new'),
                  lambda: m['replace_once']('old old', 'old', 'new')]:
    try:
        operation()
    except ValueError:
        continue
    raise SystemExit('optimization disabled a package check')
'''
        subprocess.run([sys.executable, '-O', '-c', code, str(SCRIPT)], check=True)


if __name__ == '__main__':
    unittest.main()
