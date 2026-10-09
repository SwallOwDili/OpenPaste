#!/usr/bin/env python3
"""Generate deterministic Paste SQLite fixtures for manual GUI import acceptance."""

from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import sqlite3
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]
OUTPUT_ROOT = REPO_ROOT / "build" / "acceptance-tools"
SMALL_DATABASE = OUTPUT_ROOT / "Paste-acceptance.sqlite"
STRESS_DATABASE = OUTPUT_ROOT / "Paste-stress-7500.sqlite"

SOURCE_NAME = "OpenPaste 验收专用"
SOURCE_BUNDLE_ID = "io.github.SwallOwDili.OpenPaste.acceptance.fixture"
TEXT_TYPE = "public.utf8-plain-text"

SCHEMA = """
CREATE TABLE ZITEMENTITY(
    Z_PK INTEGER PRIMARY KEY,
    ZTIMESTAMP REAL NOT NULL,
    ZTITLE TEXT NOT NULL,
    ZSOURCEAPPLICATION INTEGER NOT NULL,
    ZDATA INTEGER NOT NULL,
    ZLIST INTEGER NOT NULL
);
CREATE TABLE ZAPPLICATIONENTITY(
    Z_PK INTEGER PRIMARY KEY,
    ZNAME TEXT NOT NULL,
    ZBUNDLEIDENTIFIER TEXT NOT NULL
);
CREATE TABLE ZITEMDATAENTITY(
    Z_PK INTEGER PRIMARY KEY,
    ZRAWPASTEBOARDITEMS BLOB NOT NULL
);
CREATE TABLE ZLISTENTITY(
    Z_PK INTEGER PRIMARY KEY,
    ZNAME TEXT NOT NULL,
    ZIDENTIFIER TEXT NOT NULL,
    ZRAWTYPE INTEGER NOT NULL
);
"""


def paste_payload(text: str) -> bytes:
    encoded = base64.b64encode(text.encode("utf-8")).decode("ascii")
    value = [{"types": [TEXT_TYPE], "dataByType": {TEXT_TYPE: encoded}}]
    return b"\x01" + json.dumps(value, separators=(",", ":")).encode("utf-8")


def stress_text(index: int) -> str:
    prefix = f"OpenPaste 压力验收专用 #{index:04d}｜"
    body = "中文与 Emoji 🌟｜用于验证大量历史导入、搜索、筛选、滚动、重启持久化和唯一内容去重。｜"
    suffix = f"唯一尾标 {index:04d}"
    text = prefix + body + suffix
    if len(text) > 100:
        raise ValueError(f"stress fixture base text is too long: {len(text)}")
    return text + "验" * (100 - len(text))


def create_database(
    path: Path,
    rows: Iterable[tuple[int, float, str, str, int]],
    boards: list[tuple[int, str, str]],
) -> None:
    path.unlink(missing_ok=True)
    connection = sqlite3.connect(path)
    try:
        connection.execute("PRAGMA journal_mode=OFF")
        connection.execute("PRAGMA synchronous=OFF")
        connection.executescript(SCHEMA)
        connection.execute(
            "INSERT INTO ZAPPLICATIONENTITY VALUES(?,?,?)",
            (1, SOURCE_NAME, SOURCE_BUNDLE_ID),
        )
        connection.executemany(
            "INSERT INTO ZLISTENTITY VALUES(?,?,?,2)",
            boards,
        )
        for identifier, timestamp, title, text, board in rows:
            connection.execute(
                "INSERT INTO ZITEMENTITY VALUES(?,?,?,?,?,?)",
                (identifier, timestamp, title, 1, identifier, board),
            )
            connection.execute(
                "INSERT INTO ZITEMDATAENTITY VALUES(?,?)",
                (identifier, paste_payload(text)),
            )
        connection.commit()
    finally:
        connection.close()


