# SPDX-License-Identifier: MIT
import importlib.util
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('patch_ui', ROOT / 'src/ui/patch_ui.py')
patcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(patcher)
BUNDLE = """Ext.define('Unrelated', { initComponent: function () { this.callParent(); } });
Ext.define('PVE.node.Config', {
    initComponent: function () {
        var me = this;
        var nodename = me.pveSelNode.data.node;
        var caps = Ext.state.Manager.get('GuiCap');
        me.items = [];
        me.callParent();
    },
});
Ext.define('Another', { initComponent: function () { this.callParent(); } });
"""
TEMPLATE = '''<head>
    <script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>
    <script>Ext.onReady(function() { Ext.create('PVE.StdWorkspace'); });</script>
</head>
'''
NODES = '''package PVE::API2::Nodes::Nodeinfo;
use base qw(PVE::RESTHandler);
1;
'''


class UiPatchTests(unittest.TestCase):
    def test_tab_is_scoped_to_node_and_uses_selected_name(self):
        result = patcher.patch_bundle(BUNDLE)
        section = result.split("Ext.define('PVE.node.Config', {", 1)[1].split("Ext.define('Another'", 1)[0]
        self.assertIn(patcher.TAB_BLOCK, section)
        self.assertIn("if (caps.nodes['Sys.Audit'])", section)
        self.assertIn('nodename: nodename', section)
        self.assertEqual(result.count(patcher.TAB_BLOCK), 1)

    def test_hooks_reinstall_and_remove_preserve_unrelated_edits(self):
        for fn, source in ((patcher.patch_bundle, BUNDLE), (patcher.patch_template, TEMPLATE)):
            with self.subTest(hook=fn.__name__):
                result = fn(source)
                self.assertEqual(fn(result), result)
                updated = result + '\n// unrelated package change\n'
                self.assertEqual(fn(updated, remove=True), source + '\n// unrelated package change\n')
                self.assertEqual(fn(source, remove=True), source)

    def test_loader_precedes_workspace_and_upgrades_cache_version(self):
        result = patcher.patch_template(TEMPLATE)
        self.assertLess(result.index('pve-sensors.js'), result.index('Ext.onReady'))
        self.assertGreater(result.index('pve-sensors.js'), result.index('pvemanagerlib.js'))
        previous = result.replace('v=2.1.0', 'v=2.0.1')
        self.assertEqual(patcher.patch_template(previous), result)
        self.assertEqual(patcher.patch_template(previous, remove=True), TEMPLATE)

    def test_incompatible_or_duplicate_hooks_are_rejected(self):
        for source in (BUNDLE.replace('me.callParent();', 'me.callParent(arguments);'),
                       BUNDLE + BUNDLE, BUNDLE.replace("me.items = [];", "me.items = [{xtype: 'pveNodeSensors'}];")):
            with self.subTest(source=source), self.assertRaises(ValueError):
                patcher.patch_bundle(source)
        for source in (TEMPLATE.replace('pvemanagerlib.js', 'future.js'), TEMPLATE + TEMPLATE):
            with self.subTest(source=source), self.assertRaises(ValueError):
                patcher.patch_template(source)

    def test_modified_blocks_are_not_removed(self):
        for fn, source, before, after in (
            (patcher.patch_bundle, BUNDLE, "title: 'Sensors'", "title: 'Custom'"),
            (patcher.patch_template, TEMPLATE, '/pve2/js/pve-sensors.js', '/custom.js'),
        ):
            changed = fn(source).replace(before, after)
            with self.subTest(hook=fn.__name__), self.assertRaises(ValueError):
                fn(changed, remove=True)


