"""Fetch only the pinned official stable tag; never push release tags to the fork."""
import json,subprocess
from pathlib import Path
from upgrade import validate_tag
root=Path(__file__).resolve().parents[1]
lock=json.loads((root/'personal/upstream.json').read_text());tag=validate_tag(lock['tag'])
subprocess.run(['git','-C',str(root),'fetch','--no-tags','https://github.com/we-promise/sure.git','refs/tags/'+tag+':refs/tags/'+tag],check=True)
actual=subprocess.check_output(['git','-C',str(root),'rev-parse',tag+'^{commit}'],text=True).strip()
if actual!=lock['commit']:raise ValueError('Official tag differs from pinned revision')
print('Verified pinned official tag: '+tag)
