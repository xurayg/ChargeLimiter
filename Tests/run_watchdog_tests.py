#!/usr/bin/env python3
from pathlib import Path
import json, subprocess, tempfile, threading, time, signal, os, shutil
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
repo=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='chargelimiter-watchdog-') as tmp:
    root=Path(tmp); binary=root/'watchdog-tests'; device=root/'device'
    subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++11','-fobjc-arc','-framework','Foundation','-I',str(repo/'ChargeLimiter'),f'-DCL_DATA_DIRECTORY="{device}"',f'-DCL_LEGACY_DIRECTORY="{root / "legacy"}"',str(repo/'ChargeLimiter/storage.mm'),str(repo/'ChargeLimiter/watchdog.mm'),str(repo/'Tests/watchdog_tests.mm'),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
    def run(*args): return json.loads(subprocess.check_output([str(binary),*args],text=True,timeout=12))
    child=subprocess.Popen([str(binary),'lease'],stdout=subprocess.PIPE,text=True)
    try:
        owner=json.loads(child.stdout.readline())
        assert owner['pid']==child.pid and owner.get('start_sec'), 'process birth identity missing'
        assert run('identity')['pid']==child.pid
        duplicate=subprocess.run([str(binary),'lease'],capture_output=True,timeout=5)
        assert duplicate.returncode==10,'duplicate service lease accepted'
        result={'mode':'healthy'}
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                req=json.loads(self.rfile.read(int(self.headers['Content-Length']))); assert req['api']=='get_service_status'
                mode=result['mode']
                if mode=='hung': time.sleep(4)
                response={'status':0,'data':{'status':'running','instance':'fixture','pid':child.pid}}
                if mode=='wrong_pid': response['data']['pid']+=1
                if mode=='error': response['status']=-1
                if mode=='null_pid': response['data']['pid']=None
                if mode=='array': response=[]
                if mode=='missing_status': response.pop('status')
                data=json.dumps(response).encode(); self.send_response(200); self.send_header('Content-Length',str(len(data))); self.end_headers()
                try: self.wfile.write(data)
                except (BrokenPipeError,ConnectionResetError): pass
            def log_message(self,*args): pass
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        url=f'http://127.0.0.1:{server.server_port}/'
        for mode,healthy in [('healthy',True),('wrong_pid',False),('error',False),('array',False),('null_pid',False),('missing_status',False),('hung',False)]:
            result['mode']=mode; started=time.monotonic(); response=run('probe',url)
            assert response['healthy']==healthy,(mode,response)
            if mode=='hung': assert time.monotonic()-started<3.5,'probe did not honor timeout'
        result['mode']='healthy'
        assert not run('stop',url)['stopped'],'healthy service was terminated'
        assert child.poll() is None,'healthy process disappeared'
        server.shutdown(); server.server_close()
        lock=device/'service.lock'
        corrupt=owner.copy(); corrupt['start_sec']+=1; lock.write_text(json.dumps(corrupt))
        assert run('identity')=={},'stale birth time accepted'
        assert not run('stop')['stopped'],'unverified process terminated'
        assert child.poll() is None,'birth-time mismatch killed a process'
        corrupt['pid']=None; lock.write_text(json.dumps(corrupt))
        assert run('identity')=={},'malformed PID was accepted'
        assert child.poll() is None,'malformed lease killed a process'
        lock.write_text(json.dumps(owner))
        child.send_signal(signal.SIGSTOP)  # A hung process cannot handle SIGTERM.
        outcome=run('stop')
        assert outcome['stopped'],'verified unresponsive process not stopped'
        child.wait(timeout=5)
        assert run('identity')=={},'dead process accepted through stale lease file'
        print('PASS: real process singleton lease, PID/birth-time validation, refused unsafe kill, verified restart termination, HTTP health protocol, malformed response and bounded hang detection')
    finally:
        if child.poll() is None: child.kill(); child.wait()

    # Exercise the actual independent loop with a real stopped child. The HTTP
    # fixture mirrors a main-thread-bound API that stops answering while hung.
    incident={'hung_pid':None}
    class EngineHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            owner=json.loads((device/'service.lock').read_text())
            if owner['pid']==incident['hung_pid']: time.sleep(4)
            data=json.dumps({'status':0,'data':{'status':'running','instance':str(owner['pid']),'pid':owner['pid']}}).encode()
            self.send_response(200); self.send_header('Content-Length',str(len(data))); self.end_headers()
            try: self.wfile.write(data)
            except (BrokenPipeError,ConnectionResetError): pass
        def log_message(self,*args): pass
    daemon_binary=root/'ChargeLimiterDaemon'; watchdog_binary=root/'ChargeLimiterWatchdog'
    shutil.copy2(binary,daemon_binary); shutil.copy2(binary,watchdog_binary)
    engine_server=ThreadingHTTPServer(('127.0.0.1',0),EngineHandler)
    threading.Thread(target=engine_server.serve_forever,daemon=True).start()
    with open(root/'engine.stdout','w') as capture:
        engine=subprocess.Popen([str(watchdog_binary),'engine',f'http://127.0.0.1:{engine_server.server_port}/'],stdout=capture)
        def wait_for(predicate,seconds):
            deadline=time.monotonic()+seconds
            while time.monotonic()<deadline:
                assert engine.poll() is None,'watchdog exited unexpectedly'
                try:
                    state=json.loads((device/'watchdog-state.json').read_text())
                    if state.get('pid')==engine.pid and predicate(state): return state
                except (FileNotFoundError,json.JSONDecodeError): pass
                time.sleep(0.1)
            print('watchdog record:', (device/'watchdog-state.json').read_text(), 'service lease:', (device/'service.lock').read_text(), 'log:', (device/'aldente.log').read_text(), flush=True)
            raise AssertionError('independent watchdog did not recover before deadline')
        tracked=[]
        try:
            wait_for(lambda s:s.get('service_healthy') is True,22)
            first=json.loads((device/'service.lock').read_text())['pid']; tracked.append(first)
            os.kill(first,signal.SIGSTOP); incident['hung_pid']=first
            def successor_healthy(state):
                try: successor=json.loads((device/'service.lock').read_text())['pid']
                except json.JSONDecodeError: return False
                return state.get('service_healthy') is True and successor!=first
            wait_for(successor_healthy,70)
            second=json.loads((device/'service.lock').read_text())['pid']; tracked.append(second)
            assert second!=first,'watchdog failed to replace hung process'
            engine.terminate(); engine.wait(timeout=5)
            state=json.loads((device/'watchdog-state.json').read_text()); assert state['status']=='stopped'
            text=(device/'aldente.log').read_text()
            assert 'SIGKILL sent to verified process' in text and 'service health confirmed' in text
            print('PASS: actual independent watchdog survives hung child, verifies and kills it, launches successor, confirms health and records its own clean exit')
        finally:
            if engine.poll() is None: engine.terminate(); engine.wait(timeout=5)
            try: tracked.append(json.loads((device/'service.lock').read_text())['pid'])
            except (FileNotFoundError,json.JSONDecodeError): pass
            for pid in set(tracked):
                try: os.kill(pid,signal.SIGKILL)
                except ProcessLookupError: pass
            engine_server.shutdown(); engine_server.server_close()

    # Three unsuccessful recoveries must reach the actual fallback callback.
    failed=subprocess.Popen([str(watchdog_binary),'engine_fail','http://127.0.0.1:1/'],stdout=subprocess.DEVNULL)
    try:
        deadline=time.monotonic()+105
        while time.monotonic()<deadline:
            assert failed.poll() is None,'watchdog exited during repeated recovery failure'
            try:
                state=json.loads((device/'watchdog-state.json').read_text())
                if state.get('pid')==failed.pid and state.get('recovery',{}).get('fallback_attempted'):
                    assert state['last_fallback_result']==0
                    assert state['recovery']['restart_attempts']>=4
                    assert (device/'aldente.log').read_text().count('test fallback invoked')==1
                    break
            except (FileNotFoundError,json.JSONDecodeError): pass
            time.sleep(0.1)
        else: raise AssertionError('actual recovery loop failed to invoke fallback')
        failed.terminate(); failed.wait(timeout=5)
        print('PASS: actual failed-recovery loop invokes fallback once, saves result and continues with backoff (fixture callback; no hardware IO)')
    finally:
        if failed.poll() is None: failed.terminate(); failed.wait(timeout=5)
