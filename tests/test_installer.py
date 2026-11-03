# SPDX-License-Identifier: MIT
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("builder", ROOT / "tools/build_installer.py")
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class InstallerTests(unittest.TestCase):
    def test_payload_is_reproducible(self):
        self.assertEqual((ROOT / "install.sh").read_text(), builder.build())

    def test_shell_syntax(self):
        subprocess.run(["bash", "-n", str(ROOT / "install.sh")], check=True)

    def test_help(self):
        result = subprocess.run(["bash", str(ROOT / "install.sh"), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--accept-public-data", result.stdout)

    def test_extract_matches_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "extracted"
            subprocess.run(["bash", str(ROOT / "install.sh"), "--extract", str(destination)],
                           check=True, capture_output=True)
            for source, name in builder.FILES:
                self.assertEqual((ROOT / source).read_bytes(), (destination / name).read_bytes())

    def test_extract_refuses_existing_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["bash", str(ROOT / "install.sh"), "--extract", directory],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_unknown_argument_fails(self):
        result = subprocess.run(["bash", str(ROOT / "install.sh"), "--unknown"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_no_user_specific_absolute_runuser_path(self):
        text = (ROOT / "src/install.template.sh").read_text()
        self.assertIn('RUNUSER=$(command -v runuser)', text)
        self.assertNotIn('/usr/bin/runuser', text)

    def test_apt_guards(self):
        text = (ROOT / "src/install.template.sh").read_text()
        self.assertIn('apt-get install --yes --no-remove --no-install-recommends lm-sensors', text)
        self.assertNotIn('apt-get install -f', text)
        self.assertNotIn('systemctl restart pveproxy', text)


if __name__ == "__main__":
    unittest.main()
