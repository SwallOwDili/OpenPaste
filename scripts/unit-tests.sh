#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
python3 Tests/version-test.py
python3 -m unittest discover -s Tests -p '*_unit_test.py'
# Compile the test executable without assembling, signing, or packaging an App.
arch="$(uname -m)"
scratch="build/swiftpm-tests-${arch}"
scripts/prepare-test-scratch.sh "$arch"
OPENPASTE_TESTING=1 swift build --manifest-cache none -c release --triple "${arch}-apple-macosx14.0" --scratch-path "$scratch" --product OpenPaste
bin_dir="$(OPENPASTE_TESTING=1 swift build --manifest-cache none -c release --triple "${arch}-apple-macosx14.0" --scratch-path "$scratch" --show-bin-path)"
app="$bin_dir/OpenPaste"
for check in --maintenance-test --update-test --self-test --code-style-test --data-directory-test --paste-import-unit-test --shortcut-model-test --recording-pause-test --storage-recovery-test --permission-monitor-test --interaction-policy-test --content-editing-test --capture-boundary-test --filter-test --paste-queue-test --clipboard-write-test --current-clipboard-test --preview-cache-test --navigation-test --drag-provider-test --translation-config-test; do
    "$app" "$check"
done
# Translation checks use fake credentials and a localhost fixture, never your API.
python3 Tests/translation-mock.py &
mock_pid=$!
trap 'kill "$mock_pid" 2>/dev/null || true' EXIT
for attempt in {1..30}; do
    kill -0 "$mock_pid"
    if python3 -c 'import socket; socket.create_connection(("127.0.0.1",18767),timeout=1).close()' 2>/dev/null; then break; fi
    sleep 1
done
lsof -nP -iTCP:18767 -sTCP:LISTEN
kill -0 "$mock_pid"
fixture_key="fixture-key"
curl --noproxy "*" --fail --silent --show-error --max-time 5 -H "Authorization: Bearer $fixture_key" -H "Content-Type: application/json" --data '{"model":"fixture-model","messages":[{}, {"content":"Hello\n    world"}]}' http://127.0.0.1:18767/v1/chat/completions >/dev/null
"$app" --translation-test
