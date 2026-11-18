// JavaScriptCore has no browser TextEncoder. Encode the normalized BIP39 passphrase
// as UTF-8. Invalid UTF-16 fails closed through encodeURIComponent.
if (typeof globalThis.TextEncoder === 'undefined') {
  globalThis.TextEncoder = class {
    encode(input = '') {
      const bytes = encodeURIComponent(input).replace(/%([\dA-F]{2})/g, (_, hex) =>
        String.fromCharCode(parseInt(hex, 16)));
      return Uint8Array.from(bytes, byte => byte.charCodeAt(0));
    }
  };
}
