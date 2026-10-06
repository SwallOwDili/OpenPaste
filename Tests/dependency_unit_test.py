import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('dependency_scan', Path(__file__).resolve().parents[1] / 'scripts/dependency-scan.py')
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)

class DependencyTests(unittest.TestCase):
    def test_locked_url_normalization(self):
        self.assertEqual(scanner.package_query({'location': 'https://github.com/apple/swift-protobuf.git', 'state': {'version': '1.2.3'}}), ('github.com/apple/swift-protobuf', '1.2.3'))
        with self.assertRaises(ValueError):
            scanner.package_query({'location': 'https://github.com/apple/swift-protobuf.git', 'state': {'revision': 'abc'}})

    def test_all_dependencies_and_blocking_severities(self):
        pins = [{'location': 'https://github.com/example/' + n, 'state': {'version': '1.0.0'}} for n in ('a', 'b')]
        seen = []
        def query(name, version):
            seen.append(name)
            return [{'ghsa_id': 'fixture-high', 'severity': 'high'}, {'ghsa_id': 'fixture-medium', 'severity': 'medium'}, {'ghsa_id': 'withdrawn', 'severity': 'critical', 'withdrawn_at': '2026-01-01'}]
        self.assertEqual(scanner.scan(pins, query), ['fixture-high', 'fixture-high'])
        self.assertEqual(len(seen), 2)
        with self.assertRaises(ValueError):
            scanner.scan([], query)
        with self.assertRaises(RuntimeError):
            scanner.scan(pins, lambda *args: (_ for _ in ()).throw(RuntimeError('network failed')))
