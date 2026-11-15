"""Build a pinned source-only overlay. Never install, migrate, or start Sure."""
from pathlib import Path
import argparse,hashlib,json,re,shutil,subprocess,tempfile

ROOT=Path(__file__).resolve().parents[1]
def git(*args):return subprocess.check_output(['git','-C',str(ROOT),*args],text=True).strip()
def check(lock):
 if git('rev-parse',lock['tag']+'^{commit}')!=lock['commit']:raise ValueError('Stable tag differs from pinned commit')
 if not re.fullmatch(r'ghcr.io/we-promise/sure@sha256:[0-9a-f]{64}',lock['image']):raise ValueError('An immutable official image digest is required')
 files=lock['files']
 # The current overlay contains Ruby/ERB changes only. Asset/dependency changes
 # need a reviewed full-source build; do not silently reuse compiled assets.
 actual=set(git('diff','--name-only',lock['commit'],'--','app','config','db','lib','Gemfile','Gemfile.lock','package.json','package-lock.json').splitlines())
 if actual!=set(files):raise ValueError('Runtime delta differs from lock; regenerate/review the manifest')
 for name,digest in files.items():
  p=ROOT/name
  if not name.startswith(('app/','config/','db/')) or p.suffix not in ('.rb','.erb') or p.is_symlink():raise ValueError('Unsupported overlay file: '+name)
  if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=digest:raise ValueError('Runtime file differs from reviewed manifest: '+name)
 return files
def main():
 a=argparse.ArgumentParser(description=__doc__);a.add_argument('--check',action='store_true');a.add_argument('--image',default='sure-personal:local');args=a.parse_args()
 lock=json.loads((ROOT/'personal/upstream.json').read_text());files=check(lock)
 if args.check:print(json.dumps({'tag':lock['tag'],'verified_runtime_files':len(files)}));return
 with tempfile.TemporaryDirectory(prefix='sure-personal-build-') as directory:
  context=Path(directory)
  for name in files:
   dest=context/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,dest)
  subprocess.run(['docker','build','--network=none','--pull=false','--build-arg','UPSTREAM_IMAGE='+lock['image'],'-f',str(ROOT/'personal/Dockerfile'),'-t',args.image,str(context)],check=True)
 # Confirm the image still identifies the expected upstream revision.
 meta=json.loads(subprocess.check_output(['docker','image','inspect',args.image]))[0]
 if meta['Config']['Labels']['org.opencontainers.image.revision']!=lock['commit']:raise ValueError('Built image has unexpected upstream revision')
 print(json.dumps({'image':args.image,'id':meta['Id'],'runtime_files':len(files),'installed':False}))
if __name__=='__main__':main()
