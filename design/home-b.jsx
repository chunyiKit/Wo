// home-b.jsx — Direction B: 积木拼贴
// Asymmetric widget grid (1x1, 1x2, 2x1, 2x2). iOS-widget feel,
// long-press to rewire.

function HomeB({ theme = 'light', onToggleTheme }) {
  const edit = useLongPressEdit();
  const P = WO_PLUGINS;
  const [hidden, setHidden] = React.useState(new Set());
  const visible = (id) => !hidden.has(id);
  const remove = (id) => setHidden(s => { const n = new Set(s); n.add(id); return n; });

  return (
    <div data-theme={theme}
         className={'wo-screen ' + (edit.editing ? 'wo-edit' : '')}
         style={{ background: 'var(--bg-app)' }}>
      <WoTopBar
        family={WO_FAMILY}
        theme={theme}
        onToggleTheme={onToggleTheme}
        hint="3 个家庭"
        accentIcon
      />

      <div className="wo-scroll" style={{ paddingBottom: 96 }} {...edit.bind}>
        <div style={{ padding: '4px 16px 24px' }}>

          {/* Quick row */}
          <div style={{
            display: 'flex', gap: 8, padding: '6px 2px 14px',
            overflowX: 'auto', scrollbarWidth: 'none',
          }}>
            <Chip emoji="🌼" text="小柚 在家" />
            <Chip emoji="🌊" text="阿哲 出门" muted />
            <Chip emoji="🐱" text="栗子 在睡觉" />
          </div>

          {/* Grid */}
          <div style={{
            display: 'grid',
            gridTemplateColumns: '1fr 1fr',
            gridAutoRows: 'min-content',
            gap: 12,
          }}>

            {/* Anniv 1x1 — accent fill, punchy */}
            {visible('anniv') && (
              <BigAnnivWidget p={P.anniv} onRemove={() => remove('anniv')} delay="0.04s" />
            )}

            {/* Money 1x1 */}
            {visible('money') && (
              <MoneyWidget p={P.money} onRemove={() => remove('money')} delay="0.12s" />
            )}

            {/* Album 2x1 wide */}
            {visible('album') && (
              <AlbumWidget p={P.album} onRemove={() => remove('album')} delay="0.18s" />
            )}

            {/* Chore 1x1 */}
            {visible('chore') && (
              <ChoreWidget p={P.chore} onRemove={() => remove('chore')} delay="0.08s" />
            )}

            {/* Pet 1x1 */}
            {visible('pet') && (
              <PetWidget p={P.pet} onRemove={() => remove('pet')} delay="0.21s" />
            )}

            {/* Slot — Add */}
            {!edit.editing && (
              <button style={{
                gridColumn: 'span 2',
                height: 60, borderRadius: 18,
                border: '1.5px dashed var(--hairline)',
                background: 'transparent', color: 'var(--fg-mid)',
                fontSize: 14, fontWeight: 500,
                display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
              }}>
                <span style={{ fontSize: 18 }}>＋</span>
                添加插件 · 28 个可用
              </button>
            )}
            {edit.editing && (
              <div style={{
                gridColumn: 'span 2',
                padding: 14, borderRadius: 18,
                background: 'var(--accent-soft)', color: 'var(--accent-deep)',
                fontSize: 12.5, lineHeight: 1.5,
              }}>
                <div style={{ fontWeight: 600, marginBottom: 2 }}>🧩 编辑布局</div>
                拖动卡片调整位置 · 双击改变大小 · 点 − 移除
              </div>
            )}
          </div>
        </div>
      </div>

      {edit.editing
        ? <WoEditBar onDone={() => edit.setEditing(false)} />
        : <WoTabBar active="home" />}
    </div>
  );
}

// ─── Chips ────────────────────────────────────────────────

function Chip({ emoji, text, muted }) {
  return (
    <div style={{
      display: 'inline-flex', alignItems: 'center', gap: 6,
      padding: '7px 12px',
      borderRadius: 100,
      background: 'var(--bg-elev)',
      boxShadow: 'var(--shadow-card)',
      fontSize: 12, color: muted ? 'var(--fg-mid)' : 'var(--fg)', fontWeight: 500,
      whiteSpace: 'nowrap',
      flexShrink: 0,
    }}>
      <span style={{ fontSize: 14, opacity: muted ? 0.55 : 1 }}>{emoji}</span>
      {text}
    </div>
  );
}

// ─── Widgets ──────────────────────────────────────────────

function BigAnnivWidget({ p, onRemove, delay }) {
  return (
    <div className="wo-card" style={{
      aspectRatio: '1 / 1', padding: 14,
      background: 'var(--accent)', color: '#fff',
      display: 'flex', flexDirection: 'column',
      '--wiggle-delay': delay,
    }}>
      <button className="wo-remove" onClick={onRemove}>−</button>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <span style={{ fontSize: 14 }}>🎂</span>
        <span style={{ fontSize: 11.5, fontWeight: 500, opacity: 0.85 }}>纪念日</span>
      </div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
        <div style={{
          fontSize: 56, fontWeight: 700, letterSpacing: -2,
          lineHeight: 1, fontFamily: 'Inter, system-ui',
        }}>
          {p.daysLeft}
          <span style={{ fontSize: 18, fontWeight: 500, marginLeft: 4, letterSpacing: 0 }}>天</span>
        </div>
        <div style={{ fontSize: 13, fontWeight: 500, marginTop: 6, opacity: 0.95 }}>
          {p.nextLabel}
        </div>
        <div style={{ fontSize: 11, opacity: 0.75, marginTop: 2 }}>
          {p.date}
        </div>
      </div>
    </div>
  );
}

