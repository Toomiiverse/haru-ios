import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html=fs.readFileSync('Haru/Resources/stage.html','utf8');
test('native keyboard peek stays readable, tracks typing and restores the latest server face',()=>{
  const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
  const calls=[],classes=new Map(),styles=new Map();let expire;
  const element={style:{setProperty:(k,v)=>styles.set(k,v)},classList:{toggle:(k,v)=>classes.set(k,v)}};
  const c={window:{haruAvatar:{express:n=>calls.push(['express',n]),attend:(...a)=>calls.push(['attend',...a]),tap:()=>calls.push(['tap']),notify(){},think(){}}},
    document:{getElementById:()=>element,addEventListener(){},querySelector:()=>null},performance:{now:()=>1000},requestAnimationFrame:()=>1,setInterval:()=>1,clearInterval(){},setTimeout:fn=>{expire=fn;return 1;},clearTimeout(){expire=undefined;}};
  c.window.addEventListener=()=>{};vm.runInNewContext(code,c);
  const api=c.window.haruStage;
  api.express('sleepy');api.frame(1,0,1,true);
  assert.equal(classes.get('peek'),true);assert.deepEqual(calls.at(-2),['express','attentive']);
  assert.deepEqual(calls.at(-1),['attend','typing',3600000]);
  api.attend('typing',1500);assert.deepEqual(calls.at(-1),['attend','typing',3600000]);
  api.express('happy');assert.notDeepEqual(calls.at(-1),['express','happy']);
  api.attend('attachment',4200);assert.equal(c.window.haruNative.attachment,true);assert.deepEqual(calls.at(-2),['express','curious']);
  api.attend('typing',1800);assert.equal(c.window.haruNative.attachment,false);assert.deepEqual(calls.at(-2),['attend','typing',3600000]);
  api.attend('attachment',4200);expire();assert.equal(c.window.haruNative.attachment,false);assert.deepEqual(calls.at(-2),['express','attentive']);
  api.mouth(.7);assert.equal(c.window.haruNative.mouth,.7);assert.equal(c.window.haruNative.speakingUntil,1450);
  api.mouth(0);assert.equal(c.window.haruNative.mouth,0);
  api.tap();assert.deepEqual(calls.at(-1),['tap']);
  api.frame(1,0,1,false);assert.deepEqual(calls.at(-2),['express','happy']);assert.equal(classes.get('peek'),false);
  c.window.haruNative.ready();assert.deepEqual(calls.at(-2),['express','happy']);
  assert.match(html,/#scene\.peek #stage\s*\{[^}]*height:160px; bottom:0/);
  const swift=fs.readFileSync('Haru/Sources/Views/ChatView.swift','utf8');
  assert.match(swift,/scale: 1, peek: compact/);assert.ok(!swift.includes('scale: compact ? 0.5'));
  assert.ok(!swift.includes('composerTop'),'the stage must not follow the composer to the bottom');
  assert.ok(!swift.includes('stageView.offset'),'the stage remains anchored above the transcript');
  assert.match(swift,/Color\.clear\.frame\(height: visibleStageHeight \+ topInset\)/);
  assert.match(swift,/compact \? 160 : stageTall/);
  assert.equal((swift.match(/StageWebView\(stage:/g)||[]).length,1,'keyboard transition keeps one renderer');
  assert.match(swift,/\.contentShape\(Rectangle\(\)\)[\s\S]*\.onTapGesture\s*\{[\s\S]*chat\.stage\.tap\(\)/);
  assert.match(swift,/let hushed = chat\.tapToHush\(\)[\s\S]*chat\.stage\.tap\(\)[\s\S]*if hushed \{ return \}/);
  const stage=fs.readFileSync('Haru/Sources/Services/Stage.swift','utf8');
  assert.match(stage,/web\.isUserInteractionEnabled = false/);
});
test('the bundled stage uses shared hair, sleep, speech and depth rendering',()=>{
  for(const marker of ['avatar-sleep-layer','avatar-depth','haruNative'])assert.ok(html.includes(marker),marker);
  assert.match(html,/\.svg\?v=[a-f0-9]{16}/);
  assert.ok(!html.includes('const POKES = { exclaim:'));
  assert.ok(html.includes('--glow-voice'));
  assert.ok(!html.includes('id="aura"'));
  assert.ok(!html.includes('<i class="floor">'));
});

test('every expression is packaged with the stage so startup does not need the server',()=>{
  const faces=fs.readdirSync('Haru/Resources/emotions').filter(name=>name.endsWith('.svg'));
  const count=Number(html.match(/event: 'alive', expressions: (\d+)/)[1]);
  assert.equal(faces.length,count);
  for(const name of ['neutral.svg','sleepy.svg','attentive.svg','curious.svg'])assert.ok(faces.includes(name));
  for(const name of faces)assert.match(fs.readFileSync('Haru/Resources/emotions/'+name,'utf8'),/<svg\b/);
});
