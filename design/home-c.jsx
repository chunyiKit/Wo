// home-c.jsx — Direction C: 故事时间线
// Magazine-feed take. Section headers + full-width row cards.
// 即刻 / Notion feel, more breathing room.

function HomeC({ theme = 'light', onToggleTheme }) {
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
      />

      <div className="wo-scroll" style={{ paddingBottom: 96 }} {...edit.bind}>

        {/* Editorial header */}
        <div style={{ padding: '12px 22px 8px' }}>
          <div style={{ fontSize: 12, color: 'var(--fg-dim)', letterSpacing: 0.4, fontWeight: 500 }}>
            5 月 22 日 · 周四 · 晴 23°
          </div>
          <div style={{
            fontSize: 30, fontWeight: 700, color: 'var(--fg)',
            letterSpacing: -0.8, lineHeight: 1.15,
            marginTop: 8,
          }}>
            下午好，小柚。<br/>
            <span style={{ color: 'var(--fg-mid)', fontWeight: 600 }}>
              栗子刚刚醒了。
            </span>
          </div>
        </div>

        {/* Section: 今天 */}
        <SectionHead title="今天" hint="3 件还没做的事" />

        {/* Anniv hero row */}
        {visible('anniv') && (
          <RowCard onRemove={() => remove('anniv')} delay="0.04s">
            <div style={{
              padding: '18px 18px 18px 18px',
              display: 'flex', alignItems: 'center', gap: 16,
            }}>
              <div style={{
                width: 76, height: 76, borderRadius: 20,
                background: 'var(--accent)', color: '#fff',
                display: 'flex', flexDirection: 'column',
                alignItems: 'center', justifyContent: 'center',
                lineHeight: 1, flexShrink: 0,
              }}>
                <div style={{ fontSize: 34, fontWeight: 700, letterSpacing: -1, fontFamily: 'Inter, system-ui' }}>
                  {P.anniv.daysLeft}
                </div>
                <div style={{ fontSize: 10, fontWeight: 500, marginTop: 2, opacity: 0.85 }}>
                  天后
                </div>
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 11, color: 'var(--fg-dim)', fontWeight: 500, letterSpacing: 0.3, marginBottom: 4 }}>
                  🎂  下一个纪念日
                </div>
                <div style={{ fontSize: 17, fontWeight: 600, color: 'var(--fg)', lineHeight: 1.3, letterSpacing: -0.2 }}>
                  {P.anniv.nextLabel}
                </div>
                <div style={{ fontSize: 12, color: 'var(--fg-mid)', marginTop: 6 }}>
                  {P.anniv.date} · 已经收到 2 条提醒
                </div>
              </div>
            </div>
          </RowCard>
        )}

        {/* Chore row */}
        {visible('chore') && (
          <RowCard onRemove={() => remove('chore')} delay="0.10s">
            <div style={{ padding: '16px 18px 8px' }}>
              <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 12 }}>
                <div style={{ fontSize: 11, color: 'var(--fg-dim)', fontWeight: 500, letterSpacing: 0.3 }}>
                  🧹  家务分工
                </div>
                <div style={{ fontSize: 12, color: 'var(--fg-mid)', fontFamily: 'Inter, system-ui', fontWeight: 600 }}>
                  {P.chore.todayDone} / {P.chore.todayTotal}
                </div>
              </div>
              <div style={{ display: 'flex', flexDirection: 'column' }}>
                {P.chore.tasks.map((t, i) => (
                  <div key={i} style={{
                    display: 'flex', alignItems: 'center', gap: 12,
                    padding: '10px 0',
                    borderTop: i ? '1px solid var(--hairline)' : 'none',
                    opacity: t.done ? 0.45 : 1,
                  }}>
                    <span style={{ fontSize: 18 }}>{t.emoji}</span>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{
                        fontSize: 14, color: 'var(--fg)', fontWeight: 500,
                        textDecoration: t.done ? 'line-through' : 'none',
                      }}>{t.what}</div>
                      <div style={{ fontSize: 11, color: 'var(--fg-dim)', marginTop: 1 }}>{t.who}</div>
                    </div>
                    <div style={{
                      width: 22, height: 22, borderRadius: 7,
                      border: t.done ? 'none' : '1.5px solid var(--hairline)',
                      background: t.done ? 'var(--accent)' : 'transparent',
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      color: '#fff', fontSize: 13,
                    }}>{t.done ? '✓' : ''}</div>
                  </div>
                ))}
              </div>
            </div>
          </RowCard>
        )}

        {/* Section: 一起花的钱 */}
        <SectionHead title="一起花的钱" hint="本月还剩 9 天" />

        {visible('money') && (
          <RowCard onRemove={() => remove('money')} delay="0.16s">
            <div style={{ padding: 18 }}>
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 4 }}>
                <span style={{
                  fontSize: 32, fontWeight: 700, color: 'var(--fg)',
                  letterSpacing: -1, fontFamily: 'Inter, system-ui',
                }}>¥{P.money.monthSpent.toLocaleString()}</span>
                <span style={{ fontSize: 13, color: 'var(--fg-mid)' }}>
                  / ¥{P.money.monthBudget.toLocaleString()}
                </span>
              </div>
              <div style={{ fontSize: 12, color: 'var(--fg-dim)', marginBottom: 12 }}>
                小柚 ¥2,180 · 阿哲 ¥1,667
              </div>
              {/* Stacked split bar */}
              <div style={{ height: 8, borderRadius: 4, overflow: 'hidden', display: 'flex', background: 'var(--bg-tint)' }}>
                <div style={{ width: `${P.money.monthSpent * 0.567 / P.money.monthBudget * 100}%`, background: 'var(--accent)' }} />
                <div style={{ width: `${P.money.monthSpent * 0.433 / P.money.monthBudget * 100}%`, background: 'hsl(28 45% 72%)' }} />
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 14, gap: 12 }}>
                {P.money.recent.slice(0, 3).map((r, i) => (
                  <div key={i} style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontSize: 16, fontWeight: 600, color: 'var(--fg)', fontFamily: 'Inter, system-ui' }}>
                      ¥{r.amount}
                    </div>
                    <div style={{
                      fontSize: 11, color: 'var(--fg-mid)', marginTop: 2,
                      overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                    }}>{r.what}</div>
                  </div>
                ))}
              </div>
            </div>
          </RowCard>
        )}

        {/* Section: 栗子 */}
        <SectionHead title="栗子" hint="距下顿饭 4 小时" />

        {visible('pet') && (
          <RowCard onRemove={() => remove('pet')} delay="0.20s">
            <div style={{ display: 'flex', alignItems: 'stretch' }}>
              <div style={{
                width: 104, alignSelf: 'stretch',
                background: 'linear-gradient(135deg, hsl(312 26% 80%), hsl(28 32% 78%))',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontSize: 56, flexShrink: 0,
              }}>🐱</div>
              <div style={{ flex: 1, padding: 16, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
                <div style={{ fontSize: 16, fontWeight: 600, color: 'var(--fg)' }}>{P.pet.name}</div>
                <div style={{ fontSize: 12, color: 'var(--fg-mid)', marginTop: 2 }}>{P.pet.species}</div>
                <div style={{ display: 'flex', gap: 14, marginTop: 12, fontSize: 12, color: 'var(--fg-mid)' }}>
                  <span>下顿饭 <b style={{ color: 'var(--fg)', fontFamily: 'Inter, system-ui', marginLeft: 2 }}>{P.pet.nextMeal}</b></span>
                  <span>体重 <b style={{ color: 'var(--fg)', fontFamily: 'Inter, system-ui', marginLeft: 2 }}>{P.pet.weight}</b></span>
                </div>
              </div>
            </div>
          </RowCard>
        )}

        {/* Section: 相册 */}
        <SectionHead title="本周的窝" hint={`新加 ${P.album.weekCount} 张`} />

        {visible('album') && (
          <RowCard onRemove={() => remove('album')} delay="0.26s">
            <div style={{ padding: '16px 0 16px 18px' }}>
              <div style={{ fontSize: 12, color: 'var(--fg-mid)', marginBottom: 12 }}>
                阿哲今天加了 3 张
              </div>
              <div style={{ display: 'flex', gap: 8, overflowX: 'auto', paddingRight: 18 }}>
                {P.album.coverHues.concat([148, 220]).map((h, i) => (
                  <div key={i} style={{ width: 96, flexShrink: 0 }}>
                    <WoPhotoSquare hue={h} emoji={['🐱','🌅','🍜','🪴','🌸','🌿','☕'][i]} radius={14} />
                    <div style={{ fontSize: 10, color: 'var(--fg-dim)', marginTop: 6 }}>
                      {['今天','今天','今天','昨天','昨天','三天前','三天前'][i]}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </RowCard>
        )}

        {/* Add insertion */}
        <div style={{ padding: '8px 18px 16px' }}>
          {!edit.editing ? (
            <button style={{
              width: '100%',
              background: 'transparent',
              border: '1.5px dashed var(--hairline)',
              borderRadius: 16, padding: '16px',
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
              color: 'var(--fg-mid)', fontSize: 14, fontWeight: 500,
            }}>
              <span style={{ fontSize: 18 }}>＋</span>
              添加更多模块
            </button>
          ) : (
            <div style={{
              padding: '12px 14px', borderRadius: 14,
              background: 'var(--accent-soft)', color: 'var(--accent-deep)',
              fontSize: 12.5, lineHeight: 1.5,
              display: 'flex', gap: 8, alignItems: 'flex-start',
            }}>
              <span style={{ fontSize: 16 }}>📐</span>
              <div>布局编辑中 · 长按拖动可调整顺序，点 − 隐藏模块</div>
            </div>
          )}
        </div>
      </div>

      {edit.editing
        ? <WoEditBar onDone={() => edit.setEditing(false)} />
        : <WoTabBar active="home" />}
    </div>
  );
}

// ─── helpers ────────────────────────────────────────────────

function SectionHead({ title, hint }) {
  return (
    <div style={{
      padding: '22px 22px 10px',
      display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
    }}>
      <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)', letterSpacing: -0.1 }}>
        {title}
      </div>
      {hint && (
        <div style={{ fontSize: 11, color: 'var(--fg-dim)' }}>{hint}</div>
      )}
    </div>
  );
}

function RowCard({ children, onRemove, delay }) {
  return (
    <div style={{ padding: '4px 18px' }}>
      <div className="wo-card" style={{ '--wiggle-delay': delay }}>
        <button className="wo-remove" onClick={onRemove}>−</button>
        {children}
      </div>
    </div>
  );
}

window.HomeC = HomeC;
