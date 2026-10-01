#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
uninstaller="$repo_root/containerduninstall.sh"
source_text=$(<"$uninstaller")

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

extract_function() {
    awk -v name="$1" '
        $0 == name "() {" { printing=1 }
        printing { print }
        printing && /^}$/ { exit }
    ' "$uninstaller"
}

source <(extract_function containerd_is_shared)

package_owns_path() { return 1; }
systemctl() {
    [[ "$*" == 'cat docker.service' ]] &&
        printf '%s\n' 'ExecStart=/usr/bin/dockerd --containerd=/run/containerd/containerd.sock'
}
containerd_is_shared || fail 'Docker external containerd socket was not recognized as shared'

systemctl() { :; }
package_owns_path() { [[ "$1" == /usr/bin/containerd ]]; }
containerd_is_shared || fail 'package-owned containerd was not recognized as shared'

package_owns_path() { return 1; }
if containerd_is_shared; then
    fail 'clean bundle-owned containerd was misclassified as shared'
fi

grep -Fq 'managed_namespace="${CONTAINERD_NAMESPACE:-default}"' <<<"$source_text" ||
    fail 'uninstall does not restrict cleanup to the managed namespace'
if grep -Fq 'nerdctl namespace ls' <<<"$source_text"; then
    fail 'uninstall still enumerates Docker/Kubernetes containerd namespaces'
fi
grep -Fq '[[ "$CONTAINERD_SHARED" == true ]] || services+=(containerd)' <<<"$source_text" ||
    fail 'shared containerd can still be stopped or disabled'
grep -Fq '[[ -d /etc/containerd && "$CONTAINERD_SHARED" != true ]]' <<<"$source_text" ||
    fail 'shared containerd configuration is not protected'
grep -Fq 'data_dirs+=(/var/lib/containerd /run/containerd)' <<<"$source_text" ||
    fail 'shared containerd data and socket ownership are not protected'
grep -Fq 'package_owns_path "$f"' <<<"$source_text" ||
    fail 'package-owned systemd units are not protected'

printf 'Containerd uninstall cross-runtime safety passed\n'
