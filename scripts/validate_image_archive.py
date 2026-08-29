#!/usr/bin/env python3
import argparse
import copy
import hashlib
import io
import json
import os
import re
import stat
import sys
import tarfile
import tempfile


SHA256_DIGEST = re.compile(r"sha256:([0-9a-f]{64})\Z")
INDEX_MEDIA_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}


class ArchiveError(ValueError):
    pass


def read_json_member(archive, members, name, context):
    member = members.get(name)
    if member is None or not member.isfile():
        raise ArchiveError(f"{context} is missing from the archive")
    source = archive.extractfile(member)
    if source is None:
        raise ArchiveError(f"{context} cannot be read from the archive")
    try:
        return json.load(source)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ArchiveError(f"{context} is not valid JSON: {exc}") from exc


def descriptor_blob_path(descriptor, context):
    if not isinstance(descriptor, dict):
        raise ArchiveError(f"{context} is not an object")
    digest = descriptor.get("digest")
    match = SHA256_DIGEST.fullmatch(digest) if isinstance(digest, str) else None
    if match is None:
        raise ArchiveError(f"{context}.digest is not a sha256:<64 lowercase hex> value: {digest!r}")
    return f"blobs/sha256/{match.group(1)}", match.group(1)


def read_and_verify_blob(archive, members, descriptor, context, return_data=False):
    path, expected_digest = descriptor_blob_path(descriptor, context)
    member = members.get(path)
    if member is None or not member.isfile():
        raise ArchiveError(f"{context} references missing archive member {path}")

    expected_size = descriptor.get("size")
    if isinstance(expected_size, bool) or not isinstance(expected_size, int) or expected_size < 0:
        raise ArchiveError(f"{context}.size is not a non-negative integer: {expected_size!r}")
    if member.size != expected_size:
        raise ArchiveError(
            f"{context} size mismatch for {path}: descriptor={expected_size}, archive={member.size}"
        )

    source = archive.extractfile(member)
    if source is None:
        raise ArchiveError(f"{context} cannot read archive member {path}")
    digest = hashlib.sha256()
    data = bytearray() if return_data else None
    while True:
        chunk = source.read(1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        if data is not None:
            data.extend(chunk)
    actual_digest = digest.hexdigest()
    if actual_digest != expected_digest:
        raise ArchiveError(
            f"{context} digest mismatch for {path}: descriptor={expected_digest}, actual={actual_digest}"
        )
    return bytes(data) if data is not None else None


def parse_descriptor_json(data, context):
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ArchiveError(f"{context} blob is not valid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ArchiveError(f"{context} blob is not a JSON object")
    return value


def validate_descriptor(archive, members, descriptor, context):
    data = read_and_verify_blob(archive, members, descriptor, context, return_data=True)
    media_type = descriptor.get("mediaType", "")
    if media_type in INDEX_MEDIA_TYPES:
        nested = parse_descriptor_json(data, context)
        manifests = nested.get("manifests")
        if not isinstance(manifests, list) or not manifests:
            raise ArchiveError(f"{context} index has no manifests")
        for index, child in enumerate(manifests):
            validate_descriptor(archive, members, child, f"{context}.manifests[{index}]")
        return

    manifest = parse_descriptor_json(data, context)
    config = manifest.get("config")
    layers = manifest.get("layers")
    if not isinstance(config, dict) or not isinstance(layers, list):
        raise ArchiveError(f"{context} is not an OCI image manifest")
    read_and_verify_blob(archive, members, config, f"{context}.config")
    for index, layer in enumerate(layers):
        read_and_verify_blob(archive, members, layer, f"{context}.layers[{index}]")


def validate_docker_path(members, value, context):
    if not isinstance(value, str) or not value or value.startswith("/"):
        raise ArchiveError(f"{context} is not a valid archive member path: {value!r}")
    normalized = os.path.normpath(value)
    if normalized == ".." or normalized.startswith("../") or normalized != value:
        raise ArchiveError(f"{context} is not a safe archive member path: {value!r}")
    member = members.get(value)
    if member is None or not member.isfile():
        raise ArchiveError(f"{context} references missing archive member {value}")


def read_docker_member(archive, members, name, context, parse_json=False):
    member = members[name]
    source = archive.extractfile(member)
    if source is None:
        raise ArchiveError(f"{context} cannot read archive member {name}")
    digest = hashlib.sha256()
    data = bytearray() if parse_json else None
    while True:
        chunk = source.read(1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        if data is not None:
            data.extend(chunk)
            if len(data) > 32 * 1024 * 1024:
                raise ArchiveError(f"{context} is unexpectedly large")

    expected_digest = None
    if name.startswith("blobs/sha256/") and re.fullmatch(r"[0-9a-f]{64}", name[13:]):
        expected_digest = name[13:]
    else:
        base_name = os.path.basename(name)
        if re.fullmatch(r"[0-9a-f]{64}", base_name):
            expected_digest = base_name
        elif re.fullmatch(r"[0-9a-f]{64}\.json", base_name):
            expected_digest = base_name[:-5]
    if expected_digest is not None and digest.hexdigest() != expected_digest:
        raise ArchiveError(
            f"{context} digest mismatch for {name}: expected={expected_digest}, actual={digest.hexdigest()}"
        )
    return bytes(data) if data is not None else None


def validate_docker_manifest(archive, manifest, members):
    if not isinstance(manifest, list) or not manifest:
        raise ArchiveError("manifest.json is not a non-empty array")
    for index, entry in enumerate(manifest):
        context = f"manifest.json[{index}]"
        if not isinstance(entry, dict):
            raise ArchiveError(f"{context} is not an object")
        validate_docker_path(members, entry.get("Config"), f"{context}.Config")
        config_data = read_docker_member(
            archive, members, entry["Config"], f"{context}.Config", parse_json=True
        )
        parse_descriptor_json(config_data, f"{context}.Config")
        layers = entry.get("Layers")
        if not isinstance(layers, list):
            raise ArchiveError(f"{context}.Layers is not an array")
        for layer_index, layer in enumerate(layers):
            layer_context = f"{context}.Layers[{layer_index}]"
            validate_docker_path(members, layer, layer_context)
            read_docker_member(archive, members, layer, layer_context)


def archive_mode(archive_path, write=False):
    """Use the same compression format when reading and atomically rewriting."""
    compressed = str(archive_path).lower().endswith((".gz", ".tgz"))
    if write:
        return "w:gz" if compressed else "w:"
    return "r:*"


def rewrite_json_member(archive_path, target_name, replacement):
    directory = os.path.dirname(os.path.abspath(archive_path))
    mode = stat.S_IMODE(os.stat(archive_path).st_mode)
    temporary = tempfile.NamedTemporaryFile(
        prefix=f".{os.path.basename(archive_path)}.", suffix=".tmp", dir=directory, delete=False
    )
    temporary_path = temporary.name
    temporary.close()
    try:
        with tarfile.open(archive_path, mode="r:*") as source, tarfile.open(
            temporary_path, mode=archive_mode(archive_path, write=True)
        ) as output:
            for member in source.getmembers():
                output_member = copy.copy(member)
                if member.name == target_name:
                    output_member.size = len(replacement)
                    output.addfile(output_member, io.BytesIO(replacement))
                else:
                    output.addfile(output_member, source.extractfile(member) if member.isfile() else None)
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, archive_path)
    except Exception:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass
        raise


def platform_label(architecture, variant):
    return f"linux/{architecture}" if variant is None else f"linux/{architecture}/{variant}"


def platform_matches(value, architecture, variant):
    if not isinstance(value, dict):
        return False
    if value.get("os") != "linux" or value.get("architecture") != architecture:
        return False
    return variant is None or value.get("variant") == variant


def prepare_archive(archive_path, architecture, variant=None):
    platform = {"architecture": architecture, "os": "linux"}
    if variant is not None:
        platform["variant"] = variant
    replacement_name = None
    replacement = None

    with tarfile.open(archive_path, mode="r:*") as archive:
        member_list = archive.getmembers()
        members = {member.name: member for member in member_list}
        if len(members) != len(member_list):
            raise ArchiveError("archive contains duplicate member names")

        if "index.json" in members:
            index = read_json_member(archive, members, "index.json", "index.json")
            manifests = index.get("manifests") if isinstance(index, dict) else None
            if not isinstance(manifests, list) or not manifests:
                raise ArchiveError("index.json has no manifests")
            changed = False
            for descriptor_index, descriptor in enumerate(manifests):
                context = f"index.json.manifests[{descriptor_index}]"
                validate_descriptor(archive, members, descriptor, context)
                current_platform = descriptor.get("platform")
                if current_platform is None:
                    descriptor["platform"] = platform
                    changed = True
                elif not isinstance(current_platform, dict):
                    raise ArchiveError(f"{context}.platform is not an object")
                elif not platform_matches(current_platform, architecture, variant):
                    if (
                        variant is not None
                        and current_platform.get("os") == "linux"
                        and current_platform.get("architecture") == architecture
                        and current_platform.get("variant") is None
                    ):
                        current_platform["variant"] = variant
                        changed = True
                        continue
                    raise ArchiveError(
                        f"{context}.platform does not match {platform_label(architecture, variant)}: {current_platform!r}"
                    )
            if "manifest.json" in members:
                docker_manifest = read_json_member(archive, members, "manifest.json", "manifest.json")
                validate_docker_manifest(archive, docker_manifest, members)
            if changed:
                replacement_name = "index.json"
                replacement = json.dumps(index, separators=(",", ":")).encode() + b"\n"
        elif "manifest.json" in members:
            manifest = read_json_member(archive, members, "manifest.json", "manifest.json")
            validate_docker_manifest(archive, manifest, members)
            changed = False
            for entry in manifest:
                platform_key = "platform" if "platform" in entry else "Platform" if "Platform" in entry else "platform"
                current_platform = entry.get(platform_key)
                if current_platform is None:
                    entry[platform_key] = platform
                    changed = True
                elif not platform_matches(current_platform, architecture, variant):
                    if (
                        variant is not None
                        and isinstance(current_platform, dict)
                        and current_platform.get("os") == "linux"
                        and current_platform.get("architecture") == architecture
                        and current_platform.get("variant") is None
                    ):
                        current_platform["variant"] = variant
                        changed = True
                        continue
                    raise ArchiveError(
                        f"manifest.json platform does not match {platform_label(architecture, variant)}: {current_platform!r}"
                    )
            if changed:
                replacement_name = "manifest.json"
                replacement = json.dumps(manifest, separators=(",", ":")).encode() + b"\n"
        else:
            raise ArchiveError("archive has neither index.json nor manifest.json")

    if replacement_name is not None:
        rewrite_json_member(archive_path, replacement_name, replacement)
        print(f"[OK] patched {replacement_name} with platform {platform_label(architecture, variant)}")
    else:
        print(f"[OK] archive already declares platform {platform_label(architecture, variant)}")
    print("[OK] archive descriptors and referenced members are valid")


def main():
    parser = argparse.ArgumentParser(description="Patch and validate a docker save/OCI image archive")
    parser.add_argument("--archive", required=True)
    parser.add_argument("--arch", required=True, choices=("amd64", "arm64", "arm"))
    parser.add_argument("--variant")
    args = parser.parse_args()
    try:
        prepare_archive(args.archive, args.arch, args.variant)
    except (ArchiveError, OSError, tarfile.TarError) as exc:
        print(f"archive validation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
