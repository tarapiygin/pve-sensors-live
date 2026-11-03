#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply/remove the two small native UI hooks without touching unrelated code."""
import argparse
import re
from pathlib import Path

TAB_BEGIN = '        // BEGIN PVE SENSORS LIVE TAB\n'
TAB_END = '        // END PVE SENSORS LIVE TAB\n'
TAB_BLOCK = TAB_BEGIN + '''        if (caps.nodes['Sys.Audit']) {
            me.items.push({
                xtype: 'pveNodeSensors',
                title: 'Sensors',
                iconCls: 'fa fa-thermometer-half',
                itemId: 'pve-sensors',
                nodename: nodename,
            });
        }
''' + TAB_END
LOAD_BEGIN = '    <!-- BEGIN PVE SENSORS LIVE ASSETS -->\n'
LOAD_END = '    <!-- END PVE SENSORS LIVE ASSETS -->\n'
LOAD_BLOCK = LOAD_BEGIN + '    <script type="text/javascript" src="/pve2/js/pve-sensors.js?v=2.1.0"></script>\n' + LOAD_END


def strip_block(text, begin, end, block):
    if begin in text or end in text:
        if text.count(begin) != 1 or text.count(end) != 1 or block not in text:
            raise ValueError('Changed Sensors UI registration; review the marked block manually')
        return text.replace(block, '', 1)
    return text


def patch_bundle(text, remove=False):
    text = strip_block(text, TAB_BEGIN, TAB_END, TAB_BLOCK)
    if remove:
        return text
    header = "Ext.define('PVE.node.Config', {"
    if text.count(header) != 1:
        raise ValueError('Unsupported pvemanagerlib.js: node Config class not found uniquely')
    start = text.index(header)
    next_class = re.search(r'\nExt\.define\(', text[start + len(header):])
    end = start + len(header) + next_class.start() if next_class else len(text)
    section = text[start:end]
    anchor = '        me.callParent();\n'
    if section.count(anchor) != 1 or "var caps = Ext.state.Manager.get('GuiCap');" not in section:
        raise ValueError('Unsupported node Config: tab registration anchor changed')
    if 'pveNodeSensors' in section or "itemId: 'pve-sensors'" in section:
        raise ValueError('Sensors tab already registered outside the managed block')
    return text[:start] + section.replace(anchor, TAB_BLOCK + anchor, 1) + text[end:]


def patch_template(text, remove=False):
    # Only the cache version may differ between supported project releases.
    if LOAD_BEGIN in text or LOAD_END in text:
        loader = re.compile(re.escape(LOAD_BEGIN) +
                            r'    <script type="text/javascript" src="/pve2/js/pve-sensors\.js\?v=[0-9]+\.[0-9]+\.[0-9]+"></script>\n' +
                            re.escape(LOAD_END))
        blocks = loader.findall(text)
        if len(blocks) != 1:
            raise ValueError('Changed Sensors UI loader; review the marked block manually')
        text = strip_block(text, LOAD_BEGIN, LOAD_END, blocks[0])
    if remove:
        return text
    anchor = re.compile(r'^    <script type="text/javascript" src="/pve2/js/pvemanagerlib\.js\?ver=\[% version %\]"></script>\n', re.M)
    matches = list(anchor.finditer(text))
    if len(matches) != 1 or '/pve2/js/pve-sensors.js' in text:
        raise ValueError('Unsupported index.html.tpl: script anchor changed or duplicate Sensors loader')
    offset = matches[0].end()
    return text[:offset] + LOAD_BLOCK + text[offset:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=('bundle', 'template'))
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--remove', action='store_true')
    args = parser.parse_args()
    try:
        fn = patch_bundle if args.kind == 'bundle' else patch_template
        result = fn(args.source.read_text(), args.remove)
    except ValueError as exc:
        parser.exit(1, f'{exc}\n')
    args.destination.write_text(result)


if __name__ == '__main__':
    main()
