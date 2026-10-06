#!/usr/bin/env python3
"""Check all locked Swift packages against GitHub's public advisory database."""
import json
from pathlib import Path
import subprocess
from urllib.parse import urlparse, urlencode


def package_query(pin):
    location = urlparse(pin['location'])
    version = pin['state'].get('version')
    if location.scheme != 'https' or location.hostname != 'github.com' or not version:
        raise ValueError('Dependency must have a GitHub HTTPS URL and locked version')
    name = 'github.com/' + location.path.strip('/').removesuffix('.git')
    return name, version


def scan(pins, query):
    if not pins:
        raise ValueError('No locked dependencies found')
    blockers = []
    for pin in pins:
        name, version = package_query(pin)
        advisories = query(name, version)
        if not isinstance(advisories, list):
            raise ValueError('Invalid advisory response')
        for advisory in advisories:
            if advisory.get('withdrawn_at'):
                continue
            severity = advisory['severity']
            print(f"{name}@{version}: {advisory['ghsa_id']} ({severity})")
            if severity in ('high', 'critical'):
                blockers.append(advisory['ghsa_id'])
    return blockers


def github_query(name, version):
    params = urlencode({'ecosystem': 'swift', 'affects': name + '@' + version, 'per_page': 100})
    advisories = []
    for page in range(1, 101):
        result = subprocess.run(['gh', 'api', 'advisories?' + params + '&page=' + str(page)],
                                check=True, capture_output=True, text=True)
        entries = json.loads(result.stdout)
        if not isinstance(entries, list):
            raise ValueError('Invalid advisory response')
        advisories.extend(entries)
        if len(entries) < 100:
            return advisories
    raise ValueError('Advisory pagination limit exceeded')


if __name__ == '__main__':
    try:
        pins = json.loads(Path('Package.resolved').read_text())['pins']
        blockers = scan(pins, github_query)
        if blockers:
            raise SystemExit('Blocking dependency vulnerabilities: ' + ', '.join(sorted(set(blockers))))
        print(f'Dependency scan passed: {len(pins)} locked Swift packages, no high/critical advisories.')
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit('Dependency scan failed: ' + str(error)) from error
