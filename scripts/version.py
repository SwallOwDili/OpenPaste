#!/usr/bin/env python3
"""Validate release metadata before building; inject it before code signing."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent

def git_value(*args):
    try:
        return subprocess.check_output(['git', '-C', str(ROOT), *args], stderr=subprocess.DEVNULL, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return ''

def metadata():
    raw = os.environ.get('OPENPASTE_VERSION')
    if raw is not None:
        match = re.fullmatch(r'v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*))?', raw)
        if not match:
            raise ValueError('Release version must be MAJOR.MINOR.PATCH, optionally prefixed by v and followed by -prerelease')
        version = '.'.join(match.group(i) for i in (1, 2, 3))
        release = version + ('-' + match.group(4) if match.group(4) else '')
        source = 'release'
    else:
        commit = git_value('rev-parse', '--verify', 'HEAD')
        branch = git_value('symbolic-ref', '--short', 'HEAD')
        if not branch:
            branch = os.environ.get('GITHUB_HEAD_REF') or os.environ.get('GITHUB_REF_NAME') or 'detached'
        if re.fullmatch(r'[0-9a-f]{40,64}', commit):
            branch = re.sub(r'[\x00-\x1f\x7f]', '', branch) or 'detached'
            release, source = f'{branch}-{commit[:8]}', 'git'
        else:
            release, source = 'draft', 'draft'
        # macOS requires a numeric bundle version; the UI uses the display version.
        version = '0.0.0'
    # GitHub supplies the run number automatically; local builds use 1.
    build = os.environ.get('GITHUB_RUN_NUMBER', '1')
    if not re.fullmatch(r'[1-9]\d{0,8}', build):
        raise ValueError('GitHub run number must be a positive integer with at most 9 digits')
    return {'CFBundleShortVersionString': version, 'CFBundleVersion': build, 'OpenPasteReleaseVersion': release, 'OpenPasteVersionSource': source}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--plist', type=Path)
    args = parser.parse_args()
    try:
        values = metadata()
    except ValueError as error:
        parser.error(str(error))
    if args.plist:
        with args.plist.open('rb') as stream:
            info = plistlib.load(stream)
        info.update(values)
        with args.plist.open('wb') as stream:
            plistlib.dump(info, stream, sort_keys=False)
    print(values['OpenPasteReleaseVersion'])

if __name__ == '__main__':
    main()
