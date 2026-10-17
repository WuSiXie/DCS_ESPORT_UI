import {teamPalette} from './nameplates.mjs';
import { coalition, entityName, finite, missileTarget, missileLabels } from './telemetry.mjs';

export function drawMap(canvas, aircraft, missiles, config, stale = false) {
  const width=canvas.clientWidth,height=canvas.clientHeight;if(!width||!height)return;
  const rect=canvas.getBoundingClientRect?.()??{width,height},dpr=globalThis.devicePixelRatio||1;
  const density=Math.max(1,dpr*Math.max(rect.width/width,rect.height/height));
  const ratio=Math.min(density,8192/Math.max(width,height),Math.sqrt(16777216/(width*height)));
  canvas.width=Math.max(1,Math.round(width*ratio));canvas.height=Math.max(1,Math.round(height*ratio));
  const ctx=canvas.getContext('2d');ctx.scale(canvas.width/width,canvas.height/height);
  const valid=entity=>finite(entity.motion?.position?.x)&&finite(entity.motion?.position?.z);
  const points=[...aircraft,...missiles].filter(valid),padding=Math.min(65,width*.2,height*.2);
  ctx.strokeStyle='#28415666';ctx.lineWidth=1;
  for(let x=width/2%50;x<width;x+=50){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,height);ctx.stroke();}
  for(let y=height/2%50;y<height;y+=50){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(width,y);ctx.stroke();}
  const radius=Math.min(width,height)*.35;
  for(const r of [radius,radius/2]){ctx.beginPath();ctx.arc(width/2,height/2,r,0,Math.PI*2);ctx.stroke();}
  ctx.font='11px Segoe UI';ctx.fillStyle='#6d89a2';ctx.textAlign='center';ctx.fillText('N',width/2,24);
  ctx.textAlign='right';ctx.fillText('E',width-18,height/2);
  if(!points.length){ctx.textAlign='center';ctx.font='18px Microsoft YaHei';ctx.fillStyle='#8194ac';ctx.fillText('等待可用的位置数据',width/2,height/2);return;}
  const xs=points.map(e=>e.motion.position.z),ys=points.map(e=>e.motion.position.x);
  const minX=Math.min(...xs),maxX=Math.max(...xs),minY=Math.min(...ys),maxY=Math.max(...ys);
  const scale=Math.min((width-padding*2)/Math.max(10000,maxX-minX),(height-padding*2)/Math.max(10000,maxY-minY));
  const centerX=(minX+maxX)/2,centerY=(minY+maxY)/2;
  const project=e=>({x:width/2+(e.motion.position.z-centerX)*scale,y:height/2-(e.motion.position.x-centerY)*scale});
  const indexed=new Map(points.map(e=>[e.entityId,e]));
  if(config.appearance.targetLines)for(const missile of missiles.filter(valid)) {
    const observed=missileTarget(missile),target=observed.known?indexed.get(observed.object?.entityId):null;
    if(!target)continue;const a=project(missile),b=project(target);
    ctx.beginPath();ctx.setLineDash([5,7]);ctx.strokeStyle='#f3c77466';ctx.moveTo(a.x,a.y);ctx.lineTo(b.x,b.y);ctx.stroke();ctx.setLineDash([]);
  }
  const labelBoxes=[];
  // Selected objects get label placement first; crowded formations do not become a wall of text.
  points.sort((a,b)=>Number(b.entityId===config.aircraftId||b.entityId===config.missileId)-Number(a.entityId===config.aircraftId||a.entityId===config.missileId));
  for(const e of points) {
    const p=project(e),missile=e.kind==='missile',selected=e.entityId===(missile?config.missileId:config.aircraftId);
    const color=missile?'#f3c774':config.competition?.mode==='teams'?teamPalette(config,coalition(e)).color:coalition(e)==='blue'?'#48b7ff':coalition(e)==='red'?'#ff6079':'#b5c1d0';
    ctx.globalAlpha=stale||e.motion.status==='stale'?.55:1;
    if(selected){ctx.strokeStyle='#6ce7cb';ctx.lineWidth=1.5;ctx.beginPath();ctx.arc(p.x,p.y,20,0,Math.PI*2);ctx.stroke();}
    ctx.save();ctx.translate(p.x,p.y);const f=e.motion.basis?.forward??e.motion.velocity;
    if(finite(f?.x)&&finite(f?.z))ctx.rotate(Math.atan2(f.z,f.x));
    ctx.fillStyle=color;ctx.beginPath();
    if(missile){ctx.moveTo(0,-6);ctx.lineTo(3,5);ctx.lineTo(-3,5);}else{ctx.moveTo(0,-11);ctx.lineTo(8,9);ctx.lineTo(0,5);ctx.lineTo(-8,9);}
    ctx.closePath();ctx.fill();ctx.restore();
    const info=missile?missileLabels(e):null;
    const lines=missile?[...(config.features.mapMissileName?[info.name]:[]),...(config.features.mapMissileLauncher?['发射：'+info.launcher]:[])]:config.appearance.labels?[entityName(e)]:[];
    if(lines.length) {
      ctx.font=`${selected?'600 ':''}11px Microsoft YaHei`;ctx.textAlign='left';ctx.fillStyle=color;
      const text=lines.map(line=>line.length>24?line.slice(0,23)+'…':line),labelWidth=Math.max(...text.map(line=>ctx.measureText(line).width));
      const x=Math.max(12,Math.min(p.x+14,width-labelWidth-12));
      for(const shift of [0,-15,15,-30,30,-60,60]) {
        const y=p.y-6+shift,box={left:x-3,right:x+labelWidth+3,top:y-12,bottom:y+3+14*(text.length-1)};
        if(y<30||box.bottom>height-40||labelBoxes.some(old=>box.left<old.right&&box.right>old.left&&box.top<old.bottom&&box.bottom>old.top))continue;
        labelBoxes.push(box);text.forEach((line,i)=>ctx.fillText(line,x,y+i*14));break;
      }
    }
  }
  ctx.globalAlpha=1;
  const km=100/scale/1000;ctx.strokeStyle='#7594ac';ctx.beginPath();ctx.moveTo(width-130,height-25);ctx.lineTo(width-30,height-25);ctx.stroke();
  ctx.textAlign='center';ctx.font='10px Segoe UI';ctx.fillStyle='#9db0c4';ctx.fillText(`${km.toFixed(1)} km`,width-80,height-34);
  ctx.textAlign='left';ctx.fillStyle='#6d89a2';ctx.fillText('LOCAL TACTICAL GRID · 自动适配',18,25);
}
