import {test} from 'node:test';
import assert from 'node:assert/strict';
import {gestureRect} from '../src/web/dock-editor.mjs';
import {defaultConfig,validateConfig} from '../src/director/output-model.mjs';
test('Shift bypasses both move and resize snapping without changing the proposed dimensions',()=>{
  const r={x:100,y:100,width:200,height:100};
  assert.equal(gestureRect(r,-63,0,false,false).x,32);
  assert.equal(gestureRect(r,-63,0,false,true).x,37);
  const other=[{x:400,y:300,width:100,height:100}];
  assert.equal(gestureRect(r,95,95,true,false,other).width,300);
  assert.equal(gestureRect(r,95,95,true,true,other).width,295);
  assert.equal(gestureRect(r,95,95,true,true,other).height,195);
});
test('old profiles migrate fixed-count and per-element layouts; layout bounds reject invalid values',()=>{
  const c=defaultConfig();delete c.nameplates.fixedCount;delete c.elementLayouts;
  const saved=validateConfig(c);assert.equal(saved.nameplates.fixedCount,false);assert.deepEqual(saved.elementLayouts,{});
  saved.nameplates.fixedCount=true;saved.elementLayouts={'match/blue-score':{dx:12,dy:-5,scaleX:1.5,scaleY:2}};
  assert.deepEqual(validateConfig(saved).elementLayouts,saved.elementLayouts);
  saved.elementLayouts['match/blue-score'].scaleX=0;assert.throws(()=>validateConfig(saved));
  saved.elementLayouts={'__proto__x':{dx:0,dy:0,scaleX:1,scaleY:1}};assert.throws(()=>validateConfig(saved));
});
