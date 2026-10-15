#!/usr/bin/env python3
"""The release pipeline's workflows: what can trigger them, what each job
waits for, where secrets go, and that VM acceptance runs only for main, on
the guard's say-so, and fails closed.

The workflows are read as text (no YAML library on the runners' Pythons), by
indentation, as GitHub's own layout of these files has it. Step scripts that
decide something (plan's refusal, acceptance's guard and gate) are extracted
and run, and so is the evidence record writer.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
SCRIPTS = ROOT / "scripts"
PIPELINE = WORKFLOWS / "mac-release-pipeline.yml"
ACCEPTANCE = WORKFLOWS / "mac-acceptance.yml"
CONFIG = ROOT / ".github" / "mac-release-pipeline.json"
SHA = "a" * 64
RUN_URL = "https://github.com/omacom/omarchy-mac-installer/actions/runs/1"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


upload = load("mac_upload", SCRIPTS / "mac-upload.py")
catalog = load("catalog_release", SCRIPTS / "catalog_release.py")
fixture = load("mac_upload_fixture", SCRIPTS / "tests" / "make-mac-upload-fixture.py")


def text(path: Path) -> str:
    return path.read_text()


def lines(path: Path) -> list[str]:
    return [line for line in text(path).splitlines() if not line.lstrip().startswith("#")]


def triggers(path: Path) -> set[str]:
    found, inside = set(), False
    for line in lines(path):
        if line == "on:":
            inside = True
        elif inside and line and not line.startswith(" "):
            break
        elif inside and re.match(r"^  [a-z_]+:", line):
            found.add(line.strip().split(":")[0])
    return found


def jobs(path: Path) -> dict[str, str]:
    """Each job's lines, keyed by job id."""
    found: dict[str, list[str]] = {}
    current, inside = None, False
    for line in lines(path):
        if line == "jobs:":
            inside = True
        elif inside and line and not line.startswith(" "):
            break
        elif inside and (match := re.match(r"^  ([a-z][a-z0-9-]*):$", line)):
            current = match.group(1)
            found[current] = []
        elif inside and current:
            found[current].append(line)
    return {job: "\n".join(body) for job, body in found.items()}


def field(job: str, name: str) -> str:
    match = re.search(rf"^    {re.escape(name)}: (.*)$", job, re.M)
    return match.group(1) if match else ""


def step_script(path: Path, step: str) -> str:
    """The run block of the step named STEP, dedented."""
    body = text(path).splitlines()
    start = body.index(f"      - name: {step}")
    run = next(index for index in range(start + 1, len(body)) if body[index].strip() == "run: |")
    script = []
    for line in body[run + 1:]:
        if line.strip() and not line.startswith(" " * 10):
            break
        script.append(line)
    return textwrap.dedent("\n".join(script))


class Triggers(unittest.TestCase):
    EXPECTED = {
        "mac-release-pipeline.yml": {"workflow_dispatch"},
        "mac-acceptance.yml": {"workflow_call", "workflow_dispatch"},
        "mac-image.yml": {"workflow_call", "workflow_dispatch"},
        "mac-upload.yml": {"workflow_call", "workflow_dispatch"},
        "mac-catalog.yml": {"workflow_call", "workflow_dispatch"},
        "edge-dispatch.yml": {"repository_dispatch"},
    }

    def test_no_pipeline_workflow_runs_for_pull_requests_pushes_or_other_runs(self):
        for name, expected in self.EXPECTED.items():
            with self.subTest(name):
                self.assertEqual(triggers(WORKFLOWS / name), expected)

    def test_edge_publishes_start_the_pipeline_not_the_bare_build(self):
        dispatch = text(WORKFLOWS / "edge-dispatch.yml")
        self.assertIn('gh workflow run mac-release-pipeline.yml --repo "$REPOSITORY" --ref "$DEFAULT_BRANCH" -f dry-run=false',
                      dispatch)
        self.assertNotRegex(dispatch, r"gh workflow run mac-image\.yml")

    def test_a_manual_run_is_a_dry_run_unless_asked(self):
        self.assertRegex(text(PIPELINE), r"dry-run:\n        description: [^\n]*\n        type: boolean\n        default: true")


