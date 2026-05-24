// common.jsx — shared bits across the three home variants.
// TopBar / TabBar / FAB / mock data / long-press edit mode hook.

// ────────────────────────────────────────────────────────────
// Mock family — 二人 + 宠物
// ────────────────────────────────────────────────────────────
const WO_FAMILY = {
  name: '栗子的窝',
  members: [
    { id: 'a', name: '小柚', emoji: '🌼' },
    { id: 'b', name: '阿哲', emoji: '🌊' },
    { id: 'p', name: '栗子', emoji: '🐱', isPet: true },
  ],
  otherFamilies: [
    { name: '老家', emoji: '🏡' },
    { name: '深圳出租屋', emoji: '🌆' },
  ],
};

const WO_PLUGINS = {
  album: {
    id: 'album', emoji: '📷', name: '家庭相册',
    tint: 'var(--photo)',
    weekCount: 12, todayCount: 3,
    coverHues: [28, 188, 14, 50, 312],
  },
  money: {
    id: 'money', emoji: '💰', name: '共同记账',
    tint: 'var(--money)',
    monthSpent: 3847, monthBudget: 6000,
    recent: [
      { who: '小柚', what: '周日的菜', amount: 168 },
      { who: '阿哲', what: '电费',     amount: 89  },
      { who: '小柚', what: '猫砂 ×2',  amount: 76  },
    ],
  },
  anniv: {
    id: 'anniv', emoji: '🎂', name: '纪念日',
    tint: 'var(--anniv)',
    nextLabel: '在一起 3 周年',
    daysLeft: 18,
    date: '6 月 9 日',
    others: [
      { label: '搬到新家',  days: 47 },
      { label: '栗子生日',  days: 104 },
    ],
  },
  chore: {
    id: 'chore', emoji: '🧹', name: '家务分工',
    tint: 'var(--chore)',
    todayDone: 2, todayTotal: 4,
    tasks: [
      { who: '阿哲', what: '今晚做饭',  done: false, emoji: '🍳' },
      { who: '小柚', what: '倒垃圾',    done: false, emoji: '🗑️' },
      { who: '阿哲', what: '洗碗',      done: true,  emoji: '🍽️' },
      { who: '小柚', what: '喂栗子',    done: true,  emoji: '🐱' },
    ],
  },
  pet: {
    id: 'pet', emoji: '🐾', name: '栗子日常',
    tint: 'var(--pet)',
    name: '栗子',
    species: '布偶 · 3 岁',
    nextMeal: '18:30',
    weight: '5.2 kg',
  },
};

// ────────────────────────────────────────────────────────────
// Long-press → edit mode
// holdMs = 480, fires once.
// ────────────────────────────────────────────────────────────
function useLongPressEdit(holdMs = 480) {
  const [editing, setEditing] = React.useState(false);
  const timer = React.useRef(null);
  const start = (e) => {
    if (editing) return;
    timer.current = setTimeout(() => {
      setEditing(true);
      // haptic-ish: not real on web, but make the page feel responsive
    }, holdMs);
  };
  const cancel = () => { if (timer.current) clearTimeout(timer.current); };
  return {
    editing, setEditing,
    bind: {
      onPointerDown: start,
      onPointerUp: cancel,
      onPointerLeave: cancel,
      onPointerCancel: cancel,
    },
  };
}

