// join.jsx — 加入或创建家庭流程
// 4 pages: 入口 / 输入邀请码 / 扫码 / 创建家庭

// ─── 1. Landing: 加入 or 创建 ──────────────────────────────
function JoinOrCreatePage({ theme = 'light', onBack, onJoin, onCreate }) {
  return (
    <div data-theme={theme} className="wo-screen" style={{ background: 'var(--bg-app)' }}>
      <WoSubHeader title="" onBack={onBack} />

      <div className="wo-scroll" style={{ paddingBottom: 30 }}>
        <div style={{ padding: '8px 22px 28px' }}>
          <div style={{
            fontSize: 30, fontWeight: 700, color: 'var(--fg)',
            letterSpacing: -0.6, lineHeight: 1.2,
          }}>
            想加入哪一个<br/>窝？
          </div>
          <div style={{ fontSize: 14, color: 'var(--fg-mid)', marginTop: 10, lineHeight: 1.6 }}>
            一个人可以加入多个家庭——和爱人的、和爸妈的、和合租室友的，都可以。
          </div>
        </div>

        <div style={{ padding: '0 18px', display: 'flex', flexDirection: 'column', gap: 14 }}>

          {/* JOIN card */}
          <button onClick={onJoin} style={{
            ...optionCardStyle,
            background: 'linear-gradient(135deg, #FCE4D4, #F0C4B4)',
            color: '#2A2722',
          }}>
            <div style={{ position: 'relative', padding: '22px 22px 24px' }}>
              <div style={{ position: 'absolute', right: -10, top: -10, fontSize: 110, opacity: 0.16, pointerEvents: 'none' }}>📨</div>
              <div style={{
                width: 56, height: 56, borderRadius: 18,
                background: 'rgba(255,255,255,0.6)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontSize: 30,
              }}>📨</div>
              <div style={{ fontSize: 19, fontWeight: 700, marginTop: 16, letterSpacing: -0.3 }}>
                加入已有家庭
              </div>
              <div style={{ fontSize: 13, opacity: 0.75, marginTop: 6, lineHeight: 1.6 }}>
                输入家人发来的邀请码，或扫一扫他们的二维码。
              </div>
              <div style={{
                display: 'inline-flex', alignItems: 'center', gap: 6,
                marginTop: 18,
                padding: '8px 14px',
                background: '#2A2722', color: '#fff',
                borderRadius: 100, fontSize: 13, fontWeight: 600,
              }}>
                输入邀请码
                <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="M4 2.5L7.5 6L4 9.5"/></svg>
              </div>
            </div>
          </button>

          {/* CREATE card */}
          <button onClick={onCreate} style={{
            ...optionCardStyle,
            background: 'var(--bg-elev)',
            border: '1px solid var(--hairline)',
            color: 'var(--fg)',
            boxShadow: 'var(--shadow-card)',
          }}>
            <div style={{ position: 'relative', padding: '22px 22px 24px' }}>
              <div style={{ position: 'absolute', right: -10, top: -10, fontSize: 110, opacity: 0.08, pointerEvents: 'none' }}>🏡</div>
              <div style={{
                width: 56, height: 56, borderRadius: 18,
                background: 'var(--accent-soft)',
                color: 'var(--accent-deep)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontSize: 30,
              }}>🏡</div>
              <div style={{ fontSize: 19, fontWeight: 700, marginTop: 16, letterSpacing: -0.3 }}>
                创建一个新家
              </div>
              <div style={{ fontSize: 13, color: 'var(--fg-mid)', marginTop: 6, lineHeight: 1.6 }}>
                取个名字，再邀请家人加入。你将成为这个家的主理人。
              </div>
              <div style={{
                display: 'inline-flex', alignItems: 'center', gap: 6,
                marginTop: 18,
                padding: '8px 14px',
                background: 'var(--accent)', color: '#fff',
                borderRadius: 100, fontSize: 13, fontWeight: 600,
              }}>
                现在开始
                <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="M4 2.5L7.5 6L4 9.5"/></svg>
              </div>
            </div>
          </button>
        </div>

        <div style={{
          padding: '28px 22px 12px',
          fontSize: 12, color: 'var(--fg-dim)', lineHeight: 1.6, textAlign: 'center',
        }}>
          一个用户最多可加入 8 个家庭<br/>
          数据只在你加入的家庭内可见
        </div>
      </div>
    </div>
  );
}

