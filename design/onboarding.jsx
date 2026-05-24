// onboarding.jsx — 3-screen first-launch flow

// Inject keyframes for the orbiting / drifting visuals
if (typeof document !== 'undefined' && !document.getElementById('wo-onb-keys')) {
  const s = document.createElement('style');
  s.id = 'wo-onb-keys';
  s.textContent = `
    @keyframes wo-float-a { 0%,100% { transform: translateY(0) rotate(-4deg) } 50% { transform: translateY(-6px) rotate(-4deg) } }
    @keyframes wo-float-b { 0%,100% { transform: translateY(0) rotate(3deg) }  50% { transform: translateY(6px)  rotate(3deg) } }
    @keyframes wo-float-c { 0%,100% { transform: translateY(0) rotate(-2deg) } 50% { transform: translateY(-4px) rotate(-2deg) } }
  `;
  document.head.appendChild(s);
}

// ────────────────────────────────────────────────────────────
// Onboarding shell — common chrome (progress + skip + CTA)
// ────────────────────────────────────────────────────────────
const ONB_STEPS = [
  {
    eyebrow: '欢迎来到「窝」',
    title: ['家',  '是这里的单位。'],
    body: '每件值得记住的事，都和一个具体的家有关。这就是为什么「窝」从家庭开始，而不是个人。',
    cta: '继续',
  },
  {
    eyebrow: '一个家，自己拼起来',
    title: ['想要什么功能，', '装什么插件。'],
    body: '记账、相册、家务、纪念日……功能是积木。每家有每家的样子，不必塞给你不想要的东西。',
    cta: '继续',
  },
  {
    eyebrow: '不只一个家',
    title: ['和爱人的窝，', '和爸妈的窝。'],
    body: '同一个账号，可以加入多个家庭。在每个家里，你可能是主理人、家人、或者爸妈眼里的小孩。',
    cta: '现在开始',
  },
];

