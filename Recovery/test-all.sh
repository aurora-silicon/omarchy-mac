#!/bin/bash
# Pure Recovery fixtures; never enroll a boot object or change a live account.
set -euo pipefail
cd "$(dirname "$0")"
[[ $(uname -s) == Darwin ]] || { echo 'Recovery Swift/AppKit checks require macOS' >&2; exit 1; }
out="${1:?test output directory}"
mkdir -p "$out"
xcrun clang -Wall -Wextra -Werror Tests/AuthorizationCheck.c -o "$out/authorization-check"
"$out/authorization-check"
compile_run() {
  local name=$1
  shift
  xcrun swiftc "$@" -o "$out/$name"
  "$out/$name"
}
compile_run enrollment Sources/EnrollmentGate.swift Tests/EnrollmentGateCheck.swift
compile_run owner Sources/RecoveryOwner.swift Tests/RecoveryOwnerCheck.swift
compile_run bootstrap-owner Sources/RecoveryOwner.swift Tests/BootstrapOwnerCheck.swift
compile_run boot-selection Sources/BootSelection.swift Tests/BootSelectionCheck.swift
compile_run installer-log Sources/InstallerLog.swift Tests/InstallerLogCheck.swift
compile_run log-view Sources/LogTextView.swift Tests/LogTextViewCheck.swift
compile_run configuration Sources/RecoveryOwner.swift Sources/InstallConfiguration.swift Tests/InstallConfigurationCheck.swift
compile_run file-transaction Sources/Account/RecoveryFileTransaction.swift Tests/RecoveryFileTransactionCheck.swift
compile_run installation-journal Sources/RecoveryInstallationJournal.swift Tests/RecoveryInstallationJournalCheck.swift
compile_run directory-swap Sources/Account/RecoveryFileTransaction.swift Sources/RecoveryDirectorySwap.swift Tests/RecoveryDirectorySwapCheck.swift
compile_run baseline Sources/RecoveryBaseline.swift Tests/RecoveryBaselineCheck.swift
