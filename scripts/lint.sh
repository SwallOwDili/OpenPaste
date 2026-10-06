#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swiftlint lint --strict --config .swiftlint.yml
actionlint .github/workflows/*.yml
for script in build.sh scripts/*.sh; do
    zsh -n "$script"
done
python3 - <<'PY'
import ast
from pathlib import Path
for folder in ('scripts', 'Tests'):
    for path in Path(folder).glob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
PY
for script in .github/scripts/*.cjs; do
    node --check "$script"
done
