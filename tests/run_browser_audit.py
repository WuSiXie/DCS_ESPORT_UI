"""Isolated browser audit using previously captured DCS data; not a new live mission."""
import json
import os
import copy
from pathlib import Path
import subprocess
import threading
import time
from test_server import ROOT,Server,Client,identity
from test_director import Director,NODE
from test_web import HASH
from tools.accounts import save

folder=ROOT/'runtime/verification'/os.environ.get('AUDIT_FOLDER','ui-realtime-switches');folder.mkdir(parents=True,exist_ok=True)
users=folder/'users.json'
save(users,{'version':1,'users':[{'username':'director','role':'director','enabled':True,'instances':['dcs-local'],'password':HASH}]})
server=Server(['--users',str(users)]);director=None;hook=None;done=threading.Event();pump=None
try:
    server.start();hook=Client(server);source=identity('recorded-dcs-audit');hook.open(source)
    snapshots=ROOT/'runtime/verification/risk-v030-20261016-231335/snapshots.jsonl'
    state=json.loads(snapshots.read_text(encoding='utf-8').splitlines()[-1])['state']
    state['pageIndex']=0;state['pageCount']=1
    scenario=os.environ.get('AUDIT_SCRIPT') in ['nameplate-browser.mjs','resize-browser.mjs','threats-browser.mjs']
    command_file=folder/'scenario-command.json';reply_file=folder/'scenario-reply.json'
    threat_scenario=os.environ.get('AUDIT_SCRIPT')=='threats-browser.mjs'
    missile_template=copy.deepcopy(next(e for e in state['entities'] if e['kind']=='missile'))
    if scenario:
        command_file.write_text('{}',encoding='utf-8');reply_file.write_text('{}',encoding='utf-8')
        planes=[copy.deepcopy(e) for e in state['entities'] if e['kind']=='aircraft'][:3]
        for i,p in enumerate(planes):
            p['entityId']='test-aircraft-'+str(i);p['identity']['unitName']='Test-Unit-'+str(i)
            p['identity']['coalition']='red' if i==0 else 'blue'
            p['occupancy']['isPlayer']=i<2;p['occupancy']['playerName']=['Ace','Viper',None][i]
        state['entities']=planes
        if threat_scenario:
            missiles=[]
            for i in range(4):
                m=copy.deepcopy(missile_template);m['entityId']='test-missile-'+str(i);m['typeName']='TEST-AAM-'+str(i)
                m['targetObservation']['object']['entityId']='test-aircraft-'+str(1 if i<3 else 0)
                m['launch']['launcher']['object'].update({'isPlayer':True,'playerName':'Ace','entityId':'test-aircraft-0'})
                m['motion']['position']['z']+=i*12000;m['motion']['position']['x']+=i*7000
                missiles.append(m)
            state['entities']=planes+missiles
    hook.send('snapshot',state,source)
    final=json.loads((snapshots.parent/'source-1-final.json').read_text(encoding='utf-8'))
    events=[] if scenario else final['events']
    if isinstance(events,dict):events=events['events']
    hook.send('events',{'afterSeq':0,'throughSeq':len(events),'latestEventSeq':len(events),'events':events,'gaps':[]},source);hook.read()
    records=[{'id':2,'name':'Ace','connected':True,'slot':'1','side':1,'changed':1}, {'id':3,'name':'Viper','connected':True,'slot':'2','side':2,'changed':2}]
    threat_live=[True]
    def heartbeat():
        applied=None;sequence=len(events)

        while not done.wait(1):
            try:
                if scenario:
                    command=json.loads(command_file.read_text(encoding='utf-8'))
                    if command.get('id') and command['id']!=applied:
                        kind=command['kind']
                        if kind=='disconnect':records[0]['connected']=False;records[0]['changed']+=1
                        elif kind=='retarget':
                            missiles[0]['targetObservation']['object']['entityId']='test-aircraft-0'
                            missiles[1]['targetObservation']['status']='none_reported'
                            state['entities']=planes+[missiles[0],missiles[1],missiles[3]]
                        elif kind=='stale': threat_live[0]=False
                        elif kind=='fresh': threat_live[0]=True
                        elif kind=='spectator':records[0]['connected']=True;records[0]['slot']=''
                        elif kind=='reentry':
                            records[0]['connected']=True;records[0]['slot']='4'
                            planes[0]=copy.deepcopy(planes[0]);planes[0]['entityId']='test-reentered';planes[0]['identity']['unitName']='New-F16';planes[0]['identity']['typeName']='F-16C';planes[0]['identity']['coalition']='blue';planes[0]['discoveredSimTime']=200
                            state['entities']=planes
                        elif kind=='crash':
                            event={'eventSeq':sequence+1,'type':'crash','simTime':202,'actor':{'kind':'aircraft','entityId':planes[0]['entityId']}}
                            hook.send('events',{'afterSeq':sequence,'throughSeq':sequence+1,'latestEventSeq':sequence+1,'events':[event],'gaps':[]},source);hook.read();sequence+=1
                            state['entities']=[p for p in planes if p['entityId']!=planes[0]['entityId']]
                        elif kind=='rolloff':
                            ev=[{'eventSeq':n,'type':'takeoff'} for n in range(sequence+1,sequence+211)]
                            hook.send('events',{'afterSeq':sequence,'throughSeq':sequence+210,'latestEventSeq':sequence+210,'events':ev,'gaps':[]},source);hook.read();sequence+=210
                        applied=command['id']
                        state['snapshotId']='audit-'+str(applied);state['assembledSimTime']+=1
                        hook.send('snapshot',state,source)
                        reply_file.write_text(json.dumps({'id':applied}),encoding='utf-8')
                if threat_scenario and threat_live[0]:
                    state['snapshotId']='tick-'+str(time.time_ns());hook.send('snapshot',state,source)
                hook.send('status',{'active':True,'paused':True,'health':{'captureContinuous':True},**({'players':{'supported':True,'records':records}} if scenario else {})},source)
                hook.send('ping',{});hook.read()
            except (OSError,EOFError):return
    pump=threading.Thread(target=heartbeat,daemon=True);pump.start()
    # Fresh per-run output identity while preserving all screenshots/reports.
    directory=folder/('director-'+str(time.time_ns()))
    director=Director(server.http,directory);director.start()
    result=subprocess.run([str(NODE),str(ROOT/'tests'/os.environ.get('AUDIT_SCRIPT','browser-audit.mjs')),str(folder),f'http://127.0.0.1:{director.port}/'],
        creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0),timeout=180,capture_output=True,text=True,encoding='utf-8')
    (folder/'browser-stdout.log').write_text(result.stdout,encoding='utf-8')
    (folder/'browser-stderr.log').write_text(result.stderr,encoding='utf-8')
    print(result.stdout);print(result.stderr)
    if result.returncode:raise SystemExit(result.returncode)
finally:
    done.set()
    if pump:pump.join(timeout=4)
    if director:director.stop()
    if hook:hook.close()
    server.stop()
