#!/usr/bin/env nix
#! nix shell --inputs-from .# nixpkgs#python3 nixpkgs#bun nixpkgs#git --command python3

"""Update script for omp (oh-my-pi) package.

Linux builds from source and needs both bun2nix regeneration plus a recalculated
cargoHash. Darwin still uses upstream release binaries plus native addon assets
because the source-build packaging is currently Linux-only in llm-agents.nix.
"""

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "scripts"))

from updater import (
    calculate_dependency_hash,
    calculate_url_hash,
    clone_and_generate_bun_nix,
    fetch_github_latest_release,
    load_hashes,
    save_hashes,
    should_update,
)
from updater.hash import DUMMY_SHA256_HASH
from updater.nix import NixCommandError

PKG_DIR = Path(__file__).parent
FLAKE_ROOT = PKG_DIR.parent.parent
HASHES_FILE = PKG_DIR / "hashes.json"
BUN_NIX = PKG_DIR / "bun.nix"

OWNER = "can1357"
REPO = "oh-my-pi"
DARWIN_RELEASES = {
    "aarch64-darwin": {
        "binary": "omp-darwin-arm64",
        "native": ["pi_natives.darwin-arm64.node"],
    },
    "x86_64-darwin": {
        "binary": "omp-darwin-x64",
        "native": [
            "pi_natives.darwin-x64-baseline.node",
            "pi_natives.darwin-x64-modern.node",
        ],
    },
}


def strip_workspace_entries(bun_nix: Path) -> None:
    """Remove workspace copyPathToStore entries from bun.nix.

    Workspace packages resolve relative to bun.nix, which is in
    packages/omp/ -- not the source root. The bun2nix hook resolves
    workspace deps from the source tree during bun install, so these
    entries are unnecessary and would fail to evaluate.
    """
    text = bun_nix.read_text()
    text = re.sub(r"  copyPathToStore,\n", "", text)
    text = re.sub(
        r'  "@oh-my-pi/[^\"]*"\s*=\s*copyPathToStore\s+[^;]+;\n',
        "",
        text,
    )
    bun_nix.write_text(text)
    subprocess.run(
        ["nix", "fmt", "--", str(bun_nix)],
        cwd=FLAKE_ROOT,
        check=True,
        capture_output=True,
    )


def darwin_release_hashes(version: str) -> dict[str, dict[str, object]]:
    """Calculate hashes for the Darwin release binaries and native addons."""
    result: dict[str, dict[str, object]] = {}
    for system, assets in DARWIN_RELEASES.items():
        binary_name = assets["binary"]
        binary_url = f"https://github.com/{OWNER}/{REPO}/releases/download/v{version}/{binary_name}"
        native = []
        for name in assets["native"]:
            native_url = (
                f"https://github.com/{OWNER}/{REPO}/releases/download/v{version}/{name}"
            )
            native.append({"name": name, "hash": calculate_url_hash(native_url)})
        result[system] = {
            "binary": {
                "name": binary_name,
                "hash": calculate_url_hash(binary_url),
            },
            "native": native,
        }
    return result


def main() -> None:
    """Update the omp package."""
    data = load_hashes(HASHES_FILE)
    current = data["version"]
    latest = fetch_github_latest_release(OWNER, REPO)

    print(f"Current: {current}, Latest: {latest}")

    if not should_update(current, latest):
        print("Already up to date")
        return

    print(f"Updating omp from {current} to {latest}")

    # Step 1: Calculate new source hash and Darwin release hashes.
    print("Calculating source hash...")
    url = f"https://github.com/{OWNER}/{REPO}/archive/refs/tags/v{latest}.tar.gz"
    source_hash = calculate_url_hash(url, unpack=True)
    print("Calculating Darwin release hashes...")
    binary_hashes = darwin_release_hashes(latest)

    data = {
        "version": latest,
        "hash": source_hash,
        "cargoHash": DUMMY_SHA256_HASH,
        "hashes": binary_hashes,
    }
    save_hashes(HASHES_FILE, data)

    # Step 2: Regenerate bun.nix from upstream bun.lock.
    clone_and_generate_bun_nix(
        OWNER,
        REPO,
        latest,
        BUN_NIX,
        FLAKE_ROOT,
        ref_prefix="v",
    )
    strip_workspace_entries(BUN_NIX)

    # Step 3: Calculate cargoHash from the Linux source build.
    try:
        cargo_hash = calculate_dependency_hash(".#omp", "cargoHash", HASHES_FILE, data)
        data["cargoHash"] = cargo_hash
        save_hashes(HASHES_FILE, data)
    except (ValueError, NixCommandError) as e:
        print(f"Error: {e}")
        return

    print(f"Updated omp to {latest}")


if __name__ == "__main__":
    main()
