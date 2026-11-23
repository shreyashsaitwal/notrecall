#!/usr/bin/env python3
"""Resolve or clone Recall at its pinned commit and run any missing Phase 2
build steps (dependencies, Wine, DXMT, and Apple libd3dshared.dylib staging).
"""
import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parents[1]
RECALL_URL = 'https://github.com/shreyashsaitwal/recall'
RECALL_COMMIT = '420dbfdb6faf7f9ebb231c68f37881b99deacc93'
APPLE_LIBD3DSHARED_SHA256 = '5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995'

LLVM_MINGW_NAME = 'llvm-mingw-20251216-ucrt-macos-universal'
CLANG_LLVM_NAME = 'clang+llvm-15.0.7-x86_64-apple-darwin21.0'


def _run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def _sha256_file(path: Path) -> str:
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def _copy_file(src: Path, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() or dst.is_symlink():
        dst.unlink()
    shutil.copy2(src, dst)


def prepare_recall_source(recall_dir: Path | None, out_dir: Path) -> Path:
    """Use --recall-dir or sibling ../recall if present; otherwise clone pinned Recall into <out>/recall-source."""
    if recall_dir is not None:
        resolved = recall_dir.resolve()
        if (resolved / 'scripts/build_portable_runtime.py').is_file():
            return resolved
        raise SystemExit(f'Recall checkout not found at {resolved}')

    sibling = (PROJECT_DIR.parent / 'recall').resolve()
    if (sibling / 'scripts/build_portable_runtime.py').is_file():
        print(f'==> Using local Recall checkout at {sibling}', flush=True)
        return sibling

    source = (out_dir / 'recall-source').resolve()
    if not source.exists():
        print(f'==> Cloning Recall ({RECALL_URL} @ {RECALL_COMMIT[:7]}) -> {source}', flush=True)
        source.parent.mkdir(parents=True, exist_ok=True)
        _run('git', 'clone', '--no-checkout', RECALL_URL, source)
    current = subprocess.run(
        ['git', '-C', str(source), 'rev-parse', 'HEAD'],
        capture_output=True, text=True,
    )
    if current.returncode != 0 or current.stdout.strip() != RECALL_COMMIT:
        _run('git', '-C', source, 'fetch', 'origin', RECALL_COMMIT)
        _run('git', '-C', source, 'checkout', '--detach', RECALL_COMMIT)
    return source


def ensure_recall_toolchains(recall_dir: Path):
    """Ensure runtime/toolchains links bison, meson, ninja and verifies LLVM toolchains are present."""
    tools = recall_dir / 'runtime/toolchains'
    tools.mkdir(parents=True, exist_ok=True)

    bison_dst = tools / 'bison'
    if not (bison_dst / 'bin/bison').is_file():
        bison_src = next(
            (p for p in (Path('/opt/homebrew/opt/bison'), Path('/usr/local/opt/bison')) if (p / 'bin/bison').is_file()),
            None,
        )
        if bison_src is None:
            raise SystemExit('Missing GNU bison (3.8+). Install it with: brew install bison')
        if bison_dst.exists() or bison_dst.is_symlink():
            bison_dst.unlink()
        bison_dst.symlink_to(bison_src)

    py_bin = tools / 'python/bin'
    py_bin.mkdir(parents=True, exist_ok=True)
    for tool_name in ('meson', 'ninja'):
        dst = py_bin / tool_name
        if not dst.is_file():
            found = shutil.which(tool_name) or next(
                (str(p) for p in (Path(f'/opt/homebrew/bin/{tool_name}'), Path(f'/usr/local/bin/{tool_name}')) if p.is_file()),
                None,
            )
            if not found:
                raise SystemExit(f'Missing {tool_name}. Install it with: brew install {tool_name}')
            if dst.exists() or dst.is_symlink():
                dst.unlink()
            dst.symlink_to(found)

    missing = [name for name in (LLVM_MINGW_NAME, CLANG_LLVM_NAME) if not (tools / name).is_dir()]
    if missing:
        raise SystemExit(
            f'Missing Recall toolchain(s) under {tools}: {", ".join(missing)}.\n'
            'Extract them into runtime/toolchains/ (see recall/docs/BUILDING.md).'
        )


def ensure_nvngx_cert(recall_dir: Path):
    cert_dir = recall_dir / 'runtime/signing/recall-nvngx'
    if (cert_dir / 'recall.key').is_file():
        return
    print(f'==> Creating nvngx Authenticode certificate -> {cert_dir}', flush=True)
    _run(sys.executable, recall_dir / 'scripts/sign_pe.py', 'create-certificate', cert_dir)


def ensure_apple_libd3dshared(work: Path, gptk_dir: Path | None):
    """Ensure work/apple-original/redist/lib/external/libd3dshared.dylib is staged with Apple's SHA-256."""
    dest = work / 'apple-original/redist/lib/external/libd3dshared.dylib'
    if dest.is_file() and _sha256_file(dest) == APPLE_LIBD3DSHARED_SHA256:
        return

    candidates: list[tuple[Path, Path | None]] = []

    def add_root(root: Path):
        if root.is_file() and root.name == 'libd3dshared.dylib':
            candidates.append((root, None))
            return
        for rel in (
            'redist/lib/external/libd3dshared.dylib',
            'lib/external/libd3dshared.dylib',
            'libd3dshared.dylib',
        ):
            p = root / rel
            if p.is_file():
                candidates.append((p, root))

    if gptk_dir is not None:
        add_root(gptk_dir.resolve())
    for env_key in ('GPTK_DIR', 'LIBD3DSHARED_PATH'):
        val = os.environ.get(env_key, '').strip()
        if val:
            add_root(Path(val).expanduser().resolve())

    volumes = Path('/Volumes')
    if volumes.is_dir():
        for vol in sorted(volumes.iterdir()):
            if vol.is_dir() and 'windows games' in vol.name.lower():
                add_root(vol)

    for lib_path, license_root in candidates:
        if _sha256_file(lib_path) == APPLE_LIBD3DSHARED_SHA256:
            print(f'==> Staging unmodified Apple libd3dshared.dylib from {lib_path}', flush=True)
            _copy_file(lib_path, dest)
            if license_root is not None:
                for lic_name in ('License.rtf', 'Read Me.rtf', 'Acknowledgements.rtf'):
                    lic_src = license_root / lic_name
                    if lic_src.is_file():
                        _copy_file(lic_src, work / 'apple-original' / lic_name)
            return

    raise SystemExit(
        'Missing Apple GPTK libd3dshared.dylib '
        f'(expected SHA-256 {APPLE_LIBD3DSHARED_SHA256}).\n'
        "Mount Apple's Game Porting Toolkit DMG, or pass --gptk-dir <path> / "
        'GPTK_DIR=<path> / LIBD3DSHARED_PATH=<path>.'
    )


def ensure_recall_phase2(recall_dir: Path, work: Path, jobs: int, gptk_dir: Path | None, rebuild_recall: bool):
    """Build any missing Recall Phase 2 components (dependencies, Wine, DXMT) automatically."""
    work.mkdir(parents=True, exist_ok=True)
    ensure_apple_libd3dshared(work, gptk_dir)

    need_deps = rebuild_recall or not (work / 'native-build-proof.json').is_file()
    need_wine = rebuild_recall or not (work / 'wine-build-proof.json').is_file()
    need_dxmt = rebuild_recall or not (work / 'dxmt-build-proof.json').is_file() or not (work / 'dxmt-source').is_dir()

    if not (need_deps or need_wine or need_dxmt):
        return

    ensure_recall_toolchains(recall_dir)
    if need_dxmt:
        ensure_nvngx_cert(recall_dir)

    if need_deps or need_wine:
        print('==> Downloading Recall Phase 2 upstream sources', flush=True)
        _run(sys.executable, recall_dir / 'scripts/build_portable_runtime.py',
             '--workspace', work, '--download-only')

    if need_deps:
        print('==> Building Recall Phase 2 native dependencies', flush=True)
        _run(sys.executable, recall_dir / 'scripts/build_portable_dependencies.py',
             '--workspace', work, '--jobs', str(jobs))

    if need_wine:
        print('==> Building Recall Phase 2 Wine runtime', flush=True)
        _run(sys.executable, recall_dir / 'scripts/build_portable_runtime.py',
             '--workspace', work, '--jobs', str(jobs))

    if need_dxmt:
        print('==> Building Recall Phase 2 DXMT', flush=True)
        _run(sys.executable, recall_dir / 'scripts/build_portable_dxmt.py',
             '--workspace', work, '--jobs', str(min(max(jobs, 1), 4)))
