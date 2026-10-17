"""Inspect the real native bundle without installing/changing Windows components."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
EXE=ROOT/'dist/installer/DCS-Esport-UI-Setup-0.8.0.exe'

class BootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory=ROOT/'runtime/verification'/('bootstrap-'+time.strftime('%Y%m%d-%H%M%S'))
        cls.directory.mkdir(parents=True)
        cls.manifest=json.loads((EXE.parent/'build-manifest.json').read_text(encoding='utf-8'))

    def run_bootstrap(self,flag,name):
        target=self.directory/(name+'.json')
        r=subprocess.run([str(EXE),flag,'--report',str(target),'--bootstrap-cache',str(self.directory/'离线 缓存')],timeout=60)
        data=json.loads(target.read_text(encoding='utf-8'))
        self.assertEqual(r.returncode,0,data);self.assertTrue(data['ok']);return data

    def test_01_detect_current_framework_without_installing(self):
        data=self.run_bootstrap('--prereq-status','detection')
        self.assertEqual(data['minimumRelease'],528040)
        self.assertEqual(data['sufficient'],data['release']>=528040)
        self.assertTrue(data['nativeBootstrap'])
        self.assertFalse((self.directory/'离线 缓存').exists())

    def test_02_offline_resource_hash_and_microsoft_signature(self):
        data=self.run_bootstrap('--verify-bundle','offline-verification')
        self.assertTrue(data['offlineSignatureValid'])
        self.assertEqual(data['dotnetSha256'],self.manifest['dotnet']['sha256'])
        files=list((self.directory/'离线 缓存').glob('*/NDP48*.exe'))
        self.assertEqual(len(files),1);self.assertGreater(files[0].stat().st_size,100_000_000)
        self.assertEqual(hashlib.sha256(files[0].read_bytes()).hexdigest(),data['dotnetSha256'])
        manager=files[0].with_name('DcsEsportManager.exe')
        self.assertEqual(hashlib.sha256(manager.read_bytes()).hexdigest(),data['managerSha256'])

    def test_03_corrupted_cached_resources_restored_from_bundle(self):
        cached=next((self.directory/'离线 缓存').glob('*/NDP48*.exe'))
        cached.write_bytes(b'corrupt cache')
        cached.with_name('DcsEsportManager.exe').write_bytes(b'broken manager')
        self.run_bootstrap('--verify-bundle','cache-repair')
        self.assertEqual(hashlib.sha256(cached.read_bytes()).hexdigest(),self.manifest['dotnet']['sha256'])

    def test_04_native_executable_has_no_clr_or_external_runtime(self):
        result=subprocess.check_output([r'C:\msys64\ucrt64\bin\objdump.exe','-p',str(EXE)],text=True)
        dlls=[line.split(':',1)[1].strip().lower() for line in result.splitlines() if 'DLL Name:' in line]
        self.assertFalse(any('mscoree' in dll or 'libstdc++' in dll or 'libgcc' in dll or 'vcruntime' in dll for dll in dlls),dlls)
        (self.directory/'native-imports.json').write_text(json.dumps(dlls,indent=2),encoding='utf-8')
        self.assertTrue(any('CLR Runtime Header' in line and '0000000000000000' in line for line in result.splitlines()))

    def test_05_missing_older_success_restart_cancel_failure_policy(self):
        binary=ROOT/'build/installer/prerequisite-policy.exe'
        env=os.environ.copy();env['PATH']=r'C:\msys64\ucrt64\bin;'+env.get('PATH','')
        subprocess.run([r'C:\msys64\ucrt64\bin\g++.exe','-std=c++17','-O2','-static',str(ROOT/'tests/prerequisite_policy.cpp'),'-o',str(binary)],check=True,env=env)
        output=subprocess.check_output([str(binary)],text=True)
        self.assertIn('15 prerequisite policy cases passed',output)
        (self.directory/'policy.txt').write_text(output,encoding='utf-8')

if __name__=='__main__':unittest.main(verbosity=2)
