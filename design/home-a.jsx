// home-a.jsx — Direction A: 温润日常
// Hero album card + 2-column waterfall. Calm rhythm.

function HomeA({ theme = 'light', onToggleTheme, defaultSheet = null }) {
  const edit = useLongPressEdit();
  const P = WO_PLUGINS;
  const [sheet, setSheet] = React.useState(defaultSheet);

  // Card list for edit-mode removal (visual only — just hides on click)
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
        hint="2 个人 · 1 只猫"
        onTapFamily={() => setSheet('family')}
      />

      <div className="wo-scroll" style={{ paddingBottom: 96 }}
           {...edit.bind}>
        <div style={{ padding: '4px 18px 24px', display: 'flex', flexDirection: 'column', gap: 12 }}>

          {/* Greeting */}
          <div style={{ padding: '6px 4px 2px' }}>
            <div style={{ fontSize: 22, fontWeight: 600, color: 'var(--fg)', letterSpacing: -0.4 }}>
              下午好，小柚 <span style={{ opacity: 0.7 }}>🌼</span>
            </div>
            <div style={{ fontSize: 13, color: 'var(--fg-mid)', marginTop: 4 }}>
              今天是和阿哲在一起的第 1077 天
            </div>
          </div>

          {/* Hero — Album */}
          {visible('album') && (
          <div className="wo-card" style={{ '--wiggle-delay': '0s' }}>
            <button className="wo-remove" onClick={() => remove('album')}>−</button>
            <div style={{ padding: 16, display: 'flex', gap: 14, alignItems: 'center' }}>
              <div style={{ position: 'relative', width: 116, height: 96, flexShrink: 0 }}>
                {P.album.coverHues.slice(0, 3).map((h, i) => (
                  <div key={i} style={{
                    position: 'absolute', top: i * 6, left: i * 14,
                    width: 84, height: 84, borderRadius: 14,
                    boxShadow: '0 2px 6px rgba(0,0,0,0.12)',
                    transform: `rotate(${(i - 1) * 4}deg)`,
                  }}>
                    <WoPhotoSquare hue={h} emoji={['🐱', '🌅', '🍜'][i]} radius={14} />
                  </div>
                ))}
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 4 }}>
                  <span style={{ fontSize: 14 }}>📷</span>
                  <span style={{ fontSize: 13, color: 'var(--fg-mid)', fontWeight: 500 }}>家庭相册</span>
                </div>
                <div style={{ fontSize: 17, color: 'var(--fg)', fontWeight: 600, lineHeight: 1.35, letterSpacing: -0.2 }}>
                  本周一起拍了 12 张
                </div>
                <div style={{ fontSize: 12, color: 'var(--fg-dim)', marginTop: 6 }}>
                  阿哲今天加了 3 张 · 大多是栗子
                </div>
              </div>
            </div>
          </div>
          )}

          {/* 2-column waterfall */}
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>

            {/* Left col */}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              {visible('money') && <MoneyCard p={P.money} onRemove={() => remove('money')} delay="0.05s" />}
              {visible('chore') && <ChoreCard p={P.chore} onRemove={() => remove('chore')} delay="0.18s" />}
            </div>

            {/* Right col */}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              {visible('anniv') && <AnnivCard p={P.anniv} onRemove={() => remove('anniv')} delay="0.11s" />}
              {visible('pet') && <PetCard p={P.pet} onRemove={() => remove('pet')} delay="0.22s" />}
            </div>
          </div>

          {/* Add row */}
          {!edit.editing && (
          <button onClick={() => setSheet('add')}
                  style={{
            marginTop: 4,
            background: 'transparent',
            border: '1.5px dashed var(--hairline)',
            borderRadius: 18, padding: '16px 14px',
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
            color: 'var(--fg-mid)', fontSize: 14, fontWeight: 500,
            cursor: 'pointer',
          }}>
            <span style={{ fontSize: 18 }}>＋</span>
            添加插件
            <span style={{ color: 'var(--fg-dim)', fontSize: 12, marginLeft: 4 }}>共有 32 个</span>
          </button>
          )}

          {edit.editing && (
            <div style={{
              padding: '10px 14px', borderRadius: 14,
              background: 'var(--accent-soft)', color: 'var(--accent-deep)',
              fontSize: 13, lineHeight: 1.5,
              display: 'flex', gap: 8, alignItems: 'flex-start',
            }}>
              <span style={{ fontSize: 16 }}>✋</span>
              <div>正在编辑布局 · 拖动卡片改变顺序，点击 − 移除</div>
            </div>
          )}
        </div>
      </div>

      {edit.editing
        ? <WoEditBar onDone={() => edit.setEditing(false)} />
        : <WoTabBar active="home" />}

      <FamilySwitcher open={sheet === 'family'} onClose={() => setSheet(null)} />
      <AddPluginSheet open={sheet === 'add'} onClose={() => setSheet(null)} />
    </div>
  );
}

// ─── Sub-cards ────────────────────────────────────────────────

