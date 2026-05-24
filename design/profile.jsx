// profile.jsx — 我的页

const WO_ME = {
  name: '小柚',
  emoji: '🌼',
  bg: 'linear-gradient(135deg, #FCE4D4, #F0C4B4)',
  id: '@xiaoyou',
  level: 'Wo Lv.3 · 居家爱好者',
  joinedDays: 412,
  pluginsUsed: 9,
  photos: 247,
};

function ProfilePage({ theme = 'light', onOpenFamily }) {
  return (
    <div data-theme={theme} className="wo-screen" style={{ background: 'var(--bg-app)' }}>
      {/* Plain top bar with settings */}
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        padding: '12px 18px 4px',
      }}>
        <span style={{ fontSize: 17, fontWeight: 600, color: 'var(--fg)', letterSpacing: -0.2 }}>我的</span>
        <button style={{ ...iconBtnStyle, background: 'transparent' }}>
          <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.6" style={{ color: 'var(--fg)' }}>
            <circle cx="10" cy="10" r="2"/>
            <path d="M10 2v2M10 16v2M2 10h2M16 10h2M4 4l1.5 1.5M14.5 14.5L16 16M16 4l-1.5 1.5M5.5 14.5L4 16"/>
          </svg>
        </button>
      </div>

      <div className="wo-scroll" style={{ paddingBottom: 96 }}>
        {/* Profile hero */}
        <div style={{
          margin: '8px 18px 18px',
          padding: 20,
          background: WO_ME.bg,
          borderRadius: 24,
          position: 'relative', overflow: 'hidden',
        }}>
          <div style={{
            position: 'absolute', right: -20, bottom: -20,
            fontSize: 140, opacity: 0.12,
          }}>🌼</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 16, position: 'relative' }}>
            <div style={{
              width: 64, height: 64, borderRadius: 22,
              background: 'rgba(255,255,255,0.55)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 32, flexShrink: 0,
            }}>{WO_ME.emoji}</div>
            <div style={{ flex: 1, minWidth: 0, color: '#2A2722' }}>
              <div style={{ fontSize: 20, fontWeight: 700, letterSpacing: -0.4 }}>{WO_ME.name}</div>
              <div style={{ fontSize: 12, opacity: 0.7, marginTop: 2, fontFamily: 'Inter, system-ui' }}>{WO_ME.id}</div>
              <div style={{
                display: 'inline-block', marginTop: 8,
                padding: '2px 9px',
                background: 'rgba(255,255,255,0.55)',
                borderRadius: 100, fontSize: 11, fontWeight: 600,
              }}>{WO_ME.level}</div>
            </div>
          </div>

          <div style={{
            display: 'flex', marginTop: 18,
            padding: '12px 0 0', borderTop: '1px solid rgba(42,39,34,0.1)',
            color: '#2A2722', position: 'relative',
          }}>
            <MeStat label="加入天数" value={WO_ME.joinedDays} />
            <MeStat label="在用插件" value={WO_ME.pluginsUsed} />
            <MeStat label="贡献照片" value={WO_ME.photos} />
          </div>
        </div>

        {/* Joined families */}
        <WoSectionTitle hint={(1 + WO_OTHER_FAMILIES.length) + ' 个 · 可切换'}>我加入的家庭</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)', borderRadius: 18,
            overflow: 'hidden', boxShadow: 'var(--shadow-card)',
          }}>
            <FamilyRow emoji="🏡" name="栗子的窝"
              meta="主理人 · 3 成员"
              current onClick={onOpenFamily} />
            {WO_OTHER_FAMILIES.map((f, i) => (
              <FamilyRow key={f.name} emoji={f.emoji} name={f.name}
                meta={`家人 · ${f.members} 成员`} last={false} />
            ))}
            <FamilyRow leading="＋" leadingDim
              name="加入或创建家庭"
              meta="输入邀请码 / 扫一扫"
              last />
          </div>
        </div>

        {/* Settings */}
        <WoSectionTitle>设置</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)', borderRadius: 18,
            overflow: 'hidden', boxShadow: 'var(--shadow-card)',
          }}>
            <WoListRow leading="🔔" title="通知"     subtitle="3 个家庭，每个独立设置" chevron />
            <WoListRow leading="🔒" title="隐私与安全"   subtitle="数据可见性、登录设备" chevron />
            <WoListRow leading="🎨" title="外观"     trailing="跟随系统" chevron />
            <WoListRow leading="🌐" title="语言"     trailing="简体中文" chevron />
            <WoListRow leading="📥" title="数据导出" subtitle="个人所有内容" last chevron />
          </div>
        </div>

        {/* About */}
        <WoSectionTitle>关于</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)', borderRadius: 18,
            overflow: 'hidden', boxShadow: 'var(--shadow-card)',
          }}>
            <WoListRow leading="💬" title="反馈与建议"  subtitle="想要的插件、不太顺手的地方" chevron />
            <WoListRow leading="📖" title="帮助中心"   chevron />
            <WoListRow leading="🌱" title="关于「窝」" trailing="v1.0.0" last chevron />
          </div>
        </div>

        <button style={{
          margin: '20px 18px 28px',
          width: 'calc(100% - 36px)',
          padding: '14px',
          background: 'var(--bg-elev)', color: '#C76A3F',
          border: 'none', borderRadius: 14,
          fontSize: 14, fontWeight: 600,
          boxShadow: 'var(--shadow-card)',
        }}>退出登录</button>
      </div>

      <WoTabBar active="me" />
    </div>
  );
}

function MeStat({ label, value }) {
  return (
    <div style={{ flex: 1 }}>
      <div style={{ fontSize: 20, fontWeight: 700, letterSpacing: -0.4, fontFamily: 'Inter, system-ui' }}>
        {value}
      </div>
      <div style={{ fontSize: 11, opacity: 0.7, marginTop: 1 }}>{label}</div>
    </div>
  );
}

function FamilyRow({ emoji, leading, leadingDim, name, meta, current, last, onClick }) {
  return (
    <div onClick={onClick} style={{
      display: 'flex', alignItems: 'center', gap: 14,
      padding: '14px 16px',
      borderBottom: last ? 'none' : '1px solid var(--hairline)',
      cursor: onClick ? 'pointer' : 'default',
    }}>
      <div style={{
        width: 40, height: 40, borderRadius: 13,
        background: leadingDim ? 'var(--bg-tint)' : (current ? 'var(--accent-soft)' : 'var(--bg-tint)'),
        color: leadingDim ? 'var(--fg-mid)' : 'var(--fg)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontSize: leading ? 22 : 20, fontWeight: leading ? 300 : 400,
        flexShrink: 0,
        border: leadingDim ? '1.5px dashed var(--hairline)' : 'none',
      }}>{emoji || leading}</div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{ fontSize: 15, fontWeight: 600, color: 'var(--fg)' }}>{name}</span>
          {current && (
            <span style={{
              padding: '1px 7px',
              background: 'var(--accent)', color: '#fff',
              borderRadius: 100, fontSize: 10, fontWeight: 600,
            }}>当前</span>
          )}
        </div>
        <div style={{ fontSize: 11.5, color: 'var(--fg-mid)', marginTop: 2 }}>{meta}</div>
      </div>
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" style={{ color: 'var(--fg-dim)', flexShrink: 0 }}>
        <path d="M5 3l4 4-4 4"/>
      </svg>
    </div>
  );
}

window.ProfilePage = ProfilePage;
