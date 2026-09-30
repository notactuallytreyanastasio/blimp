// node --test chunks/lang/web/test/*.test.js -- the P-256 and AES-128-GCM
// builtins in blimp.wasm give the answers the native build gives: RFC 8291's
// ECDH secret, the GCM spec's test case 4, and a signature node's own
// crypto accepts. p256_keypair has no entropy there and says so.
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const Blimp = require('../blimp.js');
const WASM = fs.readFileSync(path.join(__dirname, '..', 'blimp.wasm'));
const load = () => new Blimp().init(WASM);

const AS_PRIVATE = 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw';
const UA_PUBLIC = 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4';

test('p256_ecdh in wasm is the RFC 8291 ecdh_secret', async () => {
  const b = await load();
  const r = b.eval(`base64url_encode(p256_ecdh(base64url_decode("${AS_PRIVATE}"), base64url_decode("${UA_PUBLIC}")))`);
  assert.ok(r.ok, r.error);
  assert.strictEqual(r.value, '"kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs"');
});

test('aes128gcm_encrypt in wasm is GCM test case 4', async () => {
  const b = await load();
  const r = b.eval('hex_encode(aes128gcm_encrypt(hex_decode("feffe9928665731c6d6a8f9467308308"), hex_decode("cafebabefacedbaddecaf888"), hex_decode("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39"), hex_decode("feedfacedeadbeeffeedfacedeadbeefabaddad2")))');
  assert.ok(r.ok, r.error);
  assert.strictEqual(r.value, '"42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e0915bc94fbc3221a5db94fae95ae7121a47"');
});

test('a signature made in wasm verifies in node', async () => {
  const b = await load();
  const r = b.eval(`base64url_encode(ecdsa_p256_sign(base64url_decode("${AS_PRIVATE}"), "header.claims")) ++ " " ++ base64url_encode(p256_public_key(base64url_decode("${AS_PRIVATE}")))`);
  assert.ok(r.ok, r.error);
  const [sig, pub] = JSON.parse(r.value).split(' ');
  const p = Buffer.from(pub, 'base64url');
  const key = crypto.createPublicKey({
    key: { kty: 'EC', crv: 'P-256', x: p.subarray(1, 33).toString('base64url'), y: p.subarray(33).toString('base64url') },
    format: 'jwk',
  });
  assert.ok(crypto.verify('sha256', Buffer.from('header.claims'), { key, dsaEncoding: 'ieee-p1363' }, Buffer.from(sig, 'base64url')));
});

test('a wrong-length key in wasm names the argument', async () => {
  const b = await load();
  const r = b.eval('aes128gcm_encrypt("short", "0123456789ab", "p", "")');
  assert.ok(!r.ok);
  assert.match(r.error, /aes128gcm_encrypt: key must be 16 bytes, got 5/);
});

test('p256_keypair in wasm fails loudly instead of making a guessable key', async () => {
  const b = await load();
  const r = b.eval('p256_keypair()');
  assert.ok(!r.ok);
  assert.match(r.error, /NotSupported/);
});
