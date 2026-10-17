import {teamPalette,plateSettings,filterPlates,resolvedSlots,teamSide,defaultPlates} from './nameplates.mjs';
import {createDockEditor,applyDocks,restoreElementLayouts} from './dock-editor.mjs';
import { eventStream, escape as e, connectionLabel, lifecycleLabel } from './stream.mjs';
import { entityName, coalition, speed, altitude, fuel, weapons, playerLabel, missileTarget, launcher,
  aircraftForOutput, missilesForOutput, eventText, missionTime, selectedAircraft, incomingMissiles, missileLabels } from './telemetry.mjs';
import { drawMap } from './map.mjs';

const stage=document.querySelector('#stage'),id=location.pathname.split('/').pop(),key=location.hash.slice(1);
let previewConfig=null,editing=false,editingDetails=false;
const config=()=>previewConfig??latest.output.config;
let latest=null,localStatus='connecting',lastReceived=0,lastPage=-1,lastMarkup=[];
let threats=new Map();
const visibility=new WeakMap(),transitions=new WeakMap();
const reducedMotion=matchMedia('(prefers-reduced-motion: reduce)');
function showFeature(node,hidden){
  const previous=visibility.has(node)?visibility.get(node):node.hidden;
  visibility.set(node,hidden);
  if(previous===hidden)return;
  const old=transitions.get(node),opacity=old?getComputedStyle(node).opacity:hidden?'1':'0';
  old?.cancel();transitions.delete(node);
  if(reducedMotion.matches||!node.animate){node.hidden=hidden;return;}
  node.hidden=false;
  const animation=node.animate([{opacity,translate:hidden?'0 0':'0 10px'},
    {opacity:hidden?0:1,translate:hidden?'0 10px':'0 0'}],
    {duration:220,easing:'cubic-bezier(.22,.7,.25,1)',fill:'both'});
  transitions.set(node,animation);
  animation.onfinish=()=>{
    if(transitions.get(node)!==animation)return;
    node.hidden=hidden;animation.cancel();transitions.delete(node);
  };
}
// Preserve live elements, including canvases and in-flight feature animations.
// Telemetry refreshes update their contents without restarting the transition.
function patchElement(current,next){
  for(const attr of [...current.attributes])if(attr.name!=='hidden'&&!(current.nodeName==='CANVAS'&&['width','height'].includes(attr.name))&&!next.hasAttribute(attr.name))current.removeAttribute(attr.name);
  for(const attr of next.attributes)if(attr.name!=='hidden'&&current.getAttribute(attr.name)!==attr.value)current.setAttribute(attr.name,attr.value);
  if(current.hasAttribute('data-feature'))showFeature(current,next.hidden);
  else current.hidden=next.hidden;
  const old=[...current.childNodes],fresh=[...next.childNodes];
  for(let i=0;i<fresh.length;i++){
    const a=old[i],b=fresh[i];
    if(!a){current.append(b);continue;}
    if(a.nodeType!==b.nodeType||a.nodeName!==b.nodeName){a.replaceWith(b);continue;}
    if(a.nodeType===Node.ELEMENT_NODE)patchElement(a,b);
    else if(a.nodeValue!==b.nodeValue)a.nodeValue=b.nodeValue;
  }
  for(let i=fresh.length;i<old.length;i++)old[i].remove();
}
function updateComposition(composition,markup){
  const template=document.createElement('template');template.innerHTML=markup;
  const count=template.content.children.length;
  [...template.content.children].forEach((next,index)=>{
    const serialized=next.outerHTML,current=composition.children[index];
    if(!current)composition.append(next);
    else if(lastMarkup[index]!==serialized){
      patchElement(current,next);
    }
    lastMarkup[index]=serialized;
  });
  while(composition.children.length>count)composition.lastElementChild.remove();lastMarkup.length=count;
}
function fit(){const scale=Math.min(innerWidth/1920,innerHeight/1080);stage.style.transform=`scale(${scale})`;stage.style.left=`${(innerWidth-1920*scale)/2}px`;stage.style.top=`${(innerHeight-1080*scale)/2}px`;}
addEventListener('resize',fit);fit();
const empty=text=>`<div class="hud-empty">${e(text)}</div>`;
const enabled=key=>config().features[key]!==false;
const feature=(key,content,classes='')=>`<section class="${classes}" data-feature="${key}" ${enabled(key)?'':'hidden'}>${content}</section>`;
// Generic aircraft symbol, not a type-specific silhouette or a player portrait.
const jet=`<svg viewBox="0 0 64 64" aria-hidden="true"><path d="M32 3 36 25 57 39 57 44 36 37 36 49 44 56 44 60 32 56 20 60 20 56 28 49 28 37 7 44 7 39 28 25Z" fill="currentColor"/></svg>`;
const sideOf=plane=>teamSide(plane,config());
function fuelBar(plane,compact=false){
  const f=fuel(plane),width=f.value===null?0:Math.max(0,Math.min(100,f.value));
  return feature('fuel',`<div class="fuel-caption"><span>FUEL / 油量${f.stale?' · 旧值':''}</span><strong>${e(f.text)}<small> %</small></strong></div><div class="fuel-track ${f.value===null?'unknown':''}" role="meter" aria-label="油量（内部油箱基准）" ${f.value===null?'':`aria-valuenow="${width}"`} aria-valuemin="0" aria-valuemax="100" aria-valuetext="${e(f.text)}%"><i style="width:${width}%"></i></div>`,`fuel-block ${compact?'compact':''} ${f.value!==null&&f.value<20?'low-fuel':''} ${f.stale?'stale':''}`);
}
function metric(key,label,value){return feature(key,`<span>${label}${value.stale?' · 旧值':''}</span><strong>${e(value.text)} <small>${e(value.unit)}</small></strong>`,`pilot-metric ${value.stale?'stale':''}`);}
function loadout(plane,compact=false){
  const w=weapons(plane),count=compact?3:4,pages=Math.ceil(w.items.length/count),page=pages?Math.floor(Date.now()/12000)%pages:0;
  return feature('loadout',`${!compact?`<div class="loadout-heading">武器挂载${w.quality==='stale'?' · 旧值':''}${pages>1?` <span>${page+1}/${pages}</span>`:''}</div>`:''}<div class="weapon-chips">${!w.known?'<span class="weapon-unknown">挂载未知</span>':!w.items.length?'<span class="weapon-unknown">未报告挂载</span>':w.items.slice(page*count,(page+1)*count).map(item=>`<span class="weapon-chip" title="${e(item.name)}"><span>${e(item.name)}</span><b>×${e(item.count??'—')}</b></span>`).join('')}${compact&&pages>1?`<small class="weapon-page">${page+1}/${pages}</small>`:''}</div>`,`pilot-loadout ${compact?'compact':''} ${w.quality==='stale'?'stale':''}`);
}
function incomingHtml(id){
  const missiles=threats.get(id)??[];if(!missiles.length)return '';
  return feature('incoming',missiles.map(m=>{const label=missileLabels(m);return `<span class="incoming-missile" data-missile-id="${e(m.entityId)}" aria-label="来袭导弹"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 1 16 8 16 14 21 20 14 18 12 23 10 18 3 20 8 14 8 8Z" fill="currentColor"/></svg><span class="incoming-text">${feature('incomingName',e(label.name),'incoming-name')}${feature('incomingLauncher','发射：'+e(label.launcher),'incoming-launcher')}</span></span>`;}).join(''),'incoming-threats');
}
function pilotCard(plane,index,c,focusId,resolved=null){
  const settings=plateSettings(c,plane.identity?.unitName,plane.occupancy?.playerName),f=settings.fields,side=resolved?.side??sideOf(plane);
  const status=resolved?.status??'live',slot=resolved?.slot,dead=status==='dead',live=status==='live';
  const key=slot?'slot:'+slot.id:'plate:'+plane.identity?.unitName;
  const label=dead?'✕ 飞机死亡 · '+({disconnected:'选手断线',crash:'坠毁',kill:'被击毁',dead:'死亡'}[resolved.death?.reason]??'死亡'):({ambiguous:'同名对象冲突'})[status];
  return `<article class="pilot-card ${side} ${plane.entityId===focusId?'observed':''} ${dead?'is-dead':''}" data-entity-id="${e(plane.entityId)}" data-dock-key="${e(key)}" data-unit-name="${e(plane.identity?.unitName??'')}" style="width:${settings.width}px;zoom:${settings.scale/100}">${slot?`<div class="seat-label">${e(slot.label||slot.playerName||slot.unitName)}</div>`:''}<div class="pilot-card-top">${f.slot?`<span class="pilot-slot">${String(index+1).padStart(2,'0')}</span>`:''}${f.name?`<strong class="pilot-name" title="${e(entityName(plane))}">${e(entityName(plane))}</strong>`:''}${f.occupancy?`<span class="pilot-kind">${e(playerLabel(plane))}</span>`:''}</div>${f.unitName?`<div class="plate-unit">${e(plane.identity?.unitName??'—')}</div>`:''}<div class="pilot-airframe">${f.type?`<span>${e(plane.identity?.typeName??'机型未知')}</span>`:''}${f.coalition?`<span>${e(c.competition.mode==='teams'?c.match[side+'Name']??'未分队':({blue:'蓝方',red:'红方'})[side]??'未知阵营')}</span>`:''}</div>${label?`<div class="death-mark">${dead?`<span class="dead-plane">${jet}</span>`:''}${e(label)}</div>`:''}${live&&f.fuel?fuelBar(plane,true):''}${live?`<div class="pilot-flight">${f.speed?metric('speed','速度',speed(plane,c.units)):''}${f.altitude?metric('altitude','高度',altitude(plane,c.units)):''}</div>${f.loadout?loadout(plane,true):''}`:''}${live?incomingHtml(plane.entityId):''}</article>`;
}
function rosterSide(planes,side,c,focusId){
  const p=c.nameplates,slots=resolvedSlots(c,latest),boundUnits=new Set(slots.filter(s=>s.slot.binding!=='player').map(s=>s.slot.unitName)),boundPlayers=new Set(slots.filter(s=>s.slot.binding==='player').map(s=>s.slot.playerName));
  const pools=slots.filter(s=>!s.slot.dock&&(side==='red'?s.side==='red':s.side!=='red')&&aircraftForOutput({entities:[s.entity]},c).length&&plateSettings(c,s.entity.identity?.unitName,s.entity.occupancy?.playerName).visible&&(s.status!=='live'||filterPlates([s.entity],c).length));
  const regular=c.competition.mode==='teams'?[]:filterPlates(planes,c).filter(p=>!boundUnits.has(p.identity?.unitName)&&!boundPlayers.has(p.occupancy?.playerName)&&!plateSettings(c,p.identity?.unitName,p.occupancy?.playerName).dock&&(side==='red'?sideOf(p)==='red':sideOf(p)!=='red')).map(entity=>({entity,status:'live',side:sideOf(entity)}));
  const list=[...pools,...regular],count=p[side+'Count'],focus=list.find(r=>r.entity.entityId===focusId),others=focus?list.filter(r=>r!==focus):list,quota=Math.max(0,count-(focus?1:0));
  const pages=count?quota?Math.max(1,Math.ceil(others.length/quota)):1:0,page=p.rotate&&pages?Math.floor(Date.now()/(p.rotationSec*1000))%pages:0;
  const shown=count?[...(focus?[focus]:[]),...others.slice(page*quota,(page+1)*quota)]:[];
  const blanks=p.fixedCount?Array.from({length:Math.max(0,count-shown.length)},()=>blankCard(c,side)).join(''):'';
  return feature('roster',`<div class="roster-heading"><strong>${e(c.match[side+'Name'])}</strong><span>${list.length} 席</span></div><div class="roster-cards">${shown.map((r,i)=>pilotCard(r.entity,i,c,focusId,r)).join('')}${blanks}</div><div class="roster-pagination"><span>${pages>1?`阵容轮换 · 每 ${p.rotationSec} 秒`:'当前阵容'}</span><b>${pages?page+1:0} / ${pages}</b></div>${p.fixedCount&&count?`<div class="plate-measure" aria-hidden="true">${blankCard(c,side)}</div>`:''}`,`roster-panel roster-${side} ${side} ${p.fixedCount?'fixed-count':''}`);
}
function blankCard(c,side){
  const entity={entityId:'',kind:'aircraft',identity:{coalition:side},occupancy:{isPlayer:true},fuel:{ratioRaw:1},motion:{speedMps:0,position:{y:0}},armament:{items:Array.from({length:3},()=>({displayName:'—',count:0}))}},pooled=c.nameplates.fixedSlots.some(s=>s.binding==='player');
  return pilotCard(entity,0,c,null,{status:'live',side,slot:pooled?{id:'',label:'—'}:null}).replace(/ data-(?:entity-id|dock-key|unit-name)="[^"]*"/gu,'').replace('class="pilot-card ', 'aria-hidden="true" class="pilot-card plate-placeholder ');
}
function detachedCards(planes,c,focusId){
  const slots=resolvedSlots(c,latest),fixed=slots.filter(r=>r.slot.dock);
  const names=new Set(slots.map(s=>s.entity.identity?.unitName));
  const loose=c.competition.mode==='teams'?[]:filterPlates(planes,c).filter(p=>!names.has(p.identity?.unitName)&&plateSettings(c,p.identity?.unitName,p.occupancy?.playerName).dock);
  return feature('roster',fixed.filter(r=>plateSettings(c,r.entity.identity?.unitName,r.entity.occupancy?.playerName).visible).map((r,i)=>pilotCard(r.entity,i,c,focusId,r)).join('')+loose.map((p,i)=>pilotCard(p,i,c,focusId)).join(''),'detached-cards');
}
function teamLogo(side,c,floating=false){if(Boolean(c.docks[side+'Logo'])!==floating)return '';return feature('teamLogos',c.competition[side+'Logo']?`<img class="team-logo" src="${e(c.competition[side+'Logo'])}" alt="${e(c.match[side+'Name'])} 队标">`:'',floating?'team-logo-box floating-brand-'+side:'team-logo-box');}
function missileList(missiles,config){
  if(config.missileId)missiles=[...missiles].sort((a,b)=>Number(b.entityId===config.missileId)-Number(a.entityId===config.missileId));
  if(!missiles.length)return empty('当前没有在跟踪导弹');
  const pages=Math.ceil(missiles.length/2),page=config.missileId?0:Math.floor(Date.now()/12000)%pages;
  return `<div class="missile-heading">导弹追踪 <b>${missiles.length}</b>${pages>1?` <span>${page+1}/${pages}</span>`:''}</div><div class="missile-list">${missiles.slice(page*2,(page+1)*2).map(m=>{
    const from=launcher(m),to=missileTarget(m),v=speed(m,config.units);
    return `<div class="missile-item"><div><strong>${e(m.identity?.typeName??m.typeName??entityName(m))}</strong>${enabled('speed')?`<small>${e(v.text)} ${v.unit}${v.stale?' · 旧值':''}</small>`:''}</div><div class="missile-path"><span>${e(from.object?entityName(from.object):'未知发射者')}</span><b>→</b><span>${e(to.object?entityName(to.object):to.label)}</span></div><div class="missile-quality">${e(from.label)} · ${e(to.label)}${to.previous?` · 上次：${e(entityName(to.previous))}`:''}${from.alternate?` · 另一来源：${e(entityName(from.alternate))}`:''}</div></div>`;
  }).join('')}</div>`;
}
function eventsHtml(){
  const c=config();
  const list=latest.events.filter(event=>!event.historical&&c.filters.eventTypes.includes(event.type)&&Date.now()-event.receivedAt<c.eventDurationSec*1000).slice(-c.eventCount).reverse();
  // No empty event panel over the game. History belongs in the control page.
  return list.map(event=>`<div class="broadcast-event"><time>${missionTime(event.simTime)}</time><span>${e(eventText(event))}</span></div>`).join('');
}
function statusHtml(){
  const source=latest.source,stale=localStatus!=='connected';
  const title=localStatus==='unauthorized'?'输出访问已失效 · 请重新登录':stale?'本地连接中断 · 显示最后收到的数据':latest.connection!=='connected'?connectionLabel(latest.connection):lifecycleLabel(source);
  const age=Math.max(0,(Date.now()-(latest.sourcesReceivedAt??lastReceived))/1000);
  let facts=source?.lifecycle==='ended'?'历史快照':source?.snapshotFresh&&latest.connection==='connected'&&age<3?'快照新鲜':'快照未更新';
  if(source?.snapshotAgeSec!=null)facts+=` · ${Math.floor(source.snapshotAgeSec+age)} 秒前`;
  const quality=[];if(source?.captureIntegrity==='incomplete')quality.push('采集存在缺失');
  if(source?.historyRetained===false)quality.push('部分历史已释放');if(latest.resync)quality.push('事件基线已重建');
  if(latest.snapshot?.coverage?.status==='partial'||latest.snapshot?.coverage?.excludedEntityCount>0)quality.push('对象覆盖不完整');
  return `<span>● ${e(title)}</span><span>${e(quality.join(' · '))}</span><span>${e(facts)} · 1 Hz</span>`;
}
function render(){
  threats=incomingMissiles(latest,localStatus);
  const original=config(),c=original.competition.mode==='teams'?{...original,filters:{...original.filters,coalition:'all'}}:original,planes=aircraftForOutput(latest.snapshot,c),plane=selectedAircraft(latest,c,localStatus);
  const missiles=missilesForOutput(latest.snapshot,{...c,aircraftId:plane?.entityId??null});
  for(const side of ['blue','red']){const palette=teamPalette(c,side);stage.style.setProperty('--'+side+'-color',palette.color);stage.style.setProperty('--'+side+'-background',palette.background);}
  stage.className=`stage ${c.layout}${c.appearance.transparent?' transparent':''}`;
  stage.style.setProperty('--safe',`${Math.min(32,c.appearance.safeMargin)}px`);
  stage.style.setProperty('--composition-scale',String(Math.min(1,(1080-2*c.appearance.safeMargin)/1016)));
  document.body.style.background=c.appearance.transparent?'transparent':'#080d16';document.title=`${c.name} · DCS 输出`;
  let composition=stage.querySelector('.hud-composition');
  if(!composition){stage.innerHTML='<div class="hud-composition"></div>';composition=stage.firstElementChild;}
  restoreElementLayouts();
  updateComposition(composition,`${feature('match',`<div class="match-team blue">${teamLogo('blue',c)}<span>${e(c.match.blueName)}</span><b>${c.match.blueScore}</b></div><div class="match-center"><div>${e(c.match.round)}</div><time>${missionTime(latest.snapshot?.assembledSimTime)}</time><h1>${e(c.match.title)}</h1></div><div class="match-team red"><b>${c.match.redScore}</b><span>${e(c.match.redName)}</span>${teamLogo('red',c)}</div>`,'match-header')}${feature('map','<div class="map-caption">战术小地图 <span>LOCAL X/Z</span></div><div class="map-surface"><canvas id="map"></canvas></div>','map-panel')}${rosterSide(planes,'blue',c,plane?.entityId)}${rosterSide(planes,'red',c,plane?.entityId)}${feature('missiles',missileList(missiles,c),'missiles-panel')}${feature('events',eventsHtml(),'events-panel')}${feature('status',statusHtml(),'output-status')}${detachedCards(planes,c,plane?.entityId)}${teamLogo('blue',c,true)}${teamLogo('red',c,true)}`);
  applyDocks(composition,c);editor.refresh(composition,c,editing,editingDetails);
  if(c.features.map)drawMap(document.querySelector('#map'),c.competition.mode==='teams'?planes.map(p=>({...p,identity:{...p.identity,coalition:teamSide(p,c)}})):planes,missiles,{...c,aircraftId:plane?.entityId??null},!latest.source?.snapshotFresh);
  lastPage=Math.floor(Date.now()/12000);
}
const editor=createDockEditor(stage,()=>config(),next=>{previewConfig=next;render();parent.postMessage({type:'dcs-dock-change',nameplates:next.nameplates,docks:next.docks,elementLayouts:next.elementLayouts},location.origin);});
addEventListener('keydown',ev=>{if(ev.key!=='Escape'||!editing)return;ev.preventDefault();if(!editor.cancelGesture())parent.postMessage({type:'dcs-cancel-preview'},location.origin);});
addEventListener('message',ev=>{
  if(parent===window||new URLSearchParams(location.search).get('editor')!=='1'||ev.origin!==location.origin||ev.source!==parent||ev.data?.type!=='dcs-preview')return;
  previewConfig=ev.data.config;editing=ev.data.editing===true;editingDetails=ev.data.editingDetails===true;if(latest)render();
});
setInterval(()=>{if(latest)render();},500);
if(/^[a-f0-9]{64}$/u.test(key))eventStream(`/api/output/${id}/stream`,{token:key,onState:value=>{latest=value;lastReceived=Date.now();render();},onStatus:status=>{
  localStatus=status;
  if(latest && status!=='unauthorized')render();
  if(status==='unauthorized') {latest=null;stage.innerHTML='<div class="output-wait"><h1>输出访问已失效</h1><p>请在控制台登录，并重新复制输出地址</p></div>';}
}});
