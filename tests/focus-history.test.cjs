// Replay compositor focus bursts against the actual service function bodies.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '..', 'Service.qml'), 'utf8');
const functions = [...source.matchAll(/^  function \w+\([^\n]*\) \{\n[\s\S]*?^  \}/gm)].map(m=>m[0]).join('\n');
function setup() {
  const c = {WindowModel:require('../WindowModel.js'), history:[], historyLimit:512,
    pendingFocus:'', focusSettle:{restart(){},stop(){}}};
  c.root=c; vm.createContext(c); vm.runInContext(functions,c); return c;
}
let passed=0;
function test(name, fn){fn();passed++;console.log('ok '+name)}
test('workspace intermediate focus does not become the previous window',()=>{
 const c=setup();
 for(const address of ['c','b']){c.queueFocus(address);c.flushFocus()}
 c.queueFocus('c');c.queueFocus('a');c.flushFocus();
 assert.equal(c.history.join(','),'a,b,c');
});
test('quick invocation flushes the final focus without waiting a frame',()=>{
 const c=setup(); c.queueFocus('b');c.flushFocus();
 c.queueFocus('c');c.queueFocus('a');
 assert.equal(c.historyRank('a'),0);assert.equal(c.historyRank('b'),1);
 assert.equal(c.historyRank('c'),-1);
});
test('long picker then repeated cross-workspace switches keeps A and B adjacent',()=>{
 const c=setup();c.queueFocus('b');c.flushFocus();c.queueFocus('a');c.flushFocus();
 for(let i=0;i<10;i++){
   // Active-window notifications while the picker holds keyboard focus.
   for(let j=0;j<5;j++){c.queueFocus('a');c.flushFocus()}
   c.queueFocus('d');c.queueFocus('b');c.flushFocus();
   assert.equal(c.history[1],'a');
   c.queueFocus('c');c.queueFocus('a');c.flushFocus();
   assert.equal(c.history[1],'b');
 }
 assert.equal(c.history.join(','),'a,b');
});
test('real same-workspace focus changes still enter history',()=>{
 const c=setup();for(const a of ['a','b','c']){c.queueFocus(a);c.flushFocus()}
 assert.equal(c.history.join(','),'c,b,a');
});
test('empty focus during a layer grab neither clears nor pollutes history',()=>{
 const c=setup();c.queueFocus('a');c.queueFocus('');c.flushFocus();
 assert.equal(c.history.join(','),'a');
});
test('closing a pending window cannot put it back in history',()=>{
 const c=setup();c.queueFocus('a');c.flushFocus();c.queueFocus('b');c.forgetWindow('b');c.flushFocus();
 assert.equal(c.history.join(','),'a');c.forgetWindow('a');assert.equal(c.history.length,0);
});
console.log(`Passed ${passed} focus-history regression checks`);
