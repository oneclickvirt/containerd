import ipaddress
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'scripts/onecontainerd.sh').read_text()
ALLOCATOR = SOURCE.split("<<'PYSTATIC'\n", 1)[1].split('\nPYSTATIC', 1)[0]

class AllocationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / 'subnet'
        self.state.write_text('2001:db8::/125')
        self.records = self.root / 'records'
        self.leases = self.root / 'leases'
        self.records.mkdir()
        self.leases.mkdir()

    def run_allocator(self, name):
        return subprocess.run([sys.executable, '-', str(self.state), str(self.records), name, str(self.leases)], input=ALLOCATOR, text=True, capture_output=True)

    def allocate(self, name):
        result = self.run_allocator(name)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_persistent_unique_and_permission(self):
        first = self.allocate('one')
        self.assertEqual(self.allocate('one'), first)
        second = self.allocate('two')
        self.assertNotEqual(first, second)
        self.assertNotIn(first, ['2001:db8::', '2001:db8::1'])
        self.assertEqual((self.records / 'one.json').stat().st_mode & 0o777, 0o600)

    def test_external_lease_and_full_pool(self):
        for i in range(2, 7):
            (self.leases / str(ipaddress.IPv6Address('2001:db8::') + i)).touch()
        self.assertEqual(self.allocate('one'), '2001:db8::7')
        result = self.run_allocator('two')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('allocation budget', result.stderr)

    def test_subnet_change_and_invalid_state(self):
        self.allocate('one')
        self.state.write_text('2001:db8:1::/120')
        self.assertIn(ipaddress.IPv6Address(self.allocate('one')), ipaddress.IPv6Network('2001:db8:1::/120'))
        (self.records / 'bad.json').write_text('bad json')
        self.assertNotEqual(self.run_allocator('two').returncode, 0)

    @unittest.skipUnless(shutil.which('flock'), 'requires Linux flock')
    def test_lock_covers_creation_and_help_capability(self):
        function = SOURCE.split('reserve_containerd_ipv6() {', 1)[1].split('\n# ======== 主逻辑', 1)[0]
        function = 'reserve_containerd_ipv6() {' + function
        script = """set -eu
_red() { echo "$*" >&2; }
check_container_name_available() { :; }
nerdctl() { printf '%s\\n' "${MOCK_HELP:---ip6 string}"; }
""" + function + """
name="$1"
reserve_containerd_ipv6 >"$CONTAINERD_IPV6_ALLOCATION_DIR/$name.out"
echo "begin:$name" >>"$CONTAINERD_IPV6_ALLOCATION_DIR/trace"
sleep 0.1
echo "end:$name" >>"$CONTAINERD_IPV6_ALLOCATION_DIR/trace"
"""
        # The real state file name used by the shell function.
        (self.root / 'containerd_ipv6_subnet').write_text('2001:db8::/120')
        env = dict(os.environ, CONTAINERD_IPV6_STATE_DIR=str(self.root), CONTAINERD_IPV6_ALLOCATION_DIR=str(self.records), CONTAINERD_CNI_LEASE_DIR=str(self.leases))
        workers = [subprocess.Popen(['bash', '-c', script, 'audit', 'ct' + str(i)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for i in range(4)]
        for worker in workers:
            out, err = worker.communicate(timeout=20)
            self.assertEqual(worker.returncode, 0, out + err)
        lines = (self.records / 'trace').read_text().splitlines()
        for i in range(0, len(lines), 2):
            self.assertEqual(lines[i].replace('begin:', 'end:'), lines[i + 1])
        addresses = [(self.records / ('ct' + str(i) + '.out')).read_text().strip() for i in range(4)]
        self.assertEqual(len(set(addresses)), 4)
        result = subprocess.run(['bash', '-c', script, 'audit', 'old-cli'], env=dict(env, MOCK_HELP='--ip string'), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not support --ip6', result.stderr)

    def test_too_small(self):
        self.state.write_text('2001:db8::/127')
        self.assertNotEqual(self.run_allocator('one').returncode, 0)

if __name__ == '__main__':
    unittest.main()
