// marketplace.jsx — 插件市场 + 插件详情

const WO_MARKET = {
  categories: ['推荐', '生活', '财务', '健康', '教育', '娱乐'],
  installed: ['album', 'money', 'anniv', 'chore', 'pet'],
  featured: {
    id: 'cinema', emoji: '🎬', name: '一起看片',
    subtitle: '记录两个人一起看过的电影和剧',
    color: 'linear-gradient(135deg, #E8895A, #C76A3F)',
    rating: 4.8, installs: '1.2 万',
    badge: '本周精选',
  },
  groups: [
    {
      cat: '生活', items: [
        { id: 'album', emoji: '📷', name: '家庭相册', sub: '共享时刻',     installs: '32 万', tint: 'var(--photo)', installed: true },
        { id: 'chore', emoji: '🧹', name: '家务分工', sub: '轮值清单',     installs: '8.4 万', tint: 'var(--chore)', installed: true },
        { id: 'menu',  emoji: '🍜', name: '今晚吃啥', sub: '菜谱与点单',   installs: '24 万', tint: '#F4D9BD' },
        { id: 'shop',  emoji: '🛒', name: '购物清单', sub: '一起列要买的', installs: '17 万', tint: '#E6E0D0' },
      ],
    },
    {
      cat: '财务', items: [
        { id: 'money',  emoji: '💰', name: '共同记账',   sub: '每月对账',   installs: '11 万', tint: 'var(--money)', installed: true },
        { id: 'budget', emoji: '📊', name: '预算管理',   sub: '分类设限额', installs: '6.7 万', tint: '#E6D6E0' },
        { id: 'big',    emoji: '🏷️', name: '大额支出',  sub: '提前商量',   installs: '3.1 万', tint: '#DAE0C8' },
      ],
    },
    {
      cat: '娱乐', items: [
        { id: 'cinema', emoji: '🎬', name: '一起看片', sub: '观影日记',     installs: '1.2 万', tint: '#D6C8E0' },
        { id: 'trip',   emoji: '✈️', name: '旅行计划', sub: '行程与开支',   installs: '4.5 万', tint: '#C8DCE6' },
        { id: 'wish',   emoji: '⭐', name: '想去清单', sub: '加 / 划掉 / 去过', installs: '2.8 万', tint: '#E0D6C8' },
      ],
    },
  ],
};

// ───────────────────────────────────────────────
// MarketPage
// ───────────────────────────────────────────────
function MarketPage({ theme = 'light', onToggleTheme, onOpenPlugin }) {
  const [cat, setCat] = React.useState('推荐');

  return (
    <div data-theme={theme} className="wo-screen" style={{ background: 'var(--bg-app)' }}>
      <WoSubHeader title="插件市场" subtitle="32 个插件 · 已安装 5" />

      <div className="wo-scroll" style={{ paddingBottom: 96 }}>
        {/* search */}
        <div style={{ padding: '0 18px 12px' }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8,
            padding: '10px 14px', borderRadius: 14,
            background: 'var(--bg-tint)',
          }}>
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" style={{ color: 'var(--fg-mid)' }}>
              <circle cx="7" cy="7" r="5"/>
              <path d="M11 11l3 3" strokeLinecap="round"/>
            </svg>
            <span style={{ fontSize: 13, color: 'var(--fg-dim)' }}>搜你想要的——比如「育儿」</span>
          </div>
        </div>

        {/* category chips */}
        <div style={{
          display: 'flex', gap: 6, padding: '4px 18px 14px',
          overflowX: 'auto', scrollbarWidth: 'none',
        }}>
          {WO_MARKET.categories.map(c => {
            const active = c === cat;
            return (
              <button key={c} onClick={() => setCat(c)} style={{
                padding: '7px 14px',
                background: active ? 'var(--accent)' : 'var(--bg-elev)',
                color: active ? '#fff' : 'var(--fg)',
                border: '1px solid ' + (active ? 'transparent' : 'var(--hairline)'),
                borderRadius: 100, fontSize: 13, fontWeight: active ? 600 : 500,
                whiteSpace: 'nowrap', flexShrink: 0, cursor: 'pointer',
              }}>{c}</button>
            );
          })}
        </div>

        {/* featured banner */}
        <div style={{ padding: '0 18px 18px' }}>
          <button onClick={() => onOpenPlugin && onOpenPlugin('cinema')}
                  style={{
                    width: '100%', padding: 0, border: 'none',
                    borderRadius: 22, overflow: 'hidden',
                    background: WO_MARKET.featured.color,
                    color: '#fff', textAlign: 'left', position: 'relative',
                    boxShadow: 'var(--shadow-card)',
                    cursor: 'pointer',
                  }}>
            <div style={{ padding: '18px 18px 18px', display: 'flex', alignItems: 'center', gap: 16 }}>
              <div style={{
                width: 64, height: 64, borderRadius: 18,
                background: 'rgba(255,255,255,0.18)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontSize: 32,
                flexShrink: 0,
              }}>{WO_MARKET.featured.emoji}</div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 10, fontWeight: 600, opacity: 0.85, letterSpacing: 0.6 }}>
                  ★ {WO_MARKET.featured.badge}
                </div>
                <div style={{ fontSize: 18, fontWeight: 700, marginTop: 3, letterSpacing: -0.3 }}>
                  {WO_MARKET.featured.name}
                </div>
                <div style={{ fontSize: 12, opacity: 0.85, marginTop: 3, lineHeight: 1.4 }}>
                  {WO_MARKET.featured.subtitle}
                </div>
              </div>
            </div>
          </button>
        </div>

        {/* groups */}
        {WO_MARKET.groups.map(g => (
          <React.Fragment key={g.cat}>
            <WoSectionTitle hint={g.items.length + ' 个'}>{g.cat}</WoSectionTitle>
            <div style={{ padding: '0 18px' }}>
              <div style={{
                background: 'var(--bg-elev)',
                borderRadius: 18,
                overflow: 'hidden',
                boxShadow: 'var(--shadow-card)',
              }}>
                {g.items.map((p, i) => (
                  <PluginRow key={p.id} p={p} last={i === g.items.length - 1}
                             onClick={() => onOpenPlugin && onOpenPlugin(p.id)} />
                ))}
              </div>
            </div>
          </React.Fragment>
        ))}
      </div>
      <WoTabBar active="home" />
    </div>
  );
}

