# Mac acceptance runner

`mac-acceptance.yml`'s VM job needs an aarch64 Linux host with `/dev/kvm`. GitHub's hosted arm64 runners and Namespace's standard arm64 runners have none. The planned runner is Namespace's Apple-backed Linux ARM64, which is not enabled for Omacom yet. Until it is, the job runs on the owner's M2 Max lab Mac (Arch Linux ARM, Omarchy), registered as an **ephemeral** self-hosted runner for one job.

The runner is the workflow's `runner` input, a JSON `runs-on` value. Its default is `["self-hosted","linux","ARM64","omarchy-m2-lab"]`, in three places in `mac-acceptance.yml` (both triggers' input defaults and the guard's `DEFAULT_RUNNER`; a test keeps them equal). Moving to Namespace means changing that default to the Namespace profile's label. Nothing else changes.

## What the host needs

- The harness's tools ([README](https://github.com/omacom/omarchy-mac-pkgs/blob/main/tools/acceptance/mac-image/README.md)): `qemu-system-aarch64`, `dtc`, `socat`, `gptfdisk`, `dosfstools`, `btrfs-progs`, `cryptsetup`, `mkinitcpio`, `libarchive`, `gnupg`, `curl`, `python3`. The job also uses `gh`, `git` and `dmsetup`.
- Readable `/dev/kvm` and passwordless `sudo` for the runner's user.
- 70 GiB free under `/var/tmp`. The job works in `/var/tmp/omarchy-mac-acceptance/<run>-<attempt>/` and removes it at the end, together with the image, the run's disks and its loop devices.

## Register it for one run

Run these steps as the lab user, never as root. The harness calls `sudo -n` itself.

1. Dispatch the run that needs it from `main`: the release pipeline (`mac-release-pipeline.yml`) or `mac-acceptance.yml` with an image artifact of an earlier run. The VM job waits in the queue for a runner with its labels for up to 24 hours.
2. Download the current `linux-arm64` runner from <https://github.com/actions/runner/releases> into a fresh directory, for example `~/actions-runner-acceptance`. Check its sha256 against the release notes before you unpack it.
3. Get a repository-level registration token. It expires after an hour, so do not keep it.

   ```bash
   gh api -X POST repos/omacom/omarchy-mac-installer/actions/runners/registration-token --jq .token
   ```

4. Configure the runner at the repository level, ephemeral, with the extra label, then start it:

   ```bash
   ./config.sh --url https://github.com/omacom/omarchy-mac-installer --token <token> \
     --ephemeral --labels omarchy-m2-lab --name omarchy-m2-lab-$(date +%Y%m%d) --unattended
   ./run.sh
   ```

   GitHub adds the `self-hosted`, `Linux` and `ARM64` labels itself. Labels are matched case-insensitively.
5. The runner takes the waiting job, runs it, and then deregisters and exits. Check that no runner is left with `gh api repos/omacom/omarchy-mac-installer/actions/runners --jq '.runners[].name'`, then delete the runner directory.

If the run is cancelled before the runner picks it up, stop `run.sh` and remove the runner (`./config.sh remove --token <a removal token>`, or delete it on the repository's Actions runners page).

## Risk

This is a self-hosted runner on a public repository. The limits that keep it safe are:

- **Ephemeral only.** The runner exists only while a dispatched `main` run is waiting for it, and it takes exactly one job. Never register it as a persistent runner or as a service.
- **Main only.** The guard job runs on a GitHub-hosted runner and refuses pull requests, any ref but `refs/heads/main` and malformed inputs before the VM job is scheduled. The VM job `needs:` it. `mac-acceptance.yml` has only `workflow_call` and `workflow_dispatch` triggers, and dispatching needs write access.
- **Fork pull requests need approval.** Any workflow can ask for the runner's labels, including one changed in a pull request. Set the repository's approval for workflows from fork pull requests to all external contributors (it is first-time contributors only on 2026-10-14), and don't approve one while the runner is registered.
- **No secrets.** The VM job's token can read this repository's contents, artifacts and attestations, nothing more. The job never receives an `id-token` permission. The evidence record is attested by a separate GitHub-hosted job.
- **Environment.** The VM job runs in the `acceptance` environment. Give that environment a deployment branch policy that allows `main` alone and no secrets. GitHub creates it unprotected on the first run if it doesn't exist yet.

The job runs the pinned harness (`HARNESS_COMMIT`) and the image under `sudo` on the lab Mac. The image is checked against its sha256 and its `mac-image.yml` build attestation first. Even so, the lab Mac should hold nothing that a misbehaving image build could not be allowed to reach.
