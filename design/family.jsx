// family.jsx — 家庭管理 + 邀请新成员

const WO_FAMILY_DETAIL = {
  emoji: '🏡',
  name: '栗子的窝',
  motto: '一家三口，二人一猫',
  createdAt: '2023.05.06',
  daysShared: 384,
  pluginCount: 5,
  members: [
    { id: 'a', name: '小柚', role: 'Owner',  roleLabel: '主理人', tag: '你', emoji: '🌼', tint: '#FCE4D4', joined: '创建', activity: '今天加了 3 张照片' },
    { id: 'b', name: '阿哲', role: 'Admin',  roleLabel: '管理员', emoji: '🌊', tint: '#D4E5F5', joined: '23 年 5 月加入', activity: '昨天记了一笔账' },
    { id: 'p', name: '栗子', role: 'Pet',    roleLabel: '宠物档案', emoji: '🐱', tint: '#E8D0E0', joined: '23 年 7 月添加', activity: '体重 5.2 kg' },
  ],
  pending: [
    { name: '妈妈', emoji: '🌷', expires: '剩 23 小时' },
  ],
};

const WO_OTHER_FAMILIES = [
  { name: '老家',         emoji: '🏡', members: 4, current: false },
  { name: '深圳出租屋',   emoji: '🌆', members: 3, current: false },
];

function FamilyManagePage({ theme = 'light', onBack, onInvite }) {
  const F = WO_FAMILY_DETAIL;
  return (
    <div data-theme={theme} className="wo-screen" style={{ background: 'var(--bg-app)' }}>
      <WoSubHeader title="家庭管理" onBack={onBack} trailing={
        <button style={{ ...iconBtnStyle, background: 'transparent' }}>
          <svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" style={{ color: 'var(--fg)' }}>
            <path d="M2 14l3-1 7.5-7.5a1.4 1.4 0 0 0-2-2L3 11l-1 3zM11 4l3 3"/>
          </svg>
        </button>
      } />

      <div className="wo-scroll" style={{ paddingBottom: 30 }}>
        {/* hero */}
        <div style={{
          margin: '4px 18px 18px',
          padding: 22,
          background: 'linear-gradient(160deg, #FCE4D4, #F4D9BD)',
          borderRadius: 24,
          color: '#2A2722',
          position: 'relative',
          overflow: 'hidden',
        }}>
          <div style={{
            position: 'absolute', right: -12, top: -12,
            fontSize: 120, opacity: 0.13,
          }}>🏡</div>
          <div style={{
            width: 64, height: 64, borderRadius: 20,
            background: 'rgba(255,255,255,0.6)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontSize: 36, marginBottom: 14,
            position: 'relative',
          }}>{F.emoji}</div>
          <div style={{ fontSize: 22, fontWeight: 700, letterSpacing: -0.4 }}>{F.name}</div>
          <div style={{ fontSize: 12, opacity: 0.75, marginTop: 4 }}>{F.motto}</div>

          <div style={{
            display: 'flex', gap: 18, marginTop: 18,
            padding: '12px 0 0', borderTop: '1px solid rgba(42,39,34,0.1)',
          }}>
            <Stat label="成员" value={F.members.length} />
            <Stat label="插件" value={F.pluginCount} />
            <Stat label="共享天数" value={F.daysShared} wide />
          </div>
        </div>

        {/* members */}
        <WoSectionTitle hint={F.members.length + ' 人'}>成员</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)',
            borderRadius: 18, overflow: 'hidden',
            boxShadow: 'var(--shadow-card)',
          }}>
            {F.members.map((m, i) => (
              <div key={m.id} style={{
                display: 'flex', alignItems: 'center', gap: 14,
                padding: '14px 16px',
                borderBottom: i === F.members.length - 1 ? 'none' : '1px solid var(--hairline)',
              }}>
                <div style={{
                  width: 42, height: 42, borderRadius: 14,
                  background: m.tint,
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  fontSize: 22, flexShrink: 0,
                }}>{m.emoji}</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span style={{ fontSize: 15, fontWeight: 600, color: 'var(--fg)' }}>{m.name}</span>
                    {m.tag && (
                      <span style={{
                        padding: '1px 7px',
                        background: 'var(--accent-soft)', color: 'var(--accent-deep)',
                        borderRadius: 100, fontSize: 10, fontWeight: 600,
                      }}>{m.tag}</span>
                    )}
                    <RoleBadge role={m.role} label={m.roleLabel} />
                  </div>
                  <div style={{ fontSize: 11.5, color: 'var(--fg-mid)', marginTop: 2 }}>
                    {m.activity}
                  </div>
                </div>
                <svg width="14" height="14" viewBox="0 0 14 14" fill="currentColor" style={{ color: 'var(--fg-dim)' }}>
                  <circle cx="3" cy="7" r="1.2"/><circle cx="7" cy="7" r="1.2"/><circle cx="11" cy="7" r="1.2"/>
                </svg>
              </div>
            ))}
          </div>

          {/* invite buttons */}
          <button onClick={onInvite}
                  style={{
                    width: '100%', marginTop: 12, padding: '14px',
                    border: '1.5px dashed var(--hairline)',
                    borderRadius: 16, background: 'transparent',
                    color: 'var(--accent-deep)',
                    fontSize: 14, fontWeight: 600,
                    display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
                    cursor: 'pointer',
                  }}>
            <span style={{ fontSize: 18 }}>＋</span>
            邀请家人加入
          </button>
        </div>

        {/* pending */}
        {F.pending.length > 0 && (
          <React.Fragment>
            <WoSectionTitle>等待加入</WoSectionTitle>
            <div style={{ padding: '0 18px' }}>
              <div style={{
                background: 'var(--bg-elev)',
                borderRadius: 18, overflow: 'hidden',
                boxShadow: 'var(--shadow-card)',
              }}>
                {F.pending.map((p, i) => (
                  <div key={i} style={{
                    display: 'flex', alignItems: 'center', gap: 14,
                    padding: '12px 16px',
                  }}>
                    <div style={{
                      width: 36, height: 36, borderRadius: 12,
                      background: 'var(--bg-tint)',
                      border: '1.5px dashed var(--hairline)',
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      fontSize: 18, flexShrink: 0,
                    }}>{p.emoji}</div>
                    <div style={{ flex: 1 }}>
                      <div style={{ fontSize: 14, fontWeight: 500, color: 'var(--fg)' }}>{p.name}</div>
                      <div style={{ fontSize: 11, color: 'var(--fg-mid)', marginTop: 1 }}>邀请已发送 · {p.expires}</div>
                    </div>
                    <button style={{
                      padding: '6px 12px', borderRadius: 100,
                      background: 'var(--bg-tint)', color: 'var(--fg-mid)',
                      border: 'none', fontSize: 12, fontWeight: 500,
                    }}>撤回</button>
                  </div>
                ))}
              </div>
            </div>
          </React.Fragment>
        )}

        {/* family settings */}
        <WoSectionTitle>家庭设置</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)',
            borderRadius: 18, overflow: 'hidden',
            boxShadow: 'var(--shadow-card)',
          }}>
            <WoListRow leading="📝" title="编辑家庭名片" subtitle="名称、标语、头像" chevron />
            <WoListRow leading="🔐" title="权限与可见性" subtitle="谁能加插件，谁能看记账" chevron />
            <WoListRow leading="📤" title="数据导出" subtitle="把这个家的内容备份带走" chevron />
            <WoListRow leading="🚪" title="离开家庭" danger last chevron />
          </div>
        </div>

        <div style={{
          padding: '20px 22px 10px',
          fontSize: 11, color: 'var(--fg-dim)', lineHeight: 1.6,
        }}>
          创建于 {F.createdAt} · ID：wo-fam-08F2K · 仅家庭成员可见
        </div>
      </div>
    </div>
  );
}