function PluginRow({ p, last, onClick }) {
  return (
    <div onClick={onClick}
         style={{
           display: 'flex', alignItems: 'center', gap: 14,
           padding: '14px 16px',
           borderBottom: last ? 'none' : '1px solid var(--hairline)',
           cursor: 'pointer',
         }}>
      <div style={{
        width: 44, height: 44, borderRadius: 14,
        background: p.tint,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontSize: 22, flexShrink: 0,
      }}>{p.emoji}</div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--fg)', letterSpacing: -0.1 }}>{p.name}</div>
        <div style={{ fontSize: 11.5, color: 'var(--fg-mid)', marginTop: 2 }}>
          {p.sub} · {p.installs} 户家庭在用
        </div>
      </div>
      <button onClick={(e) => { e.stopPropagation(); }}
              style={{
                padding: '7px 14px', minWidth: 64,
                borderRadius: 100,
                border: p.installed ? '1px solid var(--hairline)' : 'none',
                background: p.installed ? 'var(--bg-tint)' : 'var(--accent)',
                color: p.installed ? 'var(--fg-mid)' : '#fff',
                fontSize: 12.5, fontWeight: 600,
                whiteSpace: 'nowrap',
                cursor: 'pointer',
              }}>
        {p.installed ? '已安装' : '安装'}
      </button>
    </div>
  );
}

// ───────────────────────────────────────────────
// PluginDetailPage — 一起看片
// ───────────────────────────────────────────────
const WO_DETAIL = {
  emoji: '🎬', name: '一起看片',
  subtitle: '记录两个人一起看过的电影和剧',
  author: 'Wo Studio · 官方',
  color: 'linear-gradient(135deg, #E8895A, #C76A3F)',
  rating: 4.8, ratingCount: '2,408',
  installs: '1.2 万家庭',
  size: '12.6 MB',
  intro: '把每一次「今晚看什么」变成可以翻回去的回忆。两个人共写片单、共评分、看到一半也能接着看。',
  shots: [
    { hue: 28,  emoji: '🎬', label: '观影日记' },
    { hue: 280, emoji: '🍿', label: '今晚看什么' },
    { hue: 200, emoji: '⭐', label: '共同评分' },
  ],
  features: [
    { emoji: '📝', t: '共同片单',  d: '想看的、看过的、不打算看的，分三栏' },
    { emoji: '⭐', t: '双人评分', d: '两个人独立打分后再揭晓，避免互相影响' },
    { emoji: '🎯', t: '今晚抽签', d: '选不出来的时候，从片单里抽一部' },
    { emoji: '📌', t: '观影笔记', d: '看完留几个字，半年后翻回来很温暖' },
  ],
  permissions: [
    { emoji: '🔔', t: '通知',      d: '提醒对方看片的进度，仅限本家庭' },
    { emoji: '💾', t: '本地存储',  d: '缓存片单和封面' },
    { emoji: '👥', t: '家庭成员',  d: '读取家庭成员列表用于分账与评分' },
  ],
};

