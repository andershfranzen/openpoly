const assert=require('node:assert/strict');
const p=require('../driver/macos/dl3-session.cjs');
const k=Buffer.from('2b7e151628aed2a6abf7158809cf4f3c','hex'),block=Buffer.from('6bc1bee22e409f96e93d7e117393172a','hex');
assert.equal(p.aes(k,block).toString('hex'),'3ad77bb40d7a3660a89ecaf32466ef97');
assert.equal(p.cmac(k,Buffer.alloc(0)).toString('hex'),'bb1d6929e95937287fa37d129b756746');
assert.equal(p.cmac(k,block).toString('hex'),'070a16b46b4d4144f79bdd9dd04a287c');
const nonce=Buffer.from('0011223344556677','hex'),f=p.seal(k,nonce,17,10,Buffer.alloc(32,0x42));
assert.deepEqual(p.open(k,nonce,f),Buffer.alloc(32,0x42));
const tampered=Buffer.from(f);tampered[20]^=1;assert.equal(p.open(k,nonce,tampered),null);
const other=Buffer.from(nonce);other[7]^=1;assert.equal(p.open(k,other,f),null);
assert.equal(p.open(k,nonce,Buffer.alloc(15)),null);
assert.equal(p.frame(1,0,0,0).toString('hex'),'00000c00010000000000000000000000');
assert.throws(()=>p.frames(f.subarray(0,-1)));assert.throws(()=>p.frames(Buffer.alloc(16)));
assert.throws(()=>p.ake(1,0xff));assert.equal(p.ake(4,4,Buffer.alloc(128)).length,176);
const joined=Buffer.concat([f,p.frame(1,0,0,0),f]);
for(const size of [1,7,16,63,64,1024]){
  const decoder=new p.FrameDecoder();let received=[];
  for(let i=0;i<joined.length;i+=size)received.push(...decoder.feed(joined.subarray(i,i+size)));
  assert.deepEqual(received,[f,p.frame(1,0,0,0),f]);assert.equal(decoder.buffer.length,0);
}
assert.throws(()=>new p.FrameDecoder().feed(Buffer.alloc(16)));
console.log('DL3 session crypto/framing checks passed');
