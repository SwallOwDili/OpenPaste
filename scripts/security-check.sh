#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
command -v gitleaks >/dev/null || { print -u2 "Install gitleaks before running security checks"; exit 1; }
# Scan tracked files and new non-ignored files. Ignored local credentials stay excluded.
scan_dir="$(mktemp -d)"
trap 'rm -rf "$scan_dir"' EXIT
python3 - "$scan_dir" <<'PYSEC'
import pathlib, shutil, subprocess, sys
root = pathlib.Path.cwd()
out = pathlib.Path(sys.argv[1])
for raw in subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z']).split(b'\0'):
    if not raw: continue
    p = root / raw.decode()
    if not p.exists(): continue
    if p.is_symlink(): raise SystemExit('Tracked symlink is not allowed in security scan')
    target = out / p.relative_to(root)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(p, target)
PYSEC
gitleaks dir "$scan_dir" --redact --no-banner --exit-code 1
# Also detect newly committed secrets that were removed again before the final tree.
base="${SECURITY_BASE:-$(git rev-parse --verify HEAD^ 2>/dev/null || true)}"
if [[ -n "$base" && "$base" != "0000000000000000000000000000000000000000" ]]; then
    [[ "$base" =~ '^[0-9a-f]{40}$' ]] || { print -u2 "Invalid security scan base"; exit 1; }
    git cat-file -e "${base}^{commit}"
    gitleaks git . --log-opts="${base}..HEAD" --redact --no-banner --exit-code 1
fi
python3 -m unittest discover -s Tests -p '*_security_test.py'
