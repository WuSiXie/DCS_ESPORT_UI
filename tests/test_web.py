"""Real HTTP/WS/TLS tests against the C++ authority, independent of browser UI."""
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import struct
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from test_server import Server, Client, identity, batch, free_port, ROOT
from tools.accounts import password_record, save

PASSWORD = 'test-only-password-123'
HASH = password_record(PASSWORD)

class WebSocket:
    def __init__(self, port, ticket, context=None, origin=None):
        self.s = socket.create_connection(('127.0.0.1', port), 3)
        if context: self.s = context.wrap_socket(self.s, server_hostname='localhost')
        self.s.settimeout(4)
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        request = f'GET /ws/v1/telemetry?ticket={ticket} HTTP/1.1\r\nHost: localhost:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n'
        if origin: request += f'Origin: {origin}\r\n'
        self.s.sendall((request+'\r\n').encode())
        header = b''
        while not header.endswith(b'\r\n\r\n'):
            b = self.s.recv(1)
            if not b: raise EOFError('Upgrade closed')
            header += b
        self.status = int(header.split(b' ')[1])
        if self.status == 101:
            expected = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
            assert expected.lower() in header.lower()
    def close(self): self.s.close()
    def send(self, value, opcode=1):
        payload = json.dumps(value).encode() if opcode == 1 else value
        mask = secrets.token_bytes(4); n = len(payload)
        head = bytes([0x80 | opcode]) + (bytes([0x80 | n]) if n < 126 else b'\xfe'+struct.pack('!H', n))
        self.s.sendall(head+mask+bytes(b ^ mask[i%4] for i,b in enumerate(payload)))
    def exact(self, n):
        data = b''
        while len(data) < n:
            part = self.s.recv(n-len(data))
            if not part: raise EOFError('WebSocket closed')
            data += part
        return data
    def read(self):
        while True:
            first, second = self.exact(2); opcode = first & 15; size = second & 127
            if size == 126: size = struct.unpack('!H', self.exact(2))[0]
            if size == 127: size = struct.unpack('!Q', self.exact(8))[0]
            payload = self.exact(size)
            if opcode == 9: self.send(payload, 10); continue
            if opcode == 8: raise EOFError('WebSocket closed')
            # Beast may fragment large messages into continuation frames.
            while not first & 0x80:
                first, second = self.exact(2); size = second & 127
                if size == 126: size = struct.unpack('!H', self.exact(2))[0]
                if size == 127: size = struct.unpack('!Q', self.exact(8))[0]
                payload += self.exact(size)
            return json.loads(payload)
    def until(self, kind):
        for _ in range(100):
            value = self.read()
            if value['type'] == kind: return value
        raise AssertionError('Message not received: '+kind)

