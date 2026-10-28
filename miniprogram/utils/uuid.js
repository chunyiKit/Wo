// 客户端幂等键（UUID v4）。
//
// 后端创建回忆 / 上传媒体时接受一个 `client_id`：服务端把它**直接当成资源 id**，
// 同一个 client_id 的重复提交会返回第一次创建的资源，而不是再建一份。这是
// 「保存失败后原地重试不产生重复数据」的关键 —— 前提是客户端在重试时用同一个
// 键，所以它由这里生成一次、随请求重试保持不变。
//
// 用 Math.random 而非 crypto.getRandomValues：client_id 只用于去重复，不参与
// 任何安全判定；且小程序基础库在部分运行环境里并不暴露 crypto。有 crypto 时
// 优先用它，纯属顺手。
const HEX_LEN = 16;

function randomBytes(n) {
  const out = new Array(n);
  const c = typeof globalThis !== 'undefined' ? globalThis.crypto : null;
  if (c && typeof c.getRandomValues === 'function') {
    const buf = new Uint8Array(n);
    c.getRandomValues(buf);
    for (let i = 0; i < n; i += 1) out[i] = buf[i];
    return out;
  }
  for (let i = 0; i < n; i += 1) out[i] = Math.floor(Math.random() * 256);
  return out;
}

/** RFC 4122 v4 UUID，形如 `019e6f2a-……`。 */
function uuidV4() {
  const b = randomBytes(HEX_LEN);
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10x
  const hex = Array.from(b, (v) => v.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

module.exports = { uuidV4 };
