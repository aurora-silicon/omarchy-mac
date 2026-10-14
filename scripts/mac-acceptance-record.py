#!/usr/bin/env python3
"""Write the acceptance evidence record from a VM harness run.

`.github/workflows/mac-acceptance.yml` runs the omarchy-mac-pkgs harness
(`tools/acceptance/mac-image/run`) on one image and then calls this to turn
the harness's `run.txt` and exit status into `acceptance-evidence.json`
(docs/mac-acceptance-evidence.md). It always writes a record: when the image
check failed, the harness never ran, or it was cancelled, the record fails.

The harness writes one line per check to run.txt, `ok - <scenario>: ...`,
`not ok - <scenario>: ...` or `skip - <scenario>: ...`, runs the scenarios in
order, stops at the first fatal check, and exits 0 only when every check
passed. A scenario here is:

  fail  it has a `not ok` line, it has no line at all (it never ran), or the
        harness failed with no `not ok` line for any scenario and it is the
        last scenario that wrote a line (a fatal check whose message names no
        scenario, or a cancellation, stopped the run there);
  skip  it has only `skip` lines (the image lacks what it tests);
  pass  otherwise: it has an `ok` line.

The record passes only when the harness exited 0, every scenario passed, and
the record passes the upload's own check (mac-upload.py check-evidence),
which also requires first-boot, conversion and second-boot. Otherwise it
fails, with a `reason`.

Usage:
  mac-acceptance-record.py --sha256 HEX --scenarios LIST [--run-txt FILE]
      [--harness-status N] --harness-commit SHA --runner TEXT --run-url URL
      [--image NAME] [--reason TEXT] --out FILE
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

# The harness's scenarios, in the order it runs them, and its two groups.
SCENARIOS = ("first-boot", "conversion", "second-boot", "password-change", "update", "snapshot-restore",
             "factory-reset")
GROUPS = {"fresh-install": ("first-boot", "conversion", "second-boot"), "all": SCENARIOS}
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SCENARIO_NAME = re.compile(r"^[a-z][a-z-]{0,39}$")
LINE = re.compile(r"^(ok|not ok|skip) - ([a-z][a-z-]*): ")
RUNNER_LIMIT = 200


def upload_check():
    """mac-upload.py's check_evidence and Refusal, the upload's own gate."""
    path = Path(__file__).resolve().parent / "mac-upload.py"
    spec = importlib.util.spec_from_file_location("mac_upload_for_acceptance", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.check_evidence, module.Refusal


def expand(requested: str, run_txt: str) -> list[str]:
    """The scenarios this run covers: the harness's own `scenarios=` line when
    it got that far, else the request expanded as the harness expands it."""
    for line in run_txt.splitlines():
        if line.startswith("scenarios="):
            names = line.removeprefix("scenarios=").split()
            if names:
                return names
    wanted: set[str] = set()
    extra: list[str] = []
    for name in (part.strip() for part in requested.split(",")):
        if not name:
            continue
        if name in GROUPS:
            wanted.update(GROUPS[name])
        elif name in SCENARIOS:
            wanted.add(name)
        elif name not in extra:
            extra.append(name)
    return [name for name in SCENARIOS if name in wanted] + extra


def scenario_results(names: list[str], run_txt: str, harness_status: int | None) -> list[dict]:
    lines: dict[str, list[str]] = {name: [] for name in names}
    last = None
    for line in run_txt.splitlines():
        match = LINE.match(line)
        if match and match.group(2) in lines:
            lines[match.group(2)].append(match.group(1))
            last = match.group(2)
    # A failed run with no `not ok` line for any scenario stopped at a fatal
    # check that names none: blame the scenario that was running.
    blame = last if harness_status != 0 and not any("not ok" in kinds for kinds in lines.values()) else None
    results = []
    for name in names:
        kinds = lines[name]
        if "not ok" in kinds or not kinds:
            result = "fail"
        elif name == blame:
            result = "fail"
        elif "ok" in kinds:
            result = "pass"
        else:
            result = "skip"
        results.append({"name": name, "result": result})
    return results


def record(*, sha256: str, scenarios: str, run_txt: str, harness_status: int | None, harness_commit: str,
           runner: str, run_url: str, image: str = "", reason: str = "") -> dict:
    names = expand(scenarios, run_txt)
    results = scenario_results(names, run_txt, harness_status)
    document: dict = {
        "image_sha256": sha256,
        "result": "fail",
        "scenarios": results,
        "harness_commit": harness_commit,
        "runner": runner[:RUNNER_LIMIT],
        "run_url": run_url,
    }
    if image:
        document["image"] = image
    document["harness_status"] = harness_status
    if not reason:
        if harness_status is None:
            reason = "the harness did not run"
        elif harness_status != 0:
            reason = f"the harness exited {harness_status}"
        elif not results:
            reason = "the harness ran no scenario"
        elif any(item["result"] != "pass" for item in results):
            reason = "not every scenario passed: " + ", ".join(
                f"{item['name']} {item['result']}" for item in results if item["result"] != "pass")
    if not reason:
        check_evidence, refusal = upload_check()
        try:
            check_evidence({**document, "result": "pass"}, sha256)
        except refusal as error:
            reason = f"the upload would refuse this record: {error}"
    if reason:
        document["reason"] = reason
    else:
        document["result"] = "pass"
    return document


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--scenarios", required=True)
    parser.add_argument("--run-txt", type=Path)
    parser.add_argument("--harness-status", default="")
    parser.add_argument("--harness-commit", required=True)
    parser.add_argument("--runner", required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--image", default="")
    parser.add_argument("--reason", default="")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)

    problems = []
    if not SHA256_HEX.fullmatch(args.sha256):
        problems.append("--sha256 must be 64 lowercase hex digits")
    if not COMMIT.fullmatch(args.harness_commit):
        problems.append("--harness-commit must be a 40-hex commit")
    if not args.run_url.startswith("https://"):
        problems.append("--run-url must be an https URL")
    if not args.runner.strip():
        problems.append("--runner is empty")
    if args.harness_status and not re.fullmatch(r"[0-9]{1,3}", args.harness_status):
        problems.append("--harness-status must be an exit status")
    names = [name.strip() for name in args.scenarios.split(",") if name.strip()]
    if not names or not all(SCENARIO_NAME.fullmatch(name) for name in names):
        problems.append("--scenarios must be a comma-separated list of scenario names")
    if problems:
        for problem in problems:
            print(f"mac-acceptance-record: {problem}", file=sys.stderr)
        return 2

    run_txt = ""
    if args.run_txt is not None and args.run_txt.is_file() and not args.run_txt.is_symlink():
        run_txt = args.run_txt.read_text(errors="replace")
    status = int(args.harness_status) if args.harness_status else None
    document = record(sha256=args.sha256, scenarios=args.scenarios, run_txt=run_txt, harness_status=status,
                      harness_commit=args.harness_commit, runner=args.runner, run_url=args.run_url, image=args.image,
                      reason=args.reason)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(document, indent=2) + "\n")
    summary = ", ".join(f"{item['name']} {item['result']}" for item in document["scenarios"]) or "no scenarios"
    print(f"evidence for {args.sha256}: {document['result']} ({summary})"
          + (f"; {document['reason']}" if "reason" in document else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
