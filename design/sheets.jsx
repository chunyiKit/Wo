// sheets.jsx — Interactive overlays: family switcher, add-plugin sheet,
// and empty-state pattern. Imported by home-a (and reusable elsewhere).

// ────────────────────────────────────────────────────────────
// Backdrop — used by both sheets
// ────────────────────────────────────────────────────────────
function WoBackdrop({ onClose, dim = 0.42 }) {
  return (
    <div onClick={onClose}
         style={{
           position: 'absolute', inset: 0,
           background: `rgba(20,16,12,${dim})`,
           zIndex: 8,
           animation: 'wo-fade 0.18s ease-out',
         }} />
  );
}

// Inject keyframes once
if (typeof document !== 'undefined' && !document.getElementById('wo-sheet-keys')) {
  const s = document.createElement('style');
  s.id = 'wo-sheet-keys';
  s.textContent = `
    @keyframes wo-fade { from { opacity: 0 } to { opacity: 1 } }
    @keyframes wo-sheet-up {
      from { transform: translateY(100%) }
      to   { transform: translateY(0)    }
    }
    @keyframes wo-drop-down {
      from { transform: translateY(-12px); opacity: 0 }
      to   { transform: translateY(0);     opacity: 1 }
    }
  `;
  document.head.appendChild(s);
}

// ────────────────────────────────────────────────────────────
// FamilySwitcher — drops down anchored to the top bar.
// Clear "current" lock-up: tinted background + accent dot + name in 主色.
// ────────────────────────────────────────────────────────────
function FamilySwitcher({ open, onClose, current = '栗子的窝', onPick }) {
  if (!open) return null;
  const items = [
    { name: '栗子的窝',       emoji: '🏡', members: 3, badge: '主理人', current: true },
    { name: '老家',           emoji: '🌷', members: 4, badge: '家人',   notif: 2 },
    { name: '深圳出租屋',     emoji: '🌆', members: 3, badge: '家人' },
  ];

  return (
    <React.Fragment>
      <WoBackdrop onClose={onClose} dim={0.35} />
      <div style={{
        position: 'absolute', top: 56, left: 14, right: 14,
        background: 'var(--bg-elev)',
        borderRadius: 20,
        boxShadow: '0 18px 50px rgba(0,0,0,0.18), 0 0 0 1px var(--hairline)',
        padding: 8,
        zIndex: 9,
        animation: 'wo-drop-down 0.2s cubic-bezier(0.2,0.7,0.3,1)',
      }}>
        <div style={{
          padding: '8px 12px 6px',
          fontSize: 11, color: 'var(--fg-dim)', fontWeight: 600, letterSpacing: 0.4,
        }}>切换家庭</div>

        {items.map((f, i) => (
          <button key={f.name}
            onClick={() => { onPick && onPick(f.name); onClose && onClose(); }}
            style={{
              width: '100%',
              display: 'flex', alignItems: 'center', gap: 12,
              padding: '10px 12px',
              background: f.current ? 'var(--accent-soft)' : 'transparent',
              border: 'none', borderRadius: 12,
              cursor: 'pointer', textAlign: 'left',
              marginBottom: 2,
            }}>
            <div style={{
              width: 38, height: 38, borderRadius: 12,
              background: f.current ? 'rgba(255,255,255,0.55)' : 'var(--bg-tint)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 20, flexShrink: 0,
            }}>{f.emoji}</div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{
                  fontSize: 15, fontWeight: 600,
                  color: f.current ? 'var(--accent-deep)' : 'var(--fg)',
                  letterSpacing: -0.2,
                }}>{f.name}</span>
                {f.notif && (
                  <span style={{
                    minWidth: 16, height: 16, padding: '0 4px',
                    background: 'var(--accent)', color: '#fff',
                    borderRadius: 8, fontSize: 10, fontWeight: 600,
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    lineHeight: 1,
                  }}>{f.notif}</span>
                )}
              </div>
              <div style={{ fontSize: 11, color: 'var(--fg-mid)', marginTop: 1 }}>
                {f.badge} · {f.members} 成员
              </div>
            </div>
            {f.current && (
              <div style={{
                width: 22, height: 22, borderRadius: 11,
                background: 'var(--accent)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                color: '#fff',
              }}>
                <svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M2 5.5l2.2 2.2L9 3"/>
                </svg>
              </div>
            )}
          </button>
        ))}

        <div style={{ height: 1, background: 'var(--hairline)', margin: '6px 6px' }} />

        <button style={{
          width: '100%',
          display: 'flex', alignItems: 'center', gap: 12,
          padding: '10px 12px',
          background: 'transparent',
          border: 'none', borderRadius: 12,
          cursor: 'pointer', textAlign: 'left',
        }}>
          <div style={{
            width: 38, height: 38, borderRadius: 12,
            background: 'var(--bg-tint)',
            border: '1.5px dashed var(--hairline)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontSize: 18, color: 'var(--fg-mid)',
            flexShrink: 0,
          }}>＋</div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>加入或创建新家</div>
            <div style={{ fontSize: 11, color: 'var(--fg-dim)', marginTop: 1 }}>输入邀请码、扫码、或新建一个</div>
          </div>
        </button>
      </div>
    </React.Fragment>
  );
}

