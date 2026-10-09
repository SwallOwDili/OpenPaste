#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

arch="${1:-$(uname -m)}"
[[ "$arch" == "arm64" || "$arch" == "x86_64" ]] || { print -u2 "Unsupported architecture: $arch"; exit 1; }

production_scratch="build/swiftpm-${arch}"
test_scratch="build/swiftpm-tests-${arch}"
if [[ -e "$test_scratch" || ! -d "$production_scratch" ]]; then
    exit 0
fi

mkdir -p build
clone_scratch="$(mktemp -d "build/.swiftpm-tests-${arch}.XXXXXX")"
cleanup() { [[ ! -d "$clone_scratch" ]] || rm -r "$clone_scratch"; }
trap cleanup EXIT
ditto --clone "$production_scratch" "$clone_scratch"
if [[ ! -e "$test_scratch" ]]; then
    mv "$clone_scratch" "$test_scratch"
fi
