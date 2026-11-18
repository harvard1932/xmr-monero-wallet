import './encoding.js';
import { HDKey } from '@scure/bip32';
import { mnemonicToSeedSync, validateMnemonic } from '@scure/bip39';
import { wordlist as bip39English } from '@scure/bip39/wordlists/english.js';
import { base58xmr } from '@scure/base';
import { ed25519 } from '@noble/curves/ed25519.js';
import { bytesToNumberLE, numberToBytesLE } from '@noble/curves/utils.js';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex, concatBytes } from '@noble/hashes/utils.js';
import english from './monero-english.json' with { type: 'json' };

const index = new Map(english.map((word, i) => [word, i]));
const { Point } = ed25519;

function checksumWord(words) {
  // Monero English uses CRC-32 of the concatenated three-letter prefixes.
  let crc = 0xffffffff;
  for (const ch of words.map(word => word.slice(0, 3)).join('')) {
    crc ^= ch.charCodeAt(0);
    for (let bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
  }
  return words[((crc ^ 0xffffffff) >>> 0) % words.length];
}

function decodeMyMonero(phrase) {
  const all = phrase.split(' ');
  const words = all.slice(0, 12);
  if (all.length !== 13 || !words.every(word => index.has(word)) || checksumWord(words) !== all[12]) {
    throw new Error('Invalid MyMonero phrase.');
  }
  const entropy = new Uint8Array(16);
  const data = new DataView(entropy.buffer);
  const n = english.length;
  for (let i = 0; i < 4; i++) {
    const [a, b, c] = words.slice(i * 3, i * 3 + 3).map(word => index.get(word));
    const value = a + n * ((b - a + n) % n) + n * n * ((c - b + n) % n);
    if (value > 0xffffffff) throw new Error('Invalid MyMonero entropy.');
    data.setUint32(i * 4, value, true);
  }
  return entropy;
}

function scalar(bytes) {
  const reduced = Point.Fn.create(bytesToNumberLE(bytes));
  if (reduced === 0n) throw new Error('Invalid recovery key.');
  return reduced;
}

export function myMonero(phrase) {
  const entropy = decodeMyMonero(phrase);
  const spendHash = keccak_256(entropy);
  // MyMonero hashes the original, unreduced spend hash to obtain its view key.
  const viewHash = keccak_256(spendHash);
  const spend = scalar(spendHash);
  const view = scalar(viewHash);
  const payload = concatBytes(Uint8Array.of(18), Point.BASE.multiply(spend).toBytes(), Point.BASE.multiply(view).toBytes());
  const address = base58xmr.encode(concatBytes(payload, keccak_256(payload).subarray(0, 4)));
  entropy.fill(0); spendHash.fill(0); viewHash.fill(0);
  return { address, spend: bytesToHex(numberToBytesLE(spend, 32)), view: bytesToHex(numberToBytesLE(view, 32)) };
}

export function exodus(phrase, passphrase) {
  if (!validateMnemonic(phrase, bip39English)) throw new Error('Invalid English BIP39 mnemonic.');
  const seed = mnemonicToSeedSync(phrase, passphrase);
  const root = HDKey.fromMasterSeed(seed);
  const child = root.derive("m/44'/128'/0'/0/0");
  let reduced;
  try {
    reduced = numberToBytesLE(scalar(child.privateKey), 32);
    const data = new DataView(reduced.buffer, reduced.byteOffset, reduced.byteLength);
    const words = [];
    const n = english.length;
    for (let i = 0; i < 8; i++) {
      const value = data.getUint32(i * 4, true);
      const a = value % n;
      const b = (Math.floor(value / n) + a) % n;
      const c = (Math.floor(value / (n * n)) + b) % n;
      words.push(english[a], english[b], english[c]);
    }
    words.push(checksumWord(words));
    return words.join(' ');
  } finally {
    seed.fill(0); reduced?.fill(0);
    root.wipePrivateData(); child.wipePrivateData();
  }
}
