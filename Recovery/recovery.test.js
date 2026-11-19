import assert from 'node:assert/strict';
import test from 'node:test';
import { myMonero, exodus } from './recovery.js';
import { entropyToMnemonic } from '@scure/bip39';
import { wordlist as japanese } from '@scure/bip39/wordlists/japanese.js';

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


test('BIP39 imports the ten standard dictionaries, including Japanese ideographic spaces', async () => {
  for (const language of ['english', 'czech', 'french', 'italian', 'japanese', 'korean', 'portuguese', 'simplified-chinese', 'spanish', 'traditional-chinese']) {
    const { wordlist } = await import(`@scure/bip39/wordlists/${language}.js`);
    const mnemonic = entropyToMnemonic(new Uint8Array(16), wordlist);
    assert.equal(exodus(mnemonic, '').split(' ').length, 25, language);
  }
  const words = entropyToMnemonic(new Uint8Array(16), japanese);
  assert.equal(exodus(words, ''), exodus(words.normalize('NFC').replace(/\s+/gu, '　'), ''));
});


// Public 16-byte test seed from MyMonero's upstream tests. Each full phrase
// was encoded and decoded with its independently published WebAssembly client.
test('MyMonero restores the same public address across its twelve active dictionaries', () => {
  const phrases = {
    "Chinese (simplified)": "官 臣 创 景 烧 积 访 近 通 须 念 腾 通",
    "English": "foxes selfish humid nexus juvenile dodge pepper ember biscuit elapse jazz vibrate biscuit",
    "Dutch": "gegraaid skylab infecteer nihiliste kraneveld educatie pepmiddel ethicus botanicus erven klijnhout wegscheer botanicus",
    "French": "faible relever gronder neige jury corps peinture divan bondir diluer inviter tripe relever",
    "Spanish": "curva niñez espía inútil forzar canto lote cine átomo ciclón fiera pulso inútil",
    "German": "Erde Panik Floß Kanal Gespan Cartoon liefern Dohle Barbar Dickicht Gedanke Unart Cartoon",
    "Italian": "dorso rituale follia molecola gruppo cetriolo patriota cornice barato consegna giappone umore consegna",
    "Portuguese": "exaustor rafia gorro mavioso imbuzeiro debutantes obnoxio eclusa bicuspide duodeno hutu urupe hutu",
    "Japanese": "くめる つぶす こせい せおう さとおや がいらい たいえき ぎじたいけん うなじ きこう ざいたく のぼる くめる",
    "Russian": "иголка сугроб ландшафт отвечать миссия данные работа дуэт ванная дудка мазать шапка дуэт",
    "Esperanto": "eskapi poviga gliti lavejo iafoje dieto naiva efloreski bapti ecigi higieno unco poviga",
    "Lojban": "jarco stagi kesri panka lindi divzi rijno fliba citri finti lalxu zviki panka"
};
  const expected = '43zxvpcj5Xv9SEkNXbMCG7LPQStHMpFCQCmkmR4u5nzjWwq5Xkv5VmGgYEsHXg4ja2FGRD5wMWbBVMijDTqmmVqm93wHGkg';
  for (const [language, phrase] of Object.entries(phrases)) {
    assert.equal(myMonero(phrase).address, expected, language);
  }
  assert.equal(myMonero(phrases.Spanish.normalize('NFD')).address, expected);
  assert.equal(myMonero(phrases.Japanese.replaceAll(' ', '　')).address, expected);
  const german = phrases.German.toLowerCase();
  assert.equal(myMonero(german).address, expected);
  assert.throws(() => myMonero(german.replace(/[^ ]+$/, 'erde')));
  assert.throws(() => myMonero(phrases.English.replace('foxes', 'fox')));
});

test('historical EnglishOld phrases use MyMonero’s duplicate-prefix index semantics', () => {
  // The upstream decoder retains the final word at a colliding four-letter prefix.
  const phrase = 'rip stir regret spider release blind sail drink mother corner movie drama sail';
  assert.equal(myMonero(phrase).address, '42Sg2PX2DWNUdWhJYizLDrdea2a95CYRRNXirLzMdLLcLGg4NzaoFEG1G5RH2D8YHuCRzRmacvKMv2fTFMDtSBXb2Ef6vje');
});
