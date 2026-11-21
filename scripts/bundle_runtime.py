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


def bundle_runtime(recall_dir: Path, work: Path, out_dir: Path, version: str, identity: str, force: bool):
    runtime_out = out_dir / 'runtime'
    archive_path = runtime_out / 'runtime.tar.gz'
    meta_path = runtime_out / 'bundled-runtime.json'

    for proof_name in ('wine-build-proof.json', 'dxmt-build-proof.json', 'native-build-proof.json'):
        if not (work / proof_name).is_file():
            raise SystemExit(f'Missing Phase 2 build proof: {work / proof_name}')

    dxmt_proof = json.loads((work / 'dxmt-build-proof.json').read_text())
    dxmt_base = dxmt_proof.get('base', '')

    if not force and archive_path.is_file() and meta_path.is_file():
        existing = json.loads(meta_path.read_text())
        if (existing.get('version') == version and
                existing.get('dxmtBase') == dxmt_base and
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
