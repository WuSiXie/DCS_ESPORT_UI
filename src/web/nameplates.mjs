import { entityName, coalition, finite } from './telemetry.mjs';

export function teamPalette(config,side){
  const defaults={blue:{color:'#56bbfa',background:'#15283aef'},red:{color:'#ff6970',background:'#351c29ef'}};
  const fallback=defaults[side]??{color:'#bdc9d4',background:'#242d35ef'},color=config.competition?.[side+'Color'];
  if(config.competition?.mode!=='teams'||!/^#[0-9a-f]{6}$/iu.test(color??''))return fallback;
  const rgb=[1,3,5].map((i)=>Math.round(parseInt(color.slice(i,i+2),16)*.18+12*.82).toString(16).padStart(2,'0'));
  return {color:color.toLowerCase(),background:'#'+rgb.join('')+'ef'};
}

export const PLATE_FIELDS={slot:'序号',name:'选手名称',unitName:'单位名称',type:'飞机型号',occupancy:'玩家 / AI',coalition:'阵营',fuel:'油量',speed:'速度',altitude:'高度',loadout:'武器挂载'};
export const DOCK_PARTS={blueLogo:'左队队标',redLogo:'右队队标',match:'比赛信息',map:'战术小地图',blue:'蓝方标牌组',red:'红方标牌组',missiles:'导弹追踪',events:'事件播报',status:'链路状态'};
export const ANCHORS={'top-left':'左上','top-center':'顶部居中','top-right':'右上','middle-left':'左侧居中',center:'画面中心','middle-right':'右侧居中','bottom-left':'左下','bottom-center':'底部居中','bottom-right':'右下'};
export function defaultPlates(layout='overview'){
  return {fields:Object.fromEntries(Object.keys(PLATE_FIELDS).map(k=>[k,!['unitName','coalition'].includes(k)])),
    width:344,scale:100,blueCount:layout==='tactical'?8:5,redCount:layout==='tactical'?8:5,fixedCount:false,rotate:true,rotationSec:12,
    filters:{occupancy:'all',type:'',weapon:'',fuelMin:null,fuelMax:null,speedMin:null,speedMax:null,altitudeMin:null,altitudeMax:null},
    overrides:[],fixedSlots:[]};
}
export const newOverride=unitName=>({unitName,visible:true,fields:{},width:null,scale:null,dock:null});
export function plateSettings(config,unitName,playerName){
  const p=config.nameplates??defaultPlates(config.layout),unit=p.overrides.find(v=>v.unitName===unitName),player=p.overrides.find(v=>playerName&&v.unitName==='player:'+playerName),o=player??unit;
  return {...p,...unit,...player,fields:{...p.fields,...unit?.fields,...player?.fields},width:player?.width??unit?.width??p.width,scale:player?.scale??unit?.scale??p.scale,visible:o?.visible!==false,dock:player?.dock??unit?.dock??null};
}
export function filterPlates(planes,config){
  const f=(config.nameplates??defaultPlates()).filters;
  const contains=(a,b)=>String(a??'').toLocaleLowerCase().includes(b.trim().toLocaleLowerCase());
  return planes.filter(p=>{
    if(!plateSettings(config,p.identity?.unitName,p.occupancy?.playerName).visible)return false;
    const player=p.occupancy?.isPlayer,kind=player===true?'player':player===false?'ai':'unknown';
    if(f.occupancy!=='all'&&f.occupancy!==kind)return false;
    if(f.type&&!contains(p.identity?.typeName,f.type))return false;
    if(f.weapon&&!(p.armament?.items??[]).some(w=>w.count>0&&[w.displayName,w.typeName,w.weaponKey].some(n=>contains(n,f.weapon))))return false;
    for(const [key,value] of [['fuel',finite(p.fuel?.ratioRaw)?p.fuel.ratioRaw*100:null],['speed',finite(p.motion?.speedMps)?p.motion.speedMps*3.6:null],['altitude',p.motion?.position?.y]]){
      if((f[key+'Min']!==null||f[key+'Max']!==null)&&!finite(value))return false;
      if(f[key+'Min']!==null&&value<f[key+'Min']||f[key+'Max']!==null&&value>f[key+'Max'])return false;
    }
    return true;
  });
}
export function rosterPage(planes,side,config,focusId,now=Date.now()){
  const p=config.nameplates??defaultPlates(config.layout),fixed=new Set(p.fixedSlots.map(s=>s.unitName).filter(Boolean));
  const list=filterPlates(planes,config).filter(e=>!fixed.has(e.identity?.unitName)&&(side==='red'?coalition(e)==='red':coalition(e)!=='red'));
  const count=p[side+'Count'];if(!count)return {list,shown:[],page:0,pages:0};
  const focused=list.find(e=>e.entityId===focusId),others=focused?list.filter(e=>e!==focused):list,quota=count-(focused?1:0);
  const pages=quota?Math.max(1,Math.ceil(others.length/quota)):1,page=p.rotate?Math.floor(now/(p.rotationSec*1000))%pages:0;
  return {list,shown:[...(focused?[focused]:[]),...others.slice(page*quota,(page+1)*quota)],page,pages};
}
export function anchorFactors(anchor){return [anchor.endsWith('left')?0:anchor.endsWith('right')?1:.5,anchor.startsWith('top')?0:anchor.startsWith('bottom')?1:.5];}
export function dockPosition(dock,width,height){const [ax,ay]=anchorFactors(dock.anchor);return {x:ax*(1920-width)+dock.x,y:ay*(1080-height)+dock.y};}
export function dockFromPosition(x,y,width,height,anchor='top-left'){const [ax,ay]=anchorFactors(anchor);return {anchor,x:Math.round(x-ax*(1920-width)),y:Math.round(y-ay*(1080-height))};}
export function snapPosition(x,y,width,height,others=[],margin=32){
  const guidesX=[margin,960,1920-margin,...others.flatMap(r=>[r.x,r.x+r.width/2,r.x+r.width])];
  const guidesY=[margin,540,1080-margin,...others.flatMap(r=>[r.y,r.y+r.height/2,r.y+r.height])];
  function snap(value,size,guides){let distance=13,best=value,line=null;for(const g of guides)for(const offset of [0,size/2,size]){const d=Math.abs(g-(value+offset));if(d<distance){distance=d;best=g-offset;line=g;}}return [best,line];}
  const [left,lineX]=snap(x,width,guidesX),[top,lineY]=snap(y,height,guidesY);
  return {x:Math.round(Math.max(0,Math.min(1920-width,left))),y:Math.round(Math.max(0,Math.min(1080-height,top))),lineX,lineY};
}

// Source-scoped compact identity/death ledger. It outlives the 200-event display
// window, but never guesses aircraft death from a missing snapshot or track end.
export function updateAircraftLedger(records,snapshot,events=[]){
  const map=new Map(records.map(r=>[r.entity.entityId,r]));
  if(snapshot){
    for(const r of map.values())r.present=false;
    for(const entity of snapshot.entities??[])if(entity.kind==='aircraft'){
      const old=map.get(entity.entityId);
      map.set(entity.entityId,{entity:{entityId:entity.entityId,kind:'aircraft',identity:entity.identity,occupancy:entity.occupancy,discoveredSimTime:entity.discoveredSimTime},present:true,death:old?.death??null,seenAt:snapshot.assembledSimTime??0,lastPlayerName:entity.occupancy?.isPlayer?entity.occupancy.playerName:old?.lastPlayerName,playerSeenAt:entity.occupancy?.isPlayer?(snapshot.assembledSimTime??0):old?.playerSeenAt});
    }
  }
  for(const event of events){
    const reason={crash:'crash',dead:'dead',kill:'kill'}[event.type];
    if(!reason)continue;const ref=event.type==='kill'?event.target:event.actor;
    if(ref?.kind!=='aircraft'||!ref.entityId)continue;
    let r=map.get(ref.entityId);
    if(!r){r={entity:{entityId:ref.entityId,kind:'aircraft',identity:{unitName:ref.name,typeName:ref.typeName,coalition:ref.coalition},occupancy:{isPlayer:ref.isPlayer,playerName:ref.playerName}},present:false,death:null,seenAt:event.simTime??0};map.set(ref.entityId,r);}
    if(!r.death||reason!=='disconnected'&&r.death.reason==='disconnected')r.death={reason,eventSeq:event.eventSeq,simTime:event.simTime};
  }
  return [...map.values()].sort((a,b)=>Number(b.present)-Number(a.present)||b.seenAt-a.seenAt).slice(0,512);
}
export function fixedAircraft(slot,latest){
  if(slot.binding==='player')return playerAircraft(slot.playerName,latest);
  if(!slot.unitName)return {entity:null,status:'empty'};
  const live=(latest.snapshot?.entities??[]).filter(e=>e.kind==='aircraft'&&e.identity?.unitName===slot.unitName);
  if(live.length>1)return {entity:null,status:'ambiguous'};
  const history=(latest.aircraftLedger??[]).filter(r=>r.entity.identity?.unitName===slot.unitName).sort((a,b)=>b.seenAt-a.seenAt);
  const entity=live[0]??history[0]?.entity,record=entity&&history.find(r=>r.entity.entityId===entity.entityId);
  if(!entity)return {entity:null,status:'waiting'};
  if(record?.death)return {entity,status:'dead',death:record.death};
  return {entity,status:live.length?'live':'missing'};
}
export function updatePresenceLedger(records,players){
  for(const presence of players?.records??[]){
    if(presence.connected!==false||(players.records??[]).some(r=>r.name===presence.name&&r.connected))continue;
    const last=records.filter(r=>(r.lastPlayerName??r.entity.occupancy?.playerName)===presence.name).sort((a,b)=>(b.playerSeenAt??b.seenAt)-(a.playerSeenAt??a.seenAt))[0];
    if(last&&!last.death)last.death={reason:'disconnected'};
  }
  return records;
}
export function playerAircraft(name,latest){
  const records=latest.source?.hookStatus?.players?.records??[];
  const online=records.filter(r=>r.name===name&&r.connected),past=records.filter(r=>r.name===name).sort((a,b)=>b.changed-a.changed);
  if(online.length>1)return {entity:null,status:'ambiguous'};
  const presence=online[0]??past[0];
  const live=(latest.snapshot?.entities??[]).filter(e=>e.kind==='aircraft'&&e.occupancy?.isPlayer===true&&e.occupancy.playerName===name);
  const history=(latest.aircraftLedger??[]).filter(r=>(r.lastPlayerName??r.entity.occupancy?.playerName)===name).sort((a,b)=>(b.playerSeenAt??b.seenAt)-(a.playerSeenAt??a.seenAt)||(b.entity.discoveredSimTime??0)-(a.entity.discoveredSimTime??0));
  const previous=history[0]?.entity;const fallback=previous?{...previous,occupancy:{isPlayer:true,playerName:name}}:{entityId:'player:'+name,kind:'aircraft',occupancy:{isPlayer:true,playerName:name},identity:{}};
  if(presence?.connected===false)return {entity:fallback,status:'dead',death:{reason:'disconnected'}};
  if(presence?.connected&&presence.slot==='')return history[0]?.death?{entity:fallback,status:'dead',death:history[0].death}:{entity:fallback,status:'waiting'};
  if(live.length>1)return {entity:fallback,status:'ambiguous'};
  const entity=live[0]??fallback,record=history.find(r=>r.entity.entityId===entity.entityId);
  if(record?.death&&!(record.death.reason==='disconnected'&&presence?.connected&&presence.slot&&live.length))return {entity,status:'dead',death:record.death};
  return {entity,status:live.length?'live':'waiting'};
}
export function teamSide(entity,config){
  if(config.competition?.mode==='teams')return config.nameplates.fixedSlots.find(s=>s.binding==='player'&&s.playerName===entity?.occupancy?.playerName)?.team??'neutral';
  return ['blue','red'].includes(coalition(entity))?coalition(entity):'neutral';
}
export function resolvedSlots(config,latest){
  return config.nameplates.fixedSlots.filter(s=>config.competition?.mode!=='teams'||s.binding==='player').map(slot=>{
    const result=fixedAircraft(slot,latest);
    const entity=result.entity??{entityId:'slot:'+slot.id,kind:'aircraft',identity:{unitName:slot.unitName},occupancy:{isPlayer:slot.binding==='player',playerName:slot.playerName}};
    return {...result,entity,slot,side:config.competition?.mode==='teams'?slot.team:teamSide(entity,config)};
  });
}
export function dockLabel(key){if(key.startsWith('plate:'))return key.slice(6);if(key.startsWith('slot:'))return '固定席位';return DOCK_PARTS[key]??key;}
