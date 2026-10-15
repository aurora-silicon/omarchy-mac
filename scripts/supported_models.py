#!/usr/bin/env python3
"""The Macs every Omarchy Mac catalog must enable, and the ones it must refuse.

`supported-models.json` is the single list: every M1, M2 and M3 Mac the
pinned engine can inspect. A catalog that offers any Mac offers all of them,
so a release or preview can never ship a subset by accident. A channel with no
Mac release yet (an empty catalog) is the only exception. `refused` names each
board that stays out and why. `developer` names each board only a developer
build's sealed catalog may add, with its own image; channel catalogs never
carry one, so check-catalog rejects it like any unknown board.

board that stays out and why. `untested` marks the supported Macs that no
image has been installed on yet (the M3 generation), with the note a catalog
shows for each.

Usage:
  supported_models.py check-catalog FILE   exit 1 unless FILE covers every Mac
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

MANIFEST = Path(__file__).resolve().with_name("supported-models.json")


def load(path: Path = MANIFEST) -> tuple[list[str], dict[str, str]]:
    document = json.loads(path.read_text())
    if document.get("schema_version") != 1:
        raise SystemExit(f"{path}: unsupported schema")
    supported, refused = document["supported"], document["refused"]
    if len(set(supported)) != len(supported):
        raise SystemExit(f"{path}: supported lists a Mac twice")
    if set(supported) & set(refused):
        raise SystemExit(f"{path}: a Mac is both supported and refused")
    if set(document.get("developer", {})) & (set(supported) | set(refused)):
        raise SystemExit(f"{path}: a developer board is also supported or refused")
    return supported, refused


def developer_boards(path: Path = MANIFEST) -> dict[str, str]:
    """The boards only a developer build's sealed catalog may add, with why."""
    load(path)
    return dict(json.loads(path.read_text()).get("developer", {}))

def untested(path: Path = MANIFEST) -> dict[str, str]:
    """Supported Macs no Omarchy image has been installed on yet, each with
    the note a catalog shows for it."""
    supported, _ = load(path)
    notes = json.loads(path.read_text()).get("untested", {})
    if not isinstance(notes, dict) or not all(
        isinstance(note, str) and note for note in notes.values()
    ):
        raise SystemExit(f"{path}: untested maps each Mac to a note")
    stray = set(notes) - set(supported)
    if stray:
        raise SystemExit(f"{path}: untested names unsupported Macs: {', '.join(sorted(stray))}")
    return notes


def coverage_errors(identifiers: list[str]) -> list[str]:
    """Why IDENTIFIERS (the Macs a catalog enables) is not exactly the supported set."""
    supported, refused = load()
    errors = []
    missing = [identifier for identifier in supported if identifier not in identifiers]
    if missing:
        errors.append(
            "every M1, M2 and M3 Mac must be enabled; missing "
            + ", ".join(missing)
        )
    for identifier in identifiers:
        if identifier in refused:
            errors.append(f"{identifier} is refused: {refused[identifier]}")
        elif identifier not in supported:
            errors.append(
                f"{identifier} is not in scripts/supported-models.json; "
                "add it there, with its engine and device-tree support, first"
            )
    return errors


def catalog_errors(catalog: dict) -> list[str]:
    models = catalog.get("models")
    if not isinstance(models, list):
        return ["the catalog has no models list"]
    if not models:
        return []
    enabled = [
        model.get("deviceIdentifier")
        for model in models
        if model.get("status") == "enabled"
    ]
    errors = [
        f"{model.get('deviceIdentifier')} is listed but {model.get('status')}"
        for model in models
        if model.get("status") != "enabled"
    ]
    return errors + coverage_errors(enabled)


def main(arguments: list[str]) -> int:
    if len(arguments) != 2 or arguments[0] != "check-catalog":
        print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
        return 64
    errors = catalog_errors(json.loads(Path(arguments[1]).read_text()))
    for error in errors:
        print(f"catalog model coverage: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
