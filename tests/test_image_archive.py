#!/usr/bin/env python3
import hashlib
import io
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PREPARE_SCRIPT = REPO_ROOT / "scripts" / "validate_image_archive.py"
CREATE_SCRIPT = REPO_ROOT / "scripts" / "onecontainerd.sh"


def json_bytes(value):
    return json.dumps(value, separators=(",", ":")).encode()


def descriptor(data, media_type):
    return {
        "mediaType": media_type,
        "digest": f"sha256:{hashlib.sha256(data).hexdigest()}",
        "size": len(data),
    }


def add_bytes(archive, name, data):
    member = tarfile.TarInfo(name)
    member.size = len(data)
    archive.addfile(member, io.BytesIO(data))


def write_oci_archive(path, root_descriptor=None, include_manifest=True, config_descriptor=None, architecture="amd64"):
    config = json_bytes({"architecture": architecture, "os": "linux"})
    layer = b"layer-data"
    if config_descriptor is None:
        config_descriptor = descriptor(config, "application/vnd.oci.image.config.v1+json")
    manifest = json_bytes(
        {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": config_descriptor,
            "layers": [descriptor(layer, "application/vnd.oci.image.layer.v1.tar")],
        }
    )
    if root_descriptor is None:
        root_descriptor = descriptor(manifest, "application/vnd.oci.image.manifest.v1+json")
    index = json_bytes({"schemaVersion": 2, "manifests": [root_descriptor]})
    mode = "w:gz" if str(path).endswith(".gz") else "w"
    with tarfile.open(path, mode) as archive:
        add_bytes(archive, "index.json", index)
        add_bytes(archive, "oci-layout", json_bytes({"imageLayoutVersion": "1.0.0"}))
        if include_manifest:
            add_bytes(archive, f"blobs/sha256/{hashlib.sha256(manifest).hexdigest()}", manifest)
        add_bytes(archive, f"blobs/sha256/{hashlib.sha256(config).hexdigest()}", config)
        add_bytes(archive, f"blobs/sha256/{hashlib.sha256(layer).hexdigest()}", layer)


def shell_function(name):
    lines = CREATE_SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start : end + 1])
    raise AssertionError(f"function {name} has no closing brace")


