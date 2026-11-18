from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SVG = ROOT / 'Assets/OpenPaste-menu-template.svg'
SOURCE = ROOT / 'Sources/MenuBarMark.swift'


class MenuBarMarkSourceTests(unittest.TestCase):
    def test_code_draws_the_path_of_the_shipped_template(self):
        svg = SVG.read_text(encoding='utf-8')
        swift = SOURCE.read_text(encoding='utf-8')
        svg_path = re.search(r'<path[^>]*\sd="([^"]+)"', svg)
        swift_path = re.search(r'static let pathData = "([^"]+)"', swift)
        self.assertIsNotNone(svg_path, 'the template SVG has no path')
        self.assertIsNotNone(swift_path, 'MenuBarMark.pathData is missing')
        self.assertEqual(svg_path.group(1), swift_path.group(1),
                         'MenuBarMark.pathData must be the d attribute of Assets/OpenPaste-menu-template.svg')

    def test_template_is_a_single_even_odd_solid_mark(self):
        svg = SVG.read_text(encoding='utf-8')
        self.assertIn('fill-rule="evenodd"', svg)
        self.assertIn('viewBox="0 0 18 18"', svg)
        self.assertEqual(len(re.findall(r'<path\b', svg)), 1)
        self.assertNotIn('gradient', svg.lower())


if __name__ == '__main__':
    unittest.main()