class BrowserAuthorityTests(unittest.TestCase):
    def setUp(self):
        folder = ROOT/'runtime/web-tests'; folder.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=folder); self.path = Path(self.temp.name)/'users.json'
        self.users = {'version': 1, 'users': [
            {'username': name, 'role': role, 'enabled': True, 'instances': scopes, 'password': HASH}
            for name,role,scopes in [('director','director',['dcs-local']),('viewer','viewer',['elsewhere']),('admin','admin',['*'])]]}
        save(self.path, self.users)
        self.server = Server(['--users', str(self.path)]); self.server.start();self.clients=[]
    def tearDown(self):
        for client in self.clients: client.close()
        self.server.stop(); self.temp.cleanup()
    def request(self, method, path, data=None, token=None, origin=None, context=None, port=None):
        headers = {'Content-Type': 'application/json'}
        if token: headers['Authorization'] = 'Bearer '+token
        if origin: headers['Origin'] = origin
        connection = (http.client.HTTPSConnection('localhost', port, context=context, timeout=5) if context else
                      http.client.HTTPConnection('127.0.0.1', self.server.http, timeout=5))
        try:
            connection.request(method, path, json.dumps(data) if data is not None else None, headers)
            response=connection.getresponse(); return response.status, json.loads(response.read())
        finally: connection.close()
    def login(self, name='director', **kwargs):
        code, data = self.request('POST','/api/v1/auth/login',{'username':name,'password':PASSWORD},**kwargs)
        self.assertEqual(code,200,data); return data['accessToken']
    def connect(self, token, **kwargs):
        code, data = self.request('POST','/api/v1/auth/ws-ticket',token=token)
        self.assertEqual(code,200)
        client = WebSocket(kwargs.pop('port',self.server.http),data['ticket'],**kwargs);self.clients.append(client)
        self.assertEqual(client.status,101);client.until('welcome');return client
    def hook(self):
        client=Client(self.server);self.clients.append(client);return client
    def test_auth_scope_roles_logout_ticket_and_origin(self):
        hook=self.hook();hook.open(identity('auth'))
        token=self.login();viewer=self.login('viewer')
        self.assertEqual(self.request('GET','/api/v1/sources',token=viewer),(200,[]))
        self.assertEqual(self.request('GET','/api/v1/sources/1/snapshot',token=viewer)[0],404)
        self.assertEqual(self.request('GET','/api/v1/status',token=token)[0],403)
        self.assertEqual(self.request('GET','/api/v1/sources',token=token)[1][0]['createdOrder'],1)
        self.assertEqual(self.request('POST','/api/v1/auth/ws-ticket',token=token,origin='https://evil.invalid')[0],403)
        view=self.connect(viewer);view.send({'type':'subscribe','sourceId':'1'})
        self.assertEqual(view.until('error')['error'],'source_unavailable')
        code,ticket=self.request('POST','/api/v1/auth/ws-ticket',token=token)
        ws=WebSocket(self.server.http,ticket['ticket']);self.clients.append(ws);self.assertEqual(ws.status,101)
        reused=WebSocket(self.server.http,ticket['ticket']);self.clients.append(reused);self.assertEqual(reused.status,401)
        self.assertEqual(self.request('POST','/api/v1/auth/logout',token=token)[0],200)
        self.assertEqual(self.request('GET','/api/v1/auth/me',token=token)[0],401)
        with self.assertRaises((EOFError,ConnectionError)): 
            while True: ws.read()
    def test_ws_baseline_resume_live_and_epoch_reset(self):
        hook=self.hook();src=identity('stream');hook.open(src);hook.send('events',batch(0,3),src);hook.read()
        token=self.login();ws=self.connect(token);ws.send({'type':'subscribe','sourceId':'1'})
        baseline=ws.until('events');self.assertTrue(baseline['historical']);self.assertEqual([e['eventSeq'] for e in baseline['events']],[1,2,3])
        hook.send('events',batch(3,6),src);hook.read()
        live=ws.until('events');self.assertFalse(live['historical']);self.assertEqual(live['throughSeq'],6)
        ws.close();resumed=self.connect(token);resumed.send({'type':'subscribe','sourceId':'1','afterSeq':4,'serverEpoch':hook.epoch})
        replay=resumed.until('events');self.assertEqual([e['eventSeq'] for e in replay['events']],[5,6]);self.assertFalse(replay['historical'])
        resumed.send({'type':'subscribe','sourceId':'1','afterSeq':6,'serverEpoch':'old-epoch'})
        self.assertEqual(resumed.until('resync_required')['reason'],'server_epoch_changed')
        self.assertTrue(resumed.until('events')['historical'])
        page={'snapshotId':'s1','pageIndex':0,'pageCount':1,'assembledSimTime':1,'eventSeqAtCapture':6,'entities':[],'scopeRevision':1,'coverage':{}}
        hook.send('snapshot',page,src)
        self.assertEqual(resumed.until('snapshot')['state']['snapshotId'],'s1')
    def test_account_change_and_invalid_file_revoke_sessions(self):
        token=self.login();ws=self.connect(token)
        self.users['users'][0]['instances']=[];save(self.path,self.users);time.sleep(1.1)
        self.assertEqual(self.request('GET','/api/v1/auth/me',token=token)[0],401)
        with self.assertRaises((EOFError,ConnectionError)):
            while True:ws.read()
        admin=self.login('admin');self.path.write_text('{broken',encoding='utf-8');time.sleep(1.1)
        self.assertEqual(self.request('GET','/api/v1/auth/me',token=admin)[0],401)
        save(self.path,self.users);time.sleep(1.1);self.login('admin')
    def test_password_work_does_not_block_hook_and_login_is_limited(self):
        hook=self.hook();src=identity('login-load');hook.open(src)
        def bad(): return self.request('POST','/api/v1/auth/login',{'username':'director','password':'wrong'})[0]
        with ThreadPoolExecutor(max_workers=4) as workers:
            pending=[workers.submit(bad) for _ in range(4)]
            began=time.monotonic();hook.send('events',batch(0,10),src);self.assertEqual(hook.read()['payload']['ackEventSeq'],10)
            self.assertLess(time.monotonic()-began,1)
            self.assertEqual([p.result() for p in pending],[401]*4)
        self.assertEqual(bad(),401);self.assertEqual(bad(),429)
    def test_https_wss_trusted_certificate_and_untrusted_rejection(self):
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes,serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID
        from datetime import datetime,timedelta,timezone
        key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'localhost')]);now=datetime.now(timezone.utc)
        cert=x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-timedelta(minutes=1)).not_valid_after(now+timedelta(days=1)).add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]),critical=False).sign(key,hashes.SHA256())
        certpath=Path(self.temp.name)/'certificate.pem';keypath=Path(self.temp.name)/'key.pem'
        certpath.write_bytes(cert.public_bytes(serialization.Encoding.PEM));keypath.write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
        port=free_port();self.server.stop();self.server.args+=['--tls-port',str(port),'--tls-cert',str(certpath),'--tls-key',str(keypath)];self.server.start()
        with self.assertRaises(ssl.SSLCertVerificationError):self.request('GET','/healthz',context=ssl.create_default_context(),port=port)
        context=ssl.create_default_context(cafile=str(certpath));token=self.login(context=context,port=port)
        ws=self.connect(token,context=context,port=port);ws.send({'type':'ping'});self.assertEqual(ws.until('pong')['type'],'pong')

    def test_large_snapshot_slow_subscribers_do_not_block_ack(self):
        hook=self.hook();src=identity('slow-subscribers');hook.open(src);token=self.login()
        slow=[]
        for _ in range(8):
            client=self.connect(token);client.s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4096)
            client.send({'type':'subscribe','sourceId':'1'});slow.append(client)
        # 4.6 MB assembled snapshots exceed TCP receive windows and eventually
        # fill each non-reading subscriber's bounded queue. No filesystem sink.
        entities=[{'entityId':f'aircraft-{n}','kind':'aircraft','motion':{},'fuel':{},'armament':{},
                   'occupancy':{},'identity':{'unitName':str(n)},'padding':'x'*18000} for n in range(256)]
        elapsed=[]
        for tick in range(1,7):
            started=time.monotonic()
            for index in range(16):
                hook.send('snapshot',{'snapshotId':f's-{tick}','pageIndex':index,'pageCount':16,'assembledSimTime':tick,
                    'eventSeqAtCapture':tick-1,'scopeRevision':1,'coverage':{},'entities':entities[index*16:(index+1)*16]},src)
            hook.send('events',batch(tick-1,tick),src);self.assertEqual(hook.read()['payload']['ackEventSeq'],tick)
            elapsed.append(time.monotonic()-started);time.sleep(.15)
        self.assertLess(max(elapsed),3,'Slow browser consumers must not stall the Hook')
        for _ in range(60):
            status=self.server.get('/api/v1/status')[1]
            if status.get('webSubscribers',8)==0:break
            time.sleep(.1)
        self.assertEqual(status['webSubscribers'],0)
        self.assertEqual(self.server.get('/api/v1/sources')[1][0]['receivedThrough'],6)
        (ROOT/'runtime/web-load-result.json').write_text(json.dumps({'subscribers':8,'entities':256,
            'snapshotBytes':len(json.dumps(entities)),'uploadAndAckSeconds':elapsed,'remainingSubscribers':0},indent=2),encoding='utf-8')

if __name__=='__main__':unittest.main(verbosity=2)
