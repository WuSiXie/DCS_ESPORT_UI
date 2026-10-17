"""Two real director services connected to the real C++ authority."""
import http.client
import json
import os
from pathlib import Path
import subprocess
import time
import unittest
from test_server import ROOT, free_port, identity, batch
from test_web import BrowserAuthorityTests, PASSWORD

NODE = Path(os.environ.get('DCS_ESPORT_TEST_NODE',r'C:\Users\wsx\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'))

class Director:
    def __init__(self, upstream, directory):
        self.port=free_port();self.directory=directory;self.upstream=upstream;self.cookie=None;self.csrf=None;self.process=None
    def start(self):
        self.log=open(self.directory.with_suffix('.log'),'wb')
        self.process=subprocess.Popen([str(NODE),str(ROOT/'src/director/server.mjs'),'--port',str(self.port),
            '--upstream',f'http://127.0.0.1:{self.upstream}','--data-dir',str(self.directory)],
            stdout=self.log,stderr=self.log,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        for _ in range(100):
            if self.process.poll() is not None:raise RuntimeError('Director exited')
            try:
                if self.request('GET','/healthz')[0]==200:return
            except OSError:pass
            time.sleep(.03)
        self.stop();raise RuntimeError('Director not ready')
    def stop(self):
        if self.process and self.process.poll() is None:self.process.terminate();self.process.wait(timeout=5)
        if hasattr(self,'log'):self.log.close()
    def request(self, method, path, data=None, token=None, csrf=True, origin=True, host=None):
        headers={'Content-Type':'application/json'}
        if self.cookie:headers['Cookie']=self.cookie
        if csrf and self.csrf:headers['X-CSRF-Token']=self.csrf
        if origin:headers['Origin']=f'http://127.0.0.1:{self.port}' if origin is True else origin
        if host:headers['Host']=host
        if token:headers['Authorization']='Bearer '+token
        c=http.client.HTTPConnection('127.0.0.1',self.port,timeout=8)
        try:
            c.request(method,path,json.dumps(data) if data is not None else None,headers)
            r=c.getresponse();cookie=r.getheader('Set-Cookie')
            if cookie:self.cookie=cookie.split(';')[0]
            value=json.loads(r.read())
            if isinstance(value,dict) and 'csrf' in value:self.csrf=value['csrf']
            return r.status,value
        finally:c.close()
    def login(self,name='director'):
        code,value=self.request('POST','/api/login',{'username':name,'password':PASSWORD})
        assert code==200,value
        for _ in range(100):
            if self.request('GET','/api/session')[1]['status']=='connected':return
            time.sleep(.03)
        raise RuntimeError('Director upstream not ready')
    def outputs(self):return self.request('GET','/api/outputs')[1]
    def state(self,output):return self.request('GET',f"/api/output/{output['id']}/state",token=output['url'].split('#')[1])

class DirectorTests(BrowserAuthorityTests):
    # Reuse fixture helpers without rerunning the authority suite in this class.
    test_auth_scope_roles_logout_ticket_and_origin=None
    test_ws_baseline_resume_live_and_epoch_reset=None
    test_account_change_and_invalid_file_revoke_sessions=None
    test_password_work_does_not_block_hook_and_login_is_limited=None
    test_https_wss_trusted_certificate_and_untrusted_rejection=None
    test_large_snapshot_slow_subscribers_do_not_block_ack=None
    def setUp(self):super().setUp();self.directors=[]
    def tearDown(self):
        for director in self.directors:director.stop()
        super().tearDown()
    def director(self,name):
        d=Director(self.server.http,Path(self.temp.name)/name);self.directors.append(d);d.start();return d
    def test_removed_camera_controls_cannot_send_commands_and_ack_still_works(self):
        hook=self.hook();src=identity('retired-camera');hook.open(src)
        status={'active':True,'camera':{'supported':True,'status':'tracking','mode':'F2','visible':True}}
        hook.send('status',status,src)
        d=self.director('removed-camera');d.login()
        body={'serverEpoch':hook.epoch,'revision':0,'nativeEnabled':True,'transparent':True}
        self.assertEqual(d.request('POST','/api/sources/1/camera-control',body)[0],404)
        token=self.login('director')
        self.assertEqual(self.request('POST','/api/v1/sources/1/camera-control',body,token=token)[0],405)
        hook.send('status',status,src)
        hook.send('events',batch(0,2),src)
        reply=hook.read();self.assertEqual(reply['type'],'ack');self.assertEqual(reply['payload']['ackEventSeq'],2)
        self.assertNotIn('aircraft',d.outputs()[0]['config']['features'])
        self.assertNotIn('followCamera',d.outputs()[0]['config'])
        self.assertEqual(len(d.outputs()),2)
    def test_two_services_isolate_configuration_and_readonly_permissions(self):
        hook=self.hook();src=identity('directors');hook.open(src);hook.send('events',batch(0,2),src);hook.read()
        a=self.director('a');b=self.director('b');a.login();b.login()
        out=a.outputs()[0];other=b.outputs()[0];self.assertNotEqual(out['id'],other['id'])
        out['config']['features']={k:False for k in out['config']['features']};out['config']['name']='全部隐藏'
        self.assertEqual(a.request('PUT','/api/outputs/'+out['id'],out)[0],200)
        self.assertTrue(all(b.outputs()[0]['config']['features'].values()))
        self.assertEqual(a.request('PUT','/api/outputs/'+out['id'],out)[0],409)
        self.assertEqual(a.request('PUT','/api/outputs/'+out['id'],out,csrf=False)[0],403)
        saved=a.outputs()[0];key=saved['url'].split('#')[1];a.cookie=None
        self.assertEqual(a.request('GET','/api/outputs',token=key)[0],401)
        self.assertEqual(a.request('PUT','/api/outputs/'+out['id'],out,token=key)[0],401)
        for _ in range(100):
            code,state=a.state(saved)
            if state.get('source') and state['source']['receivedThrough']==2:break
            time.sleep(.03)
        self.assertEqual(code,200);self.assertEqual([e['eventSeq'] for e in state['events']],[1,2])
        encoded=json.dumps(state);self.assertNotIn('accessToken',encoded);self.assertNotIn('csrf',encoded);self.assertNotIn(key,encoded)
        a.stop();a.start();a.login();restored=a.outputs()[0]
        self.assertEqual(restored['id'],saved['id']);self.assertEqual(restored['url'],saved['url']);self.assertFalse(any(restored['config']['features'].values()))
    def test_host_origin_viewer_and_account_isolation(self):
        d=self.director('security')
        self.assertEqual(d.request('POST','/api/login',{'username':'director','password':PASSWORD},origin='http://evil.invalid')[0],403)
        self.assertEqual(d.request('GET','/healthz',host='evil.invalid')[0],403)
        d.login();old=d.outputs()[0]
        d.login('viewer');new=d.outputs()[0]
        self.assertNotEqual(old['id'],new['id']);self.assertEqual(d.state(old)[0],401)
        self.assertEqual(d.request('PUT','/api/outputs/'+new['id'],new)[0],403)
        self.assertEqual(d.request('POST','/api/outputs',{'config':new['config']})[0],403)
        self.assertEqual(d.request('GET','/api/session')[1]['sources'],[])
        self.assertEqual(d.request('POST','/api/logout')[0],200);self.assertEqual(d.state(new)[0],401)
    def test_live_events_reconnect_without_duplicate_and_main_restart_requires_login(self):
        hook=self.hook();src=identity('reconnect');hook.open(src);hook.send('events',batch(0,2),src);hook.read()
        d=self.director('reconnect');d.login();out=d.outputs()[0]
        for _ in range(100):
            state=d.state(out)[1]
            if len(state.get('events',[]))==2:break
            time.sleep(.03)
        self.assertTrue(all(e['historical'] for e in state['events']))
        hook.send('events',batch(2,4),src);hook.read();hook.send('events',batch(2,4),src);hook.read()
        for _ in range(100):
            state=d.state(out)[1]
            if len(state.get('events',[]))==4:break
            time.sleep(.03)
        self.assertEqual([e['eventSeq'] for e in state['events']],[1,2,3,4]);self.assertFalse(state['events'][-1]['historical'])
        self.server.stop();self.server.start()
        for _ in range(150):
            code,_=d.request('GET','/api/session')
            if code==401:break
            time.sleep(.05)
        self.assertEqual(code,401);self.assertEqual(d.state(out)[0],401)

if __name__=='__main__':unittest.main(verbosity=2)