const optionCardStyle = {
  width: '100%',
  border: 'none',
  borderRadius: 24,
  overflow: 'hidden',
  textAlign: 'left',
  padding: 0,
  cursor: 'pointer',
};

// ─── 2. Join by code ─────────────────────────────────────
function JoinByCodePage({ theme = 'light', onBack, onScan }) {
  // The "code" array — 8 char invite, 2 segments of 4. WO-XXXX-XXXX format
  // shown as segmented inputs.
  const [segs, setSegs] = React.useState(['3F2K', '']);
  const [activeSeg, setActiveSeg] = React.useState(1);
  const filled = segs[0].length === 4 && segs[1].length === 4;

  return (
    <div data-theme={theme} className="wo-screen" style={{ background: 'var(--bg-app)' }}>
      <WoSubHeader title="加入家庭" onBack={onBack} />

      <div className="wo-scroll" style={{ paddingBottom: 130 }}>
        <div style={{ padding: '4px 22px 24px' }}>
          <div style={{
            fontSize: 24, fontWeight: 700, color: 'var(--fg)',
            letterSpacing: -0.5, lineHeight: 1.3,
          }}>
            输入邀请码
          </div>
          <div style={{ fontSize: 13, color: 'var(--fg-mid)', marginTop: 8, lineHeight: 1.6 }}>
            家人会发给你一串 8 位的邀请码，<br/>
            或者直接扫他们的二维码。
          </div>
        </div>

        {/* Segmented code field */}
        <div style={{
          padding: '0 22px',
          display: 'flex', alignItems: 'center', gap: 10, justifyContent: 'center',
        }}>
          <span style={{
            fontSize: 18, fontWeight: 700, color: 'var(--fg-dim)',
            fontFamily: 'Inter, system-ui', letterSpacing: 1,
          }}>WO</span>
          <span style={{ color: 'var(--fg-dim)', fontWeight: 600 }}>−</span>
          {[0, 1].map(i => (
            <React.Fragment key={i}>
              <div onClick={() => setActiveSeg(i)} style={{
                display: 'flex', gap: 4,
                padding: '12px 14px',
                background: 'var(--bg-elev)',
                borderRadius: 14,
                boxShadow: activeSeg === i ? '0 0 0 2px var(--accent)' : 'var(--shadow-card)',
                minWidth: 96,
              }}>
                {Array.from({ length: 4 }).map((_, k) => (
                  <span key={k} style={{
                    width: 16, textAlign: 'center',
                    fontSize: 22, fontWeight: 700,
                    color: 'var(--fg)',
                    fontFamily: 'Inter, system-ui',
                    letterSpacing: 0,
                  }}>{segs[i][k] || (activeSeg === i && k === segs[i].length ? '|' : '_')}</span>
                ))}
              </div>
              {i === 0 && <span style={{ color: 'var(--fg-dim)', fontWeight: 600 }}>−</span>}
            </React.Fragment>
          ))}
        </div>

        <div style={{
          padding: '16px 22px 0',
          fontSize: 12, color: 'var(--fg-dim)', textAlign: 'center',
        }}>
          字母不分大小写
        </div>

        {/* Scan shortcut */}
        <div style={{ padding: '24px 18px 0' }}>
          <button onClick={onScan} style={{
            width: '100%',
            padding: '14px 18px',
            background: 'var(--bg-elev)',
            border: '1px solid var(--hairline)',
            borderRadius: 16,
            boxShadow: 'var(--shadow-card)',
            display: 'flex', alignItems: 'center', gap: 14,
            cursor: 'pointer',
          }}>
            <div style={{
              width: 40, height: 40, borderRadius: 12,
              background: 'var(--bg-tint)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 20,
            }}>📷</div>
            <div style={{ flex: 1, textAlign: 'left' }}>
              <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>扫码加入</div>
              <div style={{ fontSize: 11.5, color: 'var(--fg-mid)', marginTop: 1 }}>请家人打开「邀请加入」二维码</div>
            </div>
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" style={{ color: 'var(--fg-dim)' }}>
              <path d="M5 3l4 4-4 4"/>
            </svg>
          </button>
        </div>

        {/* Recent invites */}
        <WoSectionTitle>最近收到的邀请</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)', borderRadius: 18,
            overflow: 'hidden', boxShadow: 'var(--shadow-card)',
          }}>
            <WoListRow leading="🌷" leadingBg="#FCE4D4"
              title="妈妈邀请你加入「老家」"
              subtitle="3 分钟前 · 仍然有效" chevron />
            <WoListRow leading="🌆" leadingBg="#C8DCE6"
              title="阿哲邀请你加入「深圳出租屋」"
              subtitle="昨天 21:38 · 已加入" trailing="✓" last />
          </div>
        </div>

        <div style={{
          padding: '20px 22px 12px',
          fontSize: 11, color: 'var(--fg-dim)', lineHeight: 1.6, textAlign: 'center',
        }}>
          加入后，主理人会收到通知；<br/>
          24 小时未确认会自动失效。
        </div>
      </div>

      {/* Sticky bottom CTA */}
      <div style={{
        position: 'absolute', left: 0, right: 0, bottom: 0,
        padding: '12px 18px 14px',
        background: 'color-mix(in srgb, var(--bg) 82%, transparent)',
        backdropFilter: 'blur(20px)',
        WebkitBackdropFilter: 'blur(20px)',
        borderTop: '1px solid var(--hairline)',
      }}>
        <button style={{
          width: '100%',
          padding: '14px',
          background: filled ? 'var(--accent)' : 'var(--bg-tint)',
          color: filled ? '#fff' : 'var(--fg-dim)',
          border: 'none', borderRadius: 14,
          fontSize: 15, fontWeight: 600,
          boxShadow: filled ? 'var(--shadow-fab)' : 'none',
        }}>
          {filled ? '加入家庭' : '请输入完整邀请码'}
        </button>
      </div>
    </div>
  );
}