function MoneyCard({ p, onRemove, delay }) {
  const pct = Math.min(100, (p.monthSpent / p.monthBudget) * 100);
  return (
    <div className="wo-card" style={{ padding: 14, '--wiggle-delay': delay }}>
      <button className="wo-remove" onClick={onRemove}>−</button>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 10 }}>
        <span style={{ fontSize: 14 }}>💰</span>
        <span style={{ fontSize: 12, color: 'var(--fg-mid)', fontWeight: 500 }}>本月共同记账</span>
      </div>
      <div style={{ fontSize: 24, fontWeight: 700, color: 'var(--fg)', letterSpacing: -0.6, lineHeight: 1.1, fontFamily: 'Inter, system-ui' }}>
        ¥{p.monthSpent.toLocaleString()}
      </div>
      <div style={{ fontSize: 11, color: 'var(--fg-dim)', marginTop: 2 }}>
        / ¥{p.monthBudget.toLocaleString()} 预算
      </div>
      <div style={{
        height: 5, borderRadius: 3, background: 'var(--bg-tint)',
        margin: '10px 0 12px', overflow: 'hidden',
      }}>
        <div style={{ height: '100%', width: `${pct}%`, background: 'var(--accent)', borderRadius: 3 }} />
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
        {p.recent.slice(0, 3).map((r, i) => (
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 11.5 }}>
            <span style={{
              width: 16, height: 16, borderRadius: '50%',
              background: r.who === '小柚' ? '#FCE4D4' : '#D4E5F5',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 9, color: '#2A2722',
            }}>{r.who[0]}</span>
            <span style={{ color: 'var(--fg-mid)', flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{r.what}</span>
            <span style={{ color: 'var(--fg)', fontWeight: 500, fontFamily: 'Inter, system-ui' }}>¥{r.amount}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function AnnivCard({ p, onRemove, delay }) {
  return (
    <div className="wo-card" style={{ padding: 14, background: 'var(--anniv)', '--wiggle-delay': delay }}>
      <button className="wo-remove" onClick={onRemove}>−</button>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 10 }}>
        <span style={{ fontSize: 14 }}>🎂</span>
        <span style={{ fontSize: 12, color: 'var(--fg-mid)', fontWeight: 500 }}>下一个纪念日</span>
      </div>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 4 }}>
        <span style={{ fontSize: 36, fontWeight: 700, color: 'var(--fg)', letterSpacing: -1.2, lineHeight: 1, fontFamily: 'Inter, system-ui' }}>
          {p.daysLeft}
        </span>
        <span style={{ fontSize: 14, color: 'var(--fg-mid)', fontWeight: 500 }}>天后</span>
      </div>
      <div style={{ fontSize: 13, color: 'var(--fg)', fontWeight: 500, marginTop: 8 }}>
        {p.nextLabel}
      </div>
      <div style={{ fontSize: 11, color: 'var(--fg-mid)', marginTop: 2 }}>
        {p.date} · 周一
      </div>
    </div>
  );
}

function ChoreCard({ p, onRemove, delay }) {
  const undone = p.tasks.filter(t => !t.done);
  return (
    <div className="wo-card" style={{ padding: 14, '--wiggle-delay': delay }}>
      <button className="wo-remove" onClick={onRemove}>−</button>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{ fontSize: 14 }}>🧹</span>
          <span style={{ fontSize: 12, color: 'var(--fg-mid)', fontWeight: 500 }}>今日家务</span>
        </div>
        <span style={{
          fontSize: 11, fontWeight: 600, color: 'var(--fg-mid)',
          fontFamily: 'Inter, system-ui',
        }}>{p.todayDone}/{p.todayTotal}</span>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
        {undone.map((t, i) => (
          <div key={i} style={{
            display: 'flex', alignItems: 'center', gap: 8,
            padding: '7px 10px',
            background: 'var(--bg-tint)',
            borderRadius: 10,
          }}>
            <span style={{ fontSize: 14 }}>{t.emoji}</span>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 12.5, color: 'var(--fg)', fontWeight: 500, lineHeight: 1.2 }}>{t.what}</div>
              <div style={{ fontSize: 10.5, color: 'var(--fg-dim)', marginTop: 1 }}>{t.who}</div>
            </div>
            <div style={{
              width: 16, height: 16, borderRadius: 4,
              border: '1.5px solid var(--fg-dim)',
            }} />
          </div>
        ))}
      </div>
    </div>
  );
}

function PetCard({ p, onRemove, delay }) {
  return (
    <div className="wo-card" style={{ padding: 14, '--wiggle-delay': delay }}>
      <button className="wo-remove" onClick={onRemove}>−</button>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 10 }}>
        <span style={{ fontSize: 14 }}>🐾</span>
        <span style={{ fontSize: 12, color: 'var(--fg-mid)', fontWeight: 500 }}>{p.name}今天</span>
      </div>
      <div style={{
        height: 84, borderRadius: 14, marginBottom: 10,
        background: 'linear-gradient(135deg, hsl(312 28% 80%), hsl(28 32% 78%))',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontSize: 40,
      }}>🐱</div>
      <div style={{ fontSize: 12, color: 'var(--fg-mid)', display: 'flex', justifyContent: 'space-between', marginBottom: 4 }}>
        <span>下顿饭</span>
        <span style={{ color: 'var(--fg)', fontWeight: 600, fontFamily: 'Inter, system-ui' }}>{p.nextMeal}</span>
      </div>
      <div style={{ fontSize: 12, color: 'var(--fg-mid)', display: 'flex', justifyContent: 'space-between' }}>
        <span>体重</span>
        <span style={{ color: 'var(--fg)', fontWeight: 600, fontFamily: 'Inter, system-ui' }}>{p.weight}</span>
      </div>
    </div>
  );
}

window.HomeA = HomeA;
