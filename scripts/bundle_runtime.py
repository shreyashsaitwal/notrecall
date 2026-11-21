#!/usr/bin/env python3
"""Assemble NotRecall's self-contained Wine + DXMT runtime and shader helpers
directly from a local Recall Phase 2 source build (no Recall download needed).

Outputs:
  <out>/runtime/runtime.tar.gz          Self-contained Wine + DXMT runtime archive
  <out>/runtime/bundled-runtime.json    Runtime version, DXMT base commit, and SHA-256
  <out>/helpers/ow2-pipeline            Swift shader pipeline coordinator
  <out>/helpers/libpipeline_prepare.dylib
  <out>/helpers/pipeline-prepare
  <out>/helpers/pipeline-warm
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_RECALL_DIR = PROJECT_DIR.parent / 'recall'
MINIMUM_MACOS = '15.0'


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def sha256_file(path: Path) -> str:
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def is_macho(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    with path.open('rb') as f:
        return f.read(4) in (
            b'\xcf\xfa\xed\xfe',
            b'\xce\xfa\xed\xfe',
            b'\xca\xfe\xba\xbe',
            b'\xbe\xba\xfe\xca',
        )


def otool_links(path: Path):
    out = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True)
    return [line.strip().split(' (')[0] for line in out.splitlines()[1:]]


def otool_rpaths(path: Path):
    out = subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True)
    return re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset', out)


def copy_entry(src: Path, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_symlink():
        link = os.readlink(src)
        if os.path.isabs(link):
            raise ValueError(f'Absolute symlink in source: {src} -> {link}')
        if dst.exists() or dst.is_symlink():
            dst.unlink()
        dst.symlink_to(link)
    else:
        if dst.exists() or dst.is_symlink():
            dst.unlink()
        shutil.copy2(src, dst)


def sign_macho(path: Path, identity: str, entitlements: Path | None = None):
    args = ['/usr/bin/codesign', '--force', '--sign', identity]
    if identity != '-':
        args += ['--options', 'runtime', '--timestamp']
    if entitlements is not None:
        args += ['--entitlements', str(entitlements)]
    run(*args, path, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run('/usr/bin/codesign', '--verify', '--strict', path, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def build_helpers(recall_dir: Path, work: Path, helpers_out: Path, identity: str):
    helpers_out.mkdir(parents=True, exist_ok=True)
    native = work / 'dxmt-source/src/winemetal/unix'
    for name in ('pipeline_recipe.c', 'pipeline_recipe.h', 'pipeline_cache.c', 'pipeline_cache.h'):
        if not (native / name).is_file():
            raise SystemExit(f'Missing DXMT shader helper source: {native / name}')

    clang = '/usr/bin/clang'

    print('==> Building shader pipeline helpers ->', helpers_out, flush=True)
    run('/usr/bin/swiftc', '-O', '-target', 'arm64-apple-macos15.0',
        recall_dir / 'scripts/portable_pipeline.swift',
        '-o', helpers_out / 'ow2-pipeline')

    dylib = helpers_out / 'libpipeline_prepare.dylib'
    run(clang, '-arch', 'x86_64', '-mmacosx-version-min=15.0',
        '-x', 'objective-c', '-fblocks', '-fno-objc-arc',
        '-DDXMT_PIPELINE_CACHE_OFFLINE_TOOL', '-O2', '-dynamiclib',
        native / 'pipeline_recipe.c', native / 'pipeline_cache.c',
        '-framework', 'Foundation', '-framework', 'Metal', '-framework', 'QuartzCore',
        '-install_name', '@rpath/libpipeline_prepare.dylib',
        '-o', dylib)

    run(clang, '-arch', 'x86_64', '-mmacosx-version-min=15.0',
        '-x', 'objective-c', '-fblocks', '-fobjc-arc',
        '-DDXMT_PIPELINE_CACHE_OFFLINE_TOOL', '-O2', '-I', native,
        recall_dir / 'scripts/pipeline_prepare.m', '-x', 'none', dylib,
        '-Wl,-rpath,@executable_path',
        '-framework', 'Foundation', '-framework', 'Metal',
        '-o', helpers_out / 'pipeline-prepare')

    run(clang, '-arch', 'x86_64', '-mmacosx-version-min=15.0',
        '-x', 'objective-c', '-fblocks', '-fno-objc-arc', '-O2', '-I', native,
        recall_dir / 'scripts/pipeline_warm.m', '-x', 'none', dylib,
        '-Wl,-rpath,@executable_path',
        '-framework', 'Foundation', '-framework', 'Metal',
        '-o', helpers_out / 'pipeline-warm')

    for b in (dylib, helpers_out / 'pipeline-prepare', helpers_out / 'pipeline-warm'):
        run('/usr/bin/strip', '-S', '-x', b)
    for b in (dylib, helpers_out / 'ow2-pipeline', helpers_out / 'pipeline-prepare', helpers_out / 'pipeline-warm'):
        sign_macho(b, identity)
    print('    OK: ow2-pipeline, libpipeline_prepare.dylib, pipeline-prepare, pipeline-warm', flush=True)


WINEMACMF_PE_SOURCES = ('aac_encoder', 'h264_encoder', 'main', 'mpeg4_sink')
WINEMACMF_UNIX_SOURCES = ('unixlib.c', 'macmf_cocoa.m')
WINEMACMF_FRAMEWORKS = (
    'AVFoundation', 'AudioToolbox', 'CoreMedia', 'CoreVideo',
    'VideoToolbox', 'Foundation', 'CoreFoundation',
)


def _make_var(makefile: str, name: str) -> str:
    match = re.search(r'^' + re.escape(name) + r' = (.*)$', makefile, re.M)
    if not match:
        raise RuntimeError(f'Phase 2 Makefile lacks {name}')
    return match.group(1)


def _make_recipe(makefile: str, target: str) -> str:
    match = re.search(
        r'^' + re.escape(target) + r':[^\n]*(?:\\\n[^\n]*)*\n\t((?:[^\n]*\\\n)*[^\n]*)',
        makefile, re.M,
    )
    if not match:
        raise RuntimeError(f'Phase 2 Makefile lacks a rule for {target}')
    return match.group(1).replace('\\\n', ' ')


def _make_expand(command: str, output: Path, makefile: str, ldflags: str) -> str:
    command = (command
               .replace('$(CC)', _make_var(makefile, 'CC'))
               .replace('$(CFLAGS)', _make_var(makefile, 'CFLAGS'))
               .replace('$(LDFLAGS)', ldflags)
               .replace('$@', str(output)))
    if '$(' in command:
        raise RuntimeError(f'Unexpanded make variable in: {command}')
    return command


def _make_expand_braces(command: str, makefile: str) -> str:
    def _val(match):
        return _make_var(makefile, match.group(1))
    for _ in range(10):
        expanded = re.sub(r'\$\{(\w+)\}', _val, command)
        if expanded == command:
            return command
        command = expanded
    raise RuntimeError(f'Make variables nest too deeply in: {command}')


def _make_expand_cross(command: str, makefile: str, cross_cflags: str) -> str:
    def _val(match):
        if match.group(1) in ('x86_64_CFLAGS', 'i386_CFLAGS'):
            return cross_cflags
        return _make_var(makefile, match.group(1))
    return re.sub(r'\$\(((?:x86_64|i386)_\w+)\)', _val, command)


RECALL_WINE_OVERLAY_PATCHES = (
    'patches/wine-server-registry-save.patch',
    'patches/wine-ntdll-syscall-log.patch',
    'patches/wine-win32u-display-log.patch',
    'patches/wine-winemac-activation.patch',
    'patches/wine-audio-devices.patch',
    'patches/wine-service-security.patch',
    'patches/wine-media-foundation.patch',
)

RECALL_WINE_COMPONENTS = (
    ('server', 'server/wineserver', 'bin/wineserver'),
    ('dlls/ntdll', 'dlls/ntdll/ntdll.so', 'lib/wine/x86_64-unix/ntdll.so'),
    ('dlls/win32u', 'dlls/win32u/win32u.so', 'lib/wine/x86_64-unix/win32u.so'),
    ('dlls/winemac.drv', 'dlls/winemac.drv/winemac.so', 'lib/wine/x86_64-unix/winemac.so'),
    ('dlls/mmdevapi', 'dlls/mmdevapi/x86_64-windows/mmdevapi.dll', 'lib/wine/x86_64-windows/mmdevapi.dll'),
    ('dlls/winecoreaudio.drv', 'dlls/winecoreaudio.drv/winecoreaudio.so', 'lib/wine/x86_64-unix/winecoreaudio.so'),
    ('programs/services', 'programs/services/x86_64-windows/services.exe', 'lib/wine/x86_64-windows/services.exe'),
    ('dlls/sechost', 'dlls/sechost/x86_64-windows/sechost.dll', 'lib/wine/x86_64-windows/sechost.dll'),
    ('dlls/sechost', 'dlls/sechost/i386-windows/sechost.dll', 'lib/wine/i386-windows/sechost.dll'),
    ('dlls/mfreadwrite', 'dlls/mfreadwrite/x86_64-windows/mfreadwrite.dll', 'lib/wine/x86_64-windows/mfreadwrite.dll'),
    ('dlls/mfh264enc', 'dlls/mfh264enc/x86_64-windows/mfh264enc.dll', 'lib/wine/x86_64-windows/mfh264enc.dll'),
)

RECALL_WINE_SRC_DIRS = (
    'server',
    'dlls/ntdll',
    'dlls/win32u',
    'dlls/winemac.drv',
    'dlls/mmdevapi',
    'dlls/winecoreaudio.drv',
    'programs/services',
    'dlls/sechost',
    'dlls/mfreadwrite',
    'dlls/mfh264enc',
)


def wine_patches_digest(recall_dir: Path) -> str:
    h = hashlib.sha256()
    for rel in RECALL_WINE_OVERLAY_PATCHES:
        p = recall_dir / rel
        if not p.is_file():
            raise SystemExit(f'Missing Recall Wine patch: {p}')
        h.update(rel.encode())
        h.update(b'\0')
        h.update(p.read_bytes())
    return h.hexdigest()


def build_recall_wine_overlays(recall_dir: Path, work: Path, stage: Path, runtime_out: Path):
    """Compile all Recall native Wine overlays (wineserver, ntdll.so with WINE_GAME_MODE +
    msync fix, win32u.so, winemac.so with HID raw input + focus/fullscreen fixes,
    hotplug mmdevapi/winecoreaudio, services/sechost, and Media Foundation winemacmf)
    against the Phase 2 Wine build tree and overlay them into stage."""
    wine_build = work / 'wine-build'
    wine_src = work / 'sources/wine/sources/wine'
    for req in (wine_build / 'Makefile', wine_build / '.portable-cross-paths', wine_src / 'loader/wine.inf.in'):
        if not req.exists():
            raise SystemExit(f'Missing Wine overlay build input: {req}')
    for d in RECALL_WINE_SRC_DIRS:
        if not (wine_src / d).is_dir():
            raise SystemExit(f'Missing Wine source directory: {wine_src / d}')

    tools_dir = Path('/Library/Developer/CommandLineTools')
    sdkroot = tools_dir / 'SDKs/MacOSX26.5.sdk'
    if not sdkroot.is_dir():
        sdkroot = Path(subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], text=True).strip())

    env = dict(
        os.environ,
        MACOSX_DEPLOYMENT_TARGET=MINIMUM_MACOS,
        DEVELOPER_DIR=str(tools_dir),
        SDKROOT=str(sdkroot),
        PATH=':'.join([
            str(recall_dir / 'runtime/toolchains/bison/bin'),
            str(recall_dir / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin'),
            str(tools_dir / 'usr/bin'),
            '/usr/bin', '/bin', '/usr/sbin', '/sbin',
        ]),
    )
    ldflags = '-Wl,-headerpad,0x1000 -L' + str(work / 'deps/lib')
    makefile = (wine_build / 'Makefile').read_text()
    cross_cflags = (wine_build / '.portable-cross-paths').read_text().strip()

    overlay_work = runtime_out / '.wine-overlays-build'
    if overlay_work.exists():
        shutil.rmtree(overlay_work)
    src_copy = overlay_work / 'src'
    out_dir = overlay_work / 'out'
    out_dir.mkdir(parents=True)

    print('==> Building Recall native Wine overlays (ntdll, winemac, wineserver, win32u, audio, services, winemacmf)', flush=True)
    try:
        for d in RECALL_WINE_SRC_DIRS:
            shutil.copytree(wine_src / d, src_copy / d)
        (src_copy / 'loader').mkdir(parents=True)
        shutil.copy2(wine_src / 'loader/wine.inf.in', src_copy / 'loader/wine.inf.in')
        for rel in RECALL_WINE_OVERLAY_PATCHES:
            run('/usr/bin/patch', '-p1', '-s', '-i', recall_dir / rel, cwd=src_copy)

        prefix_map = f' -ffile-prefix-map={src_copy}=/build/overwatch-2-mac/sources/wine/sources/wine'

        def _shell(command: str, label: str):
            res = subprocess.run(command, shell=True, cwd=wine_build, env=env, capture_output=True, text=True)
            if res.returncode:
                raise RuntimeError(f'Wine overlay build failed ({label}):\n{res.stderr}')

        def _retarget(command: str, template: str, directory: str) -> str:
            command = command.replace(str(wine_src / template) + '/', str(src_copy / directory) + '/')
            command = command.replace('-I' + str(wine_src / template) + ' ', '-I' + str(src_copy / directory) + ' ')
            return command.replace('-I' + template + ' ', '-I' + directory + ' ')

        # 1. Build all patched existing Wine components.
        for directory, rule, dest_rel in RECALL_WINE_COMPONENTS:
            comp_tag = rule.replace('/', '_')
            comp_obj = out_dir / comp_tag / 'obj'
            deps = re.search(r'^' + re.escape(rule) + r':((?:[^\n]*\\\n)*[^\n]*)', makefile, re.M).group(1)
            obj_names = re.findall(r'(\S+)\.o\b', deps)

            def _compile_obj(name: str, _obj=comp_obj):
                target = _obj / (name + '.o')
                target.parent.mkdir(parents=True, exist_ok=True)
                cmd = _make_expand_braces(
                    _make_expand(_make_expand_cross(_make_recipe(makefile, name + '.o'), makefile, cross_cflags),
                                 target, makefile, ldflags),
                    makefile,
                )
                for d in RECALL_WINE_SRC_DIRS:
                    cmd = cmd.replace(str(wine_src / d) + '/', str(src_copy / d) + '/')
                    cmd = cmd.replace('-I' + str(wine_src / d) + ' ', '-I' + str(src_copy / d) + ' ')
                _shell(cmd + prefix_map, name + '.o')

            with ThreadPoolExecutor(max_workers=6) as pool:
                list(pool.map(_compile_obj, obj_names))

            raw = out_dir / comp_tag / Path(rule).name
            link = _make_expand(_make_expand_cross(_make_recipe(makefile, rule), makefile, cross_cflags),
                                raw, makefile, ldflags)
            for name in obj_names:
                link = re.sub(re.escape(name) + r'\.o\b', str(comp_obj / (name + '.o')), link)
            _shell(link, dest_rel)
            copy_entry(raw, stage / dest_rel)

        # 2. Synthesized winemacmf.dll (PE, from mfh264enc template).
        pe_obj = out_dir / 'winemacmf-pe/obj'
        pe_obj.mkdir(parents=True)
        template = 'dlls/mfh264enc'
        directory = 'dlls/winemacmf'
        compile_rule = _make_recipe(makefile, template + '/x86_64-windows/mfh264enc.o')
        pe_objs = []
        for name in WINEMACMF_PE_SOURCES:
            target = pe_obj / (name + '.o')
            cmd = compile_rule.replace(str(wine_src / template / 'mfh264enc.c'), str(src_copy / directory / (name + '.c')))
            cmd = _retarget(_make_expand(_make_expand_cross(cmd, makefile, cross_cflags), target, makefile, ldflags),
                            template, directory)
            cmd = cmd.replace('-I' + directory + ' ', '-I' + str(pe_obj) + ' ')
            _shell(cmd + prefix_map, f'winemacmf/{name}.o')
            pe_objs.append(str(target))
        res_file = pe_obj / 'winemacmf_r.res'
        res_cmd = _make_recipe(makefile, template + '/x86_64-windows/mfh264enc_r.res')
        res_cmd = res_cmd.replace(str(wine_src / template / 'mfh264enc.idl'), str(src_copy / directory / 'winemacmf.idl'))
        res_cmd = _retarget(_make_expand(res_cmd, res_file, makefile, ldflags), template, directory)
        _shell(res_cmd, 'winemacmf_r.res')
        winemacmf_dll = out_dir / 'winemacmf.dll'
        dll_link = _make_expand(_make_expand_cross(_make_recipe(makefile, template + '/x86_64-windows/mfh264enc.dll'),
                                                   makefile, cross_cflags),
                                winemacmf_dll, makefile, ldflags)
        dll_link = dll_link.replace(str(wine_src / template / 'mfh264enc.spec'), str(src_copy / directory / 'winemacmf.spec'))
        dll_link = dll_link.replace(template + '/x86_64-windows/mfh264enc.o', ' '.join(pe_objs))
        dll_link = dll_link.replace(template + '/x86_64-windows/mfh264enc_r.res', str(res_file))
        _shell(dll_link, 'winemacmf.dll')
        copy_entry(winemacmf_dll, stage / 'lib/wine/x86_64-windows/winemacmf.dll')

        # 3. Synthesized winemacmf.so (Unix Mach-O, from winedmo + winemac.drv templates).
        unix_obj = out_dir / 'winemacmf-unix/obj'
        unix_obj.mkdir(parents=True)
        unix_objs = []
        for fname in WINEMACMF_UNIX_SOURCES:
            stem, suffix = fname.rsplit('.', 1)
            tmpl, sample = ('dlls/winemac.drv', 'cocoa_app') if suffix == 'm' else ('dlls/winedmo', 'unixlib')
            target = unix_obj / (stem + '.o')
            cmd = _make_recipe(makefile, f'{tmpl}/{sample}.o')
            cmd = cmd.replace(str(wine_src / tmpl / f'{sample}.{suffix}'), str(src_copy / directory / fname))
            cmd = _retarget(_make_expand(cmd, target, makefile, ldflags), tmpl, directory)
            cmd = cmd.replace('-I' + directory + ' ', '-I' + str(unix_obj) + ' ')
            if suffix == 'm':
                cmd += ' -fobjc-arc'
            _shell(cmd + prefix_map, f'winemacmf/{fname}')
            unix_objs.append(str(target))
        winemacmf_so = out_dir / 'winemacmf.so'
        so_link = _make_expand(_make_recipe(makefile, 'dlls/winedmo/winedmo.so'), winemacmf_so, makefile, ldflags)
        so_link = so_link.replace('@rpath/winedmo.so', '@rpath/winemacmf.so')
        so_link = re.sub(r'dlls/winedmo/\w+\.o(?: dlls/winedmo/\w+\.o)*', ' '.join(unix_objs), so_link, count=1)
        if 'dlls/winedmo/' in so_link:
            raise RuntimeError(f'winedmo objects remain in winemacmf link: {so_link}')
        so_link += ''.join(' -framework ' + fw for fw in WINEMACMF_FRAMEWORKS)
        _shell(so_link, 'winemacmf.so')
        copy_entry(winemacmf_so, stage / 'lib/wine/x86_64-unix/winemacmf.so')

        # 4. Synthesized wine.inf (registers winemacmf.dll).
        wine_inf = out_dir / 'wine.inf'
        inf_cmd = _make_expand_braces(_make_recipe(makefile, 'loader/wine.inf'), makefile)
        inf_cmd = inf_cmd.replace(str(wine_src / 'loader/wine.inf.in'), str(src_copy / 'loader/wine.inf.in'))
        inf_cmd = inf_cmd.replace('>$@', '>' + str(wine_inf))
        _shell(inf_cmd, 'wine.inf')
        copy_entry(wine_inf, stage / 'share/wine/wine.inf')
        print('    OK: wineserver, ntdll.so, win32u.so, winemac.so, mmdevapi.dll, winecoreaudio.so, services.exe, sechost.dll (x64/x86), mfreadwrite.dll, mfh264enc.dll, winemacmf.{dll,so}, wine.inf', flush=True)
    finally:
        if overlay_work.exists():
            shutil.rmtree(overlay_work)


def bundle_runtime(recall_dir: Path, work: Path, out_dir: Path, version: str, identity: str, force: bool):
    runtime_out = out_dir / 'runtime'
    archive_path = runtime_out / 'runtime.tar.gz'
    meta_path = runtime_out / 'bundled-runtime.json'

    for proof_name in ('wine-build-proof.json', 'dxmt-build-proof.json', 'native-build-proof.json'):
        if not (work / proof_name).is_file():
            raise SystemExit(f'Missing Phase 2 build proof: {work / proof_name}')

    dxmt_proof = json.loads((work / 'dxmt-build-proof.json').read_text())
    dxmt_base = dxmt_proof.get('base', '')
    wine_patches_sha = wine_patches_digest(recall_dir)

    if not force and archive_path.is_file() and meta_path.is_file():
        existing = json.loads(meta_path.read_text())
        if (existing.get('version') == version and
                existing.get('dxmtBase') == dxmt_base and
                existing.get('winePatchesSHA256') == wine_patches_sha and
                existing.get('runtimeSHA256') == sha256_file(archive_path)):
            print(f'==> Bundled runtime already up to date ({version}, dxmt {dxmt_base[:7]})', flush=True)
            return

    runtime_out.mkdir(parents=True, exist_ok=True)
    stage = runtime_out / '.staging'
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    print(f'==> Assembling bundled Wine + DXMT runtime ({version}, dxmt {dxmt_base[:7]})', flush=True)
    wine = work / 'install/usr/local'
    for rel in ('bin/wine', 'bin/wineserver'):
        copy_entry(wine / rel, stage / rel)
    for p in (wine / 'lib/wine').rglob('*'):
        if p.is_file() and p.suffix != '.a' and p.name != '.DS_Store':
            copy_entry(p, stage / p.relative_to(wine))
    shutil.copytree(wine / 'share/wine', stage / 'share/wine', symlinks=True)

    # Overlay freshly built DXMT modules (.dll and .so).
    for p in (work / 'dxmt-install').rglob('*'):
        if p.is_file() and p.suffix in ('.dll', '.so'):
            copy_entry(p, stage / 'lib/wine' / p.relative_to(work / 'dxmt-install'))

    # Copy unmodified Apple GPTK libd3dshared.dylib (required by Wine ntdll.so for
    # Rosetta 2 non-native code region support via CX_APPLEGPTK_LIBD3DSHARED_PATH).
    apple_d3d = work / 'apple-original/redist/lib/external/libd3dshared.dylib'
    if not apple_d3d.is_file():
        raise SystemExit(f'Missing Apple libd3dshared.dylib at {apple_d3d}')
    if sha256_file(apple_d3d) != '5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995':
        raise ValueError(f'Unexpected libd3dshared.dylib SHA-256: {sha256_file(apple_d3d)}')
    apple_dst = stage / 'lib/external/libd3dshared.dylib'
    copy_entry(apple_d3d, apple_dst)
    for lic_name in ('License.rtf', 'Read Me.rtf', 'Acknowledgements.rtf'):
        lic_src = work / 'apple-original' / lic_name
        if lic_src.is_file():
            copy_entry(lic_src, stage / 'licenses/apple' / lic_name)

    # Build and overlay all Recall native Wine patches (including winemacmf).
    build_recall_wine_overlays(recall_dir, work, stage, runtime_out)
    # Copy baseline DXMT config & key licenses.
    copy_entry(recall_dir / 'config/dxmt-source60-1200.conf', stage / 'config/dxmt.conf')
    for src, dst in [
        (work / 'sources/wine/sources/wine/COPYING.LIB', stage / 'licenses/Wine-LGPL-2.1'),
        (work / 'dxmt-source/LICENSE', stage / 'licenses/DXMT-MIT'),
        (work / 'dxmt-source/include/native/directx/COPYING.MinGW-w64.txt', stage / 'licenses/DirectX-Headers-COPYING'),
        (work / 'dxmt-source/external/nvapi/LICENSE.txt', stage / 'licenses/NVAPI-MIT'),
    ]:
        if src.is_file():
            copy_entry(src, dst)

    # Resolve native dylib dependency closure (clean-deps + FreeType).
    available = {p.name: p for p in (work / 'clean-deps/lib').glob('*.dylib')}
    ft = work / 'deps/lib/libfreetype.6.dylib'
    if ft.is_file():
        available['libfreetype.6.dylib'] = ft

    native = [p for p in stage.rglob('*') if is_macho(p) and p != apple_dst]
    needed = {'libgnutls.30.dylib', 'libfreetype.6.dylib', 'libMoltenVK.dylib', 'libSDL2-2.0.0.dylib'}
    chosen = {}
    for p in native:
        for dep in otool_links(p):
            base = Path(dep).name
            if base in available:
                needed.add(base)
    while needed:
        name = needed.pop()
        if name in chosen or name not in available:
            continue
        p = available[name]
        chosen[name] = sha256_file(p)
        (stage / 'lib').mkdir(parents=True, exist_ok=True)
        shutil.copy2(p.resolve(), stage / 'lib' / name)
        for dep in otool_links(p):
            base = Path(dep).name
            if base in available and base != name:
                needed.add(base)

    # Strip debug symbols from PE modules.
    llvm_strip = recall_dir / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/llvm-strip'
    if llvm_strip.is_file():
        pe_files = [
            p for p in (stage / 'lib/wine').rglob('*')
            if p.is_file() and not p.is_symlink()
            and p.name != 'nvngx.dll'
            and p.suffix in ('.exe', '.dll', '.drv', '.sys', '.acm', '.cpl', '.ocx', '.ax')
        ]
        def _strip_pe(p: Path):
            run(llvm_strip, '--strip-debug', p, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(_strip_pe, pe_files))

    # Fix Mach-O install names, rpaths, strip, and sign (never modify Apple's libd3dshared.dylib).
    native = [p for p in stage.rglob('*') if is_macho(p) and p != apple_dst]
    for p in native:
        run('/usr/bin/strip', '-S', '-x', p, stderr=subprocess.DEVNULL)
        for dep in otool_links(p):
            if dep.startswith(('/usr/lib/', '/System/Library/', '@loader_path/', '@rpath/', '@executable_path/')):
                continue
            name = Path(dep).name
            if name == 'libpcap.dylib':
                run('/usr/bin/install_name_tool', '-change', dep, '/usr/lib/libpcap.A.dylib', p, stderr=subprocess.DEVNULL)
            elif name in chosen or name in ('ntdll.so', 'win32u.so'):
                run('/usr/bin/install_name_tool', '-change', dep, '@rpath/' + name, p, stderr=subprocess.DEVNULL)
            else:
                raise ValueError(f'Unresolved non-system dependency in {p}: {dep}')
        if p.suffix == '.dylib':
            run('/usr/bin/install_name_tool', '-id', '@rpath/' + p.name, p, stderr=subprocess.DEVNULL)
        desired = ['@loader_path']
        if p.parent == stage / 'bin':
            desired += ['@loader_path/../lib', '@loader_path/../lib/wine/x86_64-unix']
        elif (stage / 'lib/wine') in p.parents:
            desired += ['@loader_path/../..']
        old = otool_rpaths(p)
        for r in old:
            if r not in desired:
                run('/usr/bin/install_name_tool', '-delete_rpath', r, p, stderr=subprocess.DEVNULL)
        for r in desired:
            if r not in old:
                run('/usr/bin/install_name_tool', '-add_rpath', r, p, stderr=subprocess.DEVNULL)

    sys.path.insert(0, str(recall_dir / 'scripts'))
    import derive_runtime
    import game_mode_app
    min_ver = derive_runtime.parse_macos(MINIMUM_MACOS)
    for p in native:
        derive_runtime.restamp(p, min_ver)

    entitlements = runtime_out / '.wine-entitlements.plist'
    entitlements.write_bytes(plistlib.dumps({
        'com.apple.security.cs.allow-dyld-environment-variables': True,
        'com.apple.security.cs.allow-jit': True,
        'com.apple.security.cs.allow-unsigned-executable-memory': True,
        'com.apple.security.cs.disable-executable-page-protection': True,
        'com.apple.security.cs.disable-library-validation': True,
        'com.apple.security.device.audio-input': True,
    }))
    try:
        for p in sorted(native):
            ent = entitlements if p.name in ('wine', 'wineserver') else None
            sign_macho(p, identity, ent)

        # Create Overwatch.app Game Mode bundle using Recall's game_mode_app.py.
        game_mode_app.make(stage, MINIMUM_MACOS, identity)
        if identity == '-':
            # Re-sign ad-hoc without Hardened Runtime (--options runtime) to avoid
            # CS_ADHOC|CS_RUNTIME restrictions on Rosetta/Wine threads.
            sign_macho(stage / game_mode_app.BUNDLE, identity, entitlements)
    finally:
        entitlements.unlink(missing_ok=True)

    manifest = {
        'schema': 1,
        'version': version,
        'dxmtBase': dxmt_base,
        'winePatchesSHA256': wine_patches_sha,
        'minimum_macos': MINIMUM_MACOS,
        'native_dependency_inputs': chosen,
    }
    (stage / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')

    tmp_archive = runtime_out / '.runtime.tar.gz.part'
    if tmp_archive.exists():
        tmp_archive.unlink()
    print('==> Packing runtime.tar.gz', flush=True)
    with tarfile.open(tmp_archive, 'w:gz', compresslevel=3) as tar:
        for p in sorted(stage.rglob('*')):
            tar.add(p, arcname=str(p.relative_to(stage)), recursive=False)
    tmp_archive.replace(archive_path)
    shutil.rmtree(stage)

    archive_sha = sha256_file(archive_path)
    meta = {
        'version': version,
        'dxmtBase': dxmt_base,
        'winePatchesSHA256': wine_patches_sha,
        'runtimeArchive': 'runtime.tar.gz',
        'runtimeSHA256': archive_sha,
        'archiveBytes': archive_path.stat().st_size,
    }
    meta_path.write_text(json.dumps(meta, indent=2) + '\n')
    print(f'    OK: {archive_path} ({archive_path.stat().st_size / (1024 * 1024):.1f} MiB, sha256 {archive_sha[:12]}…)', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recall-dir', type=Path, default=DEFAULT_RECALL_DIR)
    parser.add_argument('--out', type=Path, default=PROJECT_DIR / 'build')
    parser.add_argument('--version', default=f'notrecall-{date.today().strftime("%Y%m%d")}')
    parser.add_argument('--identity', default='-')
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()

    recall_dir = args.recall_dir.resolve()
    work = recall_dir / 'runtime/phase-2'
    out_dir = args.out.resolve()

    build_helpers(recall_dir, work, out_dir / 'helpers', args.identity)
    bundle_runtime(recall_dir, work, out_dir, args.version, args.identity, args.force)


if __name__ == '__main__':
    main()