def decode_payload(value: bytes) -> str:
    if not value.startswith(b"\x01["):
        raise AssertionError("payload must use Paste inline marker followed by JSON")
    items = json.loads(value[1:])
    if not isinstance(items, list) or len(items) != 1:
        raise AssertionError("payload must contain exactly one pasteboard item")
    item = items[0]
    if item.get("types") != [TEXT_TYPE]:
        raise AssertionError("fixture must contain only public.utf8-plain-text")
    encoded = item.get("dataByType", {}).get(TEXT_TYPE)
    if not isinstance(encoded, str):
        raise AssertionError("plain-text representation is missing")
    return base64.b64decode(encoded, validate=True).decode("utf-8")


def validate_database(
    path: Path,
    expected_rows: int,
    expected_boards: int,
    expected_texts: set[str] | None = None,
) -> dict[str, str | int]:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise AssertionError(f"SQLite integrity check failed: {integrity}")
        rows = connection.execute(
            """
            SELECT i.Z_PK,i.ZTIMESTAMP,i.ZTITLE,a.ZNAME,a.ZBUNDLEIDENTIFIER,
                   d.ZRAWPASTEBOARDITEMS,i.ZLIST
            FROM ZITEMENTITY i
            LEFT JOIN ZAPPLICATIONENTITY a ON a.Z_PK=i.ZSOURCEAPPLICATION
            LEFT JOIN ZITEMDATAENTITY d ON d.Z_PK=i.ZDATA
            ORDER BY i.ZTIMESTAMP DESC
            """
        ).fetchall()
        boards = connection.execute(
            "SELECT Z_PK,ZNAME,ZIDENTIFIER FROM ZLISTENTITY WHERE ZRAWTYPE=2"
        ).fetchall()
    finally:
        connection.close()

    if len(rows) != expected_rows:
        raise AssertionError(f"expected {expected_rows} items, found {len(rows)}")
    if len(boards) != expected_boards:
        raise AssertionError(f"expected {expected_boards} boards, found {len(boards)}")
    board_ids = {row[0] for row in boards}
    texts: list[str] = []
    for identifier, _, title, source, source_id, payload, board in rows:
        if not title or source != SOURCE_NAME or source_id != SOURCE_BUNDLE_ID:
            raise AssertionError(f"invalid metadata in item {identifier}")
        if board != 0 and board not in board_ids:
            raise AssertionError(f"item {identifier} references unknown board {board}")
        texts.append(decode_payload(payload))
    if len(set(texts)) != expected_rows:
        raise AssertionError("fixture text payloads are not unique")
    if expected_texts is not None and set(texts) != expected_texts:
        raise AssertionError("small fixture text payloads changed unexpectedly")
    if expected_rows == 7500 and any(len(text) != 100 for text in texts):
        raise AssertionError("every stress payload must contain exactly 100 characters")

    return {
        "path": str(path.relative_to(REPO_ROOT)),
        "items": len(rows),
        "boards": len(boards),
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def main() -> None:
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)

    small_texts = {
        "OpenPaste 验收专用 · 小样本 01 · 中文与 Emoji：你好，世界 🌏🧪",
        "OpenPaste 验收专用 · 小样本 02 · 去重辨识：第二条唯一内容 🚀",
    }
    small_rows = [
        (1, 800_000_002.0, "验收小样本 01 🌏", sorted(small_texts)[0], 1),
        (2, 800_000_001.0, "验收小样本 02 🚀", sorted(small_texts)[1], 0),
    ]
    create_database(
        SMALL_DATABASE,
        small_rows,
        [(1, "验收收藏 🧪", "openpaste-acceptance-board")],
    )

    stress_rows = (
        (
            index,
            800_100_000.0 - index,
            f"压力验收 #{index:04d}",
            stress_text(index),
            0 if index % 4 == 0 else (index % 3) + 1,
        )
        for index in range(1, 7501)
    )
    create_database(
        STRESS_DATABASE,
        stress_rows,
        [
            (1, "压力分组 A", "openpaste-stress-board-a"),
            (2, "压力分组 B", "openpaste-stress-board-b"),
            (3, "压力分组 C", "openpaste-stress-board-c"),
        ],
    )

    summaries = [
        validate_database(SMALL_DATABASE, 2, 1, small_texts),
        validate_database(STRESS_DATABASE, 7500, 3),
    ]
    print(json.dumps(summaries, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
