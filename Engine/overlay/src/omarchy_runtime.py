# SPDX-License-Identifier: MIT
"""Closed execution runtime presented to the pinned upstream entry point."""

import os

import omarchy_apple_aea
import omarchy_asahi
import omarchy_contract
import omarchy_execution
import omarchy_planner
import omarchy_repair
import omarchy_stage1


ENVIRONMENT_KEYS = {
    "OMARCHY_ENGINE_MODE",
    "OMARCHY_ENGINE_JOURNAL",
    "OMARCHY_ENGINE_REQUEST",
    "OMARCHY_ENGINE_IDENTITY",
    "OMARCHY_ENGINE_METADATA",
    "OMARCHY_ENGINE_PAYLOAD",
    "OMARCHY_ENGINE_REPAIR_MANIFEST",
    "OMARCHY_ENGINE_BINDING_DIGEST",
    "OMARCHY_ENGINE_PLAN_DIGEST",
    "OMARCHY_MACHINE_OWNER",
    "OMARCHY_RECOVERY_APP",
    "OMARCHY_RECOVERY_MANIFEST",
    "OMARCHY_RECOVERY_REQUIREMENT",
    "DISTRO",
    "DISTRO_DOCS",
    "OMARCHY_INSTALLER_NAME",
    # The app's signed decoder and the requirement it must satisfy. Installs
    # need it (macOS 26 images, the Neo's radios); an engine never carries one.
    omarchy_apple_aea.DECODER_ENVIRONMENT,
    omarchy_apple_aea.REQUIREMENT_ENVIRONMENT,
}

# Released apps predate OMARCHY_INSTALLER_NAME; without it the Recovery
# setup is titled from DISTRO.
OPTIONAL_INSTALL_KEYS = {
    "OMARCHY_ENGINE_MODE",
    "OMARCHY_ENGINE_REPAIR_MANIFEST",
    "OMARCHY_INSTALLER_NAME",
}


class EngineRuntimeError(omarchy_contract.ContractError):
    pass


