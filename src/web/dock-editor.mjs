import {DOCK_PARTS,dockPosition,snapPosition,dockFromPosition,newOverride,plateSettings} from './nameplates.mjs';
const selectors={blueLogo:'.floating-brand-blue, .match-team.blue .team-logo-box',redLogo:'.floating-brand-red, .match-team.red .team-logo-box',match:'.match-header',map:'.map-panel',blue:'.roster-blue',red:'.roster-red',missiles:'.missiles-panel',events:'.events-panel',status:'.output-status'};

// Restore only layout-owned styles before the telemetry DOM is patched. This
// prevents accumulating zoom or restoring a stale inline fuel/plate value.
const layoutStyles=new Map();
function layoutStyle(node,key,value){
  let saved=layoutStyles.get(node);if(!saved){saved=new Map();layoutStyles.set(node,saved);}
  if(!saved.has(key))saved.set(key,{value:node.style.getPropertyValue(key),priority:node.style.getPropertyPriority(key)});
  node.style.setProperty(key,value);
}
export function restoreElementLayouts(){
  for(const [node,styles] of layoutStyles){for(const [key,old] of styles){if(old.value)node.style.setProperty(key,old.value,old.priority);else node.style.removeProperty(key);}node.removeAttribute('data-adaptive-size');}
  layoutStyles.clear();
}
function resizeElement(node,l){
  if(l.scaleX===1&&l.scaleY===1)return;
  const width=node.offsetWidth,height=node.offsetHeight;if(!width||!height)return;
  const zoom=Number(getComputedStyle(node).zoom)||1,uniform=Math.min(l.scaleX,l.scaleY);
  // CSS zoom participates in layout and rerasterizes text/SVG. Different axes
  // change the available content box rather than stretching rendered pixels.
  for(const [key,value] of Object.entries({'box-sizing':'border-box','min-width':'0','min-height':'0','max-width':'none','max-height':'none',
    width:width*l.scaleX/uniform+'px',height:height*l.scaleY/uniform+'px',zoom:String(zoom*uniform),'flex-shrink':'0'}))layoutStyle(node,key,value);
  if(getComputedStyle(node).display==='inline')layoutStyle(node,'display','inline-block');
  node.setAttribute('data-adaptive-size','');
  if(node.matches('.roster-panel')){const grid=node.querySelector('.roster-cards');if(grid)layoutStyle(grid,'grid-template-rows',grid.style.gridTemplateRows.replaceAll('max-content','minmax(0,1fr)'));}
}