// ────────────────────────────────────────────────────────────
// AddPluginSheet — slides up from the bottom, ~72% height.
// Featured + grid of plugins inline; user doesn't fully leave home.
// ────────────────────────────────────────────────────────────
function AddPluginSheet({ open, onClose }) {
  if (!open) return null;
  const featured = WO_MARKET.featured;
  const quickCats = ['推荐', '生活', '财务', '娱乐'];
  const [cat, setCat] = React.useState('推荐');
  const allPlugins = WO_MARKET.groups.flatMap(g => g.items.map(p => ({ ...p, cat: g.cat })));
  const filtered = cat === '推荐'
    ? allPlugins.filter(p => !p.installed).slice(0, 6)
    : allPlugins.filter(p => !p.installed && p.cat === cat);

  return (
    <React.Fragment>
      <WoBackdrop onClose={onClose} dim={0.45} />
      <div style={{
        position: 'absolute', left: 0, right: 0, bottom: 0,
        height: '72%',
        background: 'var(--bg-elev)',
        borderRadius: '24px 24px 0 0',
        boxShadow: '0 -10px 50px rgba(0,0,0,0.18)',
        zIndex: 9,
        display: 'flex', flexDirection: 'column',
        animation: 'wo-sheet-up 0.28s cubic-bezier(0.2,0.7,0.3,1)',
      }}>
        {/* Drag handle */}
        <div style={{
          padding: '10px 0 4px',
          display: 'flex', justifyContent: 'center',
        }}>
          <div style={{
            width: 40, height: 4, borderRadius: 2,
            background: 'var(--hairline)',
          }} />
        </div>

        {/* Header */}
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8,
          padding: '6px 18px 6px',
        }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{
              fontSize: 18, fontWeight: 700, color: 'var(--fg)',
              letterSpacing: -0.3,
            }}>添加插件</div>
            <div style={{ fontSize: 11.5, color: 'var(--fg-mid)', marginTop: 1 }}>
              装到「栗子的窝」 · 已有 5 个
            </div>
          </div>
          <button style={{
            ...iconBtnStyle, background: 'var(--bg-tint)',
          }} onClick={onClose}>
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" style={{ color: 'var(--fg)' }}>
              <path d="M3.5 3.5l7 7M10.5 3.5l-7 7"/>
            </svg>
          </button>
        </div>

        {/* Scrollable body */}
        <div className="wo-scroll" style={{ flex: 1 }}>
          {/* Featured */}
          <div style={{ padding: '14px 18px 0' }}>
            <button style={{
              width: '100%',
              padding: 0, border: 'none',
              borderRadius: 20, overflow: 'hidden',
              background: featured.color,
              color: '#fff', textAlign: 'left',
              cursor: 'pointer',
              boxShadow: '0 6px 18px rgba(200,100,60,0.22)',
            }}>
              <div style={{ padding: '16px 16px', display: 'flex', alignItems: 'center', gap: 14 }}>
                <div style={{
                  width: 52, height: 52, borderRadius: 16,
                  background: 'rgba(255,255,255,0.2)',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  fontSize: 26, flexShrink: 0,
                }}>{featured.emoji}</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 10, fontWeight: 600, opacity: 0.85, letterSpacing: 0.6 }}>
                    ★ 本周精选
                  </div>
                  <div style={{ fontSize: 16, fontWeight: 700, marginTop: 2 }}>{featured.name}</div>
                  <div style={{ fontSize: 11, opacity: 0.85, marginTop: 2 }}>{featured.subtitle}</div>
                </div>
                <div style={{
                  padding: '7px 14px', background: '#fff', color: '#C76A3F',
                  borderRadius: 100, fontSize: 12, fontWeight: 600,
                  whiteSpace: 'nowrap', flexShrink: 0,
                }}>安装</div>
              </div>
            </button>
          </div>

          {/* Category quick filter */}
          <div style={{
            display: 'flex', gap: 6, padding: '14px 18px 12px',
            overflowX: 'auto', scrollbarWidth: 'none',
          }}>
            {quickCats.map(c => {
              const active = c === cat;
              return (
                <button key={c} onClick={() => setCat(c)} style={{
                  padding: '6px 13px',
                  background: active ? 'var(--accent)' : 'var(--bg-tint)',
                  color: active ? '#fff' : 'var(--fg)',
                  border: 'none', borderRadius: 100,
                  fontSize: 12, fontWeight: active ? 600 : 500,
                  cursor: 'pointer', whiteSpace: 'nowrap',
                  flexShrink: 0,
                }}>{c}</button>
              );
            })}
          </div>

          {/* Grid */}
          <div style={{
            padding: '0 14px',
            display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8,
          }}>
            {filtered.slice(0, 8).map(p => (
              <div key={p.id} style={{
                background: 'var(--bg-tint)',
                borderRadius: 16,
                padding: 12,
                display: 'flex', flexDirection: 'column', gap: 8,
              }}>
                <div style={{
                  width: 36, height: 36, borderRadius: 12,
                  background: p.tint,
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  fontSize: 19,
                }}>{p.emoji}</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--fg)' }}>{p.name}</div>
                  <div style={{ fontSize: 10.5, color: 'var(--fg-mid)', marginTop: 1, lineHeight: 1.3 }}>{p.sub}</div>
                </div>
                <button style={{
                  padding: '5px 10px',
                  background: 'var(--bg-elev)', color: 'var(--accent-deep)',
                  border: 'none', borderRadius: 100,
                  fontSize: 11.5, fontWeight: 600,
                  alignSelf: 'flex-start',
                  cursor: 'pointer',
                }}>＋ 安装</button>
              </div>
            ))}
          </div>

          {/* Footer link */}
          <button style={{
            width: 'calc(100% - 36px)', margin: '14px 18px 20px',
            padding: '12px',
            background: 'transparent',
            border: '1px solid var(--hairline)',
            borderRadius: 12,
            color: 'var(--fg-mid)',
            fontSize: 13, fontWeight: 500,
            cursor: 'pointer',
          }}>查看全部 32 个插件  →</button>
        </div>
      </div>
    </React.Fragment>
  );
}

