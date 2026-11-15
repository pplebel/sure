"""Prepare a stable-tag merge branch. Never push, build, deploy, or read live config."""
from pathlib import Path
import argparse,json,re,subprocess
ROOT=Path(__file__).resolve().parents[1]
STABLE=re.compile(r'^v\d+\.\d+\.\d+(?:-hotfix\.\d+)?$')
def git(*args):return subprocess.check_output(['git','-C',str(ROOT),*args],text=True).strip()
def validate_tag(tag):
 if not STABLE.fullmatch(tag):raise ValueError('Choose an official stable tag, not main, alpha, beta, or a shell expression')
 return tag
def version_key(tag):
 validate_tag(tag)
 m=re.fullmatch(r'v(\d+)\.(\d+)\.(\d+)(?:-hotfix\.(\d+))?',tag)
 return tuple(int(v or 0) for v in m.groups())
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('tag');p.add_argument('--check',action='store_true',help='Validate current pinned tag locally; make no changes or network requests');a=p.parse_args();tag=validate_tag(a.tag)
 lock=json.loads((ROOT/'personal/upstream.json').read_text())
 if a.check:
  if tag!=lock['tag'] or git('rev-parse',tag+'^{commit}')!=lock['commit']:raise ValueError('Local tag does not match current pin')
  print(json.dumps({'tag':tag,'commit':lock['commit'],'network_requests':0,'deployment':False}));return
 if git('status','--porcelain'):raise ValueError('Commit or preserve working changes first; nothing was changed')
 if git('branch','--show-current')!='codex/personal':raise ValueError('Start from codex/personal')
 if version_key(tag)<=version_key(lock['tag']):raise ValueError('Choose a newer stable release; nothing was changed')
 release=json.loads(subprocess.check_output(['gh','release','view',tag,'--repo','we-promise/sure','--json','tagName,isPrerelease,isDraft'],text=True))
 if release['isPrerelease'] or release['isDraft'] or release['tagName']!=tag:raise ValueError('Release is not a published stable release')
 subprocess.run(['git','-C',str(ROOT),'fetch','upstream','tag',tag],check=True)
 commit=git('rev-parse',tag+'^{commit}')
 if commit==lock['commit']:raise ValueError('Already based on this stable release; no branch was created')
 # Hotfix backports need not be ancestors of the next minor release. Require
 # shared upstream history and a newer version, then let Git expose conflicts.
 git('merge-base',lock['commit'],commit)
 branch='codex/upgrade-'+tag.removeprefix('v')
 subprocess.run(['git','-C',str(ROOT),'switch','-c',branch],check=True)
 merged=subprocess.run(['git','-C',str(ROOT),'merge','--no-edit',tag]).returncode==0
 print(json.dumps({'branch':branch,'merged':merged,'next':'Resolve conflicts if any; inspect upstream changes; update personal/upstream.json with exact official image digest and reviewed runtime-file hashes; run full and personal tests, browser QA and backup/migration rehearsal before explicit deployment','deployment':False}))
 if not merged:raise SystemExit(1)
if __name__=='__main__':main()
