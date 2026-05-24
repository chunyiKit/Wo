// app.jsx — Canvas composition. Three home directions ×
// light + dark, presented as a design canvas with a Tweaks panel
// for global theme/edit toggles.

const WoArtboardCard = ({ Home, themeDefault, ...rest }) => {
  // Each instance owns its own theme state (toggled by sun/moon button).
  // Global Tweaks can override via `themeOverride`.
  const [theme, setTheme] = React.useState(themeDefault);
  const t = rest.themeOverride || theme;
  return (
    <Home theme={t}
          defaultSheet={rest.defaultSheet}
          onToggleTheme={() => setTheme(t === 'dark' ? 'light' : 'dark')} />
  );
};

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "per-card",
  "showAll": "both"
}/*EDITMODE-END*/;

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const override = t.theme === 'per-card' ? null : t.theme;

  // Build artboard set based on showAll
  const show = t.showAll || 'both';
  const wantPairs = show === 'both';
  const wantLight = show === 'both' || show === 'light';
  const wantDark  = show === 'both' || show === 'dark';

  const directions = [
    { id: 'a', label: 'A · 温润日常',   Comp: HomeA },
    { id: 'b', label: 'B · 积木拼贴',   Comp: HomeB },
    { id: 'c', label: 'C · 故事时间线', Comp: HomeC },
  ];

  // Sub-pages — use Direction A's visual baseline (warm minimal).
  const themeFor = (preferred) => override || preferred;
  const subAB = (id, label, Comp, themeKey) => (
    <DCArtboard id={id + '-' + themeKey} label={label + ' · ' + (themeKey === 'dark' ? '深色' : '浅色')}
      width={412} height={915}
      style={{ background: themeKey === 'dark' ? '#15120F' : '#FBF7F1' }}>
      <Comp theme={themeFor(themeKey)} />
    </DCArtboard>
  );

  return (
    <React.Fragment>
      <DesignCanvas minScale={0.1} maxScale={2}>
        <DCSection id="onboarding" title="启动 / 引导页"
          subtitle="3 屏 onboarding · 传达「插件化家庭 App」的核心价值">
          {wantLight && (
            <DCArtboard id="onb-1-light" label="① 家是单位 · 浅色"
              width={412} height={915} style={{ background: '#FBF7F1' }}>
              <OnboardingPage theme={themeFor('light')} step={1} />
            </DCArtboard>
          )}
          {wantDark && (
            <DCArtboard id="onb-1-dark" label="① 家是单位 · 深色"
              width={412} height={915} style={{ background: '#15120F' }}>
              <OnboardingPage theme={themeFor('dark')} step={1} />
            </DCArtboard>
          )}
          {wantLight && (
            <DCArtboard id="onb-2-light" label="② 插件化 · 浅色"
              width={412} height={915} style={{ background: '#FBF7F1' }}>
              <OnboardingPage theme={themeFor('light')} step={2} />
            </DCArtboard>
          )}
          {wantDark && (
            <DCArtboard id="onb-2-dark" label="② 插件化 · 深色"
              width={412} height={915} style={{ background: '#15120F' }}>
              <OnboardingPage theme={themeFor('dark')} step={2} />
            </DCArtboard>
          )}
          {wantLight && (
            <DCArtboard id="onb-3-light" label="③ 多家庭 · 浅色"
              width={412} height={915} style={{ background: '#FBF7F1' }}>
              <OnboardingPage theme={themeFor('light')} step={3} />
            </DCArtboard>
          )}
          {wantDark && (
            <DCArtboard id="onb-3-dark" label="③ 多家庭 · 深色"
              width={412} height={915} style={{ background: '#15120F' }}>
              <OnboardingPage theme={themeFor('dark')} step={3} />
            </DCArtboard>
          )}

          <DCPostIt top={-44} left={60} rotate={-3} width={230}>
            三屏：家 → 插件 → 多家庭。每屏一个完整命题，避免在 onboarding 里硬塞产品教程。
            最后一屏的 CTA 直接接入「加入或创建」流程。
          </DCPostIt>

          <DCPostIt top={520} left={1860} rotate={2} width={210}>
            视觉用主色卡片 + emoji + CSS 漂浮，不画 SVG 插图——保持品牌的「不卡通、生活化」的调性。
          </DCPostIt>
        </DCSection>

        <DCSection id="home" title="家庭首页 · 三方向"
          subtitle="Pixel 8 · 412×915 · 长按任意卡片进入「编辑布局」状态">
          {directions.map(d => (
            <React.Fragment key={d.id}>
              {wantLight && (
                <DCArtboard id={d.id + '-light'} label={d.label + ' · 浅色'}
                  width={412} height={915}
                  style={{ background: '#FBF7F1' }}>
                  <WoArtboardCard Home={d.Comp} themeDefault="light" themeOverride={override} />
                </DCArtboard>
              )}
              {wantDark && (
                <DCArtboard id={d.id + '-dark'} label={d.label + ' · 深色'}
                  width={412} height={915}
                  style={{ background: '#15120F' }}>
                  <WoArtboardCard Home={d.Comp} themeDefault="dark" themeOverride={override} />
                </DCArtboard>
              )}
            </React.Fragment>
          ))}

          <DCPostIt top={-44} left={60} rotate={-3} width={210}>
            三个方向：A 稳重 / B 模块化 / C 叙事感。
            每张画板顶部的 ☀️/🌙 可单独切换；Tweaks 里可全局对齐。
          </DCPostIt>

          <DCPostIt top={420} left={1320} rotate={2} width={220}>
            想看长按编辑状态？长按手机里任意卡片约半秒，
            卡片开始抖动，并出现「−」移除按钮。
          </DCPostIt>
        </DCSection>

        <DCSection id="interactions" title="关键交互细节"
          subtitle="家庭切换下拉 · 添加插件半屏 Sheet · 长按编辑态">
          {wantLight && (
            <DCArtboard id="switch-light" label="家庭切换下拉 · 浅色"
              width={412} height={915} style={{ background: '#FBF7F1' }}>
              <WoArtboardCard Home={HomeA} themeDefault="light" themeOverride={override}
                              defaultSheet="family" />
            </DCArtboard>
          )}
          {wantDark && (
            <DCArtboard id="switch-dark" label="家庭切换下拉 · 深色"
              width={412} height={915} style={{ background: '#15120F' }}>
              <WoArtboardCard Home={HomeA} themeDefault="dark" themeOverride={override}
                              defaultSheet="family" />
            </DCArtboard>
          )}
          {wantLight && (
            <DCArtboard id="addsheet-light" label="添加插件 · 半屏 Sheet · 浅色"
              width={412} height={915} style={{ background: '#FBF7F1' }}>
              <WoArtboardCard Home={HomeA} themeDefault="light" themeOverride={override}
                              defaultSheet="add" />
            </DCArtboard>
          )}
          {wantDark && (
            <DCArtboard id="addsheet-dark" label="添加插件 · 半屏 Sheet · 深色"
              width={412} height={915} style={{ background: '#15120F' }}>
              <WoArtboardCard Home={HomeA} themeDefault="dark" themeOverride={override}
                              defaultSheet="add" />
            </DCArtboard>
          )}

          <DCPostIt top={-44} left={60} rotate={-2} width={230}>
            家庭切换：当前家庭背景主色淡填 + 名字主色 + 右侧勾选锚点，
            未在用的家庭显示红点未读数。
          </DCPostIt>

          <DCPostIt top={420} left={1320} rotate={2} width={230}>
            加插件半屏 Sheet：精选 + 分类 chips + 网格直接装，
            装完滑下来回到家。比跳到整张市场页省 1 步。
          </DCPostIt>
        </DCSection>

        <DCSection id="empty" title="插件首次安装 · 空状态"
          subtitle="不能冷冰冰 · 大插画 + 引导 CTA + 模板 / 示例">
          {wantLight && subAB('album-empty',  '相册 · 空',     EmptyAlbumPage,  'light')}
          {wantDark  && subAB('album-empty',  '相册 · 空',     EmptyAlbumPage,  'dark')}
          {wantLight && subAB('cinema-empty', '一起看片 · 空', EmptyCinemaPage, 'light')}
          {wantDark  && subAB('cinema-empty', '一起看片 · 空', EmptyCinemaPage, 'dark')}
          {wantLight && subAB('chore-empty',  '家务 · 空',     EmptyChorePage,  'light')}
          {wantDark  && subAB('chore-empty',  '家务 · 空',     EmptyChorePage,  'dark')}

          <DCPostIt top={-44} left={60} rotate={-2} width={230}>
            空状态三件套：友好插画 + 友好文案 + 一个 primary CTA。
            再附「模板 / 示例」帮用户更快迈出第一步。
          </DCPostIt>
        </DCSection>

        <DCSection id="market" title="插件市场"
          subtitle="搜索 + 分类筛选 + 精选推荐 · 详情页含截图、功能、申请权限">
          {wantLight && subAB('market', '市场首页',   MarketPage,         'light')}
          {wantDark  && subAB('market', '市场首页',   MarketPage,         'dark')}
          {wantLight && subAB('detail', '详情 · 一起看片', PluginDetailPage, 'light')}
          {wantDark  && subAB('detail', '详情 · 一起看片', PluginDetailPage, 'dark')}

          <DCPostIt top={-44} left={60} rotate={-2} width={220}>
            已安装的卡片显示「已安装」灰按钮；
            详情页底部粘性安装栏明确「装到哪个家」。
          </DCPostIt>
        </DCSection>

        <DCSection id="family" title="家庭管理 · 邀请成员"
          subtitle="角色徽章：主理人 / 管理员 / 家人 / 小朋友 / 宠物档案">
          {wantLight && subAB('manage', '家庭管理', FamilyManagePage, 'light')}
          {wantDark  && subAB('manage', '家庭管理', FamilyManagePage, 'dark')}
          {wantLight && subAB('invite', '邀请成员', InvitePage,       'light')}
          {wantDark  && subAB('invite', '邀请成员', InvitePage,       'dark')}

          <DCPostIt top={-44} left={60} rotate={-2} width={220}>
            邀请有三种路径：面对面二维码、链接、邀请码。
            加入身份默认「家人」，主理人可后续提权。
          </DCPostIt>
        </DCSection>

        <DCSection id="me" title="我的"
          subtitle="账户 · 我加入的家庭 · 设置 · 帮助">
          {wantLight && subAB('me', '我的', ProfilePage, 'light')}
          {wantDark  && subAB('me', '我的', ProfilePage, 'dark')}

          <DCPostIt top={-44} left={60} rotate={-2} width={220}>
            一个用户可加入多个家庭；当前家庭高亮主色徽章，
            其他家庭一键切换。最后一行是「加入或创建」入口。
          </DCPostIt>
        </DCSection>

        <DCSection id="join" title="加入 / 创建家庭"
          subtitle="入口选择 → 输入邀请码 / 扫码 → 或者创建一个新家">
          {wantLight && subAB('landing', '入口选择',  JoinOrCreatePage, 'light')}
          {wantDark  && subAB('landing', '入口选择',  JoinOrCreatePage, 'dark')}
          {wantLight && subAB('joincode', '输入邀请码', JoinByCodePage,  'light')}
          {wantDark  && subAB('joincode', '输入邀请码', JoinByCodePage,  'dark')}
          {(wantLight || wantDark) && subAB('scan',    '扫码加入',  ScanPage,         'light')}
          {wantLight && subAB('create',  '创建新家',  CreateFamilyPage, 'light')}
          {wantDark  && subAB('create',  '创建新家',  CreateFamilyPage, 'dark')}

          <DCPostIt top={-44} left={60} rotate={-2} width={220}>
            入口先让用户选「加入 / 创建」二选一；
            邀请码用 WO-XXXX-XXXX 分段输入降低出错率，
            旁边一直挂着扫码捷径。
          </DCPostIt>

          <DCPostIt top={420} left={2820} rotate={2} width={220}>
            扫码页是少数永远深色的页面：相机感更强；
            创建页内置实时预览卡，所见即所得。
          </DCPostIt>
        </DCSection>

      </DesignCanvas>

      <TweaksPanel title="Tweaks">
        <TweakSection label="主题">
          <TweakRadio
            label="全局主题"
            value={t.theme}
            options={[
              { value: 'per-card', label: '各自' },
              { value: 'light',    label: '浅' },
              { value: 'dark',     label: '深' },
            ]}
            onChange={v => setTweak('theme', v)}
          />
        </TweakSection>
        <TweakSection label="展示">
          <TweakRadio
            label="对照方式"
            value={t.showAll}
            options={[
              { value: 'both',  label: '浅+深' },
              { value: 'light', label: '只浅' },
              { value: 'dark',  label: '只深' },
            ]}
            onChange={v => setTweak('showAll', v)}
          />
        </TweakSection>
      </TweaksPanel>
    </React.Fragment>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
