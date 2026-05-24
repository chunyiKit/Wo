// shell.jsx — Custom warm Android shell for Wo
// Provides: <WoShell theme size> with status bar, gesture nav, and a
// scrollable content area. Replaces the Material-green AndroidDevice from
// the starter so colors match the Wo design system.

const WO_SIZE = { w: 412, h: 915 };

function WoStatusBar({ dark }) {
  const c = dark ? '#F2EDE5' : '#2A2722';
  return (
    <div style={{
      height: 40, display: 'flex', alignItems: 'center',
      justifyContent: 'space-between', padding: '0 22px',
      position: 'relative', flexShrink: 0,
      fontFamily: 'Roboto, "HarmonyOS Sans SC", system-ui, sans-serif',
    }}>
      <span style={{ fontSize: 14, fontWeight: 500, letterSpacing: 0.2, color: c }}>9:41</span>
      <div style={{
        position: 'absolute', left: '50%', top: 8, transform: 'translateX(-50%)',
        width: 22, height: 22, borderRadius: '50%', background: '#0d0d0d',
      }} />
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        {/* signal */}
        <svg width="15" height="11" viewBox="0 0 15 11">
          <rect x="0" y="7"  width="2.5" height="4"  rx="0.6" fill={c}/>
          <rect x="3.5" y="5"  width="2.5" height="6"  rx="0.6" fill={c}/>
          <rect x="7" y="3"  width="2.5" height="8"  rx="0.6" fill={c}/>
          <rect x="10.5" y="0" width="2.5" height="11" rx="0.6" fill={c}/>
        </svg>
        {/* wifi */}
        <svg width="14" height="11" viewBox="0 0 14 11" fill={c}>
          <path d="M7 11l2.4-2.4a3.4 3.4 0 0 0-4.8 0L7 11zM7 6.2c1.7 0 3.3.6 4.5 1.8l1.4-1.4a8.4 8.4 0 0 0-11.8 0l1.4 1.4A6.4 6.4 0 0 1 7 6.2zM7 1.5c2.9 0 5.7 1.1 7.8 3.2L13.4 6.1A9.4 9.4 0 0 0 .6 6.1L2 4.7A11 11 0 0 1 7 1.5z"/>
        </svg>
        {/* battery */}
        <svg width="22" height="11" viewBox="0 0 22 11">
          <rect x="0.5" y="0.5" width="18" height="10" rx="2.5" fill="none" stroke={c} strokeWidth="1" opacity="0.45"/>
          <rect x="2" y="2" width="13" height="7" rx="1.2" fill={c}/>
          <rect x="19.5" y="3.5" width="1.5" height="4" rx="0.5" fill={c} opacity="0.45"/>
        </svg>
      </div>
    </div>
  );
}

function WoNavBar({ dark }) {
  return (
    <div style={{
      height: 22, display: 'flex', alignItems: 'center', justifyContent: 'center',
      flexShrink: 0,
    }}>
      <div style={{
        width: 124, height: 4, borderRadius: 2,
        background: dark ? '#F2EDE5' : '#2A2722', opacity: 0.55,
      }} />
    </div>
  );
}

// WoShell — frame around a screen body. `theme` selects light/dark.
// `bezelHidden` lets you embed the screen flush in a canvas card.
function WoShell({ theme = 'light', children, scale = 1, bezelHidden = false }) {
  const dark = theme === 'dark';
  const bezel = bezelHidden ? 0 : 8;
  return (
    <div
      data-theme={theme}
      className="wo-screen"
      style={{
        width: WO_SIZE.w, height: WO_SIZE.h,
        borderRadius: bezelHidden ? 0 : 44,
        boxSizing: 'border-box',
        border: bezelHidden ? 'none' : `${bezel}px solid #15120F`,
        boxShadow: bezelHidden ? 'none' : '0 30px 70px rgba(40,28,20,0.18), 0 0 0 1.5px rgba(40,28,20,0.06)',
        overflow: 'hidden',
        display: 'flex', flexDirection: 'column',
        transform: scale === 1 ? undefined : `scale(${scale})`,
        transformOrigin: 'top left',
      }}
    >
      <WoStatusBar dark={dark} />
      <div style={{ flex: 1, position: 'relative', overflow: 'hidden' }}>
        {children}
      </div>
      <WoNavBar dark={dark} />
    </div>
  );
}

Object.assign(window, { WoShell, WoStatusBar, WoNavBar, WO_SIZE });