// ────────────────────────────────────────────────────────────
// Top bar — family name + switch + notifications + theme toggle
// `compact` reduces to a single-line bar (used by direction B).
// ────────────────────────────────────────────────────────────
function WoTopBar({ family, theme, onToggleTheme, onTapFamily, hint, style, accentIcon = false }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 10,
      padding: '12px 18px 8px',
      ...style,
    }}>
      <button
        onClick={onTapFamily}
        style={{
          flex: 1, display: 'flex', alignItems: 'center', gap: 10,
          border: 'none', background: 'transparent', padding: 0, textAlign: 'left',
          cursor: 'pointer', minWidth: 0,
        }}>
        <div style={{
          width: 36, height: 36, borderRadius: 12,
          background: accentIcon ? 'var(--accent)' : 'var(--bg-tint)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontSize: 18,
        }}>🏡</div>
        <div style={{ display: 'flex', flexDirection: 'column', minWidth: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
            <span style={{
              fontSize: 17, fontWeight: 600, color: 'var(--fg)',
              letterSpacing: -0.3, whiteSpace: 'nowrap',
            }}>{family.name}</span>
            <svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" style={{ color: 'var(--fg-mid)' }}>
              <path d="M2 4l3.5 3.5L9 4"/>
            </svg>
          </div>
          {hint && (
            <div style={{ fontSize: 12, color: 'var(--fg-dim)', marginTop: 1 }}>{hint}</div>
          )}
        </div>
      </button>

      <button onClick={onToggleTheme} style={iconBtnStyle}>
        <span style={{ fontSize: 16, lineHeight: 1 }}>{theme === 'dark' ? '🌙' : '☀️'}</span>
      </button>
      <button style={iconBtnStyle}>
        <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" style={{ color: 'var(--fg)' }}>
          <path d="M10 3a4.5 4.5 0 0 0-4.5 4.5v3L4 13h12l-1.5-2.5v-3A4.5 4.5 0 0 0 10 3z"/>
          <path d="M8 16a2 2 0 0 0 4 0"/>
        </svg>
        <span style={{
          position: 'absolute', top: 7, right: 8, width: 7, height: 7,
          background: 'var(--accent)', borderRadius: '50%',
          border: '2px solid var(--bg)',
        }} />
      </button>
    </div>
  );
}

const iconBtnStyle = {
  position: 'relative',
  width: 38, height: 38, borderRadius: 12,
  background: 'var(--bg-tint)',
  border: 'none', cursor: 'pointer',
  display: 'flex', alignItems: 'center', justifyContent: 'center',
  flexShrink: 0,
};