class PrepareImageArchiveTests(unittest.TestCase):
    def run_prepare(self, archive, architecture="amd64", variant=None):
        command = [sys.executable, str(PREPARE_SCRIPT), "--archive", str(archive), "--arch", architecture]
        if variant is not None:
            command.extend(("--variant", variant))
        return subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_patches_and_validates_oci_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "image.tar"
            write_oci_archive(archive_path)
            result = self.run_prepare(archive_path)
            self.assertEqual(result.returncode, 0, result.stderr)
            with tarfile.open(archive_path) as archive:
                index = json.load(archive.extractfile("index.json"))
            self.assertEqual(index["manifests"][0]["platform"], {"architecture": "amd64", "os": "linux"})

    def test_patches_and_validates_gzipped_runtime_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "image.tar.gz"
            write_oci_archive(archive_path)
            result = self.run_prepare(archive_path)
            self.assertEqual(result.returncode, 0, result.stderr)
            with tarfile.open(archive_path, "r:gz") as archive:
                index = json.load(archive.extractfile("index.json"))
            self.assertEqual(index["manifests"][0]["platform"], {"architecture": "amd64", "os": "linux"})

    def test_patches_armv7_platform_without_rejecting_32_bit_arm(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "image.tar.gz"
            write_oci_archive(archive_path, architecture="arm")
            result = self.run_prepare(archive_path, architecture="arm", variant="v7")
            self.assertEqual(result.returncode, 0, result.stderr)
            with tarfile.open(archive_path, "r:gz") as archive:
                index = json.load(archive.extractfile("index.json"))
            self.assertEqual(
                index["manifests"][0]["platform"],
                {"architecture": "arm", "os": "linux", "variant": "v7"},
            )

    def test_runtime_repair_passes_armv7_variant_to_validator(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "image.tar.gz"
            write_oci_archive(archive_path, architecture="arm")
            shell = f"""
set -eu
_yellow() {{ :; }}
SCRIPT_SOURCE_DIR={str((REPO_ROOT / 'scripts')).__repr__()}
CONTAINERD_ARCHIVE_VALIDATOR={str(PREPARE_SCRIPT).__repr__()}
{shell_function('repair_oci_archive_platform')}
repair_oci_archive_platform {str(archive_path).__repr__()} linux/arm/v7
"""
            result = subprocess.run(
                ["bash", "-c", shell], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with tarfile.open(archive_path, "r:gz") as archive:
                index = json.load(archive.extractfile("index.json"))
            self.assertEqual(
                index["manifests"][0]["platform"],
                {"architecture": "arm", "os": "linux", "variant": "v7"},
            )

    def test_rejects_null_config_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "image.tar"
            write_oci_archive(
                archive_path,
                config_descriptor={
                    "mediaType": "application/vnd.oci.image.config.v1+json",
                    "digest": None,
                    "size": 1,
                },
            )
            result = self.run_prepare(archive_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("index.json.manifests[0].config.digest", result.stderr)
            self.assertNotIn("blobs/sha256/null", result.stderr)

    def test_rejects_null_descriptor_digest_before_building_blob_path(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "image.tar"
            write_oci_archive(
                archive_path,
                root_descriptor={
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                    "digest": None,
                    "size": 1,
                },
            )
            result = self.run_prepare(archive_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("index.json.manifests[0].digest", result.stderr)
            self.assertIn("None", result.stderr)
            self.assertNotIn("blobs/sha256/null", result.stderr)

    def test_rejects_missing_descriptor_blob(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "image.tar"
            missing_digest = "0" * 64
            write_oci_archive(
                archive_path,
                root_descriptor={
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                    "digest": f"sha256:{missing_digest}",
                    "size": 1,
                },
                include_manifest=False,
            )
            result = self.run_prepare(archive_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f"missing archive member blobs/sha256/{missing_digest}", result.stderr)

    def test_does_not_guess_a_missing_docker_config(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "image.tar"
            manifest = json_bytes([{"Config": None, "RepoTags": ["test:latest"], "Layers": []}])
            with tarfile.open(archive_path, "w") as archive:
                add_bytes(archive, "manifest.json", manifest)
                add_bytes(archive, "unrelated.json", b"{}")
            result = self.run_prepare(archive_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("manifest.json[0].Config", result.stderr)

    def test_rejects_docker_config_digest_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "image.tar"
            config_name = "0" * 64
            manifest = json_bytes([{"Config": config_name, "RepoTags": ["test:latest"], "Layers": []}])
            with tarfile.open(archive_path, "w") as archive:
                add_bytes(archive, "manifest.json", manifest)
                add_bytes(archive, config_name, b'{}')
            result = self.run_prepare(archive_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Config digest mismatch", result.stderr)

    def test_runtime_loader_never_passes_invalid_archive_to_nerdctl(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "invalid.tar.gz"
            marker = Path(directory) / "nerdctl-called"
            write_oci_archive(
                archive_path,
                config_descriptor={
                    "mediaType": "application/vnd.oci.image.config.v1+json",
                    "digest": None,
                    "size": 1,
                },
            )
            shell = f"""
set -u
_yellow() {{ :; }}
SCRIPT_SOURCE_DIR={str((REPO_ROOT / 'scripts')).__repr__()}
CONTAINERD_ARCHIVE_VALIDATOR={str(PREPARE_SCRIPT).__repr__()}
{shell_function('repair_oci_archive_platform')}
{shell_function('load_image_archive')}
nerdctl() {{ printf '%s\n' called > {str(marker).__repr__()}; return 0; }}
if load_image_archive {str(archive_path).__repr__()} linux/amd64; then
    exit 2
fi
test ! -e {str(marker).__repr__()}
"""
            result = subprocess.run(
                ["bash", "-c", shell], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists(), "nerdctl was invoked for an invalid archive")


if __name__ == "__main__":
    unittest.main()
