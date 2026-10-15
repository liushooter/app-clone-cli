import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


MOCK = r"""#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
args = sys.argv[1:]
tool = pathlib.Path(sys.argv[0]).name
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(tool + ' ' + ' '.join(args) + '\n')
case = os.environ['CASE']
if tool == 'git':
    if args[0] == 'status':
        print(' M dirty' if case == 'dirty' else '')
    elif args[0] == 'rev-parse':
        print('newsha')
    elif args[0] == 'ls-remote':
        print(('newsha' if case in ('same', 'active') else 'oldsha') + '\trefs/tags/v0.2.0')
elif args[:2] == ['repo', 'view']:
    print('owner/repo')
elif args[:2] == ['release', 'view']:
    marker = pathlib.Path(os.environ['COMMAND_LOG'] + '.viewed')
    print(json.dumps({'body': 'changed' if case == 'metadata' and marker.exists() else 'original'}))
    marker.touch()
elif args[:2] == ['run', 'list']:
    print('123')
elif args[:2] == ['run', 'view']:
    print('in_progress' if case == 'active' else 'completed')
elif args[:2] == ['run', 'watch']:
    sys.exit(1 if case == 'failed' else 0)
elif args[:2] == ['release', 'download']:
    dest = pathlib.Path(args[args.index('--dir') + 1])
    sums = []
    for chip in ('apple-silicon', 'intel'):
        name = f'app-clone-v0.2.0-macos-{chip}.tar.gz'
        data = chip.encode()
        (dest / name).write_bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        sums.append(f'{digest}  ./{name}\n')
    (dest / 'sha256sums.txt').write_text(''.join(sums))
    if case == 'corrupt':
        (dest / name).write_bytes(b'corrupt')
"""


class RepublishTests(unittest.TestCase):
    def run_case(self, case, *args):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copy(Path(__file__).resolve().parents[1] / "republish.sh", root)
            (root / "sources/core").mkdir(parents=True)
            (root / "sources/core/version.swift").write_text(
                'public static let current = "0.2.0"\n'
            )
            (root / "bin").mkdir()
            for tool in ("git", "gh"):
                path = root / "bin" / tool
                path.write_text(MOCK)
                path.chmod(0o755)
            log = root / "commands"
            result = subprocess.run(
                ["bash", str(root / "republish.sh"), *args],
                env={
                    **os.environ,
                    "PATH": f"{root / 'bin'}:{os.environ['PATH']}",
                    "COMMAND_LOG": str(log),
                    "CASE": case,
                },
                capture_output=True,
                text=True,
            )
            return result, log.read_text() if log.exists() else ""

    def test_update_tag_with_lease_and_verify(self):
        result, log = self.run_case("new")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--force-with-lease=refs/tags/v0.2.0:oldsha", log)
        self.assertIn("gh run watch 123", log)
        self.assertIn("gh release download", log)
        self.assertNotIn("gh release edit", log)

    def test_same_commit_reruns_without_pushing(self):
        result, log = self.run_case("same")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("gh run rerun 123", log)
        self.assertNotIn("git push", log)

    def test_active_run_is_reused(self):
        result, log = self.run_case("active")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("gh run rerun", log)

    def test_dirty_tree_and_wrong_version_do_not_publish(self):
        for case, args in [("dirty", []), ("new", ["v9.0.0"])]:
            with self.subTest(case=case):
                result, log = self.run_case(case, *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("git push", log)
                self.assertNotIn("gh run", log)

    def test_failed_workflow_metadata_change_and_corruption_fail(self):
        for case in ("failed", "metadata", "corrupt"):
            with self.subTest(case=case):
                result, _ = self.run_case(case)
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