function Stat({ label, value, wide }) {
  return (
    <div style={{ flex: wide ? 1.4 : 1 }}>
      <div style={{ fontSize: 22, fontWeight: 700, color: '#2A2722', letterSpacing: -0.5, fontFamily: 'Inter, system-ui' }}>
        {value}
      </div>
      <div style={{ fontSize: 11, color: 'rgba(42,39,34,0.6)', marginTop: 1 }}>{label}</div>
    </div>
  );
}

function RoleBadge({ role, label }) {
  const map = {
    Owner:  { bg: '#FCE4D4', fg: '#C76A3F' },
    Admin:  { bg: '#D4E5F5', fg: '#3A6AA8' },
    Member: { bg: 'var(--bg-tint)', fg: 'var(--fg-mid)' },
    Pet:    { bg: '#E8D0E0', fg: '#8A4F7A' },
    Child:  { bg: '#DAE6C8', fg: '#5A7A3C' },
  };
  const c = map[role] || map.Member;
  return (
    <span style={{
      padding: '1px 7px',
      background: c.bg, color: c.fg,
      borderRadius: 100, fontSize: 10, fontWeight: 600,
      letterSpacing: 0,
    }}>{label}</span>
  );
}

// ───────────────────────────────────────────────
// 邀请页 — Sheet 风格
// ───────────────────────────────────────────────
function InvitePage({ theme = 'light', onBack }) {
  const [tab, setTab] = React.useState('qr');
  const code = 'WO-3F2K-9L';
  return (
    <div data-theme={theme} className="wo-screen" style={{ background: 'var(--bg-app)' }}>
      <WoSubHeader title="邀请加入栗子的窝" onBack={onBack} />

      <div className="wo-scroll" style={{ paddingBottom: 30 }}>
        <div style={{ padding: '4px 18px 0', display: 'flex', justifyContent: 'center' }}>
          <div style={{ width: 240 }}>
            <WoSegmented
              value={tab}
              onChange={setTab}
              options={[
                { value: 'qr',   label: '面对面' },
                { value: 'link', label: '链接' },
                { value: 'code', label: '邀请码' },
              ]} />
          </div>
        </div>

        {tab === 'qr' && (
          <div style={{ padding: '24px 22px', textAlign: 'center' }}>
            <div style={{
              display: 'inline-block',
              padding: 14, background: 'var(--bg-elev)', borderRadius: 22,
              boxShadow: 'var(--shadow-card)',
            }}>
              <WoQRCode seed={code} size={228} />
            </div>
            <div style={{
              fontSize: 14, fontWeight: 600, color: 'var(--fg)',
              marginTop: 20, letterSpacing: -0.1,
            }}>请家人扫一扫</div>
            <div style={{
              fontSize: 12, color: 'var(--fg-mid)',
              marginTop: 6, lineHeight: 1.6, maxWidth: 280, margin: '6px auto 0',
            }}>
              扫码后会成为「家人」身份。<br/>
              二维码每 24 小时刷新一次。
            </div>
          </div>
        )}

        {tab === 'link' && (
          <div style={{ padding: '24px 22px' }}>
            <div style={{
              background: 'var(--bg-elev)', borderRadius: 18, padding: 18,
              boxShadow: 'var(--shadow-card)',
            }}>
              <div style={{ fontSize: 11, color: 'var(--fg-dim)', letterSpacing: 0.4, marginBottom: 6 }}>邀请链接</div>
              <div style={{
                fontSize: 14, color: 'var(--fg)',
                wordBreak: 'break-all', lineHeight: 1.5,
                fontFamily: 'Inter, monospace',
              }}>https://wo.app/j/3F2K9L</div>
              <button style={{
                marginTop: 14, width: '100%',
                padding: '12px', borderRadius: 12,
                background: 'var(--accent)', color: '#fff',
                border: 'none', fontSize: 14, fontWeight: 600,
              }}>复制链接</button>
            </div>
            <div style={{
              padding: '14px 4px', fontSize: 12, color: 'var(--fg-mid)', lineHeight: 1.6,
            }}>
              发给微信、短信、邮件，对方点击即可加入。仅当前家庭成员能转发，链接 24 小时内有效。
            </div>
          </div>
        )}

        {tab === 'code' && (
          <div style={{ padding: '24px 22px', textAlign: 'center' }}>
            <div style={{ fontSize: 12, color: 'var(--fg-mid)', marginBottom: 10 }}>
              当前邀请码
            </div>
            <div style={{
              fontSize: 38, fontWeight: 700, color: 'var(--fg)',
              letterSpacing: 6, fontFamily: 'Inter, system-ui',
              padding: '16px',
              background: 'var(--bg-elev)', borderRadius: 18,
              display: 'inline-block', minWidth: 240,
              boxShadow: 'var(--shadow-card)',
            }}>{code}</div>
            <div style={{ fontSize: 12, color: 'var(--fg-dim)', marginTop: 10 }}>
              在「我的 → 加入家庭」输入此码
            </div>
            <button style={{
              marginTop: 24, padding: '12px 32px',
              borderRadius: 100, background: 'var(--accent)', color: '#fff',
              border: 'none', fontSize: 14, fontWeight: 600,
              boxShadow: 'var(--shadow-fab)',
            }}>复制邀请码</button>
          </div>
        )}

        {/* role hint */}
        <WoSectionTitle>加入身份</WoSectionTitle>
        <div style={{ padding: '0 18px' }}>
          <div style={{
            background: 'var(--bg-elev)', borderRadius: 18,
            padding: '4px 0', boxShadow: 'var(--shadow-card)',
          }}>
            <WoListRow leading="👤" title="家人 · Member"
              subtitle="可使用所有插件，无法管理家庭"
              trailing="默认" />
            <WoListRow leading="🔑" title="管理员 · Admin"
              subtitle="可启用/停用插件、邀请成员"
              chevron />
            <WoListRow leading="🌱" title="小朋友 · Child"
              subtitle="家长可控制可用插件" last chevron />
          </div>
        </div>

        <div style={{
          padding: '20px 22px 16px',
          fontSize: 11, color: 'var(--fg-dim)', lineHeight: 1.6, textAlign: 'center',
        }}>
          所有加入请求需要主理人确认 · 你的隐私由你决定
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { FamilyManagePage, InvitePage, WO_FAMILY_DETAIL, WO_OTHER_FAMILIES });
