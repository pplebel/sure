"""Run custom regressions and optionally full Rails tests in disposable Docker state."""
from pathlib import Path
import argparse,json,subprocess,sys,tarfile,tempfile,time,uuid
ROOT=Path(__file__).resolve().parents[1]
def run(args,log=None):
 if log:
  with log.open('w') as f:p=subprocess.run(args,stdout=f,stderr=subprocess.STDOUT)
  print(log.name+': '+log.read_text()[-700:],flush=True)
  p.check_returncode()
 else:subprocess.run(args,check=True)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--full',action='store_true');a=p.parse_args()
 run([sys.executable,str(ROOT/'personal/build.py'),'--check'])
 run([sys.executable,'-m','unittest','discover','-s',str(ROOT/'personal/tests'),'-p','test_*.py'])
 prefix='sure-fork-test-'+uuid.uuid4().hex[:10];socket=prefix+'-socket';db=prefix+'-db';redis=prefix+'-redis';image=prefix+'-app'
 logs=ROOT/'personal/local'/prefix;logs.mkdir(parents=True)
 run([sys.executable,str(ROOT/'personal/build.py'),'--image',image],logs/'build.log')
 cleanup=[]
 try:
  run(['docker','volume','create',socket]);cleanup.append(['docker','volume','rm',socket])
  # The developer image ships pg_dump 17. Match it for SQL schema cloning;
  # the focused runtime suite separately verifies the deployed PostgreSQL 16.
  postgres='postgres:17' if a.full else 'postgres:16'
  run(['docker','run','-d','--name',db,'--network','none','--tmpfs','/var/lib/postgresql/data','--mount',f'type=volume,src={socket},dst=/var/run/postgresql','-e','POSTGRES_USER=sure_synthetic','-e','POSTGRES_DB=sure_review_test','-e','POSTGRES_HOST_AUTH_METHOD=trust',postgres]);cleanup.append(['docker','rm','-f',db])
  run(['docker','run','-d','--name',redis,'--network','none','--mount',f'type=volume,src={socket},dst=/var/run/postgresql','redis:latest','redis-server','--port','0','--unixsocket','/var/run/postgresql/fork-redis.sock','--unixsocketperm','777']);cleanup.append(['docker','rm','-f',redis])
  for _ in range(30):
   if subprocess.run(['docker','exec',db,'pg_isready','-U','sure_synthetic','-d','sure_review_test'],capture_output=True).returncode==0:break
   time.sleep(1)
  else:raise RuntimeError('Fictional database did not become ready')
  def container(img,env,command):
   return ['docker','run','--rm','--network','none','--entrypoint','bundle','--mount',f'type=volume,src={socket},dst=/var/run/postgresql','--mount',f'type=bind,src={ROOT}/personal/tests,dst=/fork-tests,readonly','-e','DB_HOST=/var/run/postgresql','-e','POSTGRES_USER=sure_synthetic','-e','REDIS_URL=unix:///var/run/postgresql/fork-redis.sock','-e','SECRET_KEY_BASE=fictional-fork-tests-not-a-secret','-e','RAILS_LOG_LEVEL=error',*sum((['-e',k+'='+v] for k,v in env.items()),[]),img,*command]
  # Mount test files into /rails/personal/tests as well; image contains runtime only.
  def custom(command):
   cmd=container(image,{'RAILS_ENV':'production','POSTGRES_DB':'sure_review_test','SELF_HOSTED':'true'},command)
   i=cmd.index(image);cmd[i:i]=['--mount',f'type=bind,src={ROOT}/personal/tests,dst=/rails/personal/tests,readonly'];return cmd
  run(custom(['exec','rails','runner','/fork-tests/setup.rb']),logs/'schema.log')
  run(custom(['exec','rails','runner','/fork-tests/run.rb']),logs/'custom.log')
  run(custom(['exec','ruby','/fork-tests/payload_test.rb']),logs/'payload.log')
  if a.full:
   lock=json.loads((ROOT/'personal/upstream.json').read_text())
   # Export tracked source only. Untracked .env/keys/data cannot enter this build.
   with tempfile.TemporaryDirectory(prefix='sure-full-test-') as d:
    ctx=Path(d);archive=ctx/'source.tar'
    with archive.open('wb') as f:subprocess.run(['git','-C',str(ROOT),'archive','HEAD'],stdout=f,check=True)
    with tarfile.open(archive) as t:t.extractall(ctx,filter='data')
    archive.unlink()
    run(['docker','build','--pull=false','--build-arg','UPSTREAM_IMAGE='+lock['image'],'-f',str(ROOT/'personal/Test.Dockerfile'),'-t',prefix+'-full',str(ctx)],logs/'full-build.log')
   env={'RAILS_ENV':'test','POSTGRES_DB':'sure_fork_full_test','BUNDLE_WITHOUT':'','PARALLEL_WORKERS':'4','PLAID_CLIENT_ID':'fictional','PLAID_SECRET':'fictional'}
   ruby='abort "Wrong fictional DB" unless ENV["POSTGRES_DB"] == "sure_fork_full_test"; system("bundle","exec","rails","db:drop","db:create","db:schema:load","db:migrate") || abort("setup failed"); ENV["PERSONAL_FULL_TEST_SQL"]="1"; system("bundle","exec","rails","db:schema:dump") || abort("SQL snapshot failed"); exec("bin/rails","test")'
   run(container(prefix+'-full',env,['exec','ruby','-e',ruby]),logs/'full.log')
  print(json.dumps({'passed':True,'full_suite':a.full,'logs':str(logs),'live_config_read':False,'provider_network':'none'}))
 finally:
  for cmd in reversed(cleanup):subprocess.run(cmd,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  subprocess.run(['docker','image','rm',image],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
if __name__=='__main__':main()
