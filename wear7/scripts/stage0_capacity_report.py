#!/usr/bin/env python3
"""Compute raw free-space headroom for the frozen Stage0 additions.

Input files are `debugfs -R stats` reports for the exact Pixel donor images.
This is only a capacity gate; it does not replace a metadata-aware Android image build.
"""

from __future__ import annotations
import argparse
import re
from pathlib import Path

PAYLOAD_BYTES = {
    "system": 5_446_025,
    "system_ext": 2_325_472,
    "product": 8_542,
}


def parse_stats(path: Path) -> tuple[int, int, int]:
    text = path.read_text(errors="replace")
    def value(label: str) -> int:
        m = re.search(rf"^{re.escape(label)}:\s+(\d+)", text, re.M)
        if not m:
            raise RuntimeError(f"{label!r} not found in {path}")
        return int(m.group(1))
    return value("Block size"), value("Free blocks"), value("Free inodes")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("reports", type=Path, help="directory containing pixel_*_ext4_stats.txt")
    ap.add_argument("--tsv", type=Path)
    args = ap.parse_args()

    rows = []
    for part in ("system", "system_ext", "product"):
        bs, free_blocks, free_inodes = parse_stats(
            args.reports / f"pixel_{part}_ext4_stats.txt"
        )
        free_bytes = bs * free_blocks
        payload = PAYLOAD_BYTES[part]
        after = free_bytes - payload
        verdict = "RAW_SPACE_OK" if after >= 0 else "RESIZE_OR_REBUILD_REQUIRED"
        rows.append((part, bs, free_blocks, free_bytes, free_inodes, payload, after, verdict))

    header = (
        "partition\tblock_size\tfree_blocks\tfree_bytes\tfree_inodes\t"
        "stage0_payload_bytes\traw_headroom_after_payload\tverdict"
    )
    if args.tsv:
        args.tsv.parent.mkdir(parents=True, exist_ok=True)
        with args.tsv.open("w") as f:
            f.write(header + "\n")
            for row in rows:
                f.write("\t".join(map(str, row)) + "\n")

    for part, bs, fb, free, fi, payload, after, verdict in rows:
        print(
            f"{part}: free={free} payload={payload} raw_after={after} "
            f"free_inodes={fi} => {verdict}"
        )
    print(
        "NOTE: this is a raw-space gate only. shared_blocks, metadata, alignment, "
        "filesystem labels/capabilities and AVB still require a controlled build."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
