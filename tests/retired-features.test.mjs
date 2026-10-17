import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile,rm,mkdir} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {defaultConfig,validateConfig,migrateRetiredFeatures,LAYOUTS} from '../src/director/output-model.mjs';
import {OutputStore} from '../src/director/output-store.mjs';
import {selectedAircraft} from '../src/web/telemetry.mjs';

test('retired focus and camera fields migrate without losing team and output identity',async()=>{
  const root=resolve('runtime/director-tests');await mkdir(root,{recursive:true});const dir=await mkdtemp(join(root,'retired-'));
  try{
    const store=await new OutputStore(dir).load();assert.deepEqual(LAYOUTS,['overview','tactical']);assert.equal(store.outputs.length,2);
    const old=structuredClone(store.outputs[0]);old.config.layout='focus';old.config.name='选手特写';old.config.followCamera=true;
    old.config.features.aircraft=true;old.config.docks.aircraft={anchor:'center',x:10,y:20};
    old.config.elementLayouts['aircraft/name']={dx:3,dy:4,scaleX:2,scaleY:1};old.config.match.blueName='保留队伍';old.config.match.redScore=7;
    assert.throws(()=>validateConfig(old.config));
    await writeFile(join(dir,'outputs.json'),JSON.stringify({version:1,outputs:[old]}));
    const loaded=await new OutputStore(dir).load(),current=loaded.outputs[0];
    assert.equal(current.id,old.id);assert.equal(current.readKey,old.readKey);assert.equal(current.revision,old.revision);
    assert.equal(current.config.layout,'overview');assert.equal(current.config.name,'比赛直播');
    assert.equal(current.config.match.blueName,'保留队伍');assert.equal(current.config.match.redScore,7);
    assert.ok(!('followCamera' in current.config));assert.ok(!('aircraft' in current.config.features));assert.ok(!('aircraft' in current.config.docks));assert.deepEqual(current.config.elementLayouts,{});
    assert.deepEqual(JSON.parse(await readFile(join(dir,'outputs.json'),'utf8')).outputs,loaded.outputs);
    assert.deepEqual(migrateRetiredFeatures(current.config),current.config);
  }finally{await rm(dir,{recursive:true,force:true});}
});
test('manual map/filter focus never follows camera or chooses an aircraft implicitly',()=>{
  const c=defaultConfig(),plane={kind:'aircraft',entityId:'a'},latest={snapshot:{entities:[plane]},source:{hookStatus:{camera:{entityId:'a',mode:'F2'}}}};
  assert.equal(selectedAircraft(latest,c),null);c.aircraftId='a';assert.equal(selectedAircraft(latest,c),plane);
  c.aircraftId='missing';assert.equal(selectedAircraft(latest,c),null);
});
