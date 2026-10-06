#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
python3 Tests/version-test.py
mkdir -p build
app="build/OpenPaste.app/Contents/MacOS/OpenPaste"
[[ -x "$app" ]] || ./build.sh
python3 Tests/analytics-config-test.py
python3 - <<'CHECK_ID'
import plistlib
with open('build/OpenPaste.app/Contents/Info.plist', 'rb') as stream:
    assert plistlib.load(stream)['CFBundleIdentifier'] == 'io.github.SwallOwDili.OpenPaste'
CHECK_ID
for check in --update-test --self-test --code-style-test --data-directory-test --paste-import-unit-test --shortcut-model-test; do
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
