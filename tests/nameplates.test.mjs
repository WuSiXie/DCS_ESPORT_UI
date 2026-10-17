import {test} from 'node:test';
import assert from 'node:assert/strict';
import {defaultConfig,validateConfig} from '../src/director/output-model.mjs';
import {teamPalette} from '../src/web/nameplates.mjs';
import {filterPlates,plateSettings,newOverride,updateAircraftLedger,updatePresenceLedger,playerAircraft,resolvedSlots,teamSide,snapPosition,dockFromPosition,dockPosition,rosterPage} from '../src/web/nameplates.mjs';
const plane=(id,name='Ace',side='red')=>({entityId:id,kind:'aircraft',discoveredSimTime:Number(id)||0,identity:{unitName:'unit-'+id,coalition:side,typeName:'F-16'},occupancy:{isPlayer:true,playerName:name},fuel:{ratioRaw:.5},motion:{speedMps:200,position:{y:4000}},armament:{items:[{displayName:'AIM-120',count:2}]}});
const slot=(name,team='blue')=>({id:'11111111-1111-1111-1111-111111111111',binding:'player',playerName:name,unitName:'',team,label:name,dock:null});
test('team colors migrate, validate and stay separate from coalition colors',()=>{
  const c=defaultConfig();delete c.competition.blueColor;delete c.competition.redColor;
  assert.equal(validateConfig(c).competition.blueColor,'#56bbfa');
  c.competition.blueColor='#AA22CC';c.competition.mode='teams';const saved=validateConfig(c);
  assert.equal(saved.competition.blueColor,'#aa22cc');assert.equal(teamPalette(saved,'blue').color,'#aa22cc');
  saved.competition.mode='coalition';assert.equal(teamPalette(saved,'blue').color,'#56bbfa');
  for(const bad of [null,'red','#123','url(x)','#123456;display:none']){c.competition.blueColor=bad;assert.throws(()=>validateConfig(c));}
});
test('config migrates old profiles, validates pools, logos and numeric limits',()=>{
  const c=defaultConfig();delete c.nameplates;delete c.docks;delete c.competition;assert.equal(validateConfig(c).competition.mode,'coalition');
  const n=defaultConfig();n.nameplates.fixedSlots=[slot('Ace')];n.competition.mode='teams';assert.equal(validateConfig(n).nameplates.fixedSlots[0].playerName,'Ace');
  n.nameplates.fixedSlots.push({...slot('Ace'),id:'22222222-2222-2222-2222-222222222222',team:'red'});assert.throws(()=>validateConfig(n));n.nameplates.fixedSlots.pop();
  n.competition.blueLogo='javascript:alert(1)';assert.throws(()=>validateConfig(n));n.competition.blueLogo='data:image/svg+xml;base64,AAAA';assert.throws(()=>validateConfig(n));n.competition.blueLogo='';
  n.nameplates.filters.fuelMin=90;n.nameplates.filters.fuelMax=20;assert.throws(()=>validateConfig(n));
});
test('per-card fields inherit, ranges reject unknown measurements, counts and paging are bounded',()=>{
  const c=defaultConfig(),a=plane('1'),b=plane('2','Other');c.nameplates.overrides=[{...newOverride('unit-1'),fields:{fuel:false},width:400}];
  assert.equal(plateSettings(c,'unit-1').fields.speed,true);assert.equal(plateSettings(c,'unit-1').fields.fuel,false);assert.equal(plateSettings(c,'unit-2').width,344);
  c.nameplates.filters.weapon='aim-120';c.nameplates.filters.speedMin=700;assert.equal(filterPlates([a,b],c).length,2);b.motion={};assert.deepEqual(filterPlates([a,b],c),[a]);
  c.nameplates.redCount=0;assert.equal(rosterPage([a],'red',c,null).shown.length,0);c.nameplates.redCount=1;assert.deepEqual(rosterPage([a],'red',c,'1').shown,[a]);
});
test('death facts survive removal but slot leave, track removal and missing snapshots do not kill',()=>{
  const a=plane('1'),b=plane('2'),snapshot={assembledSimTime:1,entities:[a,b]};let ledger=updateAircraftLedger([],snapshot);
  ledger=updateAircraftLedger(ledger,null,[{type:'player_left',actor:{kind:'aircraft',entityId:'1'}},{type:'entity_removed',actor:{kind:'aircraft',entityId:'1'}}]);assert.equal(ledger[0].death,null);
  ledger=updateAircraftLedger(ledger,null,[{type:'kill',actor:{kind:'aircraft',entityId:'1'},target:{kind:'aircraft',entityId:'2'},eventSeq:1}]);assert.equal(ledger.find(r=>r.entity.entityId==='1').death,null);assert.equal(ledger.find(r=>r.entity.entityId==='2').death.reason,'kill');
  ledger=updateAircraftLedger(ledger,{assembledSimTime:2,entities:[]});assert.equal(ledger.find(r=>r.entity.entityId==='2').death.reason,'kill');
});
test('player pool follows reentry, disconnect requires explicit presence, and teams override coalition',()=>{
  const a=plane('1'),b=plane('2','Ace','blue');let latest={snapshot:{assembledSimTime:1,entities:[a]},aircraftLedger:[],source:{hookStatus:{players:{records:[{id:2,name:'Ace',connected:true,slot:'1',changed:1}]}}}};
  latest.aircraftLedger=updateAircraftLedger([],latest.snapshot);assert.equal(playerAircraft('Ace',latest).status,'live');
  latest.source.hookStatus.players.records[0].connected=false;assert.equal(playerAircraft('Ace',latest).death.reason,'disconnected');
  latest.source.hookStatus.players.records[0].connected=true;latest.source.hookStatus.players.records[0].slot='';assert.equal(playerAircraft('Ace',latest).status,'waiting');
  latest.source.hookStatus.players.records[0].slot='2';latest.snapshot={assembledSimTime:2,entities:[b]};latest.aircraftLedger=updateAircraftLedger(latest.aircraftLedger,latest.snapshot);assert.equal(playerAircraft('Ace',latest).entity.entityId,'2');
  const c=defaultConfig();c.nameplates.fixedSlots=[slot('Ace','red')];assert.equal(resolvedSlots(c,latest)[0].side,'blue');c.competition.mode='teams';assert.equal(resolvedSlots(c,latest)[0].side,'red');assert.equal(teamSide(b,c),'red');
  latest.source.hookStatus.players.records.push({id:3,name:'Ace',connected:true,slot:'3'});assert.equal(playerAircraft('Ace',latest).status,'ambiguous');
});
test('dock offsets roundtrip all anchors and snapping respects canvas edges',()=>{
  for(const anchor of ['top-left','top-right','center','bottom-right'])assert.deepEqual(dockPosition(dockFromPosition(110,220,344,120,anchor),344,120),{x:110,y:220});
  const p=snapPosition(38,28,344,120);assert.equal(p.x,32);assert.equal(p.y,32);assert.equal(snapPosition(-100,-100,344,120).x,0);
});
test('disconnect attribution retains the last player after AI takeover and never infers from source loss',()=>{
  const a=plane('1');let ledger=updateAircraftLedger([],{assembledSimTime:1,entities:[a]});
  a.occupancy={isPlayer:false,playerName:null};ledger=updateAircraftLedger(ledger,{assembledSimTime:2,entities:[a]});
  updatePresenceLedger(ledger,undefined);assert.equal(ledger[0].death,null);
  updatePresenceLedger(ledger,{records:[{id:2,name:'Ace',connected:false}]});assert.equal(ledger[0].death.reason,'disconnected');
  const latest={snapshot:{entities:[a]},aircraftLedger:ledger,source:{hookStatus:{players:{records:[{id:2,name:'Ace',connected:false}]}}}};
  assert.equal(playerAircraft('Ace',latest).entity.identity.unitName,'unit-1');assert.equal(playerAircraft('Ace',latest).entity.occupancy.playerName,'Ace');
});
