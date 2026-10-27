#!/usr/bin/env python3
"""Build/run isolated same-module Store benchmarks using existing SwiftPM dependencies.

--prepare copies source snapshots and records commands but does not compile/run.
--compile is kept separate so callers can wait for other build/check work to end.
--run runs all four synthetic datasets sequentially, three fresh processes each.
No app windows, clipboard writes, personal history reads, or network requests.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / "build" / "search-performance" / "benchmarks"
SCRATCH = REPO / "build" / "swiftpm-tests-arm64"
RELEASE = SCRATCH / "arm64-apple-macosx" / "release"


def prepare() -> None:
    description = json.loads((RELEASE / "description.json").read_text())
    command = next(value for key, value in description["swiftCommands"].items() if "OpenPaste" in key)
    compiler_args = list(command["otherArguments"])
    # Same optimization and dependency imports; use one WMO output object and an
    # isolated module cache. Keep the SPM entry-point symbol for its linker alias.
    compiler_args[compiler_args.index("-num-threads") + 1] = "0"
    compiler_args.remove("-serialize-diagnostics")
    compiler_args.remove("-parseable-output")
    lines = (SCRATCH / "release.yaml").read_text().splitlines()
    index = next(i for i, line in enumerate(lines) if "description:" in line and "Linking" in line and "OpenPaste" in line)
    link = json.loads(lines[index + 1].split("args: ", 1)[1])
    original_objects = (RELEASE / "OpenPaste.product" / "Objects.LinkFileList").read_text().splitlines()
    dependency_objects = [path for path in original_objects if "/OpenPaste.build/" not in path]
    for variant in ("baseline", "candidate"):
        destination = ROOT / variant
        sources = destination / "Sources"
        sources.mkdir(parents=True, exist_ok=True)
        source_root = (REPO / "build" / "search-performance" / "baseline" if variant == "baseline" else REPO) / "Sources"
        source_hashes = {}
        for path in sorted(source_root.glob("*.swift")):
            source_hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
            shutil.copy2(path, sources / path.name)
        main = sources / "main.swift"
        source = main.read_text()
        marker = '#if OPENPASTE_TESTING\nif CommandLine.arguments.contains("--interaction-policy-test")'
        if source.count(marker) != 1:
            raise RuntimeError("cannot find unique terminal dispatcher boundary")
        prefix, dispatch_and_tail = source.split(marker)
        dispatcher_end = dispatch_and_tail.index("\n#endif") + len("\n#endif")
        main.write_text(prefix + "\nTask { @MainActor in await runStoreSearchBenchmark(); exit(0) }\nRunLoop.main.run()\n" +
                        dispatch_and_tail[dispatcher_end:])
        shutil.copy2(REPO / "Tests" / "Support" / "SearchStoreBenchmark.swift", sources / "SearchStoreBenchmark.swift")
        args = list(compiler_args)
        args[args.index("-module-cache-path") + 1] = str(destination / "ModuleCache")
        if variant == "baseline":
            args.append("-DSEARCH_BASELINE")
        compile_command = [command["executable"], "-module-name", "OpenPaste", "-I", command["importPath"],
                           *args, "-c", *map(str, sorted(sources.glob("*.swift"))), "-o", str(destination / "OpenPasteBenchmark.o")]
        objects = destination / "Objects.LinkFileList"
        objects.write_text("\n".join(dependency_objects + [str(destination / "OpenPasteBenchmark.o")]) + "\n")
        link_command = list(link)
        link_command[link_command.index("-o") + 1] = str(destination / "OpenPasteBenchmark")
        link_command = ["@" + str(objects) if value.startswith("@") and value.endswith("Objects.LinkFileList") else value for value in link_command]
        manifest = {"variant": variant, "production_source_sha256": source_hashes,
                    "instrumentation": "only terminal dispatcher replaced; SearchStoreBenchmark.swift added",
                    "compile": compile_command, "link": link_command}
        (destination / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print("prepared", variant, len(source_hashes), "source files", flush=True)


def compile_benchmarks() -> None:
    for variant in ("baseline", "candidate"):
        destination = ROOT / variant
        manifest = json.loads((destination / "build-manifest.json").read_text())
        with (destination / "compile.log").open("w") as log:
            subprocess.run(manifest["compile"], cwd=REPO, stdout=log, stderr=subprocess.STDOUT, check=True)
            subprocess.run(manifest["link"], cwd=REPO, stdout=log, stderr=subprocess.STDOUT, check=True)
        binary = destination / "OpenPasteBenchmark"
        (destination / "binary.sha256").write_text(hashlib.sha256(binary.read_bytes()).hexdigest() + "\n")
        print("compiled", variant, flush=True)


def run_benchmarks() -> None:
    datasets = ["mixed-1000", "mixed-7500", "mixed-10000", "mixed-10000-4kchars"]
    for dataset in datasets:
        for repetition in range(1, 4):
            # Alternate order across repetitions, never run two at the same time.
            variants = ("baseline", "candidate") if repetition % 2 else ("candidate", "baseline")
            for variant in variants:
                destination = ROOT / variant
                output = destination / f"{dataset}-run{repetition}.jsonl"
                with output.open("w") as log:
                    subprocess.run(["/usr/bin/time", "-l", str(destination / "OpenPasteBenchmark"), str(REPO / "build" / "search-performance" / "fixtures" / dataset)],
                                   cwd=REPO, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
                print("measured", dataset, repetition, variant, flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--compile", action="store_true")
    parser.add_argument("--run", action="store_true")
    args = parser.parse_args()
    if args.prepare:
        prepare()
    if args.compile:
        compile_benchmarks()
    if args.run:
        run_benchmarks()
