/**
 * COS 直传：把文件从小程序直接送到对象存储，不经过我们的服务器中转。
 *
 * 三步：换票（presign）→ 传文件（wx.uploadFile 到 COS）→ 落库（commit）。
 *
 * 为什么要绕这一圈：100 MB 的视频先传到 CVM 再转 COS，等于付两次上行带宽，
 * 弱网下还更容易超时。直传之后 CVM 只经手几百字节的票据。
 *
 * 关键点：**任何一步失败都直接抛错**，由调用方回退到「经后端中转」的老路径。
 * 直传是优化而不是唯一通路 —— 签名过期、COS 域名没进白名单、运营商劫持，
 * 任何一种都不该让用户传不了照片。
 */

const { request } = require('./request');
const { snapshot, assertCurrent } = require('./session');

// 服务端明确说「这个部署不支持直传」（本地磁盘存储）。一次就够，别每个文件
// 都去问一遍 —— 升级前答案不会变。
let directDisabled = false;

/** 直传是否已被判定为不可用（供调用方跳过、不给用户无谓的等待）。 */
function isDirectDisabled() {
  return directDisabled;
}

/**
 * 探测文件的真实类型与尺寸。
 *
 * 直传的服务端看不到字节，content_type 只能由我们声明，而这个声明会被写进
 * 签名（改不了）和对象元数据。照片走 `wx.getImageInfo`，顺带拿到宽高 ——
 * App 那边的布局要用；拿不到就按扩展名猜，猜错最多是元数据类型不准。
 *
 * @returns {Promise<{contentType: string, width: number, height: number}>}
 */
function probeMedia(filePath, kind) {
  if (kind === 'video') {
    return Promise.resolve({
      contentType: /\.mov$/i.test(filePath || '') ? 'video/quicktime' : 'video/mp4',
      width: 0,
      height: 0,
    });
  }

  return new Promise((resolve) => {
    wx.getImageInfo({
      src: filePath,
      success(info) {
        resolve({
          contentType: contentTypeOf(info.type) || guessByPath(filePath),
          width: info.width || 0,
          height: info.height || 0,
        });
      },
      fail() {
        resolve({ contentType: guessByPath(filePath), width: 0, height: 0 });
      },
    });
  });
}

const IMAGE_TYPES = {
  jpeg: 'image/jpeg',
  jpg: 'image/jpeg',
  png: 'image/png',
  gif: 'image/gif',
  webp: 'image/webp',
  heic: 'image/jpeg', // 服务端不支持 heic，按 jpeg 送，反正会被拒绝得明明白白
};

function contentTypeOf(type) {
  return IMAGE_TYPES[String(type || '').toLowerCase()] || '';
}

/** getImageInfo 拿不到 type 时的兜底：看扩展名，再兜到 jpeg。 */
function guessByPath(path) {
  const lower = String(path || '').toLowerCase();
  if (/\.png$/.test(lower)) return 'image/png';
  if (/\.webp$/.test(lower)) return 'image/webp';
  if (/\.gif$/.test(lower)) return 'image/gif';
  if (/\.mov$/.test(lower)) return 'video/quicktime';
  if (/\.mp4$/.test(lower)) return 'video/mp4';
  return 'image/jpeg';
}

/** 把文件 POST 到 COS。票据里已经签死了 key / 类型 / 大小 / ACL。 */
function postToCos(ticket, filePath, onProgress) {
  return new Promise((resolve, reject) => {
    const task = wx.uploadFile({
      url: ticket.url,
      filePath: filePath,
      name: ticket.file_field || 'file',
      // 票据字段必须在 file 之前 —— 微信把 file 放在最后，正合 COS 的要求。
      formData: ticket.fields || {},
      // 刻意不带头：COS 要的是票据里的签名，多一个 Authorization 反而添乱。
      timeout: 120000,
      success(res) {
        // success_action_status=200：COS 成功就回 200，body 无关紧要。
        if (res.statusCode === 200) {
          resolve(res.data);
          return;
        }
        const error = new Error(`上传失败（${res.statusCode}）`);
        error.code = 'COS_UPLOAD_FAILED';
        error.statusCode = res.statusCode;
        reject(error);
      },
      fail(err) {
        const error = new Error('上传到存储失败，请检查网络后重试');
        error.code = 'NETWORK_ERROR';
        error.raw = err;
        reject(error);
      },
    });

    if (task && typeof task.onProgressUpdate === 'function' && typeof onProgress === 'function') {
      task.onProgressUpdate((r) => onProgress(r || {}));
    }
  });
}

/**
 * 直传一个附件，resolve 后拿到服务端落库的媒体对象。
 *
 * @param {object} o {familyId, memoryId, filePath, clientId, kind,
 *                    durationMs, onProgress}
 * @throws 任一步失败都抛错；501 会顺手把直传标记为不可用。
 */
async function uploadDirect(o) {
  const scope = o.sessionScope || snapshot();
  assertCurrent(scope);
  if (directDisabled) throw new Error('直传不可用');

  const base = `/families/${o.familyId}/plugins/memory/memories/${o.memoryId}/media`;
  const probe = await probeMedia(o.filePath, o.kind);
  assertCurrent(scope);

  let ticket;
  try {
    ticket = await request({
      sessionScope: scope,
      url: `${base}/presign`,
      method: 'POST',
      data: {
        content_type: probe.contentType,
        client_id: o.clientId || undefined,
      },
    });
  } catch (e) {
    // 501 是部署层面的能力问题，不是这一次上传的偶发失败。
    if (e.statusCode === 501) directDisabled = true;
    throw e;
  }

  await postToCos(ticket, o.filePath, o.onProgress);
  assertCurrent(scope);

  const body = {
    media_id: ticket.media_id,
    key: ticket.key,
    content_type: probe.contentType,
  };
  if (o.kind === 'video' && o.durationMs) body.duration_ms = o.durationMs;
  if (o.kind === 'photo' && probe.width && probe.height) {
    body.width = probe.width;
    body.height = probe.height;
  }
  return request({ url: `${base}/commit`, method: 'POST', data: body, sessionScope: scope });
}

module.exports = { uploadDirect, isDirectDisabled, probeMedia };