function bounds(node,composition){const r=node.getBoundingClientRect(),c=composition.getBoundingClientRect(),scale=c.width/1920;return {x:(r.left-c.left)/scale,y:(r.top-c.top)/scale,width:r.width/scale,height:r.height/scale};}
function position(node,dock,composition){
  if(!dock){for(const property of ['position','left','top','right','bottom','transform'])node.style.removeProperty(property);return;}
  const rect=bounds(node,composition),p=dockPosition(dock,rect.width,rect.height),zoom=Number(node.style.zoom)||1;
  Object.assign(node.style,{position:'absolute',left:p.x/zoom+'px',top:p.y/zoom+'px',right:'auto',bottom:'auto',transform:'none'});
}
export function applyDocks(composition,c){
  restoreElementLayouts();

  // Multiple columns preserve every configured card when tall/large cards exceed the edge area.
  for(const group of composition.querySelectorAll('.roster-cards')){
    const cards=[...group.children].filter(n=>n.matches('.pilot-card'));
    if(group.closest('.fixed-count')){
      const measure=group.parentElement.querySelector('.plate-measure .pilot-card'),row=measure?bounds(measure,composition).height:128;
      for(const card of cards)card.style.minHeight=row/(Number(card.style.zoom)||1)+'px';
    }

    if(cards.length){const max=Math.max(...cards.map(n=>bounds(n,composition).height));group.style.gridTemplateRows=`repeat(${Math.max(1,Math.min(cards.length,Math.floor(660/(max+5))))}, max-content)`;}
  }
  for(const [key,selector] of Object.entries(selectors)){const n=composition.querySelector(selector);if(n)n.dataset.dockKey=key;}
  // Establish shrink-to-fit boxes (especially newly detached logos) before
  // measuring their natural size, then resolve anchors using resized bounds.
  const place=()=>{
    for(const [key,selector] of Object.entries(selectors)){const n=composition.querySelector(selector);if(n)position(n,c.docks[key],composition);}
    for(const n of composition.querySelectorAll('.detached-cards>[data-dock-key]')){
      const key=n.dataset.dockKey,dock=key.startsWith('slot:')?c.nameplates.fixedSlots.find(s=>s.id===key.slice(5))?.dock:plateSettings(c,n.dataset.unitName).dock;
      position(n,dock,composition);
    }
  };
  place();applyElements(composition,c);place();
}
const parts={
  match:{'blue-name':['.match-team.blue>span','左队队名'],'red-name':['.match-team.red>span','右队队名'],'blue-score':['.match-team.blue>b','左队比分'],'red-score':['.match-team.red>b','右队比分'],round:['.match-center>div','轮次'],clock:['.match-center>time','计时'],title:['.match-center>h1','赛事名称']},
  map:{caption:['.map-caption','地图标题'],surface:['.map-surface','地图内容']},
};
const cardParts={incoming:['.incoming-threats','来袭导弹'],name:['.pilot-name','选手名称'],slot:['.pilot-slot','序号'],kind:['.pilot-kind','身份'],unit:['.plate-unit','单位名称'],type:['.pilot-airframe','机型与队伍'],label:['.seat-label','席位标签'],fuel:['.fuel-block','油量'],speed:['[data-feature="speed"]','速度'],altitude:['[data-feature="altitude"]','高度'],loadout:['.pilot-loadout','挂载'],death:['.death-mark','死亡标识']};
function registerElements(comp){
  for(const node of comp.querySelectorAll('[data-element-key]')){delete node.dataset.elementKey;delete node.dataset.elementLabel;}
  for(const node of comp.querySelectorAll('[data-dock-key]')){
    const key=node.dataset.dockKey;node.dataset.elementKey=key;node.dataset.elementLabel=DOCK_PARTS[key]??(key.startsWith('slot:')?'固定席位 · ':'标牌 · ')+(node.querySelector('.pilot-name')?.textContent??node.dataset.unitName??'');
    const definitions=node.matches('.pilot-card')?cardParts:parts[key]??{};
    for(const [part,[selector,label]] of Object.entries(definitions)){const child=node.querySelector(selector);if(child){child.dataset.elementKey=key+'/'+part;child.dataset.elementLabel=label;}}
    if(['blue','red'].includes(key)){
      for(const [selector,part,label] of [['.roster-heading','heading','队伍标题'],['.roster-heading>strong','team-name','队名'],['.roster-heading>span','team-count','人数'],['.roster-pagination','pagination','阵容分页']]){const child=node.querySelector(selector);if(child){child.dataset.elementKey=key+'/'+part;child.dataset.elementLabel=label;}}
    }
    if(node.matches('.pilot-card')){
      for(const [selector,part,label] of [['.fuel-caption>span','fuel-label','油量标签'],['.fuel-caption>strong','fuel-value','油量数值'],['.fuel-track','fuel-bar','油量条'],['[data-feature="speed"]>span','speed-label','速度标签'],['[data-feature="speed"]>strong','speed-value','速度数值'],['[data-feature="altitude"]>span','altitude-label','高度标签'],['[data-feature="altitude"]>strong','altitude-value','高度数值']]){
        const child=node.querySelector(selector);if(child){child.dataset.elementKey=key+'/'+part;child.dataset.elementLabel=label;}
      }
      [...node.querySelectorAll('.weapon-chip')].forEach((child,i)=>{child.dataset.elementKey=key+'/weapon-'+i;child.dataset.elementLabel='武器 '+(i+1);});
    }
    if(['events','missiles','status'].includes(key)){
      const selector=key==='events'?'.broadcast-event':key==='missiles'?'.missile-heading,.missile-item':':scope>span';
      [...node.querySelectorAll(selector)].forEach((child,i)=>{child.dataset.elementKey=key+'/item-'+i;child.dataset.elementLabel=(DOCK_PARTS[key]??key)+' '+(i+1);});
    }
  }
}
function applyElements(comp,c){
  registerElements(comp);
  for(const node of comp.querySelectorAll('[data-element-key]')){
    const key=node.dataset.elementKey,l=c.elementLayouts?.[key];if(!l)continue;
    resizeElement(node,l);
    layoutStyle(node,'translate',`${l.dx}px ${l.dy}px`);
  }
}
const clamp=(n,min,max)=>Math.max(min,Math.min(max,n));
export function gestureRect(start,dx,dy,resize,shift,others=[]){
  if(!resize){const x=start.x+dx,y=start.y+dy;return {...start,...(shift?{x:Math.round(x),y:Math.round(y)}:snapPosition(x,y,start.width,start.height,others))};}
  let right=start.x+start.width+dx,bottom=start.y+start.height+dy;
  if(!shift){const snap=(v,guides)=>guides.reduce((best,n)=>Math.abs(n-v)<13&&Math.abs(n-v)<Math.abs(best-v)?n:best,v+13);const x=snap(right,[32,960,1888,...others.flatMap(r=>[r.x,r.x+r.width/2,r.x+r.width])]),y=snap(bottom,[32,540,1048,...others.flatMap(r=>[r.y,r.y+r.height/2,r.y+r.height])]);if(Math.abs(x-right)<13)right=x;if(Math.abs(y-bottom)<13)bottom=y;}
  return {...start,width:Math.max(8,Math.round(right-start.x)),height:Math.max(8,Math.round(bottom-start.y))};
}
export function createDockEditor(stage,getConfig,commit){
  let overlay=null,composition=null,boxes=[],drag=null,details=false,selectedKey='';
  function refresh(comp,c,enabled,detailMode=false){
    composition=comp;details=detailMode;if(drag||overlay?.contains(document.activeElement)&&document.activeElement.matches('.element-picker'))return;
    overlay?.remove();overlay=null;if(!enabled)return;
    overlay=document.createElement('div');overlay.className='dock-overlay';stage.append(overlay);
    const note=document.createElement('div');note.className='dock-note';note.textContent=(details?'内部元素':'整体组件')+' · 标签移动 / 角点缩放 · Shift 取消吸附 · Esc 取消';overlay.append(note);
    boxes=[];
    for(const node of comp.querySelectorAll('[data-element-key]')){
      if(node.closest('[hidden],.plate-measure,.plate-placeholder'))continue;const isRoot=node.hasAttribute('data-dock-key');if(details===isRoot)continue;
      const rect=bounds(node,comp);if(rect.width<1||rect.height<1)continue;
      const key=node.dataset.elementKey;boxes.push({key,node,...rect});
    }
    if(details){
      if(!boxes.some(b=>b.key===selectedKey))selectedKey=boxes[0]?.key??'';
      const picker=document.createElement('select');picker.className='element-picker';picker.setAttribute('aria-label','选择内部元素');
      for(const b of boxes){const parent=b.node.parentElement.closest('[data-dock-key]');const label=(parent?.dataset.elementLabel??'')+' / '+b.node.dataset.elementLabel;picker.add(new Option(label,b.key,false,b.key===selectedKey));}
      picker.addEventListener('change',()=>{selectedKey=picker.value;picker.blur();refresh(comp,getConfig(),true,true);});overlay.append(picker);
    }
    for(const {key,node,...rect} of boxes){
      if(details&&key!==selectedKey)continue;
      const button=document.createElement('button');button.type='button';button.className='dock-handle';button.dataset.key=key;button.textContent=node.dataset.elementLabel;
      Object.assign(button.style,{left:rect.x+'px',top:rect.y+'px',maxWidth:Math.max(70,rect.width)+'px'});overlay.append(button);
      const corner=document.createElement('button');corner.type='button';corner.className='dock-resize';corner.dataset.key=key;corner.setAttribute('aria-label','缩放 '+node.dataset.elementLabel);
      Object.assign(corner.style,{left:rect.x+rect.width-8+'px',top:rect.y+rect.height-8+'px'});overlay.append(corner);
    }
  }
  stage.addEventListener('pointerdown',ev=>{
    const h=ev.target.closest('.dock-handle,.dock-resize');if(!h)return;const item=boxes.find(b=>b.key===h.dataset.key);if(!item)return;
    const scale=composition.getBoundingClientRect().width/1920,l=getConfig().elementLayouts?.[item.key]??{dx:0,dy:0,scaleX:1,scaleY:1};
    drag={...item,startX:ev.clientX,startY:ev.clientY,lastX:ev.clientX,lastY:ev.clientY,scale,at:{...item},layout:l,resize:h.classList.contains('dock-resize'),shift:ev.shiftKey,
      pointerId:ev.pointerId,factorX:item.width/Math.max(1,item.node.offsetWidth),factorY:item.height/Math.max(1,item.node.offsetHeight)};
    const ghost=document.createElement('div');ghost.className='dock-ghost';Object.assign(ghost.style,{left:item.x+'px',top:item.y+'px',width:item.width+'px',height:item.height+'px'});overlay.append(ghost);drag.ghost=ghost;
    stage.setPointerCapture(ev.pointerId);h.focus({preventScroll:true});ev.preventDefault();
  });
  function move(x,y,shift){
    if(!drag)return;drag.lastX=x;drag.lastY=y;drag.shift=shift;
    const p=gestureRect(drag,(x-drag.startX)/drag.scale,(y-drag.startY)/drag.scale,drag.resize,shift,boxes.filter(b=>b.key!==drag.key));
    if(drag.resize){p.width=clamp(p.width,drag.width*.1/drag.layout.scaleX,drag.width*8/drag.layout.scaleX);p.height=clamp(p.height,drag.height*.1/drag.layout.scaleY,drag.height*8/drag.layout.scaleY);}
    drag.at=p;Object.assign(drag.ghost.style,{left:p.x+'px',top:p.y+'px',width:p.width+'px',height:p.height+'px'});
  }
  stage.addEventListener('pointermove',ev=>move(ev.clientX,ev.clientY,ev.shiftKey));
  for(const type of ['keydown','keyup'])addEventListener(type,ev=>{if(ev.key==='Shift'&&drag)move(drag.lastX,drag.lastY,type==='keydown');});
  function setDock(c,d,dock){
    if(d.key.startsWith('slot:')){const slot=c.nameplates.fixedSlots.find(s=>s.id===d.key.slice(5));if(slot)slot.dock=dock;}
    else if(d.key.startsWith('plate:')){let o=c.nameplates.overrides.find(o=>o.unitName===d.key.slice(6));if(!o){o=newOverride(d.key.slice(6));c.nameplates.overrides.push(o);}o.dock=dock;}
    else c.docks[d.key]=dock;
  }
  function finish(ev,cancel=false){
    if(!drag)return;move(ev.clientX,ev.clientY,ev.shiftKey);const d=drag;drag=null;if(stage.hasPointerCapture(ev.pointerId))stage.releasePointerCapture(ev.pointerId);
    if(cancel){refresh(composition,getConfig(),true,details);return;}
    const c=structuredClone(getConfig());c.elementLayouts??={};const root=d.node.hasAttribute('data-dock-key');
    if(d.resize){
      c.elementLayouts[d.key]={...d.layout,scaleX:Number((d.layout.scaleX*d.at.width/d.width).toFixed(5)),scaleY:Number((d.layout.scaleY*d.at.height/d.height).toFixed(5))};
      if(root)setDock(c,d,dockFromPosition(d.x,d.y,d.at.width,d.at.height));
    }else if(!root){c.elementLayouts[d.key]={...d.layout,dx:Math.round(clamp(d.layout.dx+(d.at.x-d.x)/d.factorX,-3840,3840)),dy:Math.round(clamp(d.layout.dy+(d.at.y-d.y)/d.factorY,-2160,2160))};}
    else{
      const dest=!d.shift&&d.key.startsWith('plate:')&&boxes.find(b=>b.key.startsWith('slot:')&&d.at.x+d.width/2>=b.x&&d.at.x+d.width/2<=b.x+b.width&&d.at.y+d.height/2>=b.y&&d.at.y+d.height/2<=b.y+b.height);
      if(dest){const slot=c.nameplates.fixedSlots.find(s=>s.id===dest.key.slice(5));if(slot?.binding==='unit'&&!c.nameplates.fixedSlots.some(s=>s!==slot&&s.binding==='unit'&&s.unitName===d.node.dataset.unitName))slot.unitName=d.node.dataset.unitName;}
      else setDock(c,d,dockFromPosition(clamp(d.at.x,-1920,1920),clamp(d.at.y,-1080,1080),d.at.width,d.at.height));
    }
    commit(c);
  }
  stage.addEventListener('pointerup',ev=>finish(ev));stage.addEventListener('pointercancel',ev=>finish(ev,true));
  function cancelGesture(){if(!drag)return false;const d=drag;drag=null;if(stage.hasPointerCapture(d.pointerId))stage.releasePointerCapture(d.pointerId);refresh(composition,getConfig(),true,details);return true;}
  return {refresh,cancelGesture};
}