// ─── 3. Scan camera mock ─────────────────────────────────
function ScanPage({ theme = 'light', onBack, onManual }) {
  // We ignore theme here — camera UI is always dark surface, status text white.
  return (
    <div data-theme={theme} className="wo-screen" style={{ background: '#0d0d0d' }}>
      <div style={{
        height: '100%', position: 'relative',
        background: 'radial-gradient(circle at 30% 30%, #2a2a2a, #0d0d0d 80%)',
        color: '#fff',
      }}>
        {/* top bar */}
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          padding: '12px 18px 4px',
        }}>
          <button onClick={onBack} style={{
            width: 38, height: 38, borderRadius: 12,
            background: 'rgba(255,255,255,0.12)',
            color: '#fff', border: 'none', cursor: 'pointer',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
              <path d="M12.5 4L6.5 10l6 6"/>
            </svg>
          </button>
          <span style={{ fontSize: 16, fontWeight: 600 }}>扫码加入</span>
          <button style={{
            width: 38, height: 38, borderRadius: 12,
            background: 'rgba(255,255,255,0.12)',
            color: '#fff', border: 'none', cursor: 'pointer',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontSize: 18,
          }}>💡</button>
        </div>

        {/* Camera frame */}
        <div style={{
          position: 'absolute', top: '50%', left: '50%',
          transform: 'translate(-50%, -54%)',
          width: 256, height: 256,
        }}>
          {/* corners */}
          {[
            { top: 0, left: 0, t: 1, l: 1 },
            { top: 0, right: 0, t: 1, r: 1 },
            { bottom: 0, left: 0, b: 1, l: 1 },
            { bottom: 0, right: 0, b: 1, r: 1 },
          ].map((c, i) => (
            <div key={i} style={{
              position: 'absolute', width: 30, height: 30,
              borderColor: '#E8895A',
              borderStyle: 'solid',
              borderWidth: `${c.t ? 3 : 0}px ${c.r ? 3 : 0}px ${c.b ? 3 : 0}px ${c.l ? 3 : 0}px`,
              borderRadius: 4,
              ...c,
            }} />
          ))}
          {/* scan line */}
          <div style={{
            position: 'absolute', left: 12, right: 12, top: '40%',
            height: 2,
            background: 'linear-gradient(90deg, transparent, #E8895A, transparent)',
            borderRadius: 2,
            boxShadow: '0 0 12px rgba(232,137,90,0.65)',
          }} />
          {/* pseudo QR ghost */}
          <div style={{
            position: 'absolute', inset: 24,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            opacity: 0.18,
          }}>
            <WoQRCode seed="DEMO" size={200} />
          </div>
        </div>

        {/* Instructions */}
        <div style={{
          position: 'absolute', left: 0, right: 0, bottom: 180,
          textAlign: 'center', padding: '0 24px',
        }}>
          <div style={{ fontSize: 17, fontWeight: 600 }}>把二维码对准框内</div>
          <div style={{ fontSize: 13, opacity: 0.7, marginTop: 6, lineHeight: 1.6 }}>
            如果家人在你身边，请他们打开<br/>
            「我的 → 邀请加入」二维码
          </div>
        </div>

        {/* Bottom row */}
        <div style={{
          position: 'absolute', left: 0, right: 0, bottom: 28,
          display: 'flex', justifyContent: 'center', gap: 28, padding: '0 24px',
        }}>
          <CamButton emoji="🖼️" label="相册" />
          <CamButton emoji="⌨️" label="手动输入" onClick={onManual} />
        </div>
      </div>
    </div>
  );
}