class Ordering(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = jobs(PIPELINE)

    def test_the_chain_is_build_acceptance_inputs_upload_catalog(self):
        self.assertEqual(list(self.jobs), ["plan", "build", "acceptance", "catalog-inputs", "upload", "catalog"])
        self.assertEqual(field(self.jobs["build"], "needs"), "plan")
        self.assertEqual(field(self.jobs["acceptance"], "needs"), "build")
        self.assertEqual(field(self.jobs["upload"], "needs"), "[build, acceptance, catalog-inputs]")
        self.assertEqual(field(self.jobs["catalog-inputs"], "needs"), "acceptance")
        self.assertEqual(field(self.jobs["catalog"], "needs"), "[build, acceptance, upload, catalog-inputs]")
        for job, workflow in (("build", "mac-image"), ("acceptance", "mac-acceptance"), ("upload", "mac-upload"),
                              ("catalog", "mac-catalog")):
            self.assertEqual(field(self.jobs[job], "uses"), f"./.github/workflows/{workflow}.yml")

    def test_upload_and_catalog_never_run_without_passing_evidence(self):
        passed = "needs.acceptance.outputs.result == 'pass'"
        for job in ("upload", "catalog-inputs"):
            self.assertEqual(field(self.jobs[job], "if"), passed)
        self.assertEqual(field(self.jobs["catalog"], "if"), f"{passed} && !inputs.dry-run")
        for job in ("upload", "catalog-inputs", "catalog"):
            condition = field(self.jobs[job], "if")
            # A status function would let a job run after a failed need.
            self.assertNotRegex(condition, r"always\(\)|failure\(\)|cancelled\(\)|success\(\)")
        # Nothing becomes public before the catalog's inputs are known good.
        self.assertIn("catalog-inputs", field(self.jobs["upload"], "needs"))

    def test_the_acceptance_result_is_its_gate_not_a_default(self):
        acceptance = jobs(ACCEPTANCE)["acceptance"]
        self.assertIn("result: ${{ steps.gate.outputs.result }}", acceptance)
        self.assertIn("value: ${{ jobs.acceptance.outputs.result }}", text(ACCEPTANCE))

    def test_the_catalog_takes_what_the_upload_verified(self):
        upload_job, catalog_job = self.jobs["upload"], self.jobs["catalog"]
        for line in ("image-sha256: ${{ needs.build.outputs.sha256 }}", "dry-run: ${{ inputs.dry-run }}",
                     "evidence-artifact: ${{ needs.acceptance.outputs.evidence-artifact }}",
                     "evidence-run-id: ${{ needs.acceptance.outputs.evidence-run-id }}",
                     "make-public: ${{ !inputs.dry-run }}"):
            self.assertIn(line, upload_job)
        for line in ("image: ${{ needs.build.outputs.name }}", "payload: ${{ needs.upload.outputs.payload }}",
                     "installer-data: ${{ needs.upload.outputs.installer-data }}",
                     "evidence: ${{ needs.upload.outputs.evidence }}", "channel: edge", "dry-run: false"):
            self.assertIn(line, catalog_job)

    def test_called_workflows_declare_what_the_pipeline_reads(self):
        for workflow, outputs in (("mac-image.yml", ("name", "payload", "sha256")),
                                  ("mac-acceptance.yml", ("result", "evidence-artifact", "evidence-run-id")),
                                  ("mac-upload.yml", ("payload", "installer-data", "evidence"))):
            for output in outputs:
                with self.subTest(f"{workflow} {output}"):
                    self.assertRegex(text(WORKFLOWS / workflow),
                                     rf"\n      {re.escape(output)}:\n        description: [^\n]*\n        value: \$\{{\{{ jobs\.")


class Secrets(unittest.TestCase):
    def test_secrets_are_inherited_only_into_the_catalog_signer(self):
        # The pipeline passes the key by name. A workflow may forward what it
        # was given with inherit only into the signing workflow (mac-catalog.yml
        # into mac-catalog-sign.yml, once that split lands).
        for workflow in sorted(WORKFLOWS.glob("*.yml")):
            for job, body in jobs(workflow).items():
                if re.search(r"(?m)^    secrets:\s*inherit", body):
                    with self.subTest(f"{workflow.name} {job}"):
                        self.assertEqual(field(body, "uses"), "./.github/workflows/mac-catalog-sign.yml")

    def test_the_pipeline_passes_only_the_catalog_key_and_only_to_the_catalog(self):
        pipeline_jobs = jobs(PIPELINE)
        for job, body in pipeline_jobs.items():
            with self.subTest(job):
                expected = ["CATALOG_SIGNING_KEY: ${{ secrets.CATALOG_SIGNING_KEY }}"] if job == "catalog" else []
                self.assertEqual([line.strip() for line in body.splitlines() if "secrets." in line], expected)
                self.assertNotIn("environment:", body)

    def test_the_key_is_read_only_in_the_catalog_release_environment(self):
        # Wherever the signing job lives, only a job in catalog-release reads
        # the key; other jobs may only pass it on to a called workflow.
        readers = []
        for workflow in sorted(WORKFLOWS.glob("*.yml")):
            for job, body in jobs(workflow).items():
                if "secrets.CATALOG_SIGNING_KEY" not in body:
                    continue
                with self.subTest(f"{workflow.name} {job}"):
                    if field(body, "uses").startswith("./.github/workflows/"):
                        self.assertRegex(body, r"(?m)^      CATALOG_SIGNING_KEY: \$\{\{ secrets\.CATALOG_SIGNING_KEY \}\}$")
                    else:
                        self.assertEqual(field(body, "environment"), "catalog-release")
                        readers.append(f"{workflow.name} {job}")
        self.assertEqual(len(readers), 1, readers)

    def test_build_and_acceptance_hold_no_secrets(self):
        for workflow in ("mac-image.yml", "mac-acceptance.yml"):
            with self.subTest(workflow):
                self.assertNotIn("secrets.", text(WORKFLOWS / workflow))

    def test_a_real_upload_runs_in_the_publish_environment(self):
        self.assertEqual(field(jobs(WORKFLOWS / "mac-upload.yml")["upload"], "environment"),
                         "${{ !inputs.dry-run && 'publish' || '' }}")


class Hardening(unittest.TestCase):
    PIPELINE_FILES = ("mac-release-pipeline.yml", "mac-acceptance.yml", "mac-image.yml", "mac-upload.yml",
                      "mac-catalog.yml", "edge-dispatch.yml")

    def test_every_action_is_pinned_to_a_commit(self):
        for workflow in sorted(WORKFLOWS.glob("*.yml")):
            for line in lines(workflow):
                if "uses: " not in line:
                    continue
                with self.subTest(f"{workflow.name}: {line.strip()}"):
                    target = line.split("uses: ", 1)[1]
                    if target.startswith("./"):
                        self.assertRegex(target, r"^\./\.github/workflows/[a-z0-9-]+\.yml$")
                        self.assertTrue((ROOT / target).is_file())
                    else:
                        self.assertRegex(target, r"^[A-Za-z0-9-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40} # v[0-9]")

    def test_permissions_start_from_nothing_and_every_job_names_its_own(self):
        self.assertIn("\npermissions:\n  contents: read\n", text(WORKFLOWS / "mac-image.yml"))
        for name in ("mac-upload.yml", "mac-catalog.yml", "edge-dispatch.yml"):
            self.assertIn("\npermissions: {}\n", text(WORKFLOWS / name))
        for name in ("mac-release-pipeline.yml", "mac-acceptance.yml"):
            with self.subTest(name):
                self.assertIn("\npermissions: {}\n", text(WORKFLOWS / name))
                for job, body in jobs(WORKFLOWS / name).items():
                    self.assertRegex(body, r"(?m)^    permissions:", f"{name} job {job} names no permissions")

    def test_no_workflow_checks_out_with_persisted_credentials(self):
        for name in self.PIPELINE_FILES:
            body = text(WORKFLOWS / name)
            with self.subTest(name):
                self.assertEqual(body.count("uses: actions/checkout@"), body.count("persist-credentials: false"))


DEFAULT_RUNNER = '["self-hosted","linux","ARM64","omarchy-m2-lab"]'
HARNESS_COMMIT = "c" * 40
PASSING_RUN = """scenarios=first-boot conversion second-boot
ok - set: IMAGE (unsigned), PROVENANCE and a passed INSPECTION agree
harness_commit=cccc
ok - first-boot: every deferred hardware step completed
skip - first-boot: default audio sink (no Apple audio device in a VM)
ok - first-boot: encrypt.state records phase=declined
ok - conversion: root converted to LUKS2 in the initrd
ok - conversion: encrypt.state finished
ok - second-boot: Limine's command line asks for the disk password
"""


def runs_on(job: str) -> str:
    return field(job, "runs-on")


def hosted(job: str) -> bool:
    return re.fullmatch(r"(ubuntu|macos|windows)-[0-9a-z.-]+", runs_on(job)) is not None


class AcceptanceJobs(unittest.TestCase):
    """mac-acceptance.yml: a GitHub-hosted guard in front of the VM runner,
    and a GitHub-hosted attestation after it."""

    def setUp(self) -> None:
        self.jobs = jobs(ACCEPTANCE)

    def test_the_harness_and_cleanup_steps_turn_off_errexit(self):
        # The bash shell runs with -e: a failing harness would skip writing its
        # status, and pkill finding nothing would end the cleanup at once.
        workflow = text(ACCEPTANCE)
        for name in ("Run the harness", "Remove the image and the run's disks"):
            after = workflow[workflow.index(f"- name: {name}"):]
            first = re.search(r"^\s+set .*$", after, re.M).group(0).strip()
            self.assertTrue(first.startswith("set +e"), f"{name} starts with {first!r}")

    def test_the_jobs_are_guard_vm_attest(self):
        self.assertEqual(list(self.jobs), ["guard", "acceptance", "attest"])
        self.assertEqual(field(self.jobs["acceptance"], "needs"), "guard")
        self.assertEqual(field(self.jobs["attest"], "needs"), "acceptance")
        self.assertEqual(field(self.jobs["attest"], "if"), "needs.acceptance.outputs.result == 'pass'")

    def test_only_the_guard_decides_where_the_vm_job_runs(self):
        self.assertTrue(hosted(self.jobs["guard"]))
        self.assertTrue(hosted(self.jobs["attest"]))
        self.assertEqual(runs_on(self.jobs["acceptance"]), "${{ fromJSON(needs.guard.outputs.runner) }}")
        self.assertEqual(field(self.jobs["guard"], "if"), "github.repository == 'omacom/omarchy-mac-installer'")

    def test_every_job_off_github_hosted_runners_needs_the_guard(self):
        for workflow in sorted(WORKFLOWS.glob("*.yml")):
            for job, body in jobs(workflow).items():
                if field(body, "uses") or hosted(body):
                    continue
                with self.subTest(f"{workflow.name} {job}"):
                    self.assertEqual(workflow, ACCEPTANCE)
                    self.assertIn("guard", field(body, "needs"))

    def test_no_pull_request_workflow_can_reach_the_lab_runner(self):
        for workflow in sorted(WORKFLOWS.glob("*.yml")):
            if not triggers(workflow) & {"pull_request", "pull_request_target"}:
                continue
            with self.subTest(workflow.name):
                for job, body in jobs(workflow).items():
                    self.assertTrue(hosted(body) or field(body, "uses").startswith("./"), f"{job} runs on {runs_on(body)}")
                self.assertNotIn("omarchy-m2-lab", text(workflow))
                self.assertNotIn("self-hosted", text(workflow))
                self.assertNotIn("mac-acceptance.yml", text(workflow))

    def test_the_default_runner_is_the_lab_label_in_every_place(self):
        body = text(ACCEPTANCE)
        self.assertEqual(body.count(f"default: '{DEFAULT_RUNNER}'"), 2)
        self.assertEqual(body.count(f"DEFAULT_RUNNER: '{DEFAULT_RUNNER}'"), 1)
        self.assertIn("Namespace replaces it", body)

    def test_permissions_are_the_least_each_job_needs(self):
        def permissions(job: str) -> dict[str, str]:
            block = re.search(r"(?m)^    permissions:\n((?:      .*\n?)+)", self.jobs[job] + "\n").group(1)
            return {line.split(":")[0].strip(): line.split(":", 1)[1].split("#")[0].strip() for line in block.splitlines()}
        self.assertEqual(permissions("guard"), {"contents": "read"})
        self.assertEqual(permissions("acceptance"), {"contents": "read", "actions": "read", "attestations": "read"})
        self.assertEqual(permissions("attest"), {"contents": "read", "id-token": "write", "attestations": "write"})

    def test_the_vm_job_runs_in_the_acceptance_environment(self):
        self.assertEqual(field(self.jobs["acceptance"], "environment"), "acceptance")
        self.assertEqual(field(self.jobs["guard"], "environment"), "")

    def test_the_harness_is_pinned_to_a_full_commit(self):
        match = re.search(r"(?m)^  HARNESS_COMMIT: ([0-9a-f]+)$", text(ACCEPTANCE))
        self.assertIsNotNone(match)
        self.assertRegex(match.group(1), r"^[0-9a-f]{40}$")
        self.assertIn("HARNESS_REPOSITORY: omacom/omarchy-mac-pkgs", text(ACCEPTANCE))

    def test_the_harness_runs_on_the_checked_image_with_run_scoped_state(self):
        vm = self.jobs["acceptance"]
        for line in ("OMARCHY_VM_CPUS: 8", "OMARCHY_VM_MEMORY_MB: 8192", "OMARCHY_VM_IMAGE_STATE_DIR: ${{ env.ROOT }}/state",
                     "OMARCHY_VM_EVIDENCE_DIR: ${{ env.ROOT }}/evidence", "OMARCHY_VM_RUN_ID: ${{ env.VM_RUN_ID }}",
                     "ROOT: /var/tmp/omarchy-mac-acceptance/${{ github.run_id }}-${{ github.run_attempt }}"):
            self.assertIn(line, vm)
        script = step_script(ACCEPTANCE, "Run the harness")
        self.assertIn('"$ROOT/harness/tools/acceptance/mac-image/run" --image "$ROOT/image" --scenario "$SCENARIOS"', script)
        # The serial socket lives under the run directory and must stay under 100 bytes.
        root = "/var/tmp/omarchy-mac-acceptance/99999999999-99"
        self.assertLess(len(f"{root}/state/runs/99999999999-99/serial.sock"), 100)

    def test_the_image_is_downloaded_checked_and_attested_before_the_harness(self):
        body = text(ACCEPTANCE)
        order = [body.index(marker) for marker in ("- name: Download the image", "- name: Check the image",
                                                   "- name: Fetch the harness", "- name: Run the harness")]
        self.assertEqual(order, sorted(order))
        self.assertIn("run-id: ${{ inputs.image-run-id }}", self.jobs["acceptance"])
        self.assertIn("github-token: ${{ inputs.image-run-id != '' && github.token || '' }}", self.jobs["acceptance"])
        script = step_script(ACCEPTANCE, "Check the image")
        self.assertIn('[[ $actual != "$IMAGE_SHA256" ]]', script)
        verify = re.compile(r'gh attestation verify "\$\{zips\[0\]\}" (.*?)\s*(?:>|;)', re.S)
        upload_flags = verify.search(step_script(WORKFLOWS / "mac-upload.yml", "Verify the image's build attestation")).group(1)
        self.assertEqual(" ".join(verify.search(script).group(1).split()), " ".join(upload_flags.split()))

    def test_the_record_is_always_written_kept_and_gated_and_the_runner_cleaned(self):
        steps = re.findall(r"(?m)^      - (?:name: (.*)|uses: .*)$", self.jobs["acceptance"])
        names = [name for name in steps if name]
        self.assertEqual(names[-5:], ["Write the evidence record", "Keep the evidence record", "Keep the harness's logs",
                                      "Stop unless the image passed", "Remove the image and the run's disks"])
        vm = self.jobs["acceptance"]
        for step, condition in (("Write the evidence record", "always() && steps.checkout.outcome == 'success'"),
                                ("Keep the evidence record", "always() && steps.record.outcome == 'success'"),
                                ("Stop unless the image passed", "always()"),
                                ("Remove the image and the run's disks", "always()")):
            block = vm[vm.index(f"- name: {step}"):]
            self.assertRegex(block, rf"^- name: [^\n]*\n(?:        [^\n]*\n)*?        if: {re.escape(condition)}\n")
        self.assertIn("name: acceptance-evidence\n", vm)
        self.assertIn("evidence-artifact: acceptance-evidence", vm)
        self.assertIn("evidence-run-id: ${{ github.run_id }}", vm)

    def test_cleanup_refuses_any_directory_but_this_runs(self):
        script = step_script(ACCEPTANCE, "Remove the image and the run's disks")
        self.assertLess(script.index("^/var/tmp/omarchy-mac-acceptance/"), script.index("rm -rf"))
        for root in ("/", "/var/tmp", "/var/tmp/omarchy-mac-acceptance/../x", "/home/owner"):
            with self.subTest(root):
                result = subprocess.run([shutil.which("bash"), "--noprofile", "--norc", "-c", script],
                                        env={"PATH": "/nonexistent", "ROOT": root, "VM_RUN_ID": "1-1"},
                                        stdin=subprocess.DEVNULL, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unexpected run directory", result.stdout)

    def test_the_attest_job_checks_the_record_again_and_attests_it(self):
        attest = self.jobs["attest"]
        self.assertIn("name: acceptance-evidence", attest)
        self.assertIn("scripts/mac-upload.py check-evidence", step_script(ACCEPTANCE, "Check the record again"))
        self.assertRegex(attest, r"uses: actions/attest-build-provenance@[0-9a-f]{40} # v")
        self.assertIn("subject-path: ${{ runner.temp }}/evidence/acceptance-evidence.json", attest)
        self.assertLess(attest.index("Check the record again"), attest.index("attest-build-provenance"))

    def test_a_real_upload_refuses_evidence_not_attested_by_this_workflow(self):
        script = step_script(WORKFLOWS / "mac-upload.yml", "Verify the evidence's attestation")
        self.assertIn('--signer-workflow "$GITHUB_REPOSITORY/.github/workflows/mac-acceptance.yml"', script)
        self.assertIn("--source-ref refs/heads/main --deny-self-hosted-runners", script)
        self.assertRegex(script, r'elif \[\[ \$DRY_RUN == "true" \]\]; then\n[^\n]*\n[^\n]*::warning::[^\n]*\nelse\n[^\n]*\n[^\n]*::error::[^\n]*\n  exit 1')
        body = text(WORKFLOWS / "mac-upload.yml")
        self.assertLess(body.index("- name: Verify the evidence's attestation"), body.index("- name: Upload\n"))

    def test_the_pipeline_passes_the_runner_and_the_evidence_run(self):
        pipeline = jobs(PIPELINE)
        self.assertIn("runner: ${{ inputs.runner }}", pipeline["acceptance"])
        self.assertIn("evidence-run-id: ${{ needs.acceptance.outputs.evidence-run-id }}", pipeline["upload"])
        self.assertRegex(text(PIPELINE), r"\n      runner:\n        description: [^\n]*\n        type: string\n        default: ''\n")


class Guard(unittest.TestCase):
    def guard(self, event: str = "workflow_dispatch", ref: str = "refs/heads/main", runner: str = DEFAULT_RUNNER,
              scenarios: str = "fresh-install", image: str = "omarchy-mac-edge-2026.10.14-0123456789ab",
              sha: str = SHA, run_id: str = "") -> tuple[int, str]:
        directory = Path(tempfile.mkdtemp(prefix="omarchy-acceptance-guard-"))
        self.addCleanup(shutil.rmtree, directory)
        output = directory / "output"
        output.write_text("")
        env = {"PATH": os.environ["PATH"], "EVENT": event, "GITHUB_REF": ref, "IMAGE": image, "IMAGE_SHA256": sha,
               "IMAGE_RUN_ID": run_id, "RUNNER_INPUT": runner, "SCENARIOS": scenarios, "DEFAULT_RUNNER": DEFAULT_RUNNER,
               "GITHUB_OUTPUT": str(output)}
        result = subprocess.run(["bash", "--noprofile", "--norc", "-c", step_script(ACCEPTANCE, "Refuse anything but a main run")],
                                cwd=ROOT, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        self.output = result.stdout + result.stderr
        return result.returncode, output.read_text()

    def test_a_main_dispatch_passes_with_the_lab_runner(self):
        self.assertEqual(self.guard(), (0, f"runner={DEFAULT_RUNNER}\n"), self.output)
        self.assertEqual(self.guard(run_id="38555025363")[0], 0, self.output)

    def test_an_empty_runner_is_the_default_and_a_label_becomes_a_list(self):
        self.assertEqual(self.guard(runner="")[1], f"runner={DEFAULT_RUNNER}\n")
        self.assertEqual(self.guard(runner='"namespace-profile-mac-acceptance"')[1],
                         'runner=["namespace-profile-mac-acceptance"]\n')

    def test_pull_requests_never_reach_the_runner(self):
        for event in ("pull_request", "pull_request_target"):
            with self.subTest(event):
                status, output = self.guard(event=event)
                self.assertNotEqual(status, 0)
                self.assertEqual(output, "")

    def test_only_main_reaches_the_runner(self):
        for ref in ("refs/heads/feature", "refs/tags/v2.2.0", "refs/pull/1/merge", "refs/heads/main-x"):
            with self.subTest(ref):
                self.assertEqual(self.guard(ref=ref), (1, ""))

    def test_malformed_inputs_never_reach_the_runner(self):
        for change in ({"runner": "not json"}, {"runner": "[]"}, {"runner": '["a b"]'}, {"runner": '{"group": "x"}'},
                       {"runner": '["self-hosted", 1]'}, {"scenarios": "fresh-install;id"}, {"scenarios": ""},
                       {"scenarios": "--keep"}, {"image": "../etc"}, {"sha": "b" * 63}, {"run_id": "12x"}):
            with self.subTest(change):
                status, output = self.guard(**change)
                self.assertNotEqual(status, 0)
                self.assertEqual(output, "")


class Gate(unittest.TestCase):
    """The VM job's last decision: it fails unless the record passes."""

    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="omarchy-release-pipeline-"))
        self.addCleanup(shutil.rmtree, self.directory)
        self.record = self.directory / "acceptance-evidence.json"

    def gate(self) -> tuple[int, str]:
        output = self.directory / "output"
        output.write_text("")
        env = {"PATH": os.environ["PATH"], "IMAGE": "omarchy-mac-edge-2026.10.14-0123456789ab", "IMAGE_SHA256": SHA,
               "RECORD": str(self.record), "GITHUB_OUTPUT": str(output),
               "GITHUB_STEP_SUMMARY": str(self.directory / "summary")}
        result = subprocess.run(["bash", "--noprofile", "--norc", "-c", step_script(ACCEPTANCE, "Stop unless the image passed")],
                                cwd=ROOT, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        self.stderr = result.stderr
        return result.returncode, output.read_text()

    def test_the_gate_passes_only_a_passing_record_for_the_image(self):
        self.record.write_text(json.dumps(fixture.evidence(SHA, RUN_URL)))
        self.assertEqual(self.gate(), (0, "result=pass\n"), self.stderr)
        self.assertIn("first-boot: pass", (self.directory / "summary").read_text())
        self.record.write_text(json.dumps(fixture.evidence("b" * 64, RUN_URL)))
        self.assertEqual(self.gate(), (1, "result=fail\n"), self.stderr)

    def test_a_failing_record_fails_the_job(self):
        self.record.write_text(json.dumps({**fixture.evidence(SHA, RUN_URL), "result": "fail", "reason": "x"}))
        self.assertEqual(self.gate(), (1, "result=fail\n"))

    def test_no_record_fails_the_job(self):
        self.assertEqual(self.gate(), (1, "result=fail\n"))


class Record(unittest.TestCase):
    """scripts/mac-acceptance-record.py, from the harness's run.txt to the record."""

    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="omarchy-acceptance-record-"))
        self.addCleanup(shutil.rmtree, self.directory)

    def write(self, run_txt: str | None, status: str, scenarios: str = "fresh-install", reason: str = "",
              runner: str = "runs-on [\"omarchy-m2-lab\"], runner lab, host omarchy-m2") -> tuple[int, dict]:
        args = [sys.executable, "-I", str(SCRIPTS / "mac-acceptance-record.py"), "--sha256", SHA, "--scenarios", scenarios,
                "--harness-status", status, "--harness-commit", HARNESS_COMMIT, "--runner", runner, "--run-url", RUN_URL,
                "--image", "omarchy-mac-edge-2026.10.14-0123456789ab", "--reason", reason,
                "--out", str(self.directory / "out" / "acceptance-evidence.json")]
        if run_txt is not None:
            (self.directory / "run.txt").write_text(run_txt)
            args += ["--run-txt", str(self.directory / "run.txt")]
        result = subprocess.run(args, capture_output=True, text=True)
        self.output = result.stdout + result.stderr
        out = self.directory / "out" / "acceptance-evidence.json"
        return result.returncode, json.loads(out.read_text()) if out.exists() else {}

    @staticmethod
    def results(record: dict) -> dict[str, str]:
        return {item["name"]: item["result"] for item in record["scenarios"]}

    def test_a_passing_run_is_a_record_both_gates_take(self):
        status, record = self.write(PASSING_RUN, "0")
        self.assertEqual(status, 0, self.output)
        self.assertEqual(record["result"], "pass", record)
        self.assertEqual(self.results(record), {"first-boot": "pass", "conversion": "pass", "second-boot": "pass"})
        self.assertEqual((record["image_sha256"], record["harness_commit"], record["run_url"]), (SHA, HARNESS_COMMIT, RUN_URL))
        self.assertNotIn("reason", record)
        upload.check_evidence(record, SHA, RUN_URL)
        catalog.check_evidence(record, SHA)

    def test_a_not_ok_check_fails_its_scenario_and_the_record(self):
        run = PASSING_RUN.replace("ok - conversion: encrypt.state finished", "not ok - conversion: temporary key left")
        status, record = self.write(run, "1")
        self.assertEqual(status, 0)
        self.assertEqual(record["result"], "fail")
        self.assertEqual(self.results(record), {"first-boot": "pass", "conversion": "fail", "second-boot": "pass"})
        self.assertEqual(record["reason"], "the harness exited 1")
        self.assertRaises(upload.Refusal, upload.check_evidence, record, SHA)

    def test_a_scenario_the_run_never_reached_fails(self):
        run = PASSING_RUN.split("ok - conversion: encrypt")[0] + "not ok - conversion: no LUKS header\n"
        _, record = self.write(run, "1")
        self.assertEqual(self.results(record), {"first-boot": "pass", "conversion": "fail", "second-boot": "fail"})

    def test_a_cancelled_run_blames_the_scenario_that_was_running(self):
        run = PASSING_RUN.split("ok - conversion: encrypt")[0]
        _, record = self.write(run, "143")
        self.assertEqual(self.results(record), {"first-boot": "pass", "conversion": "fail", "second-boot": "fail"})
        self.assertEqual(record["result"], "fail")

    def test_an_image_that_failed_its_checks_is_a_failing_record(self):
        status, record = self.write(None, "", reason="the image artifact did not match image-sha256")
        self.assertEqual(status, 0, self.output)
        self.assertEqual((record["result"], record["reason"], record["harness_status"]),
                         ("fail", "the image artifact did not match image-sha256", None))
        self.assertEqual(self.results(record), {"first-boot": "fail", "conversion": "fail", "second-boot": "fail"})
        self.assertRaisesRegex(catalog.Refusal, "did not pass", catalog.check_evidence, record, SHA)

    def test_a_harness_that_never_ran_fails_even_without_a_reason(self):
        _, record = self.write("", "")
        self.assertEqual((record["result"], record["reason"]), ("fail", "the harness did not run"))

    def test_a_skipped_scenario_never_passes_the_record(self):
        run = PASSING_RUN.replace("scenarios=first-boot conversion second-boot", "scenarios=first-boot conversion second-boot update")
        run += "skip - update: the image has no update-verify\n"
        _, record = self.write(run, "0", scenarios="fresh-install,update")
        self.assertEqual(self.results(record)["update"], "skip")
        self.assertEqual(record["result"], "fail")
        self.assertIn("update skip", record["reason"])

    def test_a_pass_without_the_required_scenarios_fails(self):
        run = "scenarios=first-boot\n" + "\n".join(line for line in PASSING_RUN.splitlines() if "first-boot:" in line) + "\n"
        _, record = self.write(run, "0", scenarios="first-boot")
        self.assertEqual(self.results(record), {"first-boot": "pass"})
        self.assertEqual(record["result"], "fail")
        self.assertIn("the upload would refuse this record", record["reason"])

    def test_the_request_is_expanded_as_the_harness_expands_it_when_it_wrote_none(self):
        _, record = self.write("", "1", scenarios="second-boot,fresh-install")
        self.assertEqual(list(self.results(record)), ["first-boot", "conversion", "second-boot"])

    def test_the_runner_is_cut_to_what_the_gates_take(self):
        _, record = self.write(PASSING_RUN, "0", runner="x" * 300)
        self.assertEqual(len(record["runner"]), 200)
        self.assertEqual(record["result"], "pass")

    def test_malformed_arguments_write_nothing(self):
        for change in (("--sha256", "nope"), ("--harness-commit", "abc"), ("--run-url", "http://x"),
                       ("--harness-status", "x"), ("--scenarios", "a;b")):
            with self.subTest(change):
                args = {"--sha256": SHA, "--harness-commit": HARNESS_COMMIT, "--run-url": RUN_URL,
                        "--harness-status": "0", "--scenarios": "fresh-install", **dict([change])}
                out = self.directory / f"bad-{change[0]}.json"
                result = subprocess.run([sys.executable, "-I", str(SCRIPTS / "mac-acceptance-record.py"),
                                         *[item for pair in args.items() for item in pair], "--runner", "r",
                                         "--out", str(out)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(out.exists())


class Plan(unittest.TestCase):
    def plan(self, dry_run: str, ref: str, event: str = "workflow_dispatch") -> int:
        env = {"PATH": os.environ["PATH"], "DRY_RUN": dry_run, "GITHUB_REF": ref, "EVENT": event}
        return subprocess.run(["bash", "--noprofile", "--norc", "-c", step_script(PIPELINE, "Refuse a real run off main")], env=env,
                              stdin=subprocess.DEVNULL, capture_output=True).returncode

    def test_the_plan_reads_the_runs_own_dry_run_input(self):
        plan = jobs(PIPELINE)["plan"]
        self.assertIn("DRY_RUN: ${{ inputs.dry-run }}", plan)
        self.assertIn("EVENT: ${{ github.event_name }}", plan)

    def test_a_real_run_starts_only_from_main(self):
        self.assertEqual(self.plan("false", "refs/heads/main"), 0)
        self.assertNotEqual(self.plan("false", "refs/heads/feature"), 0)
        self.assertNotEqual(self.plan("false", "refs/tags/v2.2.0"), 0)
        self.assertEqual(self.plan("true", "refs/heads/feature"), 0)

    def test_pull_requests_never_run_it(self):
        for event in ("pull_request", "pull_request_target"):
            self.assertNotEqual(self.plan("true", "refs/heads/main", event), 0)


class Config(unittest.TestCase):
    def setUp(self) -> None:
        self.config = json.loads(CONFIG.read_text())

    def test_the_engine_is_the_one_the_app_pins(self):
        engine = self.config["engine"]
        build_app = (ROOT / "Packaging" / "build-app.sh").read_text()
        self.assertIn('python3 "$script_directory/read-validation-engine.py"', build_app)
        name, digest, size = subprocess.check_output(
            [sys.executable, str(ROOT / "Packaging/read-validation-engine.py")], text=True
        ).split()
        self.assertEqual((name, digest, int(size)),
                         (engine["fileName"], engine["sha256"], engine["sizeBytes"]))
        lock = json.loads((ROOT / "Engine" / "source-lock.json").read_text())
        self.assertEqual((lock["validation_artifact"]["filename"], lock["validation_artifact"]["size_bytes"],
                          lock["validation_artifact"]["sha256"], lock["downstream_overlay"]["version"]),
                         (engine["fileName"], engine["sizeBytes"], engine["sha256"], engine["version"]))
        template = json.loads((SCRIPTS / "release-inputs.template.json").read_text())
        self.assertEqual(engine["downstreamRevision"], template["downstream_revision"])
        catalog.check_engine(engine)

    def test_the_app_block_is_unset_or_one_the_catalog_takes(self):
        self.assertEqual(set(self.config), {"engine", "installer"})
        if self.config["installer"] is not None:
            catalog.check_installer(self.config["installer"], self.config["engine"]["version"])



@unittest.skipIf(shutil.which("jq") is None, "jq is required")
class CatalogInputs(unittest.TestCase):
    """The catalog-inputs step: it runs before the upload, so it decides
    whether a real run may make anything public."""

    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="omarchy-release-pipeline-"))
        self.addCleanup(shutil.rmtree, self.directory)
        self.engine = json.loads(CONFIG.read_text())["engine"]

    def run_step(self, installer, dry_run: str, engine=None) -> tuple[int, str]:
        config = self.directory / "config.json"
        config.write_text(json.dumps({"engine": engine or self.engine, "installer": installer}))
        output = self.directory / "output"
        output.write_text("")
        env = {"PATH": os.environ["PATH"], "DRY_RUN": dry_run, "PIPELINE_CONFIG": str(config),
               "GITHUB_OUTPUT": str(output)}
        result = subprocess.run(["bash", "--noprofile", "--norc", "-c", step_script(PIPELINE, "Read the engine and app blocks")],
                                cwd=ROOT, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        return result.returncode, output.read_text() + result.stdout + result.stderr

    def installer(self) -> dict:
        return {"minimumVersion": "2.1.0", "latestVersion": "2.2.0",
                "downloadURL": f"https://github.com/{catalog.stopgap_repo()}/releases/download/v2.2.0/app.dmg"}

    def test_a_real_run_without_an_app_release_stops_before_the_upload(self):
        status, output = self.run_step(None, "false")
        self.assertNotEqual(status, 0)
        self.assertIn("names no app release", output)

    def test_a_dry_run_without_an_app_release_goes_on(self):
        self.assertEqual(self.run_step(None, "true")[0], 0)

    def test_a_malformed_block_stops_a_real_run(self):
        for installer, engine in (({**self.installer(), "minimumVersion": "2.0.0"}, None),
                                  ({**self.installer(), "downloadURL": "https://example.invalid/app.dmg"}, None),
                                  (self.installer(), {**self.engine, "sha256": "nope"})):
            with self.subTest(installer=installer, engine=engine):
                self.assertNotEqual(self.run_step(installer, "false", engine)[0], 0)

    def test_a_good_block_becomes_the_catalogs_inputs(self):
        status, output = self.run_step(self.installer(), "false")
        self.assertEqual(status, 0, output)
        lines = dict(line.split("=", 1) for line in output.splitlines() if "=" in line and not line.startswith("::"))
        self.assertEqual(json.loads(lines["engine"]), self.engine)
        self.assertEqual(json.loads(lines["installer"]), self.installer())

if __name__ == "__main__":
    unittest.main()
