// tunnel-pico-bot — minimal ZIP entry extractor (Node, zero dependencies).
// Fallback for hosts with neither unzip nor python3 (e.g. slim Node images).
// Usage: node unzip.js <zipfile> <entry-name> <output-file>
// Supports method 0 (stored) and 8 (deflate) — all the official xray
// release zips use. Extracts exactly one named entry.
'use strict';
const fs = require('fs');
const zlib = require('zlib');

const [, , zipPath, entryName, outPath] = process.argv;
if (!zipPath || !entryName || !outPath) {
  console.error('usage: node unzip.js <zipfile> <entry> <output>');
  process.exit(2);
}
const buf = fs.readFileSync(zipPath);

// --- locate End Of Central Directory ------------------------------------
let eocd = -1;
for (let i = buf.length - 22; i >= Math.max(0, buf.length - 22 - 65536); i--) {
  if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
}
if (eocd < 0) { console.error('unzip.js: no EOCD'); process.exit(1); }
const cdCount = buf.readUInt16LE(eocd + 10);
let p = buf.readUInt32LE(eocd + 16);

// --- walk the central directory for the entry ----------------------------
let found = null;
for (let n = 0; n < cdCount; n++) {
  if (buf.readUInt32LE(p) !== 0x02014b50) break;
  const method = buf.readUInt16LE(p + 10);
  const compSize = buf.readUInt32LE(p + 20);
  const nameLen = buf.readUInt16LE(p + 28);
  const extraLen = buf.readUInt16LE(p + 30);
  const commentLen = buf.readUInt16LE(p + 32);
  const localOff = buf.readUInt32LE(p + 42);
  const name = buf.toString('utf8', p + 46, p + 46 + nameLen);
  if (name === entryName) { found = { method, compSize, localOff }; break; }
  p += 46 + nameLen + extraLen + commentLen;
}
if (!found) { console.error(`unzip.js: entry ${entryName} not found`); process.exit(1); }

// --- read the local header, then the data --------------------------------
const lp = found.localOff;
if (buf.readUInt32LE(lp) !== 0x04034b50) { console.error('unzip.js: bad local header'); process.exit(1); }
const lNameLen = buf.readUInt16LE(lp + 26);
const lExtraLen = buf.readUInt16LE(lp + 28);
const dataStart = lp + 30 + lNameLen + lExtraLen;
const data = buf.subarray(dataStart, dataStart + found.compSize);

let out;
if (found.method === 0) out = data;
else if (found.method === 8) out = zlib.inflateRawSync(data);
else { console.error(`unzip.js: unsupported method ${found.method}`); process.exit(1); }

fs.writeFileSync(outPath, out);
