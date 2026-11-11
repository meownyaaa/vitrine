#!/usr/bin/env python3
"""IPA helpers for scripts/mirage-build.sh, in plain Python so the build runs on Linux too.

  mirage-ipa.py info <ipa>                         -> "<Payload/X.app/> <CFBundleShortVersionString>", fails if encrypted
  mirage-ipa.py extract-plist <ipa> <out.plist>
  mirage-ipa.py overlay <ipa> <liquid-glass.plist> <out.plist>
  mirage-ipa.py finish <ipa> <Payload/X.app/> <insert-dylib.py> [--icons DIR]
  mirage-ipa.py verify <ipa>
"""
import io, os, plistlib, re, shutil, struct, subprocess, sys, tempfile, zipfile

LC_REQ_DYLD = 0x80000000
LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_ENCRYPTION_INFO_64 = 0xC, 0x18 | LC_REQ_DYLD, 0x2C
LC_RPATH = 0x1C | LC_REQ_DYLD


def app_dir(z):
    for n in z.namelist():
        m = re.match(r'(Payload/[^/]+\.app/)Info\.plist$', n)
        if m:
            return m.group(1)
    sys.exit('no Payload/*.app/Info.plist in the IPA')


def load_commands(data):
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from('<IiiIIIII', data, 0)
    if magic != 0xFEEDFACF:
        sys.exit('not a thin arm64 Mach-O (fat binaries: thin it first)')
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, off)
        yield cmd, off, size
        off += size


def macho_info(data):
    info = {'dylibs': [], 'weak': [], 'rpaths': [], 'cryptid': None}
    for cmd, off, size in load_commands(data):
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            name_off = struct.unpack_from('<I', data, off + 8)[0]
            name = data[off + name_off:off + size].split(b'\0')[0].decode()
            (info['weak'] if cmd == LC_LOAD_WEAK_DYLIB else info['dylibs']).append(name)
        elif cmd == LC_RPATH:
            p = struct.unpack_from('<I', data, off + 8)[0]
            info['rpaths'].append(data[off + p:off + size].split(b'\0')[0].decode())
        elif cmd == LC_ENCRYPTION_INFO_64:
            info['cryptid'] = struct.unpack_from('<I', data, off + 16)[0]
    return info


def main_binary(z, app):
    plist = plistlib.loads(z.read(app + 'Info.plist'))
    return plist, app + plist['CFBundleExecutable']


def rewrite(ipa, replace):
    """Copy the IPA with some entries replaced/added (name -> bytes)."""
    tmp = ipa + '.tmp'
    with zipfile.ZipFile(ipa) as zin, zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as zout:
        for info in zin.infolist():
            if info.filename in replace:
                continue
            with zin.open(info) as src, zout.open(info, 'w', force_zip64=info.file_size > 2**31) as dst:
                shutil.copyfileobj(src, dst, 1 << 20)
        for name, data in replace.items():
            zi = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (0o100755 if data[:4] == b'\xcf\xfa\xed\xfe' else 0o100644) << 16
            zout.writestr(zi, data)
    os.replace(tmp, ipa)


def cmd_info(ipa):
    with zipfile.ZipFile(ipa) as z:
        app = app_dir(z)
        plist, exe = main_binary(z, app)
        info = macho_info(z.read(exe))
    if info['cryptid'] not in (0, None):
        sys.exit(f'{exe} is encrypted (cryptid {info["cryptid"]}): decrypt the IPA first')
    print(app, plist['CFBundleShortVersionString'])


def cmd_extract_plist(ipa, out):
    with zipfile.ZipFile(ipa) as z:
        open(out, 'wb').write(z.read(app_dir(z) + 'Info.plist'))


def cmd_overlay(ipa, overlay_path, out):
    # Same merge as scripts/pipeline.sh: Vitrine's Bonjour services after Spotify's own.
    with zipfile.ZipFile(ipa) as z:
        app = plistlib.loads(z.read(app_dir(z) + 'Info.plist'))
    overlay = plistlib.load(open(overlay_path, 'rb'))
    services = list(app.get('NSBonjourServices', []))
    services += [s for s in overlay.get('NSBonjourServices', []) if s not in services]
    overlay['NSBonjourServices'] = services
    if app.get('NSLocalNetworkUsageDescription'):
        overlay.pop('NSLocalNetworkUsageDescription', None)
    plistlib.dump(overlay, open(out, 'wb'))


