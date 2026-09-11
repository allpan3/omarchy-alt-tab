"""Exercise the installer against temporary configs and the real xremap parser."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
ORIGINAL = '# Keep my comments\nkeymap:\n  - name: Personal\n    remap:\n      Control_L-J: Down\n'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copy(ROOT / 'apply-binds.sh', self.root)
        (self.root / 'manifest.json').write_text(json.dumps({'id': 'example.switcher'}))
        self.config = self.root / 'config.yml'
        self.config.write_text(ORIGINAL)
        self.config.chmod(0o640)

    def run_installer(self, *args, ok=True):
        result = subprocess.run(['bash', str(self.root / 'apply-binds.sh'), '--config', str(self.config), *args],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_preview_changes_nothing(self):
        output = self.run_installer()
        self.assertIn('Alt-Tab', output)
        self.assertEqual(self.config.read_text(), ORIGINAL)
        self.assertFalse(list(self.root.glob('config.yml.before-*')))

    def test_install_backup_permissions_and_remove(self):
        self.run_installer('--apply')
        data = yaml.safe_load(self.config.read_text())
        rules = data['keymap'][0]['remap']
        self.assertEqual(len(rules), 4)
        self.assertEqual(rules['Alt-Tab']['launch'][3], 'example.switcher')
        self.assertEqual(json.loads(rules['Alt-Shift-Grave']['launch'][4]),
                         {'modifier': 'alt', 'mode': 'sameclass', 'dir': 'prev'})
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
        self.assertEqual(next(self.root.glob('config.yml.before-*')).read_text(), ORIGINAL)
        installed = self.config.read_text()
        self.run_installer('--remove')
        self.assertEqual(self.config.read_text(), installed)
        self.run_installer('--remove', '--apply')
        self.assertEqual(self.config.read_text(), ORIGINAL)

    def test_right_control_and_manual_edits_survive_reinstall(self):
        self.run_installer('--modifier', 'Control_R', '--apply')
        edited = self.config.read_text().replace('Control_R-Tab:', 'Control_R-F1:')
        self.config.write_text(edited)
        self.run_installer('--apply')
        self.assertEqual(self.config.read_text(), edited)
        rules = yaml.safe_load(edited)['keymap'][0]['remap']
        self.assertEqual(json.loads(rules['Control_R-F1']['launch'][4])['modifier'], 'ctrl')

    def test_unmarked_existing_shortcuts_are_not_adopted_or_removed(self):
        for combo in ('Alt-Tab', 'Alt_L-Tab', 'Alt_R-Shift-Grave'):
            text = ORIGINAL + f'      {combo}: Enter\n'
            self.config.write_text(text)
            self.run_installer('--apply', ok=False)
            self.run_installer('--remove', '--apply')
            self.assertEqual(self.config.read_text(), text)

    def test_bad_markers_and_invalid_xremap_never_write(self):
        begin, end = '  # BEGIN example.switcher\n', '  # END example.switcher\n'
        for text in (ORIGINAL + begin, ORIGINAL + end + begin,
                     ORIGINAL + begin + end + begin + end,
                     ORIGINAL.replace('Down', 'DefinitelyNotAnXremapKey')):
            self.config.write_text(text)
            self.run_installer('--apply', ok=False)
            self.assertEqual(self.config.read_text(), text)
        self.assertFalse(list(self.root.glob('config.yml.before-*')))

    def test_dotfile_symlink_is_preserved(self):
        target = self.root / 'dotfile.yml'
        self.config.rename(target)
        self.config.symlink_to(target)
        self.run_installer('--apply')
        self.assertTrue(self.config.is_symlink())
        self.run_installer('--remove', '--apply')
        self.assertEqual(target.read_text(), ORIGINAL)


if __name__ == '__main__':
    unittest.main()
