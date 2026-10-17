import {chromium} from 'file:///C:/Users/wsx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs';
import {writeFile,mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import assert from 'node:assert/strict';
const folder=resolve(process.argv[2]),base=process.argv[3];await mkdir(folder,{recursive:true});
const browser=await chromium.launch({executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
const context=await browser.newContext({viewport:{width:1600,height:1000}}),page=await context.newPage(),errors=[],checks=[];let output;
context.on('page',p=>p.on('pageerror',e=>errors.push(e.message)));page.on('pageerror',e=>errors.push(e.message));
const save=async()=>{await page.getByRole('button',{name:'保存',exact:true}).click();await page.waitForFunction(()=>document.querySelector('#save-status').textContent==='已同步');};
const command=async kind=>writeFile(resolve(folder,'scenario-command.json'),JSON.stringify({id:Date.now(),kind}));
const card=id=>output.locator(`.roster-cards>[data-entity-id="${id}"]`);
try{
  await page.goto(base);await page.getByLabel('账号',{exact:true}).fill('director');await page.getByLabel('密码',{exact:true}).fill('test-only-password-123');await page.getByRole('button',{name:'登录并连接'}).click();await page.locator('[data-open-picker]').waitFor();
  await page.locator('[data-p="mode"]').selectOption('teams');await page.locator('[data-open-picker]').click();
  await page.waitForFunction(()=>document.querySelector('[data-player="Ace"] .presence')?.textContent==='在线');
  await page.locator('[data-player="Ace"]').dragTo(page.locator('[data-pool-side="blue"]'));
  assert.ok(await page.locator('[data-pool-side="blue"] .pool-row').textContent().then(t=>t.includes('Ace')));
  await page.locator('[data-player="Viper"]').dragTo(page.locator('[data-pool-side="red"]'));
  assert.equal(await page.locator('.pool-row').count(),2);assert.equal(context.pages().length,1);
  checks.push('same-tab picker lists online players and drags into both pools regardless of coalition');
  await page.getByRole('button',{name:'关闭选手小窗'}).click();await save();
  output=await context.newPage();await output.setViewportSize({width:1920,height:1080});await output.goto(await page.locator('#open-output').getAttribute('href'));
  await output.waitForFunction(()=>document.querySelectorAll('.roster-red .incoming-missile').length===3);
  assert.equal(await card('test-aircraft-0').locator('.incoming-missile').count(),1);
  for(const [id,side] of [['test-aircraft-0','blue'],['test-aircraft-1','red']]){
    const a=await card(id).boundingBox(),b=await card(id).locator('.incoming-threats').boundingBox();assert.ok(side==='blue'?b.x>=a.x+a.width:b.x+b.width<=a.x+1);
  }
  checks.push('one icon per incoming missile appears outside the card toward center on both sides');
  await output.screenshot({path:resolve(folder,'incoming-output.png'),omitBackground:true});
  await page.getByRole('checkbox',{name:'来袭导弹 · 名称',exact:true}).uncheck();
  await output.waitForFunction(()=>[...document.querySelectorAll('.incoming-name')].every(n=>n.hidden));
  assert.equal(await output.locator('.incoming-missile').count(),4);assert.equal(await output.locator('.incoming-launcher:visible').count(),4);
  await page.getByRole('checkbox',{name:'来袭导弹 · 发射人',exact:true}).uncheck();await output.waitForFunction(()=>[...document.querySelectorAll('.incoming-launcher')].every(n=>n.hidden));
  await page.getByRole('checkbox',{name:'标牌 · 来袭导弹图标',exact:true}).uncheck();await output.waitForFunction(()=>[...document.querySelectorAll('.incoming-threats')].every(n=>n.hidden));
  await page.getByRole('checkbox',{name:'标牌 · 来袭导弹图标',exact:true}).check();await output.waitForFunction(()=>[...document.querySelectorAll('.incoming-threats')].every(n=>!n.hidden));
  checks.push('incoming icons, missile names and launcher names switch independently without saving');
  await page.getByRole('checkbox',{name:'只跟踪焦点飞机发射的导弹',exact:true}).check();await save();
  assert.equal(await output.locator('.incoming-missile').count(),4);checks.push('missile display filters do not suppress incoming threat counts');
  await command('retarget');await output.waitForFunction(()=>document.querySelectorAll('.roster-blue .incoming-missile').length===2&&document.querySelectorAll('.roster-red .incoming-missile').length===0);
  checks.push('retarget moves the icon; lost target and removed missile clear their icons');
  assert.equal(await output.locator('.incoming-missile').count(),2);
  await command('stale');await output.waitForFunction(()=>document.querySelectorAll('.incoming-missile').length===0);checks.push('stale snapshot clears active incoming indicators');
  await command('fresh');await output.waitForFunction(()=>document.querySelectorAll('.incoming-missile').length===2);
  await command('disconnect');await page.locator('[data-open-picker]').click();await page.waitForFunction(()=>document.querySelector('[data-player="Ace"] .presence')?.textContent==='历史');
  await page.locator('[data-player="Ace"]').dragTo(page.locator('[data-pool-side="red"]'));assert.equal(await page.locator('.pool-row').count(),2);
  assert.ok((await page.locator('[data-pool-side="red"]').textContent()).includes('Ace'));checks.push('disconnected player remains draggable in history and moving pools does not duplicate the slot');
  await page.screenshot({path:resolve(folder,'player-picker.png'),fullPage:true});await page.getByRole('button',{name:'关闭选手小窗'}).click();await save();
  await output.waitForFunction(()=>document.querySelectorAll('.incoming-missile').length===0);checks.push('dead or disconnected player cards do not show incoming indicators');
  assert.deepEqual(errors,[]);await writeFile(resolve(folder,'browser-report.json'),JSON.stringify({passed:true,checks},null,2));console.log(JSON.stringify({passed:true,checks}));
}catch(error){await page.screenshot({path:resolve(folder,'failure.png'),fullPage:true}).catch(()=>{});await output?.screenshot({path:resolve(folder,'output-failure.png')}).catch(()=>{});await writeFile(resolve(folder,'browser-report.json'),JSON.stringify({passed:false,checks,errors,error:String(error)},null,2));throw error;}
finally{await browser.close();}