function PluginDetailPage({ theme = 'light', onBack }) {
  const D = WO_DETAIL;
  return (
    <div data-theme={theme} className="wo-screen" style={{ background: 'var(--bg-app)' }}>
      <WoSubHeader title="" onBack={onBack} trailing={
        <button style={{ ...iconBtnStyle, background: 'transparent' }}>
          <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" style={{ color: 'var(--fg)' }}>
            <path d="M10 14l-4-4 4-4M14 14l-4-4 4-4" opacity="0"/>
            <path d="M14 5v10M10 5l-4 5 4 5"/>
          </svg>
        </button>
      } />

      <div className="wo-scroll" style={{ paddingBottom: 110 }}>
        {/* hero */}
        <div style={{ padding: '4px 22px 18px', display: 'flex', alignItems: 'center', gap: 14 }}>
          <div style={{
            width: 72, height: 72, borderRadius: 20,
            background: D.color, color: '#fff',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontSize: 38, flexShrink: 0,
            boxShadow: '0 6px 18px rgba(200,100,60,0.28)',
          }}>{D.emoji}</div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 19, fontWeight: 700, color: 'var(--fg)', letterSpacing: -0.3 }}>{D.name}</div>
            <div style={{ fontSize: 12, color: 'var(--fg-mid)', marginTop: 3 }}>{D.author}</div>
            <div style={{ display: 'flex', gap: 12, marginTop: 8, fontSize: 11, color: 'var(--fg-mid)' }}>
              <span style={{ color: 'var(--fg)', fontWeight: 600 }}>★ {D.rating}</span>
              <span>{D.installs}</span>
              <span>{D.size}</span>
            </div>
          </div>
        </div>

        {/* intro */}
        <div style={{ padding: '0 22px 22px', fontSize: 14, color: 'var(--fg-mid)', lineHeight: 1.65 }}>
          {D.intro}
        </div>

        {/* screenshots */}
        <div style={{
          display: 'flex', gap: 10, padding: '0 22px 24px',
          overflowX: 'auto', scrollbarWidth: 'none',
        }}>
          {D.shots.map((s, i) => (
            <div key={i} style={{ width: 160, flexShrink: 0 }}>
              <div style={{
                width: 160, height: 280, borderRadius: 22,
                background: `linear-gradient(160deg, hsl(${s.hue} 35% 80%), hsl(${s.hue + 25} 35% 70%))`,
                position: 'relative', overflow: 'hidden',
                boxShadow: '0 4px 14px rgba(0,0,0,0.08)',
              }}>
                <div style={{
                  position: 'absolute', top: 14, left: 0, right: 0,
                  textAlign: 'center', fontSize: 11, color: 'rgba(0,0,0,0.45)',
                  fontWeight: 600, letterSpacing: 0.3,
                }}>{s.label}</div>
                <div style={{
                  position: 'absolute', inset: 0,
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  fontSize: 64, opacity: 0.65,
                }}>{s.emoji}</div>
              </div>
            </div>
          ))}
        </div>

        {/* features */}
        <WoSectionTitle>主要功能</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)',
            borderRadius: 18, overflow: 'hidden',
            boxShadow: 'var(--shadow-card)',
          }}>
            {D.features.map((f, i) => (
              <div key={i} style={{
                padding: '14px 16px', display: 'flex', alignItems: 'flex-start', gap: 12,
                borderBottom: i === D.features.length - 1 ? 'none' : '1px solid var(--hairline)',
              }}>
                <div style={{
                  width: 32, height: 32, borderRadius: 10,
                  background: 'var(--bg-tint)',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  fontSize: 16, flexShrink: 0,
                }}>{f.emoji}</div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>{f.t}</div>
                  <div style={{ fontSize: 12, color: 'var(--fg-mid)', marginTop: 2, lineHeight: 1.5 }}>{f.d}</div>
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* permissions */}
        <WoSectionTitle hint="安装后可在设置中关闭">申请权限</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)',
            borderRadius: 18, overflow: 'hidden',
            boxShadow: 'var(--shadow-card)',
          }}>
            {D.permissions.map((p, i) => (
              <WoListRow key={i}
                leading={p.emoji} title={p.t} subtitle={p.d}
                last={i === D.permissions.length - 1} />
            ))}
          </div>
        </div>

        <div style={{
          padding: '20px 22px 10px',
          fontSize: 11, color: 'var(--fg-dim)', lineHeight: 1.6,
        }}>
          所有数据仅在「栗子的窝」内共享 · 退出家庭即同步删除
        </div>
      </div>

      {/* sticky bottom install bar */}
      <div style={{
        position: 'absolute', left: 0, right: 0, bottom: 0,
        padding: '12px 18px 14px',
        background: 'color-mix(in srgb, var(--bg) 82%, transparent)',
        backdropFilter: 'blur(20px)',
        WebkitBackdropFilter: 'blur(20px)',
        borderTop: '1px solid var(--hairline)',
        display: 'flex', gap: 10, alignItems: 'center',
      }}>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 11, color: 'var(--fg-dim)' }}>安装到</div>
          <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)', marginTop: 1 }}>栗子的窝</div>
        </div>
        <button style={{
          padding: '12px 28px', borderRadius: 100,
          background: 'var(--accent)', color: '#fff',
          border: 'none', fontSize: 15, fontWeight: 600,
          boxShadow: 'var(--shadow-fab)',
        }}>免费安装</button>
      </div>
    </div>
  );
}

Object.assign(window, { MarketPage, PluginDetailPage, WO_MARKET, WO_DETAIL });
