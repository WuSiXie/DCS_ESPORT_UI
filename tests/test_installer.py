"""Exercise the shipped EXE against disposable workspace directories and ports."""
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import time
import unittest
from types import SimpleNamespace
from test_server import Client, identity, batch

ROOT=Path(__file__).resolve().parents[1]
EXE=ROOT/'dist/installer/DCS-Esport-UI-Setup-0.8.0.exe'

def free_port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()

class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base=ROOT/'runtime/verification'/('installer-'+time.strftime('%Y%m%d-%H%M%S'))
        cls.base.mkdir(parents=True)
        cls.target=cls.base/'安装 目录';cls.profile=cls.base/'保存的游戏'/'DCS.test'
        cls.hook=cls.profile/'Scripts/Hooks/DcsEsportHook.lua'
        cls.hook.parent.mkdir(parents=True);cls.hook.write_text('-- existing hook fixture\n',encoding='utf-8')
        cls.other=cls.hook.with_name('OtherPlugin.lua');cls.other.write_text('-- unrelated plugin\n')
        cls.original=digest(cls.hook);cls.other_hash=digest(cls.other)
        cls.ports=[]
        while len(cls.ports)<3:
            p=free_port()
            if p not in cls.ports:cls.ports.append(p)
        cls.password=secrets.token_hex(16)
        cls.call('/install','--profile',str(cls.profile),'--username','installer_test','--http-port',str(cls.ports[0]),'--hook-port',str(cls.ports[1]),'--director-port',str(cls.ports[2]),'--no-integrate',password=cls.password)
        cls.preserved_hashes={p:digest(cls.target/p) for p in ['runtime/server/config.json','runtime/server/users.json']}
        cls.outputs=cls.target/'runtime/director-fixture/account/outputs.json';cls.outputs.parent.mkdir(parents=True)
        cls.outputs.write_text('{"team":"原队伍", "readKey":"fixture-read-key"}',encoding='utf-8')
        cls.output_hash=digest(cls.outputs)
        cls.proof=[]

    @classmethod
    def call(cls,mode,*args,password=None,exe=EXE,ok=True,root=None):
        report=cls.base/(secrets.token_hex(5)+'.json')
        env=os.environ.copy()
        if password:env['DCS_SETUP_PASSWORD']=password
        bootstrap=['--bootstrap-cache',str(cls.base/'bootstrap-cache')] if exe==EXE else []
        result=subprocess.run([str(exe),mode,'--root',str(root or cls.target),*args,'--report',str(report),*bootstrap],env=env,timeout=60)
        data=json.loads(report.read_text(encoding='utf-8'))
        if ok and (result.returncode or not data['ok']):raise AssertionError(data)
        if not ok and result.returncode==0:raise AssertionError('Expected failure: '+str(data))
        if password and password in report.read_text(encoding='utf-8'):raise AssertionError('Password leaked')
        return data

    @classmethod
    def tearDownClass(cls):
        cls.call('/stop')
        (cls.base/'summary.json').write_text(json.dumps({'testRun':str(cls.base),'ports':cls.ports,'checks':cls.proof},ensure_ascii=False,indent=2),encoding='utf-8')

    def preserved(self):
        for p,h in self.preserved_hashes.items():self.assertEqual(digest(self.target/p),h)
        self.assertEqual(digest(self.outputs),self.output_hash)
        self.assertEqual(digest(self.other),self.other_hash)

    def test_01_install_offline_credentials_hook_and_original_backup(self):
        self.call('/verify')
        state=json.loads((self.target/'runtime/installation.json').read_text(encoding='utf-8'))
        self.assertEqual(digest(Path(state['profiles'][0]['originalBackup'])),self.original)
        hook=self.hook.read_text(encoding='utf-8')
        self.assertIn('network = { enabled = true',hook)
        self.assertIn('pollHz = 1',hook)
        self.assertNotIn('StatusBarDialog',hook)
        self.assertNotIn('LoSetCommand',hook)
        self.assertNotIn(self.password,(self.target/'runtime/server/users.json').read_text())
        self.proof.append('offline install, Unicode/spaced paths, configured single Hook, original backup, no plaintext password')

    def test_02_missing_corrupt_files_and_hook_repaired_without_runtime_reset(self):
        damaged=self.target/'src/web/control.html';damaged.write_text('corrupt')
        missing=self.target/'runtime-bin/node.exe';missing.unlink()
        self.hook.write_text('-- corrupt\n')
        self.call('/verify',ok=False)
        data=self.call('/repair',exe=self.target/'DCS电竞UI.exe')
        self.assertTrue(any('control.html' in s for s in data['logs']))
        self.call('/verify');self.preserved()
        self.proof.append('offline repair from installed EXE restores deleted Node, HTML and Hook; preserves config, account, output, unrelated plugin')

    def test_03_start_auto_repairs_and_authenticates_real_services(self):
        (self.target/'src/web/control.html').write_text('broken before start')
        self.call('/start',exe=self.target/'DCS电竞UI.exe')
        self.call('/verify')
        port=self.ports[2]
        conn=http.client.HTTPConnection('127.0.0.1',port,timeout=8)
        try:
            conn.request('POST','/api/login',json.dumps({'username':'installer_test','password':self.password}),{'Content-Type':'application/json','Origin':f'http://127.0.0.1:{port}'})
            r=conn.getresponse();body=r.read();self.assertEqual(r.status,200,body)
        finally:conn.close()
        cfg=json.loads((self.target/'runtime/server/config.json').read_text(encoding='utf-8'))
        client=Client(SimpleNamespace(port=self.ports[1]),token=cfg['hookToken'])
        try:
            source=identity('installer-smoke');client.open(source);client.send('events',batch(0,2),source)
            self.assertEqual(client.read()['payload']['ackEventSeq'],2)
        finally:client.close()
        self.preserved();self.proof.append('startup automatic repair, actual C++/Node health, first-user login and password hash compatibility')

    def test_04_repair_while_running_restarts_only_owned_services(self):
        before=json.loads((self.target/'runtime/server/process.json').read_text(encoding='utf-8'))
        real_outputs=list((self.target/f'runtime/director-{self.ports[2]}').glob('*/outputs.json'))
        self.assertEqual(len(real_outputs),1)
        before_outputs={p:digest(p) for p in real_outputs}
        (self.target/'src/web/output.html').write_text('damage during idle')
        self.call('/repair')
        after=json.loads((self.target/'runtime/server/process.json').read_text(encoding='utf-8'))
        self.assertNotEqual(before['processId'],after['processId'])
        for p,h in before_outputs.items():self.assertEqual(digest(p),h)
        self.call('/verify');self.preserved();self.call('/stop')
        self.proof.append('repair restores previously-running owned services; stop uses recorded process identity')

    def test_05_port_conflict_leaves_foreign_listener_alone(self):
        with socket.socket() as s:
            s.bind(('127.0.0.1',self.ports[0]));s.listen()
            result=self.call('/start',ok=False)
            self.assertIn('占用',result['error']);self.assertEqual(s.getsockname()[1],self.ports[0])
        self.proof.append('port conflict reported without terminating existing listener')

    def test_06_existing_credentials_and_outputs_survive_rerun(self):
        self.call('/install','--profile',str(self.profile),'--no-integrate',password='must-not-replace-original-password')
        self.preserved();self.call('/verify')
        self.proof.append('rerun setup preserves credentials and OBS configuration')

    def test_07_invalid_config_is_not_silently_regenerated(self):
        config=self.target/'runtime/server/config.json';data=config.read_bytes()
        try:
            config.write_text('{"hookToken":"broken"}')
            self.call('/repair',ok=False)
            self.assertEqual(config.read_text(),'{"hookToken":"broken"}')
        finally:config.write_bytes(data)
        self.proof.append('invalid credential config rejected rather than silently reset')

    def test_08_nonempty_unmanaged_directory_is_rejected(self):
        path=self.base/'not-an-install';path.mkdir();(path/'keep.txt').write_text('keep')
        self.call('/install','--no-integrate',root=path,password=self.password,ok=False)
        self.assertEqual((path/'keep.txt').read_text(),'keep')
        self.proof.append('nonempty unmanaged directories protected')

    def test_09_discovery_readonly(self):
        report=self.base/'discovery.json'
        p=subprocess.run([str(EXE),'/discover','--report',str(report),'--bootstrap-cache',str(self.base/'bootstrap-cache')],timeout=20)
        self.assertEqual(p.returncode,0)
        d=json.loads(report.read_text(encoding='utf-8'));self.assertTrue(Path(d['path']).is_absolute());self.assertTrue(d['source'])
        self.proof.append('read-only Saved Games discovery: '+d['source'])

    def test_10_path_escape_guard(self):
        state=self.target/'runtime/installation.json';original=state.read_bytes()
        try:
            data=json.loads(original);data['root']=str(self.base);state.write_text(json.dumps(data))
            self.call('/repair',ok=False)
        finally:state.write_bytes(original)
        self.proof.append('installation root mismatch rejected')

    def test_11_external_setup_restores_missing_manager(self):
        manager=self.target/'DCS电竞UI.exe';manager.unlink()
        self.call('/repair');self.assertEqual(digest(manager),json.loads((EXE.parent/'build-manifest.json').read_text(encoding='utf-8'))['managerSha256'])
        self.proof.append('external repair restores missing manager executable')

    def test_12_reselect_moved_profile(self):
        moved=self.profile.with_name('DCS.moved');self.profile.rename(moved)
        self.call('/install','--profile',str(moved),'--no-integrate')
        self.call('/verify')
        state=json.loads((self.target/'runtime/installation.json').read_text(encoding='utf-8'))
        self.assertEqual(state['profiles'][0]['path'],str(moved))
        self.call('/install','--no-integrate')
        self.assertTrue((moved/'Scripts/Hooks/DcsEsportHook.lua').exists())
        self.proof.append('moved profile can be reselected; deselect does not delete old Hook')

    def test_13_bundled_scripts_work_in_windows_powershell_with_unicode_root(self):
        ps=Path(os.environ.get('WINDIR',r'C:\Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe'
        def run(script,action,*args):
            # Windows PowerShell children can inherit pipe handles even after the shell exits.
            # Capture to an ordinary file so the test waits for the shell, not its background service.
            logfile=self.base/(script+'-'+action+'.log')
            with logfile.open('wb') as stream:
                r=subprocess.run([str(ps),'-NoProfile','-ExecutionPolicy','Bypass','-File',str(self.target/'tools'/script),action,*args],stdout=stream,stderr=subprocess.STDOUT,timeout=30,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            r.stdout=r.stderr=logfile.read_bytes();return r
        try:
            r=run('Server.ps1','Start');self.assertEqual(r.returncode,0,r.stderr)
            r=run('Director.ps1','Start','-Port',str(self.ports[2]),'-Upstream',f'http://127.0.0.1:{self.ports[0]}');self.assertEqual(r.returncode,0,r.stderr)
            r=run('Director.ps1','Status','-Port',str(self.ports[2]));self.assertEqual(r.returncode,0,r.stderr)
            self.assertNotIn(b'not running',r.stdout)
        finally:
            run('Director.ps1','Stop','-Port',str(self.ports[2]));run('Server.ps1','Stop')
        self.proof.append('Windows PowerShell 5.1 launchers use embedded Node and handle Unicode process records')

if __name__=='__main__':unittest.main(verbosity=2)
