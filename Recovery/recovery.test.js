import assert from 'node:assert/strict';
import test from 'node:test';
import { myMonero, exodus } from './recovery.js';

const myPhrase = 'slid otherwise jeers lurk swung tawny zodiac tusks twang cajun swagger peaches tawny';
const cakePhrase = 'color ranch color remove subway public water embrace before begin liberty fault';

test('MyMonero public address and both private keys match the upstream example', () => {
  assert.deepEqual(myMonero(myPhrase), {
    address: '48VWHdLTEpE5dqa5VpAy5xgQWBHZARiGmEmojNLqD4ef1FAzkPxCe9JXUYwCShRR5XNMGnyusrnkmMWr2HMdfDRx2vsrG7c',
    spend: '804f08b84507fb0610910d04ae517c07ae2f38f9330e42e86a50286db16ad60e',
    view: 'dbb024c981cf7dc797593713f5f426c3b1cad50542c0814d4786e12e768be504'
  });
});

test('BIP39 conversion matches the independent Cake account-zero vector', () => {
  const standard = 'somewhere problems gauze gigantic intended foxes upcoming saved waffle pipeline lurk bogeys empty wipeout abbey italics novelty tucks rafts elite lunar obnoxious awful bugs elite';
  assert.equal(exodus(cakePhrase, ''), standard);
  assert.notEqual(exodus(cakePhrase, 'passphrase'), standard);
  assert.equal(exodus(cakePhrase, 'é'), exodus(cakePhrase, 'e\u0301'));
});

test('bad checksums reject both formats', () => {
  assert.throws(() => myMonero(myPhrase.replace(/tawny$/, 'peaches')));
  assert.throws(() => exodus(cakePhrase.replace(/fault$/, 'color'), ''));
});
