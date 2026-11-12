// keccak256 for the passbook, so it can check a signed raise request without a library or a server.
// Plain Keccak-f[1600] with 64-bit lanes as BigInt; checked against `cast keccak` (see README).
const RC = [0x1n, 0x8082n, 0x800000000000808an, 0x8000000080008000n, 0x808bn, 0x80000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x8an, 0x88n, 0x80008009n, 0x8000000an, 0x8000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x800an, 0x800000008000000an, 0x8000000080008081n, 0x8000000000008080n, 0x80000001n, 0x8000000080008008n];
const ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]; // ROT[x][y]
const M = (1n << 64n) - 1n;
const rol = (v, n) => (n ? ((v << BigInt(n)) | (v >> BigInt(64 - n))) & M : v);

/** @param {Uint8Array} bytes @returns {string} 0x-prefixed 32-byte hash */
export function keccak256(bytes) {
  const rate = 136, p = new Uint8Array(Math.ceil((bytes.length + 1) / rate) * rate);
  p.set(bytes); p[bytes.length] ^= 0x01; p[p.length - 1] ^= 0x80;
  const s = Array(25).fill(0n); // lane (x, y) lives at s[x + 5y]
  for (let o = 0; o < p.length; o += rate) {
    for (let i = 0; i < rate / 8; i++) { let w = 0n; for (let b = 7; b >= 0; b--) w = (w << 8n) | BigInt(p[o + i * 8 + b]); s[i] ^= w; }
    for (let r = 0; r < 24; r++) {
      const C = [0, 1, 2, 3, 4].map((x) => s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20]);
      for (let x = 0; x < 5; x++) { const D = C[(x + 4) % 5] ^ rol(C[(x + 1) % 5], 1); for (let y = 0; y < 25; y += 5) s[x + y] ^= D; }
      const B = Array(25);
      for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) B[y + 5 * ((2 * x + 3 * y) % 5)] = rol(s[x + 5 * y], ROT[x][y]);
      for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) s[x + 5 * y] = B[x + 5 * y] ^ (~B[((x + 1) % 5) + 5 * y] & M & B[((x + 2) % 5) + 5 * y]);
      s[0] ^= RC[r];
    }
  }
  let hex = "0x";
  for (let i = 0; i < 4; i++) for (let b = 0; b < 8; b++) hex += ((s[i] >> BigInt(8 * b)) & 0xffn).toString(16).padStart(2, "0");
  return hex;
}
