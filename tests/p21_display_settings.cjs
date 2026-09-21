const assert=require('node:assert/strict');
const {displaySettings}=require('../driver/macos/p21-display-settings.cjs');
const {options}=require('../driver/macos/p21-display.cjs');
const {getRequest,setRequest,parseReply}=require('../driver/macos/p21-brightness.cjs');
assert.deepEqual(options(['--resolution','1280x720','--refresh','30']).settings,{width:1280,height:720,refreshHz:30});
for(const value of [{width:1920,height:1200},{refreshHz:120},{refreshHz:'60'},{width:NaN}])assert.throws(()=>displaySettings(value));
assert.throws(()=>options(['--resolution','1280x720junk']));
for(const n of ['-1','101','NaN','12.5'])assert.throws(()=>options(['--brightness',n]));
assert.equal(options(['--brightness','0']).brightness,0);
assert.equal(getRequest().subarray(22,29).toString('hex'),'000551820110ac');
assert.equal(setRequest(30).subarray(22,31).toString('hex'),'0007518403100009a1');
assert.equal(setRequest(100).subarray(22,31).toString('hex'),'000751840310001fb7');
for(const n of [-1,101,NaN,Infinity])assert.throws(()=>setRequest(n));
const reply=Buffer.from('200025006200000000000000000000000000000000000b6e8802001000001f0017ac','hex');
assert.deepEqual(parseReply(reply),{value:23,maximum:31,percent:74});
for(let i=23;i<reply.length;i++){const bad=Buffer.from(reply);bad[i]^=1;assert.throws(()=>parseReply(bad));}
assert.throws(()=>parseReply(reply.subarray(0,30)));
console.log('Display modes and measured backlight packets passed');
