#!/usr/bin/env python3
"""Wear7 V7 installer entry point.

This reuses the already-tested bounded transport backend but freezes it to the
validated V7 candidate from Actions run 35198609607. Hardware writes remain
gated by validated-recoveries.json; no force bypass is introduced here.
"""
import json
from pathlib import Path
import sys

import wear7_installer as core

HERE = Path(__file__).resolve().parent
V7_RUN = 35198609607
V7_RAM = "/tmp/wear7-v7-transfer"


def reference_v7():
    return json.loads((HERE / "candidate-v7.json").read_text())


def candidate_images_v7(package):
    package = Path(package).resolve()
    manifest = core.preflight.verify_package(package)
    reference = reference_v7()
    if manifest != reference:
        raise ValueError(f"package differs from the frozen V7 run {V7_RUN}")
    images = {}
    for name in core.ORDER:
        item = manifest["images"][name + ".img"]
        size = manifest["super_expanded_bytes"] if name == "super" else item["bytes"]
        checksum = manifest["super_expanded_sha256"] if name == "super" else item["sha256"]
        images[name] = core.Image(name, package / (name + ".img"), size, checksum, name == "super")
    return manifest, images


# Patch only candidate identity and temporary namespace. The transport, recovery
# gates, rollback requirements, protected-partition checks and no-auto-reboot
# behavior remain exactly the tested core implementation.
core.reference = reference_v7
core.candidate_images = candidate_images_v7
core.RAM = V7_RAM
core.__doc__ = "Wear7 V7 installer development kit. Hardware writes remain gated."


if __name__ == "__main__":
    try:
        raise SystemExit(core.main())
    except (Exception, KeyboardInterrupt) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