class EngineRuntime:
    def __init__(self, *, mode, values):
        self.mode = mode
        self.values = values
        self.journal = omarchy_contract.Journal(
            values["OMARCHY_ENGINE_JOURNAL"]
        )
        self.device_identifier = None

    @classmethod
    def from_environment(cls, environment=None):
        environment = os.environ if environment is None else environment
        values = {
            key: environment.get(key)
            for key in ENVIRONMENT_KEYS
            if environment.get(key)
        }
        mode = values.get("OMARCHY_ENGINE_MODE")
        if mode is None:
            if values:
                raise EngineRuntimeError("engine mode is missing")
            return None
        if mode not in (
            "inspect",
            "plan",
            "install",
            "retry-recovery-authorization",
        ):
            raise EngineRuntimeError("unsupported engine mode")
        if environment.get("EXPERT"):
            raise EngineRuntimeError("expert mode is forbidden")

        required = {
            "inspect": {"OMARCHY_ENGINE_JOURNAL"},
            "plan": {
                "OMARCHY_ENGINE_JOURNAL",
                "OMARCHY_ENGINE_REQUEST",
                "OMARCHY_ENGINE_IDENTITY",
            },
            "install": ENVIRONMENT_KEYS - OPTIONAL_INSTALL_KEYS,
            "retry-recovery-authorization": ENVIRONMENT_KEYS - OPTIONAL_INSTALL_KEYS,
        }[mode]
        missing = sorted(required - set(values))
        if missing:
            raise EngineRuntimeError(
                "missing engine environment: " + ",".join(missing)
            )
        if mode in ("install", "retry-recovery-authorization"):
            # Refuse before any disk change, not when the first image needs it.
            try:
                omarchy_apple_aea.decoder(values)
            except omarchy_apple_aea.AppleInputError as error:
                raise EngineRuntimeError(str(error)) from error
        return cls(mode=mode, values=values)

    def metadata(self, bundled_metadata):
        if self.mode not in (
            "install",
            "retry-recovery-authorization",
        ):
            return bundled_metadata
        return omarchy_asahi.load_metadata(
            self.values["OMARCHY_ENGINE_METADATA"]
        )

    def inspect(self, device_class, supported):
        self.device_identifier = (
            omarchy_contract.normalize_device_identifier(device_class)
        )
        self.journal.inspection(
            self.device_identifier,
            "supported" if supported else "unsupported",
        )

    def run_layout(
        self,
        *,
        installer,
        free_parts,
        resizable_parts,
        stub_size,
        part_align,
    ):
        if self.device_identifier is None:
            inspection = self.journal.inspection_payload
            if inspection is None:
                raise EngineRuntimeError("inspection is required")
            self.device_identifier = inspection["device_identifier"]
        if self.journal.inspection_payload["support"] != "supported":
            raise EngineRuntimeError("unsupported device has no layout")

        repair_manifest = None
        repair_manifest_path = self.values.get(
            "OMARCHY_ENGINE_REPAIR_MANIFEST"
        )
        if repair_manifest_path is not None:
            repair_manifest = omarchy_repair.load_repair_manifest(
                repair_manifest_path
            )
            if repair_manifest["device_identifier"] != self.device_identifier:
                raise EngineRuntimeError("repair device changed")
            collected = omarchy_repair.collect_repair_inventory(
                installer,
                repair_manifest,
                disk_identity_reader=(
                    omarchy_repair.read_normalized_disk_identity
                ),
                filesystem_identity_reader=(
                    omarchy_repair.inspect_filesystem_identity
                ),
            )
        else:
            is_gpt = (
                installer.dutil.disks[installer.cur_disk]["Content"]
                == "GUID_partition_scheme"
            )
            collected = omarchy_planner.collect_inventory(
                installer,
                free_parts,
                # Also keep tight macOS containers for exact shortfalls.
                # Do not probe unrelated stubs or data-only containers that
                # upstream did not consider resizable. A stub carries the
                # version of the macOS it was made from, so test stub too.
                [
                    part for part in installer.parts
                    if part in resizable_parts or (
                        part.type == "Apple_APFS"
                        and part.container is not None
                        and part.os
                        and any(os.version and not os.stub for os in part.os)
                    )
                ] if is_gpt else [],
                stub_size,
                part_align,
            )
        live = omarchy_contract.normalized_inventory(
            collected["system_store_identifier"],
            collected["candidates"],
        )
        if self.journal.inventory_payload is None:
            self.journal.inventory(
                live["system_store_identifier"],
                live["candidates"],
            )
        elif self.journal.plan_payload is None or self.mode not in (
            "install",
            "retry-recovery-authorization",
        ):
            self.journal.inventory(
                live["system_store_identifier"],
                live["candidates"],
            )
        elif (
            live["system_store_identifier"]
            != self.journal.inventory_payload["system_store_identifier"]
        ):
            raise EngineRuntimeError("system store changed during resume")

        if self.mode == "inspect":
            return "inspected"
        if self.mode == "plan":
            omarchy_planner.emit_plan(
                self.journal,
                self.values["OMARCHY_ENGINE_REQUEST"],
                self.values["OMARCHY_ENGINE_IDENTITY"],
                self.device_identifier,
                part_align,
            )
            return "planned"

        admission_inventory = self.journal.inventory_payload
        if (
            self.journal.plan_payload is not None
            and not self.journal.events
            and not self.journal.checkpoints
            and self.journal.completion_outcome is None
        ):
            admission_inventory = live

        plan = omarchy_execution.admit_execution(
            request_path=self.values["OMARCHY_ENGINE_REQUEST"],
            identity_path=self.values["OMARCHY_ENGINE_IDENTITY"],
            live_inventory=admission_inventory,
            expected_binding_digest=self.values[
                "OMARCHY_ENGINE_BINDING_DIGEST"
            ],
            expected_plan_digest=self.values[
                "OMARCHY_ENGINE_PLAN_DIGEST"
            ],
        )
        self._record_execution_plan(plan)
        if getattr(plan, "operation", "install") == omarchy_repair.REPAIR_OPERATION:
            if repair_manifest is None:
                raise EngineRuntimeError("repair manifest is required")
            adapter = omarchy_asahi.AsahiInPlaceRepairAdapter(
                installer=installer,
                manifest=repair_manifest,
                metadata_path=self.values["OMARCHY_ENGINE_METADATA"],
                payload_path=self.values["OMARCHY_ENGINE_PAYLOAD"],
            )
            executor = omarchy_repair.RepairExecutor(adapter)
            if self.mode == "retry-recovery-authorization":
                return executor.retry_boot_policy(
                    plan,
                    self.journal,
                )
            return executor.apply(
                plan,
                self.journal,
            )
        completed = omarchy_stage1.validate_stage1_resume(
            plan,
            self.journal,
        )
        if completed is not None:
            if self.mode == "retry-recovery-authorization":
                raise EngineRuntimeError(
                    "Recovery authorization is already complete"
                )
            return completed

        adapter = omarchy_asahi.AsahiStage1Adapter(
            installer=installer,
            metadata_path=self.values["OMARCHY_ENGINE_METADATA"],
            payload_path=self.values["OMARCHY_ENGINE_PAYLOAD"],
            stub_size=stub_size,
            recovery_app=self.values["OMARCHY_RECOVERY_APP"],
            recovery_manifest=self.values["OMARCHY_RECOVERY_MANIFEST"],
            recovery_requirement=self.values["OMARCHY_RECOVERY_REQUIREMENT"],
            authorized_owner=self.values["OMARCHY_MACHINE_OWNER"],
            full_readback=os.environ.get("OMARCHY_FULL_READBACK") == "1",
        )
        with omarchy_asahi.timing("preflight"):
            adapter.preflight(plan)
        if self.mode == "retry-recovery-authorization":
            return omarchy_stage1.retry_recovery_authorization(
                plan,
                self.journal,
                adapter,
            )
        return omarchy_stage1.run_stage1(
            plan,
            self.journal,
            adapter,
        )

    def _record_execution_plan(self, plan):
        digest = self.journal.plan(
            device_identifier=plan.device_identifier,
            layout_digest=plan.layout_digest,
            candidate_kind=plan.candidate_kind,
            source_identifier=plan.source_identifier,
            requested_length_bytes=plan.length_bytes,
            engine_version=plan.engine_version,
            engine_digest=plan.engine_digest,
            metadata_digest=plan.metadata_digest,
            payload_digest=plan.payload_digest,
            repair_manifest_digest=getattr(
                plan,
                "repair_manifest_digest",
                None,
            ),
            required_human_steps=list(plan.required_human_steps),
        )
        if digest != plan.plan_digest:
            raise EngineRuntimeError("admitted plan journal mismatch")
