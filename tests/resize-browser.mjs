import {chromium} from 'file:///C:/Users/wsx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs';
import {writeFile,mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import assert from 'node:assert/strict';
const folder=resolve(process.argv[2]),base=process.argv[3];await mkdir(folder,{recursive:true});
const browser=await chromium.launch({executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
const context=await browser.newContext({viewport:{width:1600,height:1000}}),page=await context.newPage(),errors=[],checks=[];let output;
context.on('page',p=>p.on('pageerror',e=>errors.push(e.message)));page.on('pageerror',e=>errors.push(e.message));
const save=async()=>{await page.getByRole('button',{name:'保存',exact:true}).click();await page.waitForFunction(()=>document.querySelector('#save-status').textContent==='已同步');};
const frame=()=>page.frames().find(f=>f.url().includes('/output/'));
async function drag(key,dx,dy,{resize=false,shift=false}={}){
  const f=frame(),selector=`.${resize?'dock-resize':'dock-handle'}[data-key="${key}"]`,locator=f.locator(selector);await locator.waitFor();
  const box=await locator.boundingBox(),factor=await f.locator('.hud-composition').evaluate(n=>n.getBoundingClientRect().width/1920);
  await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();if(shift)await page.keyboard.down('Shift');
  await page.mouse.move(box.x+box.width/2+dx*factor,box.y+box.height/2+dy*factor,{steps:5});await page.mouse.up();if(shift)await page.keyboard.up('Shift');
}
try{
  await page.goto(base);await page.getByLabel('账号',{exact:true}).fill('director');await page.getByLabel('密码',{exact:true}).fill('test-only-password-123');await page.getByRole('button',{name:'登录并连接'}).click();await page.locator('[data-p="fixedCount"]').waitFor();
  await page.locator('[data-p="fixedCount"]').check();await save();
  output=await context.newPage();await output.setViewportSize({width:1920,height:1080});await output.goto(await page.locator('#open-output').getAttribute('href'));await output.locator('.roster-blue.fixed-count').waitFor();
  assert.equal(await output.locator('.roster-blue .roster-cards>.pilot-card').count(),5);assert.equal(await output.locator('.roster-blue .roster-cards>.plate-placeholder').count(),3);
  const height=(await output.locator('.roster-blue').boundingBox()).height;
  await page.locator('[data-field="filters.search"]').fill('no-matching-player');await save();await output.waitForFunction(()=>document.querySelectorAll('.roster-blue .roster-cards>.plate-placeholder').length===5);
  const emptyHeight=(await output.locator('.roster-blue').boundingBox()).height;assert.ok(Math.abs(emptyHeight-height)<2,`fixed count height must survive an empty roster: ${height} to ${emptyHeight}`);
  assert.equal(await output.getByText('等待选手数据',{exact:true}).count(),0);assert.equal(await output.getByText('等待观战选手数据',{exact:true}).count(),0);
  await page.locator('[data-p="fixedCount"]').uncheck();await save();await output.waitForFunction(()=>document.querySelectorAll('.roster-blue .roster-cards>.pilot-card').length===0);
  assert.equal(await output.locator('.roster-blue .hud-empty').count(),0);checks.push('fixed count fills missing slots, holds height at zero data, and no waiting text is shown');
  await page.locator('[data-field="filters.search"]').fill('');await save();
  await page.locator('[data-edit-preview]').click();await drag('map',80,40,{resize:true,shift:true});
  await page.locator('[data-field="match.title"]').fill('unsaved title');
  await page.getByRole('checkbox',{name:'油量条与数值',exact:true}).uncheck();
  await page.waitForFunction(()=>document.querySelector('#save-status').textContent.includes('开关已实时保存'));
  await page.getByRole('button',{name:'取消',exact:true}).click();
  await frame().waitForFunction(()=>document.querySelectorAll('.dock-handle').length===0&&!document.querySelector('.map-panel').hasAttribute('data-adaptive-size'));
  assert.notEqual(await page.locator('[data-field="match.title"]').inputValue(),'unsaved title');
  assert.equal(await page.getByRole('checkbox',{name:'油量条与数值',exact:true}).isChecked(),false);
  assert.equal(Math.round((await output.locator('.map-panel').boundingBox()).width),300);
  const afterCancel=await page.evaluate(()=>fetch('/api/outputs').then(r=>r.json()));assert.equal(afterCancel[0].config.elementLayouts.map,undefined);
  await page.getByRole('checkbox',{name:'油量条与数值',exact:true}).check();
  await page.waitForFunction(()=>document.querySelector('#save-status').textContent.includes('开关已实时保存'));
  checks.push('Cancel restores draft layout and fields, exits editing and preserves independently saved live switches');
  await page.locator('[data-edit-preview]').click();await drag('map',100,50,{resize:true,shift:true});
  const previewMap=await frame().locator('.map-panel').boundingBox();assert.ok(previewMap.width>150);
  assert.equal(Math.round((await output.locator('.map-panel').boundingBox()).width),300,'resize draft must not publish before Save');await save();
  await output.waitForFunction(()=>Math.abs(document.querySelector('.map-panel').getBoundingClientRect().width-400)<2&&Math.abs(document.querySelector('.map-panel').getBoundingClientRect().height-294)<2);
  const mapResolution=await output.locator('#map').evaluate(n=>({pixels:n.width,display:n.getBoundingClientRect().width,logical:n.clientWidth,scale:getComputedStyle(n.closest('.map-panel')).scale}));
  assert.ok(mapResolution.pixels>=mapResolution.display-2);assert.ok(mapResolution.pixels>300);assert.equal(mapResolution.scale,'none');
  const stableWidth=(await output.locator('.map-panel').boundingBox()).width;await output.waitForTimeout(2200);assert.ok(Math.abs((await output.locator('.map-panel').boundingBox()).width-stableWidth)<1);
  const highDpi=await browser.newContext({viewport:{width:1920,height:1080},deviceScaleFactor:2}),dpiPage=await highDpi.newPage();
  await dpiPage.goto(await page.locator('#open-output').getAttribute('href'));await dpiPage.locator('#map').waitFor();
  await dpiPage.waitForFunction(()=>{const n=document.querySelector('#map');return n.width>=n.getBoundingClientRect().width*2-2;});await highDpi.close();
  checks.push('resize relayouts actual dimensions, rerasterizes the map at display/DPR resolution, and stays stable across telemetry refreshes');
  // At x=32, moving by five pixels would snap back. Shift must preserve x=37.
  await drag('map',5,0,{shift:true});await save();await output.waitForFunction(()=>Math.abs(document.querySelector('.map-panel').getBoundingClientRect().left-37)<2);
  // Resize towards the 960 center guide: snapped 928 width versus Shift-free 923.
  await page.locator('[data-p="dockTarget"]').selectOption('map');await page.locator('[data-p="dockX"]').fill('32');await save();
  await drag('map',523,0,{resize:true,shift:true});await save();await output.waitForFunction(()=>Math.abs(document.querySelector('.map-panel').getBoundingClientRect().width-923)<2);
  await drag('map',0,0,{resize:true});await save();await output.waitForFunction(()=>Math.abs(document.querySelector('.map-panel').getBoundingClientRect().width-928)<2);
  checks.push('Shift bypasses move and resize snapping; releasing Shift restores center snapping');
  await page.locator('[data-edit-details]').click();await frame().locator('.element-picker').selectOption('match/blue-score');const scoreBefore=await frame().locator('.match-team.blue>b').boundingBox();await drag('match/blue-score',30,10,{resize:true,shift:true});await drag('match/blue-score',17,13,{shift:true});await save();
  const scoreAfter=await frame().locator('.match-team.blue>b').boundingBox();assert.ok(scoreAfter.width>scoreBefore.width+8);const saved=await page.evaluate(()=>fetch('/api/outputs').then(r=>r.json()));assert.ok(saved[0].config.elementLayouts['match/blue-score'].dx>0);
  checks.push('inner score text has independent move and resize controls');
  await page.locator('[data-edit-details]').click();await drag('plate:Test-Unit-1',30,20,{resize:true,shift:true});await save();await output.locator('.detached-cards [data-unit-name="Test-Unit-1"]').waitFor();
  checks.push('individual nameplates support corner resize and retain their own dock');
  const rosterBefore=await output.locator('.roster-blue').boundingBox();await drag('blue',80,40,{resize:true,shift:true});await save();
  await output.waitForFunction(width=>Math.abs(document.querySelector('.roster-blue').getBoundingClientRect().width-width)<2,rosterBefore.width+80);
  const rosterAfter=await output.locator('.roster-blue').boundingBox(),rosterCard=await output.locator('.roster-blue .roster-cards>.pilot-card').first().boundingBox();assert.ok(Math.abs(rosterAfter.width-rosterCard.width)<2);
  checks.push('resized roster reflows its cards to the new content width');
  const png=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=1024;c.height=1024;const g=c.getContext('2d');g.fillStyle='#56bbfa';g.fillRect(0,0,1024,1024);g.fillStyle='#102638';g.font='bold 500px sans-serif';g.fillText('A',300,700);return c.toDataURL('image/png').split(',')[1];});
  await page.locator('[data-logo="blue"]').setInputFiles({name:'sharp-logo.png',mimeType:'image/png',buffer:Buffer.from(png,'base64')});await page.locator('.logo-preview').waitFor();await save();
  await output.locator('.match-team.blue .team-logo').waitFor();assert.equal(await output.locator('.match-team.blue .team-logo').evaluate(n=>n.naturalWidth),1024);
  await drag('blueLogo',44,44,{resize:true,shift:true});await save();await output.locator('.floating-brand-blue .team-logo').waitFor();
  const logo=await output.locator('.floating-brand-blue .team-logo').boundingBox();assert.ok(Math.abs(logo.width-88)<2&&Math.abs(logo.height-88)<2,JSON.stringify(logo));
  checks.push('new logos retain source resolution up to 1024px and fit a resized logo box without distortion');
  // Escape during a gesture cancels only that gesture; a second Escape cancels the draft.
  await drag('map',10,0,{shift:true});
  const handle=frame().locator('.dock-handle[data-key="map"]'),box=await handle.boundingBox();
  await page.mouse.move(box.x+10,box.y+5);await page.mouse.down();await page.mouse.move(box.x+40,box.y+5);
  await page.keyboard.press('Escape');await page.mouse.up();assert.equal(await frame().locator('.dock-ghost').count(),0);assert.ok(await frame().locator('.dock-handle').count()>0);
  await page.keyboard.press('Escape');await frame().waitForFunction(()=>document.querySelectorAll('.dock-handle').length===0);
  checks.push('Escape cancels an active gesture without committing, then cancels the unsaved preview');
  await page.reload();await page.locator('[data-edit-preview]').waitFor();await output.reload();await output.waitForFunction(()=>Math.abs(document.querySelector('.map-panel').getBoundingClientRect().width-928)<2);
  await output.screenshot({path:resolve(folder,'resized-output.png'),omitBackground:true});await page.screenshot({path:resolve(folder,'resize-control.png'),fullPage:true});assert.deepEqual(errors,[]);
  checks.push('saved element layouts survive reload without JavaScript errors');await writeFile(resolve(folder,'browser-report.json'),JSON.stringify({passed:true,checks},null,2));console.log(JSON.stringify({passed:true,checks}));
}catch(error){await page.screenshot({path:resolve(folder,'failure.png'),fullPage:true}).catch(()=>{});await output?.screenshot({path:resolve(folder,'output-failure.png')}).catch(()=>{});await writeFile(resolve(folder,'browser-report.json'),JSON.stringify({passed:false,checks,errors,error:String(error)},null,2));throw error;}
finally{await browser.close();}