def cmd_finish(ipa, app, insert_dylib, icons=None):
    replace = {}
    work = tempfile.mkdtemp()
    with zipfile.ZipFile(ipa) as z:
        names = set(z.namelist())
        # The App Group shim in the extensions (scripts/pipeline.sh, issue #60), fakesigned again with
        # their own entitlements.
        for ext in ('WidgetExtension', 'IntentsExtension', 'NotificationServiceExtension'):
            name = f'{app}PlugIns/{ext}.appex/{ext}'
            if name not in names:
                print(f'    no {ext}.appex')
                continue
            path = os.path.join(work, ext)
            open(path, 'wb').write(z.read(name))
            subprocess.run([sys.executable, insert_dylib, path, '@rpath/SpotifyGlassAppGroups.dylib'], check=True)
            ents = subprocess.run(['ldid', '-e', path], capture_output=True).stdout
            entpath = path + '.ents'
            open(entpath, 'wb').write(ents)
            subprocess.run(['ldid', '-S' + entpath if ents.strip() else '-S', path], check=True)
            replace[name] = open(path, 'rb').read()
            print(f'    {ext}: App Group shim loaded')
        if icons:
            try:
                from PIL import Image
            except ImportError:
                print('    no Pillow: skipping the alternate icons')
                icons = None
        if icons:
            plist = plistlib.loads(z.read(app + 'Info.plist'))
            pngs = sorted(f for f in os.listdir(icons) if f.endswith('.png'))
            for png in pngs:
                stem = png[:-4]
                if not re.fullmatch(r'[A-Za-z0-9_-]+', stem):
                    sys.exit(f'icon names are letters, digits, _ and - only: {png}')
                img = Image.open(os.path.join(icons, png)).convert('RGB')
                for suffix, px in (('@2x.png', 120), ('@3x.png', 180), ('@2x~ipad.png', 152)):
                    buf = io.BytesIO()
                    img.resize((px, px), Image.LANCZOS).save(buf, 'PNG')
                    replace[f'{app}{stem}{suffix}'] = buf.getvalue()
                for key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
                    if key in plist:
                        plist[key].setdefault('CFBundleAlternateIcons', {})[stem] = {'CFBundleIconFiles': [stem]}
            replace[app + 'Info.plist'] = plistlib.dumps(plist, fmt=plistlib.FMT_BINARY)
            print(f'    {len(pngs)} alternate icons')
    rewrite(ipa, replace)
    shutil.rmtree(work)


def cmd_verify(ipa):
    with zipfile.ZipFile(ipa) as z:
        bad = z.testzip()
        if bad:
            sys.exit(f'corrupt entry: {bad}')
        app = app_dir(z)
        plist, exe = main_binary(z, app)
        names = set(z.namelist())
        info = macho_info(z.read(exe))
        print(f'    {app} Spotify {plist["CFBundleShortVersionString"]} ({plist["CFBundleVersion"]}), '
              f'bundle id {plist["CFBundleIdentifier"]}, cryptid {info["cryptid"]}, {len(names)} entries')
        injected = [d for d in info['dylibs'] + info['weak'] if d.startswith('@')]
        print('    injected load commands: ' + ', '.join(injected))
        for d in injected:
            rel = d.replace('@rpath/', 'Frameworks/').replace('@executable_path/', '')
            ok = (app + rel) in names
            print(f'      {d} -> {app}{rel} {"present" if ok else "MISSING"}')
        for need in ('Mirage.dylib', 'spotifyglass.dylib'):
            if not any(need in d for d in injected):
                print(f'    warning: {need} is not in the load commands')
        watch = any(n.startswith(app + 'Watch/') for n in names)
        print(f'    Watch app removed: {not watch}; PlugIns: ' +
              ', '.join(sorted({n.split("/")[3] for n in names if n.startswith(app + "PlugIns/") and n.count("/") > 3})))


if __name__ == '__main__':
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == 'finish':
        icons = None
        if '--icons' in args:
            i = args.index('--icons'); icons = args[i + 1]; del args[i:i + 2]
        cmd_finish(*args, icons=icons)
    else:
        {'info': cmd_info, 'extract-plist': cmd_extract_plist, 'overlay': cmd_overlay, 'verify': cmd_verify}[cmd](*args)
