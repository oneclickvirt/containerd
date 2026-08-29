#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpbin=$(mktemp -d "${TMPDIR:-/tmp}/containerd-script-smoke.XXXXXX")
trap 'rm -rf -- "$tmpbin"' EXIT

cd "$repo_root"

bash -n containerdinstall.sh
bash -n containerduninstall.sh
bash -n scripts/create_containerd.sh
bash -n scripts/onecontainerd.sh
bash -n scripts/containerd_manage.sh
bash -n scripts/ssh_bash.sh
sh -n scripts/ssh_sh.sh
python3 tests/test_image_archive.py
bash tests/test_ipv6_network.sh
bash tests/test_creation_rollback.sh
bash tests/test_batch_creation_rollback.sh
bash scripts/create_containerd.sh --help >"$tmpbin/create-help"
bash scripts/containerd_manage.sh --help >"$tmpbin/manage-help"

archive_fixture="$tmpbin/image.tar.gz"
smoke_workdir="$tmpbin/work"
mkdir -p "$smoke_workdir"
fixture_arch=amd64
case "$(uname -m)" in
    aarch64|arm64) fixture_arch=arm64 ;;
esac
python3 - "$archive_fixture" "$fixture_arch" <<'PYFIXTURE'
import hashlib
import io
import json
import sys
import tarfile


def encoded(value):
    return json.dumps(value, separators=(",", ":")).encode()


def add_bytes(archive, name, data):
    member = tarfile.TarInfo(name)
    member.size = len(data)
    archive.addfile(member, io.BytesIO(data))


config = encoded({"architecture": sys.argv[2], "os": "linux"})
layer = b"smoke-layer"
config_digest = hashlib.sha256(config).hexdigest()
layer_digest = hashlib.sha256(layer).hexdigest()
manifest = encoded({
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {
        "mediaType": "application/vnd.oci.image.config.v1+json",
        "digest": f"sha256:{config_digest}",
        "size": len(config),
    },
    "layers": [{
        "mediaType": "application/vnd.oci.image.layer.v1.tar",
        "digest": f"sha256:{layer_digest}",
        "size": len(layer),
    }],
})
manifest_digest = hashlib.sha256(manifest).hexdigest()
index = encoded({
    "schemaVersion": 2,
    "manifests": [{
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "digest": f"sha256:{manifest_digest}",
        "size": len(manifest),
    }],
})
with tarfile.open(sys.argv[1], "w:gz") as archive:
    add_bytes(archive, "index.json", index)
    add_bytes(archive, "oci-layout", encoded({"imageLayoutVersion": "1.0.0"}))
    add_bytes(archive, f"blobs/sha256/{manifest_digest}", manifest)
    add_bytes(archive, f"blobs/sha256/{config_digest}", config)
    add_bytes(archive, f"blobs/sha256/{layer_digest}", layer)
PYFIXTURE

export ARCHIVE_FIXTURE="$archive_fixture"
export VALIDATOR_SOURCE="$repo_root/scripts/validate_image_archive.py"

cat > "$tmpbin/nerdctl" <<'NERDCTL'
#!/bin/sh
case "${1:-}" in
    image)
        [ "${2:-}" = "inspect" ] && exit 1
        ;;
    pull|tag|cp|exec|commit|export|stats|load)
        exit 0
        ;;
    run)
        printf '%s\n' 'fake-container-id'
        exit 0
        ;;
    ps|images)
        exit 0
        ;;
esac
exit 0
NERDCTL
chmod +x "$tmpbin/nerdctl"

cat > "$tmpbin/curl" <<'FAKECURL'
#!/bin/sh
output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--output)
            shift
            output="${1:-}"
            ;;
        --output=*)
            output="${1#--output=}"
            ;;
    esac
    shift || break
done
if [ -n "$output" ]; then
    case "$output" in
        *.tar.gz)
            cp "$ARCHIVE_FIXTURE" "$output"
            ;;
        *.py)
            cp "$VALIDATOR_SOURCE" "$output"
            ;;
        *)
            printf '%s\n' 'fake-download' > "$output"
            ;;
    esac
    exit 0
fi
printf '%s\n' '127.0.0.1'
FAKECURL
chmod +x "$tmpbin/curl"

cat > "$tmpbin/noop" <<'NOOP'
#!/bin/sh
exit 0
NOOP
chmod +x "$tmpbin/noop"

for command_name in iptables ip6tables iptables-save ip6tables-save nft systemctl service rc-update rc-service netfilter-persistent; do
    ln -sf "$tmpbin/noop" "$tmpbin/$command_name"
done

(
    cd "$smoke_workdir"
    PATH="$tmpbin:$PATH" ONECLICKVIRT_TESTING=1 WITHOUTCDN=TRUE bash "$repo_root/scripts/onecontainerd.sh" ctSmoke 0.5 64 "pass'word" 25001 35001 35002 n debian 0
    PATH="$tmpbin:$PATH" \
        ONECLICKVIRT_TESTING=1 \
        WITHOUTCDN=TRUE \
        noninteractive=true \
        CONTAINERD_CREATE_COUNT=1 \
        CONTAINERD_CONTAINER_MEMORY=64 \
        CONTAINERD_CONTAINER_CPU=0.5 \
        CONTAINERD_CONTAINER_DISK=0 \
        CONTAINERD_CONTAINER_SYSTEM=alpine \
        CONTAINERD_CONTAINER_IPV6=n \
        bash -c 'source "$1"; main' _ "$repo_root/scripts/create_containerd.sh"
    PATH="$tmpbin:$PATH" ONECLICKVIRT_TESTING=1 WITHOUTCDN=TRUE bash "$repo_root/scripts/containerd_manage.sh" version-check debian >"$tmpbin/version-check"
)

printf 'Containerd script smoke tests passed\n'
