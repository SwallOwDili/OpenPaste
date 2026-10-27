#!/usr/bin/env python3
"""Create synthetic version-2 histories; never reads existing clipboard/history data.

The output directory must be new. For GUI use, pass --profile UUID to create an
isolated, correctly marked build/acceptance profile, without starting the app.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import html
import json
from pathlib import Path
import struct
import uuid
import zlib


REPO = Path(__file__).resolve().parents[2]
NAMESPACE = uuid.UUID("a878829b-26d2-42fc-bdf7-10fb40258619")
BASE_DATE = 813_499_200  # Fixed Foundation reference-date seconds; no wall clock.


def identifier(name: str) -> str:
    return str(uuid.uuid5(NAMESPACE, name)).upper()


def png(number: int) -> bytes:
    """Small, valid RGB PNG generated solely from synthetic fixture numbers."""
    def chunk(kind: bytes, content: bytes) -> bytes:
        return struct.pack(">I", len(content)) + kind + content + struct.pack(">I", zlib.crc32(kind + content))

    width, height = 320, 180
    rows = b"".join(b"\0" + bytes((number % 256, y % 256, 160)) * width for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def sized_text(prefix: str, size: int, suffix: str) -> str:
    remaining = size - len((prefix + suffix).encode("utf-8"))
    if remaining < 0:
        raise ValueError("requested text size cannot fit markers")
    return prefix + ("synthetic searchable text " * (remaining // 26 + 1))[:remaining] + suffix


def character_text(prefix: str, count: int, suffix: str) -> str:
    remaining = count - len(prefix + suffix)
    return prefix + ("中文搜索性能 synthetic " * (remaining // 10 + 1))[:remaining] + suffix


def generate(root: Path, count: int, text_chars: int) -> dict:
    root.mkdir(parents=True, exist_ok=False)
    blobs = root / "blobs"
    files = root / "files"
    blobs.mkdir()
    files.mkdir()
    boards = [{"id": identifier("board-" + str(i)), "name": "Search Fixture " + str(i), "color": color}
              for i, color in enumerate(("蓝色", "橙色", "绿色"))]
    records, lengths, characters, markers = [], [], [], {}
    categories: Counter = Counter()

    def part(kind: str, data: bytes) -> dict:
        digest = hashlib.sha256(data).hexdigest()
        path = blobs / digest
        if not path.exists():
            path.write_bytes(data)
        return {"type": kind, "blob": digest, "size": len(data)}

    for index in range(count):
        slot = index % 20
        category = "text" if slot < 10 else "rich" if slot < 13 else "image" if slot < 16 else "link" if slot < 18 else "file"
        categories[category] += 1
        prefix = f"OpenPaste synthetic {index:05d} 中文 Emoji 🌟 café cafe\u0301 "
        suffix = f" tailmarker{index:05d}"
        size = 12_288 if slot in (8, 9) else 512
        text = sized_text(prefix, size, suffix) if not text_chars else character_text(prefix, text_chars, suffix)
        title = f"Synthetic {category} {index:05d}"
        kind = {"text": "文字", "rich": "文字", "image": "图片", "link": "链接", "file": "文件"}[category]
        payload = [part("public.utf8-plain-text", text.encode())]
        clip = {"id": identifier(str(index)), "created": BASE_DATE - index * 60,
                "source": "Fixture " + str(index % 7), "sourceID": "org.openpaste.fixture." + str(index % 7),
                "kind": kind, "title": title, "text": text, "parts": [],
                "boards": [boards[index % 3]["id"]] if index % 4 == 0 else []}
        if category == "rich":
            if slot == 10:
                rich = "{\\rtf1\\ansi{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs28\\b Synthetic rich " + str(index) + "\\b0 plain body}"
                payload.append(part("public.rtf", rich.encode()))
            else:
                rich = "<html><body><h2>" + html.escape(title) + "</h2><p style='color:blue'><b>" + html.escape(text) + "</b></p></body></html>"
                payload.append(part("public.html", rich.encode()))
        elif category == "image":
            payload = [part("public.png", png(index))]
            clip["ocrText"] = f"Synthetic OCR 你好世界 ocrmarker{index:05d}"
        elif category == "link":
            url = f"https://example.test/learning-web/{index}"
            if not text_chars:
                clip["text"] = url
                payload = [part("public.utf8-plain-text", url.encode())]
            payload.append(part("public.url", url.encode()))
            clip["linkTitle"] = f"Learning web linktitlemarker{index:05d}"
        elif category == "file":
            file = files / f"synthetic-{index:05d}.txt"
            file.write_text(f"Synthetic file fixture {index}\n")
            payload.append(part("public.file-url", file.as_uri().encode()))
        if index % 97 == 0:
            clip["userLabel"] = f"labelmarker{index:05d}"
        # An intentionally deep full-text marker and a reproducible GIF query.
        if index == count - 1:
            clip["text"] = (sized_text(prefix, size, " learning-web-deep-tail") if not text_chars else
                            character_text(prefix, text_chars, " learning-web-deep-tail"))
            payload = [p for p in payload if p["type"] != "public.utf8-plain-text"]
            payload.insert(0, part("public.utf8-plain-text", clip["text"].encode()))
            markers["learning-web-deep-tail"] = [clip["id"]]
        lengths.append(len(clip["text"].encode()))
        characters.append(len(clip["text"]))
        records.append({"clip": clip, "parts": [payload]})

    encoded = json.dumps({"version": 2, "clips": records, "boards": boards}, ensure_ascii=False, separators=(",", ":")).encode()
    (root / "history.json").write_bytes(encoded)
    ordered = sorted(lengths)
    manifest = {"generator": "make_search_fixtures.py", "synthetic_only": True, "seed": str(NAMESPACE),
                "items": count, "categories": dict(categories), "long_text_items": count // 10 if not text_chars else count,
                "text_characters_total": sum(characters), "text_characters_min": min(characters),
                "text_characters_max": max(characters), "text_bytes_total": sum(lengths), "text_bytes_p50": ordered[(count - 1) // 2],
                "text_bytes_p95": ordered[int((count - 1) * .95)], "text_bytes_max": max(lengths),
                "attachment_bytes_referenced": sum(part["size"] for row in records for group in row["parts"] for part in group),
                "blob_count": len(list(blobs.iterdir())),
                "blob_bytes_on_disk": sum(p.stat().st_size for p in blobs.iterdir()),
                "history_sha256": hashlib.sha256(encoded).hexdigest(), "expected_queries": markers}
    (root / "fixture-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, choices=(1000, 7500, 10000), default=10000)
    parser.add_argument("--text-chars", type=int, choices=(0, 4096), default=0)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--profile", type=uuid.UUID)
    args = parser.parse_args()
    if args.profile and args.output:
        parser.error("choose --profile or --output")
    if args.profile:
        profile = str(args.profile).upper()
        profile_root = REPO / "build" / "acceptance" / profile
        profile_root.mkdir(parents=True, exist_ok=False)
        (profile_root / ".openpaste-acceptance-profile").write_text(
            f"OpenPaste acceptance profile\nprofile={str(args.profile).lower()}\nroot={profile_root}\n")
        output = profile_root / "Application Support" / "OpenPaste"
    else:
        output = args.output
        if output is None:
            output = REPO / "build" / "search-performance" / "fixtures" / (f"mixed-{args.count}" + ("-4kchars" if args.text_chars else ""))
    output = output.absolute()
    allowed = (REPO / "build").resolve()
    if not output.resolve().is_relative_to(allowed):
        parser.error("fixture output must be inside this repository's build directory")
    manifest = generate(output, args.count, args.text_chars)
    print(json.dumps({"root": str(output), **manifest}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
