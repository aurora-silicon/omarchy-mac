#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

python3 - "$ROOT/Packaging/pkg/scripts/postinstall" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
start = source.index("  bootstrap_succeeded=false")
end = source.index("  if ! /bin/launchctl print", start)
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    stub = root / "launchctl"
    stub.write_text("""#!/bin/bash
count=$(cat "$COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s' "$count" > "$COUNT"
(( count > FAILURES ))
""")
    stub.chmod(0o755)
    script = root / "probe.sh"
    body = source[start:end].replace("/bin/launchctl", str(stub))
    body = body.replace("/bin/sleep 0.2", "/bin/true")
    body = body.replace("/usr/bin/logger", "/bin/true")
    script.write_text("#!/bin/bash\nPLIST=fixture\nLABEL=fixture\n" + body)
    for failures, calls, status in [(0, 1, 0), (1, 2, 0), (9, 10, 0), (10, 10, 1)]:
        count = root / "count"
        count.unlink(missing_ok=True)
        env = dict(os.environ, COUNT=str(count), FAILURES=str(failures))
        result = subprocess.run(["bash", str(script)], env=env, capture_output=True)
        assert result.returncode == status, (failures, result.stderr)
        assert int(count.read_text()) == calls
print("PASS: immediate success, transient retry, final retry success and bounded permanent failure")
PY
