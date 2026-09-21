// SPDX-License-Identifier: GPL-2.0-only
// P21 Firefly memory transport measured on firmware 12.2.15.
// Haar bit grammar and decoder table construction adapted from FireBurn/linux
// vino-v3, drivers/gpu/drm/vino/video{_arm,/haar/{strip,transform}}.rs.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const {frame, seal} = require('./dl3-session.cjs');

const WIDTH = 1920, HEIGHT = 1088, BANK_SIZE = 0x180000;
function words(values, size = 2) {
  const b = Buffer.alloc(values.length * size);
  values.forEach((v, i) => size === 2 ? b.writeUInt16LE(v, i * size) : b.writeUInt32LE(v, i * size));
  return b;
}
function tlv(kind, payload) { return Buffer.concat([words([payload.length + 2, kind]), payload]); }
function memory(kind, address, data) {
  assert(address >= 0 && address + data.length <= BANK_SIZE * 2, 'video memory range');
  assert(data.length <= 3600, 'memory write too large');
  return tlv(kind, Buffer.concat([words([address], 4), data]));
}
function mode(width = WIDTH, height = HEIGHT) {
  return words([26, 0x030b, 0x0204, 2, 2, width, height, width ? 0x1800 : 0,
    2, width, height, width ? 0x1800 : 0, 0, 0]);
}
function configuration() {
  const records = [mode(0, 0)];
  for (let index = 0; index < 2; index++) {
    const naturals = 8 + index, t = Array(47).fill(0);
    for (let n = 1; n <= naturals; n++) {
      t[2 * n - 1] = 2 ** n * (2 ** (n + 1) - 1);
      t[24 + 2 * n - 1] = t[2 * n - 1] - (2 ** (n + 1) - 1);
    }
    t[2 * naturals] = 2 ** (2 * naturals + 2);
    t[24 + 2 * naturals] = t[2 * naturals] - (2 ** (naturals + 2) - 1);
    records.push(Buffer.concat([words([194, 0x0d | index << 8]), words([1, ...t], 4)]));
  }
  const narrow = [
    [1,0,2,0,4,0,8,0,16,0,32,0,64,0,128,0,256,0,512,1024],
    [1,0,2,0,4,0,8,15,2],
    [1,0,2,0,4,0,8,0,16,0,32,0,64,127,2],
  ];
  narrow.forEach((t, i) => {
    const size = (6 + t.length * 2 + 3) & ~3;
    const b = Buffer.alloc(size);
    words([size - 2, 0x09 | (i + 2) << 8, t.length, ...t]).copy(b);
    records.push(b);
  });
  let address = 0;
  const pointers = [], writes = records.map(r => {
    pointers.push(address); const w = memory(0x80, address, r); address += r.length; return w;
  });
  assert.equal(address, 0x210);
  return {writes: Buffer.concat(writes), pointers};
}
function quantizer() {
  return words([82,10,1,1,0,64,64,16,16,16,16,16,16,16,32,32,32,1,1,1,16,16,4,
    16,16,4,32,32,8,1,1,1,32,32,2,32,32,2,64,64,4,0]);
}
function commit(address, bytes, kind = 0x81) {
  return [tlv(0x282, words([0], 4)),
    tlv(kind, Buffer.concat([words([address], 4), words([bytes])])),
    tlv(0x182, words([0], 4))];
}
function packets(records) {
  const out = []; let parts = [], used = 0;
  function flush() {
    if (!used) return;
    const pad = (16 - used % 16) % 16;
    out.push(frame(4, 0, pad, 0, Buffer.concat([...parts, Buffer.alloc(pad)])));
    parts = []; used = 0;
  }
  for (const r of records) {
    assert(r.length <= 4064);
    if (used + r.length > 4064) flush();
    parts.push(r); used += r.length;
  }
  flush(); return out;
}
class Bits {
  constructor() { this.bytes = []; this.byte = 0; this.bits = 0; }
  bit(v) { this.byte |= (v & 1) << this.bits; if (++this.bits === 8) { this.bytes.push(this.byte); this.byte = this.bits = 0; } }
  unary(n, terminate, payload, wide = false) {
    if (wide) {
      for (let i = 0; i < n; i++) this.bit(1);
      if (terminate) this.bit(0);
      for (let i = n - 1; i >= 0; i--) this.bit(payload >> i);
    } else {
      for (let i = 0; i < n; i++) { this.bit(1); this.bit(payload >> i); }
      if (terminate) this.bit(0);
    }
  }
  esc(v, cmax = 10, wide = false) {
    if (!v) { this.bit(0); return; }
    const c = Math.min(cmax, 32 - Math.clz32(Math.abs(v)));
    const offset = Math.min(Math.abs(v), 2 ** c - 1) - 2 ** (c - 1);
    this.unary(c, c < cmax, offset * 2 + Number(v > 0), wide);
  }
  finish() { return Buffer.from(this.bits ? [...this.bytes, this.byte] : this.bytes); }
}
function solidStrip(x, y, rgb) {
  assert(x % 64 === 0 && y % 16 === 0 && x >= 0 && x < WIDTH && y >= 0 && y < HEIGHT);
  assert(rgb.length === 3 && rgb.every(v => Number.isInteger(v) && v >= 0 && v <= 255));
  const [r,g,b] = rgb, dc = [b-g, r-g, 4*g + 4*((r+b-2*g) >> 2)];
  const bits = new Bits();
  for (let k = 0; k < 16; k++) { bits.bit(0); bits.bit(0); bits.unary(6, true, 0); }
  for (let k = 0; k < 16; k++) for (const v of dc) bits.esc(k ? 0 : v);
  const main = bits.finish(), offset = 16 + ((main.length + 1) & ~1) + 2;
  // Firefly aligns the entire length-prefixed memory record to four bytes.
  const bdy = Buffer.alloc(((offset + 2 + 3) & ~3) - 2); bdy.writeUInt16LE(0x2801); bdy.writeUInt16LE(x, 2);
  bdy.writeUInt16LE(y, 4); bdy.writeUInt16LE(offset, 10); bdy.writeUInt16LE(offset, 12);
  main.copy(bdy, 16);
  return Buffer.concat([words([bdy.length]), bdy]);
}
function encodedFrame(bank, strips) {
  assert(bank === 0 || bank === BANK_SIZE);
  const records = [], pointers = [bank, bank + 28];
  let address = bank + 0x24b0;
  for (let y = 0; y < HEIGHT; y += 16) for (let x = 0; x < WIDTH; x += 64) {
    const strip = strips(x,y);
    assert(strip.length >= 20 && strip.length % 4 === 0 && strip.readUInt16LE(0) + 2 === strip.length);
    assert(strip.readUInt16LE(2) === 0x2801 && strip.readUInt16LE(4) === x && strip.readUInt16LE(6) === y);
    assert(address + strip.length <= bank + BANK_SIZE);
    pointers.push(address);
    for (let i = 0; i < strip.length; i += 3600) records.push(memory(0x80, address+i, strip.subarray(i,i+3600)));
    address += strip.length;
  }
  const table = words(pointers, 4), tableAddress = bank + 112;
  assert(tableAddress + table.length <= bank + 0x24b0);
  for (let i = 0; i < table.length; i += 3600) records.push(memory(0x180, tableAddress + i, table.subarray(i, i + 3600)));
  records.push(...commit(tableAddress, table.length));
  return packets(records);
}
function solidFrame(bank,pixel) { return encodedFrame(bank,(x,y)=>solidStrip(x,y,pixel(x,y))); }
function desktopFrame(bank,buffer) {
  let offset=0;
  const result=encodedFrame(bank,()=>{
    assert(offset+2<=buffer.length,'short strip header');
    const length=buffer.readUInt16LE(offset)+2;
    assert(offset+length<=buffer.length,'short strip body');
    const strip=buffer.subarray(offset,offset+length);offset+=length;return strip;
  });
  assert.equal(offset,buffer.length,'trailing strips');return result;
}
class DesktopBank {
  constructor(bank){assert(bank===0||bank===BANK_SIZE);this.bank=bank;this.entries=null;}
  frame(buffer){
    const strips=[];let offset=0;
    for(let i=0;i<2040;i++){
      assert(offset+20<=buffer.length,'short desktop strip');const n=buffer.readUInt16LE(offset)+2;
      assert(n>=20&&n%4===0&&offset+n<=buffer.length,'invalid desktop strip length');
      const s=buffer.subarray(offset,offset+n);
      assert(s.readUInt16LE(2)===0x2801&&s.readUInt16LE(4)===(i%30)*64&&s.readUInt16LE(6)===Math.floor(i/30)*16,'invalid desktop strip coordinates');
      strips.push(s);offset+=n;
    }
    assert.equal(offset,buffer.length,'trailing desktop data');
    const repacked=!this.entries||strips.some((s,i)=>s.length>this.entries[i].capacity);
    if(repacked){
      // Slack keeps a moving cursor or changing text inside its existing slot.
      // Dense images fall back to tighter allocation within the measured bank.
      const alignment=[256,128,64,4].find(a=>strips.reduce((n,s)=>n+Math.ceil(s.length/a)*a,0)<=BANK_SIZE-0x24b0);
      assert(alignment,'compressed desktop exceeds video memory');let address=this.bank+0x24b0;
      this.entries=strips.map(s=>{const e={address,capacity:Math.ceil(s.length/alignment)*alignment,data:null};address+=e.capacity;return e;});
    }
    const records=[];let changed=0;
    strips.forEach((s,i)=>{
      const entry=this.entries[i];if(entry.data&&entry.data.equals(s))return;
      changed++;
      for(let n=0;n<s.length;n+=3600)records.push(memory(0x80,entry.address+n,s.subarray(n,n+3600)));
      entry.data=Buffer.from(s);
    });
    const tableAddress=this.bank+112;
    if(repacked){
      const table=words([this.bank,this.bank+28,...this.entries.map(e=>e.address)],4);
      for(let n=0;n<table.length;n+=3600)records.push(memory(0x180,tableAddress+n,table.subarray(n,n+3600)));
    }
    records.push(...commit(tableAddress,8168));
    return {packets:packets(records),changedStrips:changed,repacked};
  }
}
function simple(id, sub, payload = Buffer.alloc(0)) {
  const b = crypto.randomBytes(Math.ceil((id + 2) / 16) * 16);
  b.fill(0, 0, 22); b.writeUInt16LE(id); b.writeUInt16LE(sub, 2); payload.copy(b, 22);
  return b;
}
async function startVideo(io, connector, report = () => {}) {
  const {cp} = connector;
  const send = (id, sub, p = []) => cp.send(simple(id, sub, Buffer.from(p)), (16 - (id + 2) % 16) % 16);
  for (let n = 0; n <= 20; n++) await send(0x18, 0x48, [n,0,0,0]);
  for (const [id,sub,p] of [[0x16,0x57,[0,1]],[0x15,7,[1]],[0x14,0],
    [0x15,0x20,[0]],[0x15,0x21,[0]],[0x16,0x23,[0,0]],[0x14,0xc],[0x14,0xc],
    [0x18,0x48,[20,0,0,0]],[0x18,0x48,[19,0,0,0]],[0x15,0x53,[1]]]) await send(id,sub,p);
  for (let n = 0; n < 9; n++) await send(0x14,0xc);
  // Measured 1920x1080/60 timing, stride and allocation for Firefly, not a
  // generic DL3 profile. The final six bytes are a fresh per-message token.
  const timing = Buffer.from('000200008007180158002c0038042d000400050000073c000008000200000000000000008000ff000000000000080002023a0000','hex');
  await cp.send(simple(0x48,0x22,timing),6);
  for (const [id,sub,p] of [[0x16,0x2f,[0,1]],[0x16,0x2e,[0,3]],[0x16,0x2f,[0,1]],
    [0x14,0xc],[0x16,0x2e,[0,3]],[0x16,0x2f,[0,1]],[0x16,0x2e,[0,0]]]) await send(id,sub,p);
  let sequence = 0;
  async function video(body) {
    const pad = (16 - body.length % 16) % 16;
    const padded = Buffer.concat([body, crypto.randomBytes(pad)]);
    const f = seal(connector.key, connector.nonce, sequence, pad, padded);
    f.writeUInt16LE(8,8); sequence += padded.length / 16; await io.write(f);
  }
  await video(words([4,0x408,2]));
  const config = configuration(); await video(config.writes);
  await io.write(frame(2,0,0,0,Buffer.alloc(16)));
  for (const p of packets([memory(0x180,0x210,words(config.pointers,4)), ...commit(0x210,24,0x381)])) await io.write(p);
  for (let n = 0; n < 9; n++) await send(0x14,0xc);
  report('own video decoder configured');
  let first = true;const banks=new Map(),configuredBanks=new Set();
  return {
    async display(bank, pixel) {
      if(!configuredBanks.has(bank)){
        await video(Buffer.concat([memory(0x80,bank,mode()), memory(0x80,bank+28,quantizer())]));configuredBanks.add(bank);
      }
      let encoded,changedStrips=2040;
      if(Buffer.isBuffer(pixel)){
        if(!banks.has(bank))banks.set(bank,new DesktopBank(bank));
        const update=banks.get(bank).frame(pixel);encoded=update.packets;changedStrips=update.changedStrips;
      }else encoded=solidFrame(bank,pixel);
      // Preserve protocol frames while batching USB writes below the observed
      // 64 KiB transfer size. No replayed desktop pixels are used.
      for (let i = 0; i < encoded.length; i += 12) await io.write(Buffer.concat(encoded.slice(i,i+12)));
      if (first) { await send(0x16,0x2f,[0,0]); first = false; }
      const statistics={bank,bytes:encoded.reduce((s,b)=>s+b.length,0),changedStrips};
      report('own frame submitted',statistics);return statistics;
    },
    poll: () => send(0x14,0xc),
  };
}
module.exports = {words,tlv,memory,mode,configuration,quantizer,commit,packets,Bits,solidStrip,solidFrame,desktopFrame,DesktopBank,startVideo};
