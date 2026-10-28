// 首页插件卡片墙 —— 与 App 首页同源：都渲染 /me/bootstrap 的 installed_plugins。
//
// 布局口径对齐 App（lib/features/home/home_page.dart）：
//   · 4 列网格，卡片跨 cw 列、ch 行，两者都 clamp 到 1..4
//   · ch<=1 是「矮卡」：横向排布，只显示 primary + secondary
//   · 卡片底色 = color_token 16% 叠白（见 utils/theme.js）
//
// 刷新口径（AGENTS.md：列表页增改后不能「闪一下」）：
//   `_first` 只驱动首屏 loading；之后 onShow / 下拉刷新都是**就地替换** cards，
//   卡片墙全程在屏，不会退化成转圈。只有首屏失败后的「重试」才回到 loading。
//
// 封面（回忆卡右侧/整卡的图片轮播）：
//   后端 preview.image_urls 给的是 `/raw` 代理地址，<image> 发不出 Authorization，
//   所以拿到手还只是「哪几张」的清单；真正能加载的预签名直链由 media-url.js
//   一次批量换回。图比文字慢，因此不阻塞首屏 —— 文字先上，图到了再补丁。
const { toCards } = require('../../utils/card-view');
const { memoryMediaUrls } = require('../../utils/media-url');

/** 两张照片序列是否完全一致（用于避免每次 onShow 都白跑一次渲染）。 */
function samePhotos(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i].id !== b[i].id || a[i].url !== b[i].url) return false;
  }
  return true;
}

const app = getApp();

Page({
  data: {
    loading: true,
    error: '',
    empty: false,
    familyName: '',
    memberCount: 0,
    cards: [],
  },

  onLoad() {
    this._loaded = false;
    this.load({ first: true });
  },

  onShow() {
    // 首屏交给 onLoad；之后每次回到前台静默刷新（如 App 里刚装了新插件）。
    if (this._loaded) this.load({ first: false });
  },

  async onPullDownRefresh() {
    await this.load({ first: false });
    wx.stopPullDownRefresh();
  },

  /**
   * @param {object} o  first=true 时显示首屏 loading；false 为静默刷新。
   */
  async load(o) {
    const first = !!(o && o.first);
    if (first) this.setData({ loading: true, error: '' });

    try {
      const data = await app.loadBootstrap();
      const family = data.current_family || app.globalData.family || null;
      const familyId = family ? family.id : '';
      const cards = toCards(data.installed_plugins, familyId);

      // 静默刷新时先把上一轮的图接回新对象上。否则一次 setData 换掉 cards，
      // 图片会白一帧再被补丁填回来 —— 正是 AGENTS.md 里禁止的「闪一下」。
      const prevPhotos = {};
      this.data.cards.forEach((c) => {
        if (c && c.photos && c.photos.length) prevPhotos[c.pluginId] = c.photos;
      });
      cards.forEach((c) => {
        const kept = prevPhotos[c.pluginId];
        // 只接同一批照片：家庭/回忆变了就该换新图，不能拿旧图凑数。
        if (kept && kept.length && c.photoIds.indexOf(kept[0].id) >= 0) c.photos = kept;
      });

      this.setData({
        loading: false,
        error: '',
        empty: cards.length === 0,
        familyName: family ? family.name : '',
        memberCount: family ? family.member_count || 0 : 0,
        cards: cards,
      });
      this._loaded = true;

      // 不 await：首屏文字不该等图片。失败也只是少一张封面，文字照常可读。
      this.loadCovers(cards, familyId);
    } catch (e) {
      // 静默刷新失败：保留旧数据，只在首屏失败时才露出错误态。
      if (first) {
        this.setData({ loading: false, error: e.message || '加载失败' });
      }
    }
  },

  onRetry() {
    this.load({ first: true });
  },

  /**
   * 把所有卡的封面 id 收成一批，一次换回预签名直链再逐卡回填。
   *
   * 为什么合并成一次：一张卡最多 5 张图，首页可能有多张带图卡；逐卡请求就是
   * 一次请求风暴。media-url.js 里还有按过期时间的缓存，回到首页基本零请求。
   */
  async loadCovers(cards, familyId) {
    if (!familyId) return;
    const wanted = [];
    cards.forEach((c) => {
      (c.photoIds || []).forEach((id) => {
        if (wanted.indexOf(id) < 0) wanted.push(id);
      });
    });
    if (!wanted.length) return;

    let urls = {};
    try {
      const r = await memoryMediaUrls(familyId, wanted);
      urls = r.urls || {};
    } catch (e) {
      return; // 换不到就保持文字卡，不打扰用户
    }

    const patch = {};
    cards.forEach((c, i) => {
      const photos = (c.photoIds || [])
        .map((id) => ({ id: id, url: urls[id] }))
        .filter((p) => !!p.url);
      if (!photos.length) return;
      const now = this.data.cards[i];
      // 期间如果 cards 已被新一轮刷新换掉，按 pluginId 找它的新位置，
      // 找不到就放弃这次补丁 —— 宁可少一张图，也不要补到错的卡上。
      const target = now && now.pluginId === c.pluginId ? i : this.indexOfCard(c.pluginId);
      if (target < 0) return;
      if (samePhotos(this.data.cards[target].photos, photos)) return;
      patch['cards[' + target + '].photos'] = photos;
    });

    if (Object.keys(patch).length) this.setData(patch);
  },

  indexOfCard(pluginId) {
    return this.data.cards.findIndex((c) => c.pluginId === pluginId);
  },

  /**
   * 图片加载失败（直链过期 / COS 域名没进 downloadFile 白名单 / 文件已被删）
   * 就把这张卡退回纯文字。破图比没有图难看得多，而且用户点进去仍然能看详情。
   */
  onCoverError(e) {
    const i = Number(e.currentTarget.dataset.index);
    const card = this.data.cards[i];
    if (!card || !card.photos || !card.photos.length) return;
    const patch = {};
    patch['cards[' + i + '].photos'] = [];
    this.setData(patch);
  },

  onCardTap(e) {
    const index = Number(e.currentTarget.dataset.index);
    const card = this.data.cards[index];
    if (!card) return;
    if (!card.available) {
      wx.showToast({ title: '「' + card.name + '」暂未在小程序开放', icon: 'none' });
      return;
    }
    wx.navigateTo({
      url: card.url,
      fail() {
        wx.showToast({ title: '打开失败，请重试', icon: 'none' });
      },
    });
  },
});