function CamButton({ emoji, label, onClick }) {
  return (
    <button onClick={onClick} style={{
      display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6,
      padding: '10px 16px',
      background: 'rgba(255,255,255,0.1)',
      border: 'none', borderRadius: 14,
      color: '#fff', cursor: 'pointer',
      minWidth: 88,
    }}>
      <span style={{ fontSize: 22 }}>{emoji}</span>
      <span style={{ fontSize: 12, fontWeight: 500 }}>{label}</span>
    </button>
  );
}

// ─── 4. Create family ────────────────────────────────────
const EMOJI_OPTIONS = ['🏡', '🌿', '🐱', '🐶', '☀️', '🌙', '🍊', '🌸', '🌊', '🔥', '🪐', '🌱'];

function CreateFamilyPage({ theme = 'light', onBack }) {
  const [emoji, setEmoji] = React.useState('🏡');
  const [name, setName] = React.useState('我们的窝');
  const [motto, setMotto] = React.useState('');
  const valid = name.trim().length > 0;

  return (
    <div data-theme={theme} className="wo-screen" style={{ background: 'var(--bg-app)' }}>
      <WoSubHeader title="创建新的家" onBack={onBack} />

      <div className="wo-scroll" style={{ paddingBottom: 130 }}>
        <div style={{ padding: '4px 22px 18px' }}>
          <div style={{ fontSize: 22, fontWeight: 700, color: 'var(--fg)', letterSpacing: -0.4 }}>
            起个温柔的名字
          </div>
          <div style={{ fontSize: 13, color: 'var(--fg-mid)', marginTop: 6, lineHeight: 1.6 }}>
            这个名字会出现在每位家人的首页顶部，之后随时可以改。
          </div>
        </div>

        {/* Preview card */}
        <div style={{ padding: '0 18px 18px' }}>
          <div style={{
            padding: 22,
            background: 'linear-gradient(160deg, #FCE4D4, #F4D9BD)',
            borderRadius: 22,
            color: '#2A2722',
            position: 'relative', overflow: 'hidden',
          }}>
            <div style={{ position: 'absolute', right: -10, top: -10, fontSize: 100, opacity: 0.16 }}>{emoji}</div>
            <div style={{ fontSize: 10, fontWeight: 600, letterSpacing: 0.4, opacity: 0.7 }}>预览</div>
            <div style={{
              width: 60, height: 60, borderRadius: 18,
              background: 'rgba(255,255,255,0.6)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 32, marginTop: 8,
            }}>{emoji}</div>
            <div style={{ fontSize: 22, fontWeight: 700, letterSpacing: -0.4, marginTop: 12 }}>
              {name || '我们的窝'}
            </div>
            <div style={{ fontSize: 12, opacity: 0.7, marginTop: 4 }}>
              {motto || '加一句话，描述这个家'}
            </div>
          </div>
        </div>

        {/* Emoji picker */}
        <WoSectionTitle>选个图标</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)', borderRadius: 18, padding: 12,
            display: 'grid', gridTemplateColumns: 'repeat(6, 1fr)', gap: 6,
            boxShadow: 'var(--shadow-card)',
          }}>
            {EMOJI_OPTIONS.map(e => {
              const active = e === emoji;
              return (
                <button key={e} onClick={() => setEmoji(e)} style={{
                  aspectRatio: '1 / 1',
                  border: 'none',
                  background: active ? 'var(--accent-soft)' : 'transparent',
                  boxShadow: active ? 'inset 0 0 0 2px var(--accent)' : 'none',
                  borderRadius: 12,
                  fontSize: 24,
                  cursor: 'pointer',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  transition: 'background 0.12s',
                }}>{e}</button>
              );
            })}
          </div>
        </div>

        {/* Name */}
        <WoSectionTitle>家的名字</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)', borderRadius: 14,
            padding: '14px 16px',
            boxShadow: 'var(--shadow-card)',
            display: 'flex', alignItems: 'center', gap: 10,
          }}>
            <input value={name} onChange={e => setName(e.target.value)}
              placeholder="例如：栗子的窝"
              style={{
                flex: 1, border: 'none', outline: 'none',
                background: 'transparent',
                fontSize: 15, color: 'var(--fg)', fontWeight: 500,
                fontFamily: 'inherit',
              }} />
            <span style={{
              fontSize: 11, color: 'var(--fg-dim)',
              fontFamily: 'Inter, system-ui',
            }}>{name.length} / 16</span>
          </div>
        </div>

        {/* Motto */}
        <WoSectionTitle hint="可不填">一句话标语</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)', borderRadius: 14,
            padding: '14px 16px',
            boxShadow: 'var(--shadow-card)',
          }}>
            <input value={motto} onChange={e => setMotto(e.target.value)}
              placeholder="例如：一家三口，二人一猫"
              style={{
                width: '100%', border: 'none', outline: 'none',
                background: 'transparent',
                fontSize: 14, color: 'var(--fg)',
                fontFamily: 'inherit',
              }} />
          </div>
        </div>

        {/* Your role */}
        <WoSectionTitle>你的身份</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)', borderRadius: 18,
            overflow: 'hidden', boxShadow: 'var(--shadow-card)',
            padding: '14px 16px',
            display: 'flex', alignItems: 'center', gap: 12,
          }}>
            <div style={{
              width: 36, height: 36, borderRadius: 12,
              background: 'var(--accent-soft)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 18,
            }}>👑</div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>主理人 (Owner)</div>
              <div style={{ fontSize: 11.5, color: 'var(--fg-mid)', marginTop: 1 }}>创建者默认身份 · 可管理一切</div>
            </div>
          </div>
        </div>

        <div style={{
          padding: '24px 22px 12px',
          fontSize: 11, color: 'var(--fg-dim)', lineHeight: 1.6, textAlign: 'center',
        }}>
          创建后可立即邀请家人加入<br/>
          数据存放在你的账号下，可随时删除
        </div>
      </div>

      {/* Sticky CTA */}
      <div style={{
        position: 'absolute', left: 0, right: 0, bottom: 0,
        padding: '12px 18px 14px',
        background: 'color-mix(in srgb, var(--bg) 82%, transparent)',
        backdropFilter: 'blur(20px)',
        WebkitBackdropFilter: 'blur(20px)',
        borderTop: '1px solid var(--hairline)',
      }}>
        <button style={{
          width: '100%',
          padding: '14px',
          background: valid ? 'var(--accent)' : 'var(--bg-tint)',
          color: valid ? '#fff' : 'var(--fg-dim)',
          border: 'none', borderRadius: 14,
          fontSize: 15, fontWeight: 600,
          boxShadow: valid ? 'var(--shadow-fab)' : 'none',
        }}>
          创建并邀请家人
        </button>
      </div>
    </div>
  );
}

Object.assign(window, {
  JoinOrCreatePage, JoinByCodePage, ScanPage, CreateFamilyPage,
});