// ────────────────────────────────────────────────────────────
// Bottom tab bar — 首页 / 消息 / 我的
// ────────────────────────────────────────────────────────────
function WoTabBar({ active = 'home' }) {
  const tabs = [
    { id: 'home', label: '首页', emoji: '🏠' },
    { id: 'msg',  label: '消息', emoji: '💬' },
    { id: 'me',   label: '我的', emoji: '👤' },
  ];
  return (
    <div className="wo-tabbar">
      {tabs.map(t => (
        <div key={t.id} className={'wo-tab' + (active === t.id ? ' is-active' : '')}>
          <span className="wo-tab-emoji" style={{ filter: active === t.id ? 'none' : 'grayscale(0.6)' }}>
            {t.emoji}
          </span>
          <span style={{ fontWeight: active === t.id ? 600 : 400 }}>{t.label}</span>
          {t.id === 'msg' && (
            <span style={{
              position: 'absolute', top: -2, right: 'calc(50% - 18px)',
              minWidth: 16, height: 16, padding: '0 4px',
              background: 'var(--accent)', color: '#fff',
              borderRadius: 8, fontSize: 10, fontWeight: 600,
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>3</span>
          )}
        </div>
      ))}
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// Edit mode toolbar — replaces tab bar when editing
// ────────────────────────────────────────────────────────────
function WoEditBar({ onDone }) {
  return (
    <div className="wo-tabbar" style={{ padding: '8px 18px 12px', gap: 10 }}>
      <button style={{
        flex: 1, height: 48, borderRadius: 14,
        background: 'var(--bg-tint)', color: 'var(--fg)',
        border: 'none', fontSize: 15, fontWeight: 500,
        display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
      }}>
        <span style={{ fontSize: 18 }}>＋</span> 添加插件
      </button>
      <button onClick={onDone} style={{
        flex: 1, height: 48, borderRadius: 14,
        background: 'var(--accent)', color: '#fff',
        border: 'none', fontSize: 15, fontWeight: 600,
      }}>完成</button>
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// FAB — + 添加插件 (used by directions that don't reserve a row for it)
// ────────────────────────────────────────────────────────────
function WoFab({ onClick }) {
  return (
    <button className="wo-fab" onClick={onClick}>＋</button>
  );
}

// ────────────────────────────────────────────────────────────
// Reusable photo placeholder — emoji + tinted gradient
// (acts as the "real" photo would; subtle, not too gimmicky)
// ────────────────────────────────────────────────────────────
function WoPhotoSquare({ hue = 28, emoji = '📷', size = '100%', radius = 12, dim = false }) {
  const sat = dim ? 18 : 32;
  const l1 = dim ? 70 : 78;
  const l2 = dim ? 58 : 66;
  return (
    <div style={{
      width: size, aspectRatio: '1 / 1', borderRadius: radius,
      background: `linear-gradient(135deg, hsl(${hue} ${sat}% ${l1}%), hsl(${hue + 18} ${sat - 6}% ${l2}%))`,
      position: 'relative', overflow: 'hidden', flexShrink: 0,
    }}>
      <div style={{
        position: 'absolute', inset: 0,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontSize: 'min(46%, 28px)', opacity: 0.5,
      }}>{emoji}</div>
    </div>
  );
}

Object.assign(window, {
  WO_FAMILY, WO_PLUGINS,
  WoTopBar, WoTabBar, WoEditBar, WoFab, WoPhotoSquare,
  WoSubHeader, WoListRow, WoSectionTitle, WoSegmented, WoQRCode,
  useLongPressEdit, iconBtnStyle,
});

// ────────────────────────────────────────────────────────────
// WoSubHeader — Material 3 sub-page header (back arrow + title +
// optional trailing icon). Used on every screen except the home tab.
// ────────────────────────────────────────────────────────────
function WoSubHeader({ title, subtitle, trailing, onBack }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 8,
      padding: '8px 8px 8px 4px', minHeight: 56,
    }}>
      <button onClick={onBack} style={{
        ...iconBtnStyle, background: 'transparent',
      }}>
        <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" style={{ color: 'var(--fg)' }}>
          <path d="M12.5 4L6.5 10l6 6"/>
        </svg>
      </button>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{
          fontSize: 17, fontWeight: 600, color: 'var(--fg)',
          letterSpacing: -0.2, lineHeight: 1.2,
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>{title}</div>
        {subtitle && (
          <div style={{ fontSize: 12, color: 'var(--fg-mid)', marginTop: 1 }}>{subtitle}</div>
        )}
      </div>
      {trailing}
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// WoSectionTitle — small caps title above a group
// ────────────────────────────────────────────────────────────
function WoSectionTitle({ children, hint, style }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
      padding: '20px 22px 8px', ...style,
    }}>
      <div style={{
        fontSize: 11, fontWeight: 600, color: 'var(--fg-mid)',
        letterSpacing: 0.4, textTransform: 'none',
      }}>{children}</div>
      {hint && <div style={{ fontSize: 11, color: 'var(--fg-dim)' }}>{hint}</div>}
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// WoListRow — Material list item, settings-row style
// ────────────────────────────────────────────────────────────
function WoListRow({ leading, leadingBg, title, subtitle, trailing, chevron, danger, last, first }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 14,
      padding: '14px 16px',
      borderBottom: last ? 'none' : '1px solid var(--hairline)',
    }}>
      {leading && (
        <div style={{
          width: 36, height: 36, borderRadius: 12,
          background: leadingBg || 'var(--bg-tint)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontSize: 18, flexShrink: 0,
        }}>{leading}</div>
      )}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{
          fontSize: 15, fontWeight: 500,
          color: danger ? '#C76A3F' : 'var(--fg)',
          letterSpacing: -0.1,
        }}>{title}</div>
        {subtitle && (
          <div style={{ fontSize: 12, color: 'var(--fg-mid)', marginTop: 2 }}>{subtitle}</div>
        )}
      </div>
      {trailing && (
        <div style={{ fontSize: 13, color: 'var(--fg-mid)' }}>{trailing}</div>
      )}
      {chevron && (
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" style={{ color: 'var(--fg-dim)', flexShrink: 0 }}>
          <path d="M5 3l4 4-4 4"/>
        </svg>
      )}
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// WoSegmented — Material 3 SegmentedButton row
// ────────────────────────────────────────────────────────────
function WoSegmented({ options, value, onChange }) {
  return (
    <div style={{
      display: 'flex',
      background: 'var(--bg-tint)',
      borderRadius: 100,
      padding: 4,
    }}>
      {options.map(o => {
        const active = (o.value ?? o) === value;
        return (
          <button key={o.value ?? o} onClick={() => onChange(o.value ?? o)}
            style={{
              flex: 1, padding: '7px 10px',
              border: 'none',
              borderRadius: 100,
              background: active ? 'var(--bg-elev)' : 'transparent',
              color: active ? 'var(--fg)' : 'var(--fg-mid)',
              fontSize: 12, fontWeight: active ? 600 : 500,
              boxShadow: active ? '0 1px 3px rgba(0,0,0,0.06)' : 'none',
              whiteSpace: 'nowrap',
              cursor: 'pointer',
            }}>
            {o.label ?? o}
          </button>
        );
      })}
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// WoQRCode — pseudo-QR built from a deterministic 25×25 grid.
// Not a scannable code — purely a visual placeholder.
// ────────────────────────────────────────────────────────────
function WoQRCode({ seed = 'WO-3F2K-9L', size = 200 }) {
  const N = 25;
  // Cheap deterministic hash for the seed → 0..N*N grid bits.
  const grid = React.useMemo(() => {
    const bits = [];
    let h = 0;
    for (let i = 0; i < seed.length; i++) h = (h * 31 + seed.charCodeAt(i)) & 0xffffffff;
    let s = h || 1;
    for (let i = 0; i < N * N; i++) {
      s = (s * 1664525 + 1013904223) & 0xffffffff;
      bits.push(((s >>> 16) & 0xff) > 130 ? 0 : 1);
    }
    return bits;
  }, [seed]);
  const isFinder = (x, y) => {
    // top-left, top-right, bottom-left 7×7 finder patterns
    const corners = [[0, 0], [N - 7, 0], [0, N - 7]];
    return corners.some(([cx, cy]) => x >= cx && x < cx + 7 && y >= cy && y < cy + 7);
  };
  const isFinderOn = (x, y) => {
    for (const [cx, cy] of [[0, 0], [N - 7, 0], [0, N - 7]]) {
      if (x >= cx && x < cx + 7 && y >= cy && y < cy + 7) {
        const lx = x - cx, ly = y - cy;
        if (lx === 0 || lx === 6 || ly === 0 || ly === 6) return true;
        if (lx >= 2 && lx <= 4 && ly >= 2 && ly <= 4) return true;
        return false;
      }
    }
    return false;
  };
  const cell = size / N;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}
         style={{ display: 'block' }}>
      <rect width={size} height={size} fill="#fff" />
      {Array.from({ length: N }).flatMap((_, y) =>
        Array.from({ length: N }).map((_, x) => {
          const on = isFinder(x, y) ? isFinderOn(x, y) : grid[y * N + x] === 1;
          return on ? (
            <rect key={`${x},${y}`}
              x={x * cell + 0.4} y={y * cell + 0.4}
              width={cell - 0.8} height={cell - 0.8}
              rx={1.2}
              fill="#2A2722" />
          ) : null;
        })
      )}
      {/* center logo */}
      <rect x={size / 2 - 18} y={size / 2 - 18} width={36} height={36} rx={10} fill="#fff" />
      <rect x={size / 2 - 14} y={size / 2 - 14} width={28} height={28} rx={8} fill="#E8895A" />
      <text x={size / 2} y={size / 2 + 6} fontSize={18} textAnchor="middle" fill="#fff" fontWeight={700}
            fontFamily="Inter, system-ui">窝</text>
    </svg>
  );
}
