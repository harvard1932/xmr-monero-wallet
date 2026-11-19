import './encoding.js';
import { HDKey } from '@scure/bip32';
import { mnemonicToSeedSync, validateMnemonic } from '@scure/bip39';
import { wordlist as bip39English } from '@scure/bip39/wordlists/english.js';
import { wordlist as czech } from '@scure/bip39/wordlists/czech.js';
import { wordlist as french } from '@scure/bip39/wordlists/french.js';
import { wordlist as italian } from '@scure/bip39/wordlists/italian.js';
import { wordlist as japanese } from '@scure/bip39/wordlists/japanese.js';
import { wordlist as korean } from '@scure/bip39/wordlists/korean.js';
import { wordlist as portuguese } from '@scure/bip39/wordlists/portuguese.js';
import { wordlist as simplifiedchinese } from '@scure/bip39/wordlists/simplified-chinese.js';
import { wordlist as spanish } from '@scure/bip39/wordlists/spanish.js';
import { wordlist as traditionalchinese } from '@scure/bip39/wordlists/traditional-chinese.js';
import { base58xmr } from '@scure/base';
import { ed25519 } from '@noble/curves/ed25519.js';
import { bytesToNumberLE, numberToBytesLE } from '@noble/curves/utils.js';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex, concatBytes } from '@noble/hashes/utils.js';
import english from './monero-english.json' with { type: 'json' };

import myMoneroLanguages from './mymonero-languages.json' with { type: 'json' };
const { Point } = ed25519;
// Match the upstream decoder's order for words shared by multiple languages.
const { chinese_simplified, ...remainingMyMoneroLists } = myMoneroLanguages;
const myMoneroLists = [chinese_simplified, { words: english, prefix: 3 }, ...Object.values(remainingMyMoneroLists)];

function prefix(word, length) {
  return Array.from(word).slice(0, length).join('');
}

function checksumWord(words, prefixLength = 3) {
  // CRC-32 covers UTF-8 bytes of the dictionary's canonical prefixes.
  let crc = 0xffffffff;
  const bytes = new TextEncoder().encode(words.map(word => prefix(word, prefixLength)).join(''));
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
  }
  return words[((crc ^ 0xffffffff) >>> 0) % words.length];
}

function decodeMyMonero(phrase) {
  const input = phrase.normalize('NFC').trim().toLowerCase().split(/\s+/u);
  if (input.length !== 13) throw new Error('Invalid MyMonero phrase.');
  for (const list of myMoneroLists) {
    const byWord = new Map(list.words.map((word, i) => [word.toLowerCase(), i]));
    if (!input.every(word => byWord.has(word))) continue;
    const canonical = input.map(word => list.words[byWord.get(word)]);
    const checksum = checksumWord(canonical.slice(0, 12), list.prefix).toLowerCase();
    if (prefix(checksum, list.prefix) !== prefix(input[12], list.prefix)) continue;
    // EnglishOld contains duplicate prefixes. MyMonero's own trimmed map
    // retains the last index. Match it even when the owner enters full words.
    const byPrefix = new Map(list.words.map((word, i) => [prefix(word.toLowerCase(), list.prefix), i]));
    const indices = input.slice(0, 12).map(word => byPrefix.get(prefix(word, list.prefix)));
    return decodeTriplets(indices, list.words.length);
  }
  throw new Error('Invalid MyMonero phrase.');
}

function decodeTriplets(indices, n) {
  const entropy = new Uint8Array(16);
  const data = new DataView(entropy.buffer);
  for (let i = 0; i < 4; i++) {
    const [a, b, c] = indices.slice(i * 3, i * 3 + 3);
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
  phrase = phrase.normalize('NFKD').trim().split(/\s+/u).join(' ');
  const dictionaries = [bip39English, czech, french, italian, japanese, korean, portuguese, simplifiedchinese, spanish, traditionalchinese];
  if (!dictionaries.some(list => validateMnemonic(phrase, list))) throw new Error('Invalid BIP39 mnemonic or checksum.');
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
