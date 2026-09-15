#!/usr/bin/env python3
"""Reconstruct one Android BLOCK OTA partition from new.dat + transfer.list.

Fail-closed: only source-independent new/zero/erase commands are accepted.
Intended for exact full BLOCK OTAs such as TicWatch TMDB.240925.002/379.
"""

from __future__ import annotations
import argparse
import zipfile
from pathlib import Path

BLOCK = 4096


def parse_rangeset(raw: str) -> list[tuple[int, int]]:
    nums = [int(x) for x in raw.split(",") if x]
    if not nums:
        raise ValueError("empty rangeset")
    count, rest = nums[0], nums[1:]
    if count != len(rest) or count % 2:
        raise ValueError(f"invalid rangeset: {raw[:120]}")
    return [(rest[i], rest[i + 1]) for i in range(0, len(rest), 2)]


def reconstruct(ota: Path, partition: str, output: Path) -> None:
    with zipfile.ZipFile(ota) as zf:
        transfer_name = f"{partition}.transfer.list"
        new_name = f"{partition}.new.dat"
        lines = zf.read(transfer_name).decode("utf-8", "strict").splitlines()
        version = int(lines[0])
        total_blocks = int(lines[1])
        if version not in (1, 2, 3, 4):
            raise RuntimeError(f"unsupported transfer-list version {version}")
        commands = lines[2:] if version == 1 else lines[4:]
        new_ranges: list[tuple[int, int]] = []
        for line in commands:
            line = line.strip()
            if not line:
                continue
            op, *rest = line.split()
            if op == "new":
                if not rest:
                    raise RuntimeError("new command without rangeset")
                new_ranges.extend(parse_rangeset(rest[0]))
            elif op in ("zero", "erase"):
                continue
            else:
                raise RuntimeError(
                    f"source-dependent/unsupported command in {partition}: {op}"
                )

        output.parent.mkdir(parents=True, exist_ok=True)
        with zf.open(new_name) as src, output.open("wb") as dst:
            dst.truncate(total_blocks * BLOCK)
            copied = 0
            for start, end in new_ranges:
                if start < 0 or end < start or end > total_blocks:
                    raise RuntimeError(f"bad range {start}-{end} / {total_blocks}")
                dst.seek(start * BLOCK)
                left = (end - start) * BLOCK
                while left:
                    data = src.read(min(left, 8 * 1024 * 1024))
                    if not data:
                        raise RuntimeError("premature EOF in new.dat")
                    dst.write(data)
                    copied += len(data)
                    left -= len(data)
            if src.read(1):
                raise RuntimeError("trailing bytes remain in new.dat")

    print(
        f"{partition}: version={version} total_blocks={total_blocks} "
        f"image_bytes={total_blocks * BLOCK} copied_new_bytes={copied}"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("ota", type=Path)
    ap.add_argument("partition")
    ap.add_argument("output", type=Path)
    args = ap.parse_args()
    reconstruct(args.ota, args.partition, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
