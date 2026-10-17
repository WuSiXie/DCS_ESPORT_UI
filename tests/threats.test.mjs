import {test} from 'node:test';
import assert from 'node:assert/strict';
import {incomingMissiles,missileLabels} from '../src/web/telemetry.mjs';
import {playerDirectory} from '../src/web/player-picker.mjs';
import {drawMap} from '../src/web/map.mjs';
import {defaultConfig,validateConfig} from '../src/director/output-model.mjs';
const now=10000;
const fresh=()=>({source:{online:true,statusFresh:true,snapshotFresh:true,statusAgeSec:0,snapshotAgeSec:0,lifecycle:'running'},connection:'connected',sourcesReceivedAt:now});
const missile=(id,target)=>({kind:'missile',entityId:id,typeName:'AIM-120',targetObservation:{status:'object',object:{entityId:target}},motion:{position:{x:1,z:1}},launch:{launcher:{status:'known',object:{isPlayer:true,playerName:'Ace'}}}});
test('incoming counts current targets once, moves on retarget, clears missing and stale targets',()=>{
  const a=missile('a','p'),b=missile('b','p'),c=missile('c','q');const state={...fresh(),snapshot:{entities:[a,b,c,a]}};
  assert.equal(incomingMissiles(state,'connected',now).get('p').length,2);
  a.targetObservation.object.entityId='q';b.lastKnownTarget=b.targetObservation;b.targetObservation={status:'none_reported'};
  const result=incomingMissiles(state,'connected',now);assert.equal(result.has('p'),false);assert.equal(result.get('q').length,2);
  assert.equal(incomingMissiles(state,'connected',now+3000).size,0);
  assert.equal(incomingMissiles(state,'offline',now).size,0);
  state.source.lifecycle='ended';assert.equal(incomingMissiles(state,'connected',now).size,0);
});
test('launcher labels retain known player identity and expose conflict instead of guessing',()=>{
  const m=missile('a','p');assert.deepEqual(missileLabels(m),{name:'AIM-120',launcher:'Ace'});
  m.launch.launcher.status='conflict';assert.equal(missileLabels(m).launcher,'发射来源冲突');
  m.launch.launcher.status='unknown';assert.equal(missileLabels(m).launcher,'未知发射人');
});
test('picker merges observed history, excludes AI, deduplicates names and expires online badges',()=>{
  const state={...fresh(),players:[{name:'Ace',connected:true},{name:'Past',connected:false}],history:['Ace','Older'],snapshot:{entities:[{occupancy:{isPlayer:false,playerName:null}}]},aircraftLedger:[{lastPlayerName:'OldPilot'}]};
  assert.deepEqual(playerDirectory(state,now).filter(r=>r.online).map(r=>r.name),['Ace']);
  assert.equal(playerDirectory(state,now).length,4);assert.equal(playerDirectory(state,now+3000).some(r=>r.online),false);
});
test('map missile labels have independent switches and profiles migrate',()=>{
  const c=defaultConfig();for(const key of ['mapMissileName','mapMissileLauncher','incoming','incomingName','incomingLauncher'])delete c.features[key];
  const config=validateConfig(c);config.appearance.labels=false;
  const text=[],ctx=new Proxy({measureText:s=>({width:s.length*5}),fillText:s=>text.push(s)},{get:(o,k)=>k in o?o[k]:()=>{}});
  globalThis.devicePixelRatio=1;const canvas={clientWidth:500,clientHeight:400,getContext:()=>ctx};
  drawMap(canvas,[],[missile('m','p')],config);assert.ok(text.includes('AIM-120'));assert.ok(text.includes('发射：Ace'));
  text.length=0;config.features.mapMissileName=false;drawMap(canvas,[],[missile('m','p')],config);assert.ok(!text.includes('AIM-120'));assert.ok(text.includes('发射：Ace'));
  text.length=0;config.features.mapMissileLauncher=false;drawMap(canvas,[],[missile('m','p')],config);assert.ok(!text.includes('发射：Ace'));
});