class InstallerMigrationTests(unittest.TestCase):
    def test_staging_failure_leaves_all_upstream_files_untouched(self):
        source = (ROOT / 'src/install.template.sh').read_text()
        helper = source[source.index('stage_patches() {'):source.index('put_patches() {')]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Nodes.pm').write_text(NODES)
            (root / 'pvemanagerlib.js').write_text(BUNDLE)
            (root / 'index.html.tpl').write_text('incompatible template')
            stage = root / 'stage'
            stage.mkdir()
            (stage / 'patch_nodes.py').write_text((ROOT / 'src/api/patch_nodes.py').read_text())
            (stage / 'patch_ui.py').write_text((ROOT / 'src/ui/patch_ui.py').read_text())
            script = f'''set -euo pipefail
WEB={shlex.quote(directory)}
NODES="$WEB/Nodes.pm" UI_BUNDLE="$WEB/pvemanagerlib.js" UI_TEMPLATE="$WEB/index.html.tpl"
UPSTREAM=("$NODES" "$UI_BUNDLE" "$UI_TEMPLATE")
STAGE="$WEB/stage"
die() {{ exit 1; }}
{helper}
stage_patches
'''
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unsupported index.html.tpl', result.stderr)
            self.assertEqual((root / 'Nodes.pm').read_text(), NODES)
            self.assertEqual((root / 'pvemanagerlib.js').read_text(), BUNDLE)
            self.assertEqual((root / 'index.html.tpl').read_text(), 'incompatible template')

    def test_clean_v1_and_v2_migration_then_uninstall_preserve_unrelated_code(self):
        source = (ROOT / 'src/install.template.sh').read_text()
        helpers = source[source.index('backup_files() {'):source.index('trap cleanup EXIT')]
        helpers += source[source.index('put_file() {'):source.index('if [[ "$MODE" == uninstall ]]; then')]
        uninstall = source[source.index('if [[ "$MODE" == uninstall ]]; then'):source.index("say 'Sensor data requires")]
        for upgrade in (None, '1.0.0', '2.0.0'):
            with self.subTest(upgrade=upgrade), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                nodes = root / 'Nodes.pm'
                bundle = root / 'pvemanagerlib.js'
                template = root / 'index.html.tpl'
                nodes.write_text(NODES)
                bundle.write_text(BUNDLE)
                template.write_text(TEMPLATE)
                if upgrade:
                    (root / 'installed-version').write_text(upgrade)
                    (root / 'agent.py').write_text('previous collector')
                    (root / 'pve-sensors.html').write_text('old standalone page')
                    (root / 'pve-sensors.json').symlink_to(root / 'metrics.json')
                stage = root / 'stage'
                stage.mkdir()
                (stage / 'patch_nodes.py').write_text((ROOT / 'src/api/patch_nodes.py').read_text())
                (stage / 'patch_ui.py').write_text((ROOT / 'src/ui/patch_ui.py').read_text())
                functions = helpers.replace('/var/backups/pve-sensors', str(root / 'backups'))
                # Run actual stage/backup/write helpers, then the real uninstall
                # branch. All paths and service operations are temporary/stubbed.
                script = f'''set -euo pipefail
WEB={shlex.quote(directory)}
NODES="$WEB/Nodes.pm" UI_BUNDLE="$WEB/pvemanagerlib.js" UI_TEMPLATE="$WEB/index.html.tpl"
UPSTREAM=("$NODES" "$UI_BUNDLE" "$UI_TEMPLATE")
MARKER="$WEB/installed-version" SERVICE=pve-sensors.service
FILES=("$WEB/agent.py" "$MARKER")
STAGE="$WEB/stage" OLD_ACTIVE=no OLD_ENABLED=no CHANGED=no COMMITTED=no
say() {{ :; }}
die() {{ exit 1; }}
confirm() {{ :; }}
systemctl() {{ printf '%s\\n' "$*" >> "$WEB/services.log"; return 0; }}
{functions}
trap cleanup EXIT
rm -f -- "$WEB/pve-sensors.json" "$WEB/pve-sensors.html"
stage_patches
backup_files
CHANGED=yes
put_patches
printf installed > "$WEB/agent.py"
printf 2.1.0 > "$MARKER"
COMMITTED=yes
# Simulate unrelated edits made after installation.
printf '\n# unrelated edit\n' >> "$NODES"
printf '\\n// unrelated edit\\n' >> "$UI_BUNDLE"
printf '\\n<!-- unrelated edit -->\\n' >> "$UI_TEMPLATE"
MODE=uninstall
COMMITTED=no
{uninstall}
'''
                result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(nodes.read_text(), NODES + '\n# unrelated edit\n')
                self.assertEqual(bundle.read_text(), BUNDLE + '\n// unrelated edit\n')
                self.assertEqual(template.read_text(), TEMPLATE + '\n<!-- unrelated edit -->\n')
                for name in ('agent.py', 'installed-version', 'pve-sensors.html', 'pve-sensors.json'):
                    self.assertFalse((root / name).exists())
                    self.assertFalse((root / name).is_symlink())
                actions = (root / 'services.log').read_text().splitlines()
                self.assertTrue(all(line in {
                    'is-active --quiet pve-sensors.service',
                    'is-enabled --quiet pve-sensors.service',
                    'disable --now pve-sensors.service',
                    'reload pvedaemon pveproxy', 'daemon-reload',
                    'reset-failed pve-sensors.service',
                } for line in actions), actions)
