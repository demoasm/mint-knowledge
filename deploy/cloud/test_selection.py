import contextlib,io,json,runpy,sys,unittest
from pathlib import Path
from unittest.mock import patch
SCRIPT=Path(__file__).with_name('select-components.py')
class SelectionTests(unittest.TestCase):
 def selected(self,files,requested="auto"):
  output=io.StringIO()
  with patch.object(sys,'argv',[str(SCRIPT),'base','head',requested]),patch('subprocess.run'),patch('subprocess.check_output',return_value=files),contextlib.redirect_stdout(output):
   runpy.run_path(str(SCRIPT),run_name='__main__')
  values=dict(line.split('=',1) for line in output.getvalue().splitlines())
  return values['components'],json.loads(values['matrix'])['include']
 def test_ui_only(self): self.assertEqual(self.selected('frontend/src/App.vue\n')[0],'frontend')
 def test_app_only(self): self.assertEqual(self.selected('internal/handler/model.go\n')[0],'app')
 def test_native_recipe(self): self.assertEqual(self.selected('deploy/cloud/native-artifacts.sh\n')[0],'app')
 def test_parser_only(self): self.assertEqual(self.selected('docreader/requirements.txt\n')[0],'docreader')
 def test_forced_components(self): self.assertEqual(self.selected('', 'app,frontend')[0], 'app,frontend')
 def test_invalid_override(self):
  with self.assertRaises(SystemExit): self.selected('', 'postgres')
 def test_docs_skip(self): self.assertEqual(self.selected('README.md\n.github/workflows/fork-deploy.yml\n')[1],[])
 def test_mixed(self): self.assertEqual(self.selected('internal/types/model.go\nfrontend/src/main.ts\n')[0],'app,frontend')
 def test_global_context(self): self.assertEqual(self.selected('.dockerignore\n')[0],'app,frontend,docreader')
if __name__=='__main__': unittest.main()