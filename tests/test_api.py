# SPDX-License-Identifier: MIT
import importlib.util
import subprocess
import tempfile
import shlex
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('patch_nodes', ROOT / 'src/api/patch_nodes.py')
patcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(patcher)
NODES = '''package PVE::API2::Nodes::Nodeinfo;
use strict;
use base qw(PVE::RESTHandler);
# Node methods
package PVE::API2::Nodes;
use base qw(PVE::RESTHandler);
1;
'''


class ApiTests(unittest.TestCase):
    def test_handler(self):
        result = subprocess.run(['perl', 'tests/test_api.pl'], cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_registration_is_in_nodeinfo_only(self):
        patched = patcher.patch(NODES)
        self.assertEqual(patched.count(patcher.BLOCK), 1)
        self.assertLess(patched.index(patcher.BLOCK), patched.index('package PVE::API2::Nodes;'))

    def test_reinstall_and_remove_preserve_unrelated_changes(self):
        patched = patcher.patch(NODES)
        self.assertEqual(patcher.patch(patched), patched)
        updated = patched.replace('# Node methods', '# Updated by upstream')
        self.assertEqual(patcher.patch(updated, remove=True), NODES.replace('# Node methods', '# Updated by upstream'))
        self.assertEqual(patcher.patch(NODES, remove=True), NODES)

    def test_incompatible_upstream_is_rejected(self):
        for source in (NODES.replace('use base', 'use parent'),
                       NODES.replace('Nodeinfo', 'DifferentPackage'),
                       NODES.replace('# Node methods', "__PACKAGE__->register_method({path => 'sensors'});")):
            with self.subTest(source=source), self.assertRaises(ValueError):
                patcher.patch(source)

    def test_modified_marker_block_is_rejected(self):
        patched = patcher.patch(NODES)
        for source in (patched.replace(patcher.END, ''), patched + patcher.BLOCK,
                       patched.replace("path => 'sensors'", "path => 'custom'")):
            with self.subTest(source=source), self.assertRaises(ValueError):
                patcher.patch(source)


if __name__ == '__main__':
    unittest.main()


class MigrationTests(unittest.TestCase):
    def test_failed_upgrade_restores_files_but_never_public_json(self):
        source = (ROOT / 'src/install.template.sh').read_text()
        functions = source[source.index('backup_files() {'):source.index('trap cleanup EXIT')]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            nodes = root / 'Nodes.pm'
            agent = root / 'agent.py'
            bundle = root / 'pvemanagerlib.js'
            template = root / 'index.html.tpl'
            bundle.write_text('original bundle')
            template.write_text('original template')
            nodes.write_text(NODES)
            agent.write_text('old agent')
            (root / 'pve-sensors.json').symlink_to(root / 'metrics.json')
            (root / 'pve-sensors.html').write_text('old public page')
            functions = functions.replace('/var/backups/pve-sensors', str(root / 'backups'))
            script = f"""set -euo pipefail
WEB={shlex.quote(directory)}
NODES="$WEB/Nodes.pm"
UI_BUNDLE="$WEB/pvemanagerlib.js" UI_TEMPLATE="$WEB/index.html.tpl"
UPSTREAM=("$NODES" "$UI_BUNDLE" "$UI_TEMPLATE")
SERVICE=pve-sensors.service
FILES=("$WEB/agent.py")
OLD_ACTIVE=no OLD_ENABLED=no CHANGED=no COMMITTED=no STAGE=
say() {{ :; }}
die() {{ exit 1; }}
systemctl() {{ return 0; }}
{functions}
backup_files
CHANGED=yes
printf changed > "$NODES"
printf changed > "$UI_BUNDLE"
printf changed > "$UI_TEMPLATE"
printf changed > "$WEB/agent.py"
trap cleanup EXIT
exit 17
"""
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
            self.assertEqual(result.returncode, 17, result.stderr)
            self.assertEqual(nodes.read_text(), NODES)
            self.assertEqual(bundle.read_text(), 'original bundle')
            self.assertEqual(template.read_text(), 'original template')
            self.assertEqual(agent.read_text(), 'old agent')
            self.assertFalse((root / 'pve-sensors.json').is_symlink())
            self.assertFalse((root / 'pve-sensors.html').exists())

    def test_incompatible_upgrade_revokes_public_link_before_patch_failure(self):
        source = (ROOT / 'src/install.template.sh').read_text()
        helper_start = source.index('stage_patches() {')
        helpers = source[helper_start:source.index('put_patches() {')]
        start = source.index("# Revocation is intentionally")
        end = source.index('if [[ ! -e "$MARKER" ]]', start)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Nodes.pm').write_text('unsupported upstream')
            (root / 'pve-sensors.json').symlink_to(root / 'metrics.json')
            (root / 'pve-sensors.html').write_text('old public page')
            # The patcher writes only on success, so use a separate stage.
            stage = root / 'stage'
            stage.mkdir()
            (stage / 'patch_nodes.py').write_text((ROOT / 'src/api/patch_nodes.py').read_text())
            script = f"""set -euo pipefail
WEB={shlex.quote(directory)}
NODES="$WEB/Nodes.pm"
UI_BUNDLE="$NODES" UI_TEMPLATE="$NODES"
UPSTREAM=("$NODES")
STAGE="$WEB/stage"
die() {{ exit 1; }}
{helpers}
{source[start:end]}
"""
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unsupported Nodes.pm', result.stderr)
            self.assertEqual((root / 'Nodes.pm').read_text(), 'unsupported upstream')
            self.assertFalse((root / 'pve-sensors.json').is_symlink())
            self.assertFalse((root / 'pve-sensors.html').exists())