// ────────────────────────────────────────────────────────────
// EmptyState — friendly first-run for a newly installed plugin
// ────────────────────────────────────────────────────────────
function WoEmptyState({ emoji, eyebrow, title, body, primary, secondary, hint, tone = 'warm' }) {
  const toneMap = {
    warm: 'linear-gradient(135deg, #FCE4D4, #F0C4B4)',
    cream: 'linear-gradient(135deg, #F8E8C8, #E8D4A8)',
    sage: 'linear-gradient(135deg, #DAE6C8, #B8CAA8)',
  };
  return (
    <div style={{ padding: '32px 22px 24px', textAlign: 'center' }}>
      {/* Illustration: large soft circle with floating emoji */}
      <div style={{
        width: 140, height: 140, borderRadius: 999,
        background: toneMap[tone] || toneMap.warm,
        margin: '0 auto 26px',
        position: 'relative',
      }}>
        <div style={{
          position: 'absolute', inset: 0,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontSize: 68,
        }}>{emoji}</div>
        {/* sparkles */}
        <div style={{ position: 'absolute', top: -8, right: 10, fontSize: 20, opacity: 0.8 }}>✨</div>
        <div style={{ position: 'absolute', bottom: 6, left: 0, fontSize: 14, opacity: 0.7 }}>·</div>
      </div>

      {eyebrow && (
        <div style={{
          display: 'inline-block',
          padding: '4px 10px',
          background: 'var(--accent-soft)', color: 'var(--accent-deep)',
          borderRadius: 100, fontSize: 11, fontWeight: 600,
          letterSpacing: 0.2,
          marginBottom: 12,
        }}>{eyebrow}</div>
      )}

      <div style={{
        fontSize: 22, fontWeight: 700, color: 'var(--fg)',
        letterSpacing: -0.4, lineHeight: 1.3,
      }}>{title}</div>
      <div style={{
        fontSize: 14, color: 'var(--fg-mid)',
        marginTop: 10, lineHeight: 1.6,
        maxWidth: 280, marginLeft: 'auto', marginRight: 'auto',
      }}>{body}</div>

      {primary && (
        <button style={{
          marginTop: 28,
          padding: '13px 28px',
          background: 'var(--accent)', color: '#fff',
          border: 'none', borderRadius: 100,
          fontSize: 14, fontWeight: 600,
          boxShadow: 'var(--shadow-fab)',
          cursor: 'pointer',
        }}>{primary}</button>
      )}
      {secondary && (
        <button style={{
          display: 'block', margin: '14px auto 0',
          padding: '6px 14px',
          background: 'transparent', color: 'var(--fg-mid)',
          border: 'none',
          fontSize: 13, fontWeight: 500,
          cursor: 'pointer',
        }}>{secondary}</button>
      )}
      {hint && (
        <div style={{
          marginTop: 24,
          fontSize: 11, color: 'var(--fg-dim)', lineHeight: 1.6,
        }}>{hint}</div>
      )}
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// Empty state demos — wrapped as full plugin "first launch" pages.
// ────────────────────────────────────────────────────────────
function EmptyAlbumPage({ theme = 'light', onBack }) {
  return (
    <div data-theme={theme} className="wo-screen" style={{ background: 'var(--bg-app)' }}>
      <WoSubHeader title="家庭相册" subtitle="栗子的窝" onBack={onBack}
        trailing={<button style={{ ...iconBtnStyle, background: 'transparent' }}>
          <svg width="18" height="18" viewBox="0 0 18 18" fill="currentColor" style={{ color: 'var(--fg)' }}>
            <circle cx="4" cy="9" r="1.4"/><circle cx="9" cy="9" r="1.4"/><circle cx="14" cy="9" r="1.4"/>
          </svg>
        </button>} />
      <div className="wo-scroll">
        <WoEmptyState
          emoji="📷"
          eyebrow="刚刚安装"
          title="一起拍点什么吧"
          body="阿哲也加入了这个相册。从今天起拍的照片、你截的屏，都可以攒在这里。"
          primary="添加第一张照片"
          secondary="从手机相册导入"
          hint="只有「栗子的窝」的成员能看到这些照片"
          tone="warm"
        />
        {/* Template chips */}
        <div style={{ padding: '0 22px 32px' }}>
          <div style={{
            fontSize: 11, fontWeight: 600, color: 'var(--fg-mid)',
            letterSpacing: 0.4, marginBottom: 10, textAlign: 'center',
          }}>试试这些主题相册</div>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', justifyContent: 'center' }}>
            {[
              ['🍜', '今天吃了什么'],
              ['🌅', '一起的早晨'],
              ['🐱', '栗子专辑'],
              ['🚶', '周末出去走'],
            ].map(([e, t]) => (
              <div key={t} style={{
                display: 'flex', alignItems: 'center', gap: 6,
                padding: '8px 12px',
                background: 'var(--bg-elev)',
                boxShadow: 'var(--shadow-card)',
                borderRadius: 100,
                fontSize: 12, color: 'var(--fg)', fontWeight: 500,
              }}>
                <span style={{ fontSize: 13 }}>{e}</span>
                {t}
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function EmptyCinemaPage({ theme = 'light', onBack }) {
  return (
    <div data-theme={theme} className="wo-screen" style={{ background: 'var(--bg-app)' }}>
      <WoSubHeader title="一起看片" subtitle="刚装上 · 等待你的第一部"
        onBack={onBack}
        trailing={<button style={{ ...iconBtnStyle, background: 'transparent' }}>
          <svg width="18" height="18" viewBox="0 0 18 18" fill="currentColor" style={{ color: 'var(--fg)' }}>
            <circle cx="4" cy="9" r="1.4"/><circle cx="9" cy="9" r="1.4"/><circle cx="14" cy="9" r="1.4"/>
          </svg>
        </button>} />
      <div className="wo-scroll">
        <WoEmptyState
          emoji="🎬"
          title="今晚想看点什么？"
          body="加进想看的电影或剧，然后两个人独立打分，看完再揭晓。"
          primary="加一部想看的"
          secondary="从豆瓣 / IMDb 导入"
          tone="cream"
        />
        {/* example movies */}
        <div style={{ padding: '0 22px 32px' }}>
          <div style={{
            fontSize: 11, fontWeight: 600, color: 'var(--fg-mid)',
            letterSpacing: 0.4, marginBottom: 12, textAlign: 'center',
          }}>最近这周大家都在看</div>
          <div style={{
            display: 'flex', gap: 10, overflowX: 'auto',
            paddingBottom: 4, scrollbarWidth: 'none',
          }}>
            {[
              { hue: 28, t: '日落以后' },
              { hue: 200, t: '昨日的盒饭' },
              { hue: 280, t: '冬末' },
              { hue: 148, t: '夏天的尾巴' },
            ].map(m => (
              <div key={m.t} style={{ width: 96, flexShrink: 0 }}>
                <div style={{
                  width: 96, height: 132, borderRadius: 12,
                  background: `linear-gradient(160deg, hsl(${m.hue} 35% 78%), hsl(${m.hue + 20} 30% 65%))`,
                  display: 'flex', alignItems: 'flex-end', padding: 8,
                }}>
                  <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.7)', fontWeight: 600 }}>
                    {m.t}
                  </div>
                </div>
                <button style={{
                  display: 'block', margin: '8px auto 0',
                  padding: '4px 10px',
                  background: 'var(--bg-tint)', color: 'var(--fg)',
                  border: 'none', borderRadius: 100,
                  fontSize: 11, fontWeight: 500,
                }}>＋ 想看</button>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function EmptyChorePage({ theme = 'light', onBack }) {
  return (
    <div data-theme={theme} className="wo-screen" style={{ background: 'var(--bg-app)' }}>
      <WoSubHeader title="家务分工" subtitle="栗子的窝 · 3 人" onBack={onBack} />
      <div className="wo-scroll">
        <WoEmptyState
          emoji="🧹"
          title="还没有要做的事"
          body="家务也是一种约定。先列几件常做的，App 会帮你们轮流。"
          primary="开始安排"
          secondary="跳过，自由记录"
          tone="sage"
        />
        {/* templates */}
        <div style={{ padding: '0 18px 24px' }}>
          <div style={{
            background: 'var(--bg-elev)', borderRadius: 18,
            overflow: 'hidden', boxShadow: 'var(--shadow-card)',
          }}>
            <div style={{
              padding: '14px 16px 6px',
              fontSize: 11, fontWeight: 600, color: 'var(--fg-mid)',
              letterSpacing: 0.4,
            }}>常用模板 · 一键导入</div>
            {[
              { e: '🍳', t: '今晚做饭',  d: '每日轮值' },
              { e: '🗑️', t: '倒垃圾',    d: '每周一三五' },
              { e: '🧺', t: '洗衣服',    d: '随手记录' },
              { e: '🪴', t: '浇花',      d: '每周一次' },
            ].map((c, i, arr) => (
              <div key={c.t} style={{
                display: 'flex', alignItems: 'center', gap: 12,
                padding: '12px 16px',
                borderBottom: i === arr.length - 1 ? 'none' : '1px solid var(--hairline)',
              }}>
                <span style={{ fontSize: 18 }}>{c.e}</span>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 14, fontWeight: 500, color: 'var(--fg)' }}>{c.t}</div>
                  <div style={{ fontSize: 11, color: 'var(--fg-mid)', marginTop: 1 }}>{c.d}</div>
                </div>
                <button style={{
                  width: 28, height: 28, borderRadius: 8,
                  background: 'var(--accent-soft)', color: 'var(--accent-deep)',
                  border: 'none', fontSize: 16, fontWeight: 600,
                  cursor: 'pointer',
                }}>＋</button>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, {
  WoBackdrop, FamilySwitcher, AddPluginSheet, WoEmptyState,
  EmptyAlbumPage, EmptyCinemaPage, EmptyChorePage,
});