function MoneyWidget({ p, onRemove, delay }) {
  const pct = Math.min(100, (p.monthSpent / p.monthBudget) * 100);
  return (
    <div className="wo-card" style={{
      aspectRatio: '1 / 1', padding: 14,
      display: 'flex', flexDirection: 'column',
      '--wiggle-delay': delay,
    }}>
      <button className="wo-remove" onClick={onRemove}>−</button>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <span style={{ fontSize: 14 }}>💰</span>
        <span style={{ fontSize: 11.5, color: 'var(--fg-mid)', fontWeight: 500 }}>本月支出</span>
      </div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
        <div style={{
          fontSize: 30, fontWeight: 700, color: 'var(--fg)',
          letterSpacing: -1, lineHeight: 1, fontFamily: 'Inter, system-ui',
        }}>¥{p.monthSpent.toLocaleString()}</div>
        <div style={{ fontSize: 11, color: 'var(--fg-dim)', marginTop: 4 }}>
          预算 ¥{p.monthBudget.toLocaleString()} · 余 {Math.round(100 - pct)}%
        </div>
        {/* Mini bar segments */}
        <div style={{ display: 'flex', gap: 3, marginTop: 8 }}>
          {Array.from({ length: 12 }).map((_, i) => (
            <div key={i} style={{
              flex: 1, height: 6, borderRadius: 2,
              background: i < Math.round(pct / 100 * 12) ? 'var(--accent)' : 'var(--bg-tint)',
            }} />
          ))}
        </div>
      </div>
    </div>
  );
}

function AlbumWidget({ p, onRemove, delay }) {
  return (
    <div className="wo-card" style={{
      gridColumn: 'span 2',
      padding: 14,
      '--wiggle-delay': delay,
    }}>
      <button className="wo-remove" onClick={onRemove}>−</button>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{ fontSize: 14 }}>📷</span>
          <span style={{ fontSize: 12, color: 'var(--fg-mid)', fontWeight: 500 }}>家庭相册 · 本周 12 张</span>
        </div>
        <span style={{ fontSize: 11, color: 'var(--fg-dim)' }}>今日 +3</span>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 6 }}>
        {p.coverHues.map((h, i) => (
          <WoPhotoSquare key={i} hue={h} emoji={['🐱','🌅','🍜','🪴','🌸'][i]} radius={10} />
        ))}
      </div>
    </div>
  );
}

function ChoreWidget({ p, onRemove, delay }) {
  const undone = p.tasks.filter(t => !t.done).slice(0, 2);
  return (
    <div className="wo-card" style={{
      aspectRatio: '1 / 1', padding: 14,
      display: 'flex', flexDirection: 'column',
      '--wiggle-delay': delay,
    }}>
      <button className="wo-remove" onClick={onRemove}>−</button>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{ fontSize: 14 }}>🧹</span>
          <span style={{ fontSize: 11.5, color: 'var(--fg-mid)', fontWeight: 500 }}>家务</span>
        </div>
        <span style={{
          fontSize: 11, fontWeight: 600, color: 'var(--fg-mid)',
          fontFamily: 'Inter, system-ui',
        }}>{p.todayDone}/{p.todayTotal}</span>
      </div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 6, marginTop: 10 }}>
        {undone.map((t, i) => (
          <div key={i} style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '6px 8px', borderRadius: 9,
            background: 'var(--bg-tint)',
          }}>
            <span style={{ fontSize: 13 }}>{t.emoji}</span>
            <span style={{ fontSize: 11.5, color: 'var(--fg)', fontWeight: 500, flex: 1, lineHeight: 1.2 }}>{t.what}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function PetWidget({ p, onRemove, delay }) {
  return (
    <div className="wo-card" style={{
      aspectRatio: '1 / 1', padding: 0,
      overflow: 'hidden', position: 'relative',
      '--wiggle-delay': delay,
    }}>
      <button className="wo-remove" onClick={onRemove}>−</button>
      <div style={{
        position: 'absolute', inset: 0,
        background: 'linear-gradient(160deg, hsl(312 26% 76%), hsl(28 32% 76%))',
      }}>
        <div style={{
          position: 'absolute', inset: 0,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontSize: 70, transform: 'translate(8px, -2px) rotate(-6deg)',
        }}>🐱</div>
      </div>
      <div style={{
        position: 'absolute', left: 0, right: 0, bottom: 0,
        padding: '20px 12px 12px',
        background: 'linear-gradient(180deg, transparent, rgba(0,0,0,0.45))',
        color: '#fff',
      }}>
        <div style={{ fontSize: 11.5, opacity: 0.85, fontWeight: 500 }}>下顿饭 · {p.nextMeal}</div>
        <div style={{ fontSize: 14, fontWeight: 600, marginTop: 2 }}>{p.name} · {p.species}</div>
      </div>
    </div>
  );
}

window.HomeB = HomeB;
