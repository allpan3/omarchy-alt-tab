// Exercise the actual QML function bodies with a mocked desktop, without input injection.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '..', 'Switcher.qml'), 'utf8');
const functions = [...source.matchAll(/^  function \w+\([^\n]*\) \{\n[\s\S]*?^  \}/gm)].map(m => m[0]).join('\n');
const Qt = {ShiftModifier: 1, ControlModifier: 4, Key_A: 65, Key_Z: 90, Key_1: 49, Key_9: 57};
['Shift','Control','Alt','Super_L','Super_R','Meta','Escape','Return','Enter','Tab','Backtab','Up','Down','QuoteLeft','Backspace','Insert'].forEach((s, i) => Qt['Key_'+s] = 1000+i);
function top(address, app, ws, title) {
  return {address, title, workspace: {id:ws}, wayland:{appId:app}, lastIpcObject:{focusHistoryID:parseInt(address,16)}};
}
function setup() {
  const timer = () => ({restart(){}, stop(){}});
  const dispatched = [];
  const c = {Qt, JSON, Number, String, Math,
    WindowModel: require('../WindowModel.js'),
    Hyprland: {toplevels:{values:[top('a','browser',1,'cats'),top('b','browser',2,'videos'),top('c','terminal',2,'shell')]},
      activeToplevel:{address:'a'}, dispatch(x){dispatched.push(x)}},
    pluginId:'example.switcher', shell:null, service:null, opened:false,
    variant:'two-line', modifier:'ctrl', mode:'all', refClass:'', filterText:'', sticky:false,
    revealed:false, holdOpen:false, shiftPressReverses:true, sessionSerial:0,
    selectedIndex:0, viewStart:0, windows:[], visibleWindows:[],
    maxWindows:256, maxField:256, maxRows:20, maxFilter:128,
    luaDispatchMode:true, pendingFocusAddress:'', focusRetries:0,
    revealTimer:timer(), focusTimer:timer(), releaseDelay:timer(), modifierCheck:{running:false},
    dispatched,
  };
  Object.defineProperty(c,'autoCommit',{get(){return c.modifier!=='none'&&!c.holdOpen}});
  Object.defineProperty(c,'visibleRows',{get(){return c.visibleWindows.slice(c.viewStart,c.viewStart+c.maxRows)}});
  c.root=c;
  vm.createContext(c); vm.runInContext(functions,c);
  c.press=(key, extra={})=>c.keyPressed({key:Qt['Key_'+key]??key,text:'',modifiers:4,isAutoRepeat:false,...extra});
  c.release=(key,extra={})=>c.keyReleased({key:Qt['Key_'+key],...extra});
  c.openCtrl=(extra={})=>c.open(JSON.stringify({modifier:'ctrl',...extra}));
  return c;
}
let passed=0;
function test(name, fn) { fn(); passed++; console.log('ok '+name); }
test('all windows includes same-app windows on a second workspace',()=>{
 const c=setup(); c.openCtrl(); assert.equal(c.windows.length,3); assert.equal(c.selectedIndex,1);
 assert.equal(c.visibleWindows[1].workspaceId,2);
});
test('same-app mode retains both browser windows across workspaces',()=>{
 const c=setup(); c.openCtrl({mode:'sameclass'}); assert.equal(c.windows.length,2);
 assert.equal(c.windows[1].address,'b');
});
test('raw Shift notification reverses; Qt delivery cannot double count',()=>{
 const c=setup(); c.openCtrl(); c.shiftPressed('ctrl'); assert.equal(c.selectedIndex,0);
 c.press('Shift',{nativeScanCode:50}); c.release('Shift',{nativeScanCode:50}); assert.equal(c.selectedIndex,0);
 c.shiftPressed('ctrl'); assert.equal(c.selectedIndex,2);
});
test('notifications outside a matching held-modifier session are ignored',()=>{
 const c=setup(); c.shiftPressed('ctrl'); assert.equal(c.opened,false);
 c.openCtrl(); c.shiftPressed('alt'); assert.equal(c.selectedIndex,1);
 c.shiftPressed('ctrl,alt'); assert.equal(c.selectedIndex,0);
});
test('Shift already held before opening is not an extra reverse step',()=>{
 const c=setup(); c.shiftPressed('ctrl'); c.openCtrl({dir:'prev'}); assert.equal(c.selectedIndex,2);
 c.release('Shift',{nativeScanCode:50}); assert.equal(c.selectedIndex,2);
});
test('Shift plus Tab/grave continues backward',()=>{
 const c=setup(); c.openCtrl(); c.shiftPressed('ctrl'); c.press('Tab',{modifiers:5}); assert.equal(c.selectedIndex,2);
 c.press('QuoteLeft',{modifiers:5}); assert.equal(c.selectedIndex,1);
});
test('Shift-alone behavior is configurable and leaves search capitalization alone',()=>{
 const c=setup(); c.openCtrl({shiftPressReverses:false}); c.shiftPressed('ctrl'); assert.equal(c.selectedIndex,1);
 c.press('Backtab'); assert.equal(c.selectedIndex,0);
 c.close(); c.openCtrl(); c.press(83,{text:'s'}); const index=c.selectedIndex;
 c.shiftPressed('ctrl'); assert.equal(c.selectedIndex,index);
});
test('repeated named actions cycle without double counting',()=>{
 const c=setup(); c.openCtrl(); c.openCtrl(); assert.equal(c.selectedIndex,2);
 c.openCtrl({dir:'prev'}); assert.equal(c.selectedIndex,1);
});
test('typing searches and prevents Ctrl release from selecting',()=>{
 const c=setup(); c.openCtrl(); c.press(83,{text:'\u0013'}); assert.equal(c.sticky,true); assert.equal(c.filterText,'s');
 c.modifierResult('error: SWITCHER_MODIFIER:false',c.sessionSerial); assert.equal(c.opened,true);
 c.press('Return'); assert.equal(c.opened,false);
});
test('Ctrl+Insert searches for c with the existing copy mapping',()=>{
 const c=setup(); c.openCtrl(); c.press('Insert',{modifiers:4}); assert.equal(c.filterText,'c'); assert.equal(c.visibleWindows[0].title,'cats');
});
test('Shift+Insert searches for v and does not commit on synthetic Ctrl release',()=>{
 const c=setup(); c.openCtrl(); c.release('Control'); c.press('Insert',{modifiers:1});
 c.modifierResult('error: SWITCHER_MODIFIER:false',c.sessionSerial); assert.equal(c.opened,true);
 assert.equal(c.filterText,'v'); assert.equal(c.visibleWindows[0].title,'videos');
});
test('normal search supports spaces, backspace and Escape after releasing Ctrl',()=>{
 const c=setup(); c.openCtrl(); c.press(83,{text:'s'}); c.press(32,{text:' ',modifiers:0});
 assert.equal(c.filterText,'s '); c.press('Backspace'); assert.equal(c.filterText,'s');
 c.press('Escape'); assert.equal(c.opened,false); assert.equal(c.dispatched.length,0);
});
test('a quick release missed by the popup is caught by the modifier query',()=>{
 const c=setup(); c.openCtrl(); c.modifierResult('error: SWITCHER_MODIFIER:false',c.sessionSerial);
 assert.equal(c.opened,false); assert.match(c.dispatched[0],/address:0xb/);
});
test('held modifier or IPC failure does not select',()=>{
 const c=setup(); c.openCtrl(); c.modifierResult('error: SWITCHER_MODIFIER:true',c.sessionSerial);
 c.modifierResult('socket unavailable',c.sessionSerial); assert.equal(c.opened,true);
});
test('an old asynchronous modifier response cannot close a newer session',()=>{
 const c=setup(); c.openCtrl(); const serial=c.sessionSerial; c.close(); c.openCtrl();
 c.modifierResult('error: SWITCHER_MODIFIER:false',serial); assert.equal(c.opened,true);
});
test('hold-open diagnostics and picker mode never auto-select',()=>{
 const c=setup(); c.openCtrl({hold:true}); c.modifierResult('SWITCHER_MODIFIER:false',c.sessionSerial); assert.equal(c.opened,true);
 c.close(); c.openCtrl({modifier:'none'}); c.modifierResult('SWITCHER_MODIFIER:false',c.sessionSerial); assert.equal(c.opened,true);
});
test('empty filtered list cannot focus anything',()=>{
 const c=setup(); c.openCtrl(); c.press(90,{text:'z'}); c.press('Return'); assert.equal(c.dispatched.length,0);
});
test('default Alt modifier cycles and commits on release',()=>{
 const c=setup(); c.open('{}'); assert.equal(c.modifier,'alt');
 c.shiftPressed('alt'); assert.equal(c.selectedIndex,0);
 c.open('{}'); assert.equal(c.selectedIndex,1);
 c.modifierResult('SWITCHER_MODIFIER:false',c.sessionSerial);
 assert.equal(c.opened,false); assert.match(c.dispatched[0],/address:0xb/);
});
console.log(`Passed ${passed} keyboard integration checks`);
