#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/containerdinstall.sh"

extract_function() {
    local name="$1"
    awk -v name="$name" '
        $0 == name "() {" { printing = 1 }
        printing {
            print
            if ($0 == "}") {
                exit
            }
        }
    ' "$installer"
}

# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function derive_containerd_ipv6_subnet)
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
source <(extract_function is_public_ipv6)
# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function detect_global_ipv6_cidr)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function ndpresponder_image_matches_architecture)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function resolve_ndpresponder_image)

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/containerd-ipv6-test.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT
cat > "$tmpdir/ip" <<'EOF'
#!/bin/sh
printf '%s\n' '2: eth0    inet6 fd42::1/64 scope global'
printf '%s\n' '2: eth0    inet6 2a14:6781:000a:0000::9/64 scope global tentative'
printf '%s\n' '2: eth0    inet6 2a14:6781:000a:0000::10/64 scope global'
EOF
chmod 700 "$tmpdir/ip"

host_cidr="2a14:6781:000a:0000::9/64"
old_path="$PATH"
export PATH="$tmpdir:$PATH"
detected=$(detect_global_ipv6_cidr eth0)
if [[ "$detected" != "2a14:6781:000a:0000::10/64" ]]; then
    printf 'local public CIDR detection returned %q\n' "$detected" >&2
    exit 1
fi
candidate=$(derive_containerd_ipv6_subnet "$host_cidr" 96 0 false)
if derive_containerd_ipv6_subnet "$host_cidr" 96 0 true >/dev/null; then
    printf 'explicit host-containing CNI subnet was accepted\n' >&2
    exit 1
fi
export PATH="$old_path"

if ! is_public_ipv6 "2a14:6781:a::9"; then
    printf 'expected a global unicast IPv6 to be accepted\n' >&2
    exit 1
fi
for non_public in "fec0::1" "ff02::1" "64:ff9b::1" "2001:0000::1" "2001:0002::1" "2001:0010::1" "2001:0020::1" "2001:0db8::1" "2002::1" "3fff:000f::1"; do
    if is_public_ipv6 "$non_public"; then
        printf 'non-public IPv6 was accepted as a Containerd source: %s\n' "$non_public" >&2
        exit 1
    fi
done

python3 - "$host_cidr" "$candidate" <<'PY'
import ipaddress
import sys

host = ipaddress.IPv6Interface(sys.argv[1])
candidate = ipaddress.IPv6Network(sys.argv[2])
if candidate.prefixlen != 96:
    raise SystemExit(f"unexpected prefix length: {candidate}")
if candidate.network_address not in host.network or candidate.broadcast_address not in host.network:
    raise SystemExit(f"candidate outside parent: {candidate}")
if host.ip in candidate:
    raise SystemExit(f"candidate contains host address: {candidate}")
PY

if extract_function check_ipv6 | grep -Eq 'API_NET|curl[[:space:]]'; then
    printf 'check_ipv6 must not use an external address as a CNI subnet source\n' >&2
    exit 1
fi
if ! extract_function adapt_ipv6 | grep -Fq 'net.ipv6.conf.${interface}.accept_ra=2'; then
    printf 'Containerd IPv6 forwarding must preserve router advertisements on the uplink\n' >&2
    exit 1
fi
if ! ndpresponder_image_matches_architecture arm64 arm64 ||
   ! ndpresponder_image_matches_architecture arm arm ||
   ndpresponder_image_matches_architecture arm64 amd64 ||
   ndpresponder_image_matches_architecture arm amd64; then
    printf 'Containerd responder image architecture validation is incorrect\n' >&2
    exit 1
fi
if ! grep -Fq 'arm64) arch_tag="aarch64"' "$installer" ||
   ! grep -Fq 'NDPRESPONDER_SOURCE_URL' "$installer"; then
    printf 'Containerd must select the published aarch64 responder tag on ARM64\n' >&2
    exit 1
fi
_yellow() { :; }
ARCH_TYPE=arm64
mock_build_succeeds=true
mock_build_called=false
mock_remove_called=false
mock_git_clone_called=false
git() {
    case "$1:$2" in
        clone:--depth)
            mock_git_clone_called=true
            return 0
            ;;
        *)
            printf 'unexpected git invocation during resolver test: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
nerdctl() {
    case "$1:$2" in
        pull:*)
            return 0
            ;;
        image:inspect)
            case "$*" in
                *localhost/oneclickvirt-ndpresponder:arm64*) printf '%s\n' arm64 ;;
                *) printf '%s\n' amd64 ;;
            esac
            return 0
            ;;
        build:--tag)
            local build_context=""
            for build_context in "$@"; do :; done
            [[ "$build_context" != *"://"* ]] || return 1
            mock_build_called=true
            "$mock_build_succeeds"
            return
            ;;
        rm:*)
            mock_remove_called=true
            return 0
            ;;
        *)
            printf 'unexpected nerdctl invocation during resolver test: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
NDPRESPONDER_SOURCE_URL=https://example.invalid/ndpresponder.git
if ! resolve_ndpresponder_image; then
    printf 'Containerd did not build a validated local responder after a bad registry architecture\n' >&2
    exit 1
fi
[[ "$NDPRESPONDER_IMAGE" == 'localhost/oneclickvirt-ndpresponder:arm64' ]] || {
    printf 'Containerd resolver selected %q instead of the validated local responder\n' "$NDPRESPONDER_IMAGE" >&2
    exit 1
}
[[ "$mock_git_clone_called" == true && "$mock_build_called" == true && "$mock_remove_called" == false ]] || {
    printf 'Containerd resolver mutated a responder container before the caller could validate the fallback\n' >&2
    exit 1
}

# A broken remote ARM tag must not tear down a known-good responder before the
# new image has passed architecture validation.
# shellcheck disable=SC1090 # The test intentionally loads the installer function.
source <(extract_function start_ndpresponder)
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer function.
_yellow() { :; }
# shellcheck disable=SC2034 # Read by the dynamically sourced installer function.
ARCH_TYPE=arm64
nerdctl_rm_called=false
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer function.
mkdir() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer function.
nerdctl() {
    case "$1:$2" in
        pull:*)
            return 0
            ;;
        image:inspect)
            printf '%s\n' amd64
            return 0
            ;;
        build:--tag)
            return 1
            ;;
        rm:*)
            nerdctl_rm_called=true
            return 0
            ;;
        *)
            printf 'unexpected nerdctl invocation during architecture guard: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
if start_ndpresponder; then
    printf 'Containerd accepted an amd64 responder image on ARM64\n' >&2
    exit 1
fi
[[ "$nerdctl_rm_called" == false ]] || {
    printf 'Containerd removed the existing responder before rejecting the wrong architecture\n' >&2
    exit 1
}

printf 'containerd IPv6 network candidate tests passed\n'
