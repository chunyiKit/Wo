import {api,showError} from '../../core/api';
import {getSession,setFamily,epoch,onSessionChange} from '../../core/session';
import {hydrateAvatars,privateMedia} from '../../core/media';
import {applyTheme,theme,toggleTheme} from '../../core/theme';
type Role = 'owner'|'admin'|'member'|'child';
interface Family {id:string;name:string;slogan:string|null;member_count:number;my_role:Role;background_url?:string}
interface Installed {plugin_id:string;preview?:Record<string,unknown>}
interface Bootstrap {user:Record<string,unknown>;current_family:Family|null;families:Family[];installed_plugins:Installed[]}
interface Member {user_id:string;avatar_url?:string|null;avatar_emoji:string;display_name:string}
interface InvitationPreview {family:{name:string;member_count:number};role:Role}
interface PreviewView {name:string;memberCount:number;role:string}
interface InputEvent {detail:{value:string};currentTarget:{dataset:{page?:string;id?:string}}}
const CARDS = [
  {id:'accounting',title:'记账本',en:'THE LITTLE LEDGER',icon:'¥',desc:'把生活的花费，记得明明白白',page:'accounting'},
  {id:'chore',title:'家务板',en:'A LITTLE TEAMWORK',icon:'✓',desc:'分担琐碎，也分享轻松',page:'chores'},
  {id:'memory',title:'回忆录',en:'MOMENTS TO KEEP',icon:'▧',desc:'平凡日子，也值得被收藏',page:'memories'},
];
const ROLE_NAMES:Record<Role,string> = {owner:'家庭主人',admin:'管理员',member:'家庭成员',child:'儿童成员'};
function normalizeInvitation(raw:string):string|null {
  let value=raw.trim().toUpperCase().replace(/[-\s]/g,'');
  if(value.startsWith('WO'))value=value.slice(2);
  return /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$/.test(value)?value:null;
}
Page({
  data:{theme:theme(),loading:true,error:'',bootstrap:null as Bootstrap|null,members:[] as Member[],background:'',familyNames:[] as string[],
    cards:[] as typeof CARDS,missingCards:[] as typeof CARDS,canManagePlugins:false,
    familyName:'',inviteInput:'',invitePreview:null as PreviewView|null,previewCode:'',busy:false,busyAction:'',installing:''},
  stamp:-1,sequence:0,disposed:false,unsubscribe:null as (()=>void)|null,
  onLoad(){this.unsubscribe=onSessionChange(()=>this.clearPrivateState());},
  clearPrivateState(){
    this.sequence++;this.stamp=epoch();
    this.setData({bootstrap:null,members:[],background:'',cards:[],missingCards:[],canManagePlugins:false,familyNames:[],loading:true,error:'',
      familyName:'',inviteInput:'',invitePreview:null,previewCode:'',busy:false,busyAction:'',installing:''});
  },
  onShow(){
    applyTheme(this);
    if(this.stamp!==epoch())this.clearPrivateState();
    if(!getSession()){wx.reLaunch({url:'/pages/login/index'});return;}
    void this.load();
  },
  onUnload(){this.disposed=true;this.sequence++;this.unsubscribe?.();},
  onPullDownRefresh(){this.load().finally(()=>wx.stopPullDownRefresh());},
  showBootstrap(bootstrap:Bootstrap){
    const installed=new Set(bootstrap.installed_plugins.map(plugin=>plugin.plugin_id));
    const role=bootstrap.current_family?.my_role;
    this.setData({bootstrap,loading:false,error:'',familyNames:bootstrap.families.map(f=>f.name),
      cards:CARDS.filter(card=>installed.has(card.id)),missingCards:CARDS.filter(card=>!installed.has(card.id)),
      canManagePlugins:role==='owner'||role==='admin'});
  },
  async load(){
    if(!getSession())return;
    let stamp=epoch();let sequence=++this.sequence;this.stamp=stamp;
    this.setData({loading:!this.data.bootstrap,error:''});
    try {
      const boot=await api<Bootstrap>('/me/bootstrap');
      if(stamp!==epoch()||sequence!==this.sequence||this.disposed)return;
      // bootstrap 可能为新会话恢复当前家庭；setFamily 会同步清空前一身份的缓存。
      setFamily(boot.current_family?.id||null);stamp=epoch();sequence=this.sequence;this.stamp=stamp;
      const family=boot.current_family;this.showBootstrap(boot);
      if(!family){this.setData({members:[],background:''});return;}
      const [members,background]=await Promise.all([
        api<Member[]>(`/families/${encodeURIComponent(family.id)}/members`).then(rows=>hydrateAvatars(rows)),
        family.background_url?privateMedia(family.background_url).catch(()=> ''):Promise.resolve(''),
      ]);
      if(stamp!==epoch()||sequence!==this.sequence||this.disposed)return;
      this.setData({members,background});
    } catch(error){if(stamp===epoch()&&sequence===this.sequence&&!this.disposed)this.setData({error:error instanceof Error?error.message:'加载失败',loading:false});}
  },
  retry(){void this.load();},toggleTheme(){toggleTheme();applyTheme(this);},
  open(event:InputEvent){const card=this.data.cards.find(item=>item.page===event.currentTarget.dataset.page);if(card)wx.navigateTo({url:`/pages/${card.page}/index`});},
  account(){wx.navigateTo({url:'/pages/login/index'});},
  async switchFamily(event:InputEvent){
    if(this.data.busy)return;
    const family=this.data.bootstrap?.families[Number(event.detail.value)];if(!family||family.id===getSession()?.familyId)return;
    const stamp=epoch();this.setData({busy:true,busyAction:'switch'});
    try {
      await api(`/families/${encodeURIComponent(family.id)}/switch`,'POST');
      if(stamp!==epoch()||this.disposed)return;
      setFamily(family.id);this.setData({busy:true,busyAction:'switch'});const fresh=epoch();
      await this.load();if(fresh===epoch()&&!this.disposed)this.setData({busy:false,busyAction:''});
    }catch(error){if(stamp===epoch()&&!this.disposed)showError(error);}
    finally{if(stamp===epoch()&&!this.disposed)this.setData({busy:false,busyAction:''});}
  },
  updateFamilyName(event:InputEvent){if(!this.data.busy)this.setData({familyName:event.detail.value});},
  updateInvite(event:InputEvent){if(!this.data.busy)this.setData({inviteInput:event.detail.value,invitePreview:null,previewCode:''});},
  canStartFamilyAction():boolean{return !!getSession()&&!!this.data.bootstrap&&!this.data.bootstrap.current_family&&!this.data.busy&&!this.disposed;},
  async createFamily(){
    if(!this.canStartFamilyAction())return;
    const name=this.data.familyName.trim();
    if(!name||Array.from(name).length>16){wx.showToast({title:'请输入 1 至 16 个字的家庭名称',icon:'none'});return;}
    const stamp=epoch();this.setData({busy:true,busyAction:'create'});
    try {
      const family=await api<Family>('/families','POST',{name});
      if(stamp!==epoch()||this.disposed)return;
      setFamily(family.id);this.setData({familyName:'',busy:true,busyAction:'create'});const fresh=epoch();
      await this.load();if(fresh===epoch()&&!this.disposed)this.setData({busy:false,busyAction:''});
    }catch(error){if(stamp===epoch()&&!this.disposed)showError(error);}
    finally{if(stamp===epoch()&&!this.disposed)this.setData({busy:false,busyAction:''});}
  },
  async previewInvitation(){
    if(!this.canStartFamilyAction())return;
    const code=normalizeInvitation(this.data.inviteInput);
    if(!code){wx.showToast({title:'请输入有效的 WO-XXXX-XXXX 邀请码',icon:'none'});return;}
    const stamp=epoch();this.setData({busy:true,busyAction:'preview',invitePreview:null,previewCode:''});
    try {
      const preview=await api<InvitationPreview>(`/invitations/${encodeURIComponent(code)}/preview`);
      if(stamp!==epoch()||this.disposed)return;
      // 只留存家庭级摘要，不把缺少真实头像契约的邀请人资料带入页面。
      this.setData({invitePreview:{name:preview.family.name,memberCount:preview.family.member_count,role:ROLE_NAMES[preview.role]||'家庭成员'},previewCode:code});
    }catch(error){if(stamp===epoch()&&!this.disposed)showError(error);}
    finally{if(stamp===epoch()&&!this.disposed)this.setData({busy:false,busyAction:''});}
  },
  async acceptInvitation(){
    if(!this.canStartFamilyAction()||!this.data.invitePreview||!this.data.previewCode)return;
    const code=normalizeInvitation(this.data.inviteInput);
    if(code!==this.data.previewCode)return;
    const stamp=epoch();this.setData({busy:true,busyAction:'accept'});
    try {
      const family=await api<Family>(`/invitations/${encodeURIComponent(code)}/accept`,'POST');
      if(stamp!==epoch()||this.disposed)return;
      setFamily(family.id);this.setData({inviteInput:'',invitePreview:null,previewCode:'',busy:true,busyAction:'accept'});const fresh=epoch();
      await this.load();if(fresh===epoch()&&!this.disposed)this.setData({busy:false,busyAction:''});
    }catch(error){if(stamp===epoch()&&!this.disposed)showError(error);}
    finally{if(stamp===epoch()&&!this.disposed)this.setData({busy:false,busyAction:''});}
  },
  async installPlugin(event:InputEvent){
    const boot=this.data.bootstrap;const family=boot?.current_family;const plugin=event.currentTarget.dataset.id;
    if(!boot||!family||!plugin||!this.data.canManagePlugins||this.data.busy||!this.data.missingCards.some(card=>card.id===plugin))return;
    const stamp=epoch();this.setData({busy:true,installing:plugin});
    try {
      const installed=await api<Installed>(`/families/${encodeURIComponent(family.id)}/plugins`,'POST',{plugin_id:plugin});
      if(stamp!==epoch()||this.disposed)return;
      this.showBootstrap({...boot,installed_plugins:[...boot.installed_plugins,installed]});
      await this.load();
    }catch(error){if(stamp===epoch()&&!this.disposed)showError(error);}
    finally{if(stamp===epoch()&&!this.disposed)this.setData({busy:false,installing:''});}
  },
});
