import tempfile
import unittest
from pathlib import Path

from validate_identity_boundary import clang_import_flags


class ClangImportFlagsTests(unittest.TestCase):
    def test_both_build_layouts_and_source_headers_are_discovered(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkouts = root / 'checkouts'
            include = checkouts / 'dependency' / 'Sources' / '_Shims' / 'include'
            include.mkdir(parents=True)
            (include / 'shim.h').write_text('')
            native = root / 'arm64-debug' / 'CNative.build'
            xcode = root / 'out' / 'Intermediates.noindex' / 'GeneratedModuleMaps'
            for directory, name in [(native, 'CNative'), (xcode, 'CXcode')]:
                directory.mkdir(parents=True)
                (directory / (name + '.modulemap')).write_text(
                    'module ' + name + ' { umbrella "' + str(include) + '" export * }')
            flags = clang_import_flags(root, checkouts)
            self.assertIn(str(include.resolve()), flags)
            for directory, name in [(native, 'CNative'), (xcode, 'CXcode')]:
                self.assertIn('-fmodule-map-file=' + str((directory / (name + '.modulemap')).resolve()), flags)

    def test_missing_and_swift_compatibility_maps_are_excluded_and_duplicates_collapsed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'valid.h').write_text('')
            for name, body in {
                'a.modulemap': 'module CValid { header "valid.h" export * }',
                'b.modulemap': 'module CValid { header "valid.h" export * }',
                'missing.modulemap': 'module Missing { header "missing.h" export * }',
                'swift.modulemap': 'module SwiftCompat { header "Compat-Swift.h" export * }',
            }.items():
                (root / name).write_text(body)
            flags = clang_import_flags(root, root / 'checkouts')
            self.assertEqual(flags, ['-Xcc', '-fmodule-map-file=' + str((root / 'a.modulemap').resolve())])


if __name__ == '__main__':
    unittest.main()
