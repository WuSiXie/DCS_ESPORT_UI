"""Real TCP/HTTP integration tests for the C++ receiver and the packaged Hook."""
from pathlib import Path
import http.client
import json
import os
import secrets
import socket
import struct
import subprocess
import sys
import time
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from tools.package import render
EXE=Path(os.environ.get('DCS_ESPORT_TEST_SERVER',ROOT/'build-gcc/dcs-esport-server.exe'))
LUA=Path(os.environ.get('DCS_ESPORT_TEST_LUA',r'D:\SteamLibrary\steamapps\common\DCSWorld\bin\luae.exe'))
TOKEN=secrets.token_hex(24)
API=secrets.token_hex(24)

def free_port():
    with socket.socket() as s: s.bind(('127.0.0.1',0)); return s.getsockname()[1]

class Server:
    def __init__(self,args=()):
        self.port=free_port();self.http=free_port();self.process=None;self.args=list(args)
    def start(self):
        self.log=tempfile.TemporaryFile()
        env=os.environ.copy();env['PATH']=r'C:\msys64\ucrt64\bin;'+env.get('PATH','')
        env['DCS_ESPORT_HOOK_TOKEN']=TOKEN;env['DCS_ESPORT_API_TOKEN']=API
        self.process=subprocess.Popen([str(EXE),'--port',str(self.port),'--http-port',str(self.http)]+self.args,env=env,
            stdout=subprocess.DEVNULL,stderr=self.log,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        for _ in range(100):
            if self.process.poll() is not None: raise RuntimeError('C++ receiver exited')
            try:
                if self.get('/healthz')[0]==200: return
            except OSError: pass
            time.sleep(.03)
        self.stop()
        raise RuntimeError('C++ receiver not ready')
    def stop(self):
        if self.process and self.process.poll() is None:self.process.terminate();self.process.wait(timeout=5)
        if hasattr(self,'log'):self.log.close()
    def rejections(self):
        self.log.seek(0);return [json.loads(line) for line in self.log.readlines()]
    def get(self,path,auth=True):
        c=http.client.HTTPConnection('127.0.0.1',self.http,timeout=3)
        try:
            c.request('GET',path,headers={'Authorization':'Bearer '+API} if auth else {})
            r=c.getresponse();return r.status,json.loads(r.read())
        finally:c.close()

class Client:
    def __init__(self,server,token=TOKEN):
        self.s=socket.create_connection(('127.0.0.1',server.port),3);self.s.settimeout(3)
        self.cid=None
        self.send('hello',{'instanceId':'dcs-local','token':token,'ackMode':'memory'})
        try: welcome=self.read()
        except Exception: self.s.close();raise
        self.cid=welcome['connectionId'];self.epoch=welcome['serverEpoch']
    def close(self):self.s.close()
    def send(self,kind,payload,source=None,fragment=False):
        m={'transportVersion':1,'type':kind,'connectionId':self.cid,'payload':payload}
        if source:m['source']=source
        b=json.dumps(m,separators=(',',':')).encode();b=struct.pack('!I',len(b))+b
        if fragment:
            for i in range(0,len(b),3):self.s.sendall(b[i:i+3])
        else:self.s.sendall(b)
    def read(self):
        def exact(n):
            b=b''
            while len(b)<n:
                chunk=self.s.recv(n-len(b))
                if not chunk:raise EOFError('connection closed')
                b+=chunk
            return b
        return json.loads(exact(struct.unpack('!I',exact(4))[0]))
    def open(self,source,confirmed=0,read=0):
        self.send('source_open',{'confirmedSeq':confirmed,'readThrough':read},source);return self.read()

def identity(name):return {'instanceId':'dcs-local','missionSessionId':name,'collectorEpoch':'epoch-1'}
def batch(after,through):return {'afterSeq':after,'throughSeq':through,'latestEventSeq':through,
    'events':[{'eventSeq':n,'type':'takeoff','text':'中文'} for n in range(after+1,through+1)],'gaps':[]}

class ReceiverTests(unittest.TestCase):
    def setUp(self):self.server=Server();self.server.start();self.clients=[]
    def tearDown(self):
        for c in self.clients:c.close()
        self.server.stop()
    def client(self):
        c=Client(self.server);self.clients.append(c);return c
    def test_rejections_log_source_stage_and_no_credentials(self):
        ports=[]
        for data in [b'GET / HTTP/1.1\r\n\r\n',struct.pack('!I',0),struct.pack('!I',524289),struct.pack('!I',1)+b'{']:
            with socket.create_connection(('127.0.0.1',self.server.port),3) as s:
                ports.append(s.getsockname()[1]);s.sendall(data)
                try:self.assertEqual(s.recv(1),b'')
                except ConnectionResetError:pass
        with self.assertRaises((EOFError,ConnectionError)):Client(self.server,'private-invalid-token-do-not-log-123')
        c=self.client();src=identity('logging');c.open(src);c.send('events',batch(0,1),src);c.read()
        bad=batch(0,1);bad['events'][0]['text']='private-payload-do-not-log';c.send('events',bad,src)
        with self.assertRaises((EOFError,ConnectionError)):c.read()
        rows=self.server.rejections();self.assertEqual(len(rows),6)
        self.assertEqual([r['stage'] for r in rows],['header','header','header','json','protocol','protocol'])
        self.assertEqual([r['peerPort'] for r in rows[:4]],ports)
        self.assertEqual(rows[0]['headerHex'],'47455420');self.assertEqual(rows[0]['declaredLength'],1195725856)
        self.assertEqual(rows[4]['reason'],'authentication_failed');self.assertFalse(rows[4]['authenticated'])
        self.assertTrue(rows[5]['authenticated']);self.assertEqual(rows[5]['connectionId'],c.cid)
        for r in rows:
            self.assertEqual(r['peerAddress'],'127.0.0.1');self.assertEqual(r['localPort'],self.server.port)
            self.assertTrue(r['timestampUtc'].endswith('Z'));self.assertTrue(r['serverEpoch'])
        self.assertEqual(self.server.get('/api/v1/status')[1]['protocolErrors'],6)
        text=json.dumps(rows)
        for secret in [TOKEN,API,'private-invalid-token','private-payload']:self.assertNotIn(secret,text)
        output=ROOT/'runtime/network-rejections.json';output.parent.mkdir(parents=True,exist_ok=True)
        output.write_text(json.dumps(rows,indent=2),encoding='utf-8')
    def test_fragmentation_duplicate_ack_and_conflict(self):
        c=self.client();src=identity('duplicates');c.open(src)
        c.send('events',batch(0,3),src,fragment=True);self.assertEqual(c.read()['payload']['ackEventSeq'],3)
        c.send('events',batch(0,3),src);self.assertEqual(c.read()['payload']['ackEventSeq'],3)
        rows=self.server.get('/api/v1/sources')[1];self.assertEqual(rows[0]['acceptedEvents'],3);self.assertEqual(rows[0]['duplicateEvents'],3)
        bad=batch(0,3);bad['events'][1]['text']='conflict';c.send('events',bad,src)
        with self.assertRaises((EOFError,ConnectionError)):c.read()
        self.assertEqual(self.server.get('/api/v1/sources')[1][0]['receivedThrough'],3)
    def test_ack_loss_reconnect_and_restart_baseline(self):
        src=identity('resume');c=self.client();c.open(src);c.send('events',batch(0,3),src)
        # Close without receiving the ACK; the next source_ready must recover it.
        time.sleep(.05);c.close();d=self.client();self.assertEqual(d.open(src,0,3)['payload']['ackEventSeq'],3)
        d.send('events',batch(0,3),src);self.assertEqual(d.read()['payload']['ackEventSeq'],3)
        epoch=d.epoch;self.server.stop();self.server.start();e=self.client()
        self.assertNotEqual(e.epoch,epoch);r=e.open(src,3,3);self.assertTrue(r['payload']['historyIncomplete'])
        e.send('events',batch(3,5),src);self.assertEqual(e.read()['payload']['ackEventSeq'],5)
        rows=self.server.get('/api/v1/sources')[1];self.assertEqual(rows[0]['gaps'][0]['toSeq'],3)
    def test_hidden_gap_rejected_and_explicit_gap_accepted(self):
        src=identity('gap');c=self.client();c.open(src);b=batch(0,3);b['events'].pop(1);c.send('events',b,src)
        with self.assertRaises((EOFError,ConnectionError)):c.read()
        d=self.client();d.open(src);b['gaps']=[{'fromSeq':2,'toSeq':2,'reason':'buffer_overflow'}];d.send('events',b,src)
        self.assertEqual(d.read()['payload']['ackEventSeq'],3)
        self.assertTrue(self.server.get('/api/v1/sources')[1][0]['historyIncomplete'])
        d.send('events',batch(0,3),src)
        with self.assertRaises((EOFError,ConnectionError)):d.read()
        e=self.client();e.open(src,3,3)
        e.send('events',{'afterSeq':0,'throughSeq':3,'latestEventSeq':3,'events':[],
                         'gaps':[{'fromSeq':1,'toSeq':3,'reason':'buffer_overflow'}]},src)
        with self.assertRaises((EOFError,ConnectionError)):e.read()
    def test_authentication_limits_and_stale_connection(self):
        self.assertEqual(self.server.get('/api/v1/sources',False)[0],401)
        with self.assertRaises((EOFError,ConnectionError)):Client(self.server,'x'*32)
        c=self.client();c.open(identity('old'));d=self.client()
        c.send('ping',{})
        with self.assertRaises((EOFError,ConnectionError)):c.read()
        d.s.sendall(struct.pack('!I',524289))
        with self.assertRaises((EOFError,ConnectionError)):d.read()
    def test_end_and_old_source_are_independent(self):
        c=self.client();old=identity('old');new=identity('new');c.open(old);c.open(new)
        c.send('events',batch(0,2),old);c.read();c.send('events',batch(0,1),new);c.read()
        c.send('session_end',{'latestEventSeq':2,'readThrough':2,'tailComplete':True,'tailReason':'complete'},old)
        self.assertEqual(c.read()['type'],'session_end_received')
        rows={r['source']['missionSessionId']:r for r in self.server.get('/api/v1/sources')[1]}
        self.assertTrue(rows['old']['serverTailComplete']);self.assertEqual(rows['new']['receivedThrough'],1)
        details={'latestEventSeq':2,'readThrough':2,'tailComplete':True,'tailReason':'complete',
                 'collectorAck':{'state':'unverified','actualAck':1,'confirmedSeq':2}}
        c.send('session_end',details,old);c.read()
        row=next(r for r in self.server.get('/api/v1/sources')[1] if r['source']['missionSessionId']=='old')
        self.assertTrue(row['serverTailComplete']);self.assertFalse(row['collectorCleanupComplete'])
        self.assertEqual(row['collectorAck']['actualAck'],1)
        details['collectorAck'].update(state='confirmed',actualAck=2)
        c.send('session_end',details,old);c.read()
        self.assertTrue(next(r for r in self.server.get('/api/v1/sources')[1]
                             if r['source']['missionSessionId']=='old')['collectorCleanupComplete'])
    def test_snapshot_is_atomic_and_event_query(self):
        c=self.client();src=identity('pages');c.open(src)
        page={'snapshotId':'s1','pageIndex':0,'pageCount':2,'assembledSimTime':1,
              'eventSeqAtCapture':0,'entities':[],'scopeRevision':1,'coverage':{}}
        c.send('snapshot',page,src);c.send('ping',{});c.read()
        self.assertIsNone(self.server.get('/api/v1/sources/1/snapshot')[1]['state'])
        page['pageIndex']=1;c.send('snapshot',page,src);c.send('ping',{});c.read()
        self.assertEqual(self.server.get('/api/v1/sources/1/snapshot')[1]['state']['snapshotId'],'s1')
        page.update(snapshotId='s2',pageIndex=0,assembledSimTime=2)
        c.send('snapshot',page,src);c.send('ping',{});c.read();c.close()
        self.assertEqual(self.server.get('/api/v1/sources/1/snapshot')[1]['state']['snapshotId'],'s1')
        d=self.client();d.open(src);d.send('events',batch(0,3),src);d.read()
        code,data=self.server.get('/api/v1/sources/1/events?afterSeq=1')
        self.assertEqual(code,200);self.assertEqual([e['eventSeq'] for e in data['events']],[2,3])
    def test_freshness_disconnect_and_capture_integrity_are_independent(self):
        c=self.client();src=identity('freshness');c.open(src)
        c.send('status',{'active':True,'paused':False,'healthFresh':True,
                        'health':{'captureContinuous':False,'captureErrorCount':1}},src)
        c.send('ping',{});c.read()
        row=self.server.get('/api/v1/sources')[1][0]
        self.assertTrue(row['online']);self.assertTrue(row['statusFresh'])
        self.assertEqual(row['captureIntegrity'],'incomplete')
        time.sleep(3.1)
        row=self.server.get('/api/v1/sources')[1][0]
        self.assertTrue(row['online']);self.assertFalse(row['statusFresh'])
        c.close()
        for _ in range(30):
            row=self.server.get('/api/v1/sources')[1][0]
            if not row['online']:break
            time.sleep(.02)
        self.assertFalse(row['online']);self.assertEqual(row['lifecycle'],'offline')
        self.assertTrue(row['hookStatus']['active'],'Historical Hook status stays distinguishable from live status')
    def test_completed_sources_archive_without_blocking_active_or_old_receipts(self):
        c=self.client();live=identity('live');c.open(live)
        old=identity('finished-0')
        for i in range(70):
            src=identity('finished-'+str(i));c.open(src)
            c.send('session_end',{'latestEventSeq':None if i==0 else 0,'readThrough':0,'confirmedSeq':0,'actualAck':0,
                                 'tailComplete':i!=0,'captureClosed':True,'tailReason':'test'},src);c.read()
        rows=self.server.get('/api/v1/sources')[1]
        self.assertEqual(len(rows),71);self.assertEqual(sum(not r['archived'] for r in rows),64)
        self.assertFalse(next(r for r in rows if r['source']['missionSessionId']=='live')['archived'])
        self.assertEqual(c.open(old)['payload']['ackEventSeq'],0)
        c.send('events',batch(0,1),live);self.assertEqual(c.read()['payload']['ackEventSeq'],1)
        archived=next(r for r in self.server.get('/api/v1/sources')[1] if r['source']==old)
        self.assertTrue(archived['archived']);self.assertFalse(archived['historyRetained'])
        self.assertFalse(archived['serverTailComplete']);self.assertEqual(archived['lifecycle'],'ended')
    @unittest.skipUnless(LUA.exists(),'DCS native Lua not installed')
    def test_native_single_hook_reconnect_restart_tail(self):
        folder=ROOT/'runtime/network-native';folder.mkdir(parents=True,exist_ok=True)
        text=render().replace('network = { enabled = false','network = { enabled = true',1)
        text=text.replace('port = 9081','port = '+str(self.server.port),1).replace('token = ""','token = "'+TOKEN+'"',1)
        hook=folder/'DcsEsportHook.lua';hook.write_text(text,encoding='utf-8')
        code='PROJECT_ROOT=[['+ROOT.as_posix()+']];HOOK_FILE=[['+hook.as_posix()+']];dofile(PROJECT_ROOT..[[/tests/network_native.lua]])'
        process=subprocess.Popen([str(LUA),'-e',code],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8',errors='replace',
            creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        import threading,queue
        lines=queue.Queue()
        def reader():
            for line in process.stdout:lines.put(line.strip())
            lines.put(None)
        threading.Thread(target=reader,daemon=True).start()
        result=None;output=[];deadline=time.monotonic()+60;sample_start=None;sample_delta=None
        try:
            while time.monotonic()<deadline:
                line=lines.get(timeout=max(.1,deadline-time.monotonic()))
                if line is None:break
                output.append(line)
                if line=='SAMPLE_START':sample_start=self.server.get('/api/v1/sources')[1][0]['snapshotCount']
                if line=='SAMPLE_END':
                    sample_delta=self.server.get('/api/v1/sources')[1][0]['snapshotCount']-sample_start
                    state=self.server.get('/api/v1/sources/1/snapshot')[1]['state']
                    aircraft=next(e for e in state['entities'] if e['kind']=='aircraft' and e['identity']['unitName']=='Native-TCP-Pilot')
                    self.assertEqual(aircraft['motion']['speedMps'],300)
                    self.assertEqual(aircraft['fuel']['ratioRaw'],0.4)
                    self.assertTrue(aircraft['occupancy']['isPlayer']);self.assertTrue(aircraft['armament']['items'])
                    missile=next(e for e in state['entities'] if e['kind']=='missile')
                    self.assertEqual(missile['launch']['launcher']['object']['entityId'],aircraft['entityId'])
                    self.assertEqual(missile['targetObservation']['object']['name'],'Target')
                if line=='RESTART_NOW':self.server.stop();self.server.start()
                if line.startswith('RESULT '):result=json.loads(line[7:])
            process.wait(timeout=3)
            self.assertEqual(process.returncode,0,'\n'.join(output));self.assertIsNotNone(result,'\n'.join(output))
            self.assertGreaterEqual(result['reconnects'],4)
            self.assertIn(sample_delta,(2,3,4),'Expected about three 1 Hz snapshots in 3.2 seconds')
            rows=self.server.get('/api/v1/sources')[1];self.assertEqual(len(rows),2)
            first=next(r for r in rows if r['source']['missionSessionId']==result['firstSource']['missionSessionId'])
            self.assertEqual(first['receivedThrough'],373);self.assertTrue(first['serverTailComplete']);self.assertTrue(first['historyIncomplete'])
            second=next(r for r in rows if r is not first);self.assertEqual(second['receivedThrough'],1);self.assertTrue(second['serverTailComplete'])
            snapshot=self.server.get('/api/v1/sources/'+first['sourceId']+'/snapshot')[1]['state']
            self.assertGreater(first['snapshotCount'],0);self.assertTrue(snapshot['entities'])
            (folder/'summary.json').write_text(json.dumps({'result':result,'snapshotsIn3_2Seconds':sample_delta,'sources':rows},ensure_ascii=False,indent=2),encoding='utf-8')
        finally:
            if process.poll() is None:process.kill();process.wait()
            process.stdout.close()

if __name__=='__main__':unittest.main(verbosity=2)