function OnboardingPage({ theme = 'light', step = 1 }) {
  const idx = Math.max(1, Math.min(3, step)) - 1;
  const s = ONB_STEPS[idx];

  return (
    <div data-theme={theme} className="wo-screen" style={{ background: 'var(--bg-app)' }}>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>

        {/* Top: progress + skip */}
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          padding: '8px 22px 0', minHeight: 44,
        }}>
          <div style={{ display: 'flex', gap: 6 }}>
            {[0,1,2].map(i => (
              <div key={i} style={{
                height: 4,
                width: i === idx ? 22 : 14,
                borderRadius: 2,
                background: i === idx ? 'var(--accent)' : (i < idx ? 'var(--fg-dim)' : 'var(--hairline)'),
                transition: 'all 0.2s',
              }} />
            ))}
          </div>
          {idx < 2 && (
            <button style={{
              background: 'transparent', border: 'none', cursor: 'pointer',
              color: 'var(--fg-mid)', fontSize: 13, padding: '6px 10px',
              fontFamily: 'inherit',
            }}>跳过</button>
          )}
        </div>

        {/* Visual */}
        <div style={{
          flex: '1 1 auto', minHeight: 320,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          padding: '8px 22px',
        }}>
          {idx === 0 && <Visual1 />}
          {idx === 1 && <Visual2 />}
          {idx === 2 && <Visual3 />}
        </div>

        {/* Copy + CTA */}
        <div style={{
          padding: '0 26px 32px',
        }}>
          {s.eyebrow && (
            <div style={{
              fontSize: 11, fontWeight: 600,
              color: 'var(--accent-deep)',
              letterSpacing: 0.6, textTransform: 'none',
              marginBottom: 12,
            }}>{s.eyebrow}</div>
          )}
          <div style={{
            fontSize: 32, fontWeight: 700, color: 'var(--fg)',
            letterSpacing: -0.8, lineHeight: 1.18,
          }}>
            {s.title[0]}<br/><span style={{ color: 'var(--fg-mid)', fontWeight: 600 }}>{s.title[1]}</span>
          </div>
          <div style={{
            fontSize: 14, color: 'var(--fg-mid)',
            marginTop: 14, lineHeight: 1.7,
            maxWidth: 340,
          }}>{s.body}</div>

          <button style={{
            marginTop: 28, width: '100%',
            padding: '15px',
            background: 'var(--accent)', color: '#fff',
            border: 'none', borderRadius: 16,
            fontSize: 15, fontWeight: 600,
            boxShadow: 'var(--shadow-fab)',
            cursor: 'pointer',
            letterSpacing: -0.1,
          }}>{s.cta}</button>

          {idx === 2 && (
            <button style={{
              display: 'block', margin: '14px auto 0',
              background: 'transparent', border: 'none', cursor: 'pointer',
              fontSize: 13, color: 'var(--fg-mid)',
              padding: '6px 12px',
              fontFamily: 'inherit',
            }}>已经有账号？登录</button>
          )}
        </div>
      </div>
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// Visual 1 — 家庭头像 + 围绕的成员气泡
// ────────────────────────────────────────────────────────────
function Visual1() {
  return (
    <div style={{ position: 'relative', width: 280, height: 280 }}>
      {/* central home card */}
      <div style={{
        position: 'absolute', top: '50%', left: '50%',
        transform: 'translate(-50%, -50%)',
        width: 168, height: 168, borderRadius: 36,
        background: 'linear-gradient(160deg, #FCE4D4, #F0C4B4)',
        boxShadow: '0 10px 30px rgba(200,140,100,0.28)',
        display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
      }}>
        <div style={{
          fontSize: 64, lineHeight: 1,
        }}>🏡</div>
        <div style={{
          marginTop: 12,
          fontSize: 13, fontWeight: 600, color: '#2A2722',
          letterSpacing: -0.2,
        }}>栗子的窝</div>
        <div style={{ fontSize: 10.5, color: 'rgba(42,39,34,0.6)', marginTop: 2 }}>
          2 人 · 1 猫
        </div>
      </div>

      {/* member bubbles */}
      {[
        { emoji: '🌼', name: '小柚', x: -18, y: 24,  bg: '#FCE4D4', anim: 'wo-float-a' },
        { emoji: '🌊', name: '阿哲', x: 248, y: 16,  bg: '#D4E5F5', anim: 'wo-float-b' },
        { emoji: '🐱', name: '栗子', x: 226, y: 226, bg: '#E8D0E0', anim: 'wo-float-c' },
      ].map(m => (
        <div key={m.name} style={{
          position: 'absolute', left: m.x, top: m.y,
          animation: m.anim + ' 5s ease-in-out infinite',
        }}>
          <div style={{
            width: 62, height: 62, borderRadius: 18,
            background: m.bg,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontSize: 30,
            boxShadow: '0 6px 18px rgba(0,0,0,0.08)',
          }}>{m.emoji}</div>
          <div style={{
            fontSize: 10, color: 'var(--fg-mid)', fontWeight: 500,
            textAlign: 'center', marginTop: 4,
          }}>{m.name}</div>
        </div>
      ))}

      {/* connecting lines (faint) */}
      <svg width="280" height="280" style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
        <g stroke="rgba(200,140,100,0.25)" strokeWidth="1.4" strokeDasharray="3 4" fill="none">
          <path d="M48 70 Q90 110 120 130"/>
          <path d="M242 56 Q200 90 168 122"/>
          <path d="M232 244 Q190 200 170 168"/>
        </g>
      </svg>
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// Visual 2 — 插件卡片网格漂浮
// ────────────────────────────────────────────────────────────
function Visual2() {
  const tiles = [
    { e: '📷', t: '相册',    bg: '#E8DCC8', rot: -6, y: 0,   delay: 0.0 },
    { e: '💰', t: '记账',    bg: '#E8D4A8', rot: 4,  y: -12, delay: 0.2 },
    { e: '🎂', t: '纪念日',  bg: '#F0C4B4', rot: -3, y: 14,  delay: 0.4 },
    { e: '🧹', t: '家务',    bg: '#D6DCC8', rot: 6,  y: -6,  delay: 0.1 },
    { e: '🎬', t: '一起看片', bg: '#D6C8E0', rot: -4, y: 8,   delay: 0.3 },
    { e: '🍜', t: '今晚吃啥', bg: '#F4D9BD', rot: 5,  y: -4,  delay: 0.5 },
  ];
  return (
    <div style={{
      position: 'relative', width: 300, height: 280,
    }}>
      <div style={{
        display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 14,
        padding: 10,
      }}>
        {tiles.map((p, i) => (
          <div key={p.t} style={{
            background: p.bg,
            borderRadius: 22,
            padding: '14px 8px',
            display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8,
            transform: `rotate(${p.rot}deg) translateY(${p.y}px)`,
            boxShadow: '0 6px 18px rgba(0,0,0,0.08)',
            animation: `wo-float-${['a','b','c'][i % 3]} ${4 + i * 0.4}s ease-in-out infinite`,
            animationDelay: `${p.delay}s`,
          }}>
            <span style={{ fontSize: 30, lineHeight: 1 }}>{p.e}</span>
            <span style={{ fontSize: 10, color: '#2A2722', fontWeight: 600 }}>{p.t}</span>
          </div>
        ))}
      </div>

      {/* faint dashed plus indicating "more" */}
      <div style={{
        position: 'absolute', bottom: -8, left: '50%', transform: 'translateX(-50%)',
        display: 'flex', alignItems: 'center', gap: 6,
        padding: '6px 14px',
        background: 'var(--bg-elev)',
        border: '1.5px dashed var(--hairline)',
        borderRadius: 100,
        fontSize: 11, color: 'var(--fg-mid)', fontWeight: 500,
      }}>
        <span style={{ fontSize: 14 }}>＋</span>
        还有 26 个
      </div>
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// Visual 3 — 三个家庭层叠
// ────────────────────────────────────────────────────────────
function Visual3() {
  const homes = [
    { name: '老家',       emoji: '🌷', role: '家人',   bg: 'linear-gradient(160deg, #FAE8D0, #F4D9BD)', y: 28, x: -52, rot: -8,  z: 1 },
    { name: '栗子的窝',   emoji: '🏡', role: '主理人', bg: 'linear-gradient(160deg, #FCE4D4, #F0C4B4)', y: 0,  x: 0,   rot: 0,   z: 3, current: true },
    { name: '深圳出租屋', emoji: '🌆', role: '家人',   bg: 'linear-gradient(160deg, #DCE7F0, #C8DCE6)', y: 28, x: 52,  rot: 8,   z: 1 },
  ];
  return (
    <div style={{ position: 'relative', width: 300, height: 260 }}>
      {homes.map(h => (
        <div key={h.name} style={{
          position: 'absolute', top: 16, left: '50%',
          transform: `translateX(calc(-50% + ${h.x}px)) translateY(${h.y}px) rotate(${h.rot}deg)`,
          width: 184, padding: 18,
          background: h.bg,
          borderRadius: 24,
          boxShadow: h.current
            ? '0 12px 30px rgba(200,140,100,0.32), 0 0 0 2px rgba(255,255,255,0.85)'
            : '0 6px 20px rgba(0,0,0,0.08)',
          zIndex: h.z, color: '#2A2722',
        }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 10,
          }}>
            <div style={{
              width: 40, height: 40, borderRadius: 14,
              background: 'rgba(255,255,255,0.55)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 22,
            }}>{h.emoji}</div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 14, fontWeight: 700, letterSpacing: -0.2 }}>{h.name}</div>
              <div style={{ fontSize: 10.5, opacity: 0.7, marginTop: 1 }}>{h.role}</div>
            </div>
          </div>
          {h.current && (
            <div style={{
              marginTop: 12,
              fontSize: 10, fontWeight: 600,
              color: '#C76A3F',
              display: 'flex', alignItems: 'center', gap: 6,
            }}>
              <span style={{
                width: 7, height: 7, borderRadius: '50%',
                background: '#C76A3F',
              }} />
              当前家庭
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

window.OnboardingPage = OnboardingPage;
