import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('native_key', HERE / 'native-cache-key.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class NativeArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        files = ('docker/Dockerfile.app', 'scripts/build_browserskill.sh', 'scripts/browserskill-release.json',
                 'scripts/build-anydoc-lib.sh', 'third_party/anydoc-go/Cargo.toml',
                 'third_party/anydoc-go/Cargo.lock', 'third_party/anydoc-go/build.rs',
                 'third_party/anydoc-go/version.go', 'third_party/anydoc-go/LICENSE',
                 'third_party/anydoc-go/src/lib.rs', 'third_party/anydoc-go/include/anydoc.h')
        for name in files:
            p=self.root/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_text(name)
        p=self.root/'deploy/cloud'; p.mkdir(parents=True)
        shutil.copy(HERE/'native-cache-key.py',p/'native-cache-key.py')
        shutil.copy(HERE/'native-artifacts.sh',p/'native-artifacts.sh')
    def keys(self):
        return [module.cache_key(self.root,c) for c in ('browserskill','anydoc')]
    def test_application_changes_reuse_both(self):
        before=self.keys()
        (self.root/'go.mod').write_text('module changed')
        (self.root/'internal').mkdir(); (self.root/'internal/app.go').write_text('new app code')
        self.assertEqual(before,self.keys())
    def test_browser_pin_only_changes_browser(self):
        before=self.keys(); (self.root/'scripts/browserskill-release.json').write_text('new pin')
        after=self.keys(); self.assertNotEqual(before[0],after[0]); self.assertEqual(before[1],after[1])
    def test_rust_source_only_changes_anydoc(self):
        before=self.keys(); (self.root/'third_party/anydoc-go/src/lib.rs').write_text('new rust')
        after=self.keys(); self.assertEqual(before[0],after[0]); self.assertNotEqual(before[1],after[1])
    def test_recipe_changes_invalidate_both(self):
        before=self.keys(); (self.root/'docker/Dockerfile.app').write_text('new compiler ABI')
        self.assertTrue(all(a!=b for a,b in zip(before,self.keys())))
    def run_helper(self,hit,fail=False):
        bindir=self.root/'bin'; bindir.mkdir()
        docker=bindir/'docker'
        docker.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$CALLS"
if [[ "$1 $2" == 'manifest inspect' ]]; then [[ "$HIT" == 1 ]]; exit $?; fi
if [[ "$1 $2" == 'buildx build' && "$FAIL" == 1 ]]; then exit 1; fi
exit 0
''');docker.chmod(0o755)
        log=self.root/'calls'
        env=dict(os.environ,PATH=str(bindir)+os.pathsep+os.environ['PATH'],CALLS=str(log),HIT=str(int(hit)),FAIL=str(int(fail)))
        result=subprocess.run(['bash','-ec','source "$1"; tcb_repo=ccr.ccs.tencentyun.com/test/repo; ensure_native_artifacts "$2"',
                               'test',str(HERE/'native-artifacts.sh'),str(self.root)],env=env,capture_output=True,text=True)
        return result,log.read_text()
    def test_registry_hit_never_compiles_or_pushes(self):
        result,calls=self.run_helper(True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(calls.count('manifest inspect'),2)
        self.assertNotIn('buildx build',calls); self.assertNotIn('push ',calls)
    def test_registry_miss_builds_separate_small_targets(self):
        result,calls=self.run_helper(False)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('--target browserskill-artifacts',calls)
        self.assertIn('--target anydoc-artifacts',calls)
        self.assertEqual(sum(c.startswith('push ') for c in calls.splitlines()),2)
    def test_native_build_failure_does_not_push(self):
        result,calls=self.run_helper(False,True)
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('push ',calls)

if __name__=='__main__': unittest.main()
