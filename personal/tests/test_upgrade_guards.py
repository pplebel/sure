"""The preparation command must reject moving/pre-release refs and shell text."""
import importlib.util,unittest
from pathlib import Path
s=importlib.util.spec_from_file_location('upgrade',Path(__file__).resolve().parents[1]/'upgrade.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class StableTagTests(unittest.TestCase):
 def test_stable_releases(self):
  for tag in ('v0.7.6','v0.7.6-hotfix.1','v1.2.3'):
   with self.subTest(tag=tag):self.assertEqual(tag,m.validate_tag(tag))
 def test_unstable_or_executable_inputs(self):
  for tag in ('main','stable','latest','v0.7.7-alpha.6','v1.0.0-beta.1','v1.2.3; touch /tmp/x','$(id)','../main','v1.2.3\n'):
   with self.subTest(tag=tag),self.assertRaises(ValueError):m.validate_tag(tag)
 def test_hotfix_and_next_minor_order(self):
  self.assertLess(m.version_key('v0.7.6'),m.version_key('v0.7.6-hotfix.1'))
  self.assertLess(m.version_key('v0.7.6-hotfix.1'),m.version_key('v0.7.6-hotfix.2'))
  self.assertLess(m.version_key('v0.7.6-hotfix.2'),m.version_key('v0.7.7'))
if __name__=='__main__':unittest.main()
