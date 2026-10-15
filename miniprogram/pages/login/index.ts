import {api,showError} from '../../core/api';
import {getSession,setSession,clearSession,epoch,assertEpoch,onSessionChange} from '../../core/session';
import {applyTheme,theme} from '../../core/theme';
import {hydrateAvatars} from '../../core/media';
import {clearMemoryDrafts} from '../../core/memory-draft';
interface AuthResult {token:string;user:any;registration_required?:boolean;recovery_code?:string;recovery_expires_at?:string}
function wxCode():Promise<string> {return new Promise((resolve,reject)=>wx.login({timeout:10000,success:(r:{code:string})=>r.code?resolve(r.code):reject(new Error('微信登录未返回凭据，请重试')),fail:()=>reject(new Error('微信登录失败，请重试'))}));}
Page({
  data:{theme:theme(),account:null,mode:'login',busy:false,error:'',phone:'',password:'',displayName:'',recoveryCode:'',newPassword:'',secret:'',expires:'',consent:false},
  visible:false, request:0, unsubscribe:null as (()=>void)|null,
  onLoad(){this.unsubscribe=onSessionChange(()=>this.setData({account:getSession()?.user||null,secret:'',password:'',newPassword:'',recoveryCode:''}));},
  async onShow(){this.visible=true;applyTheme(this);const session=getSession();this.setData({account:session?.user||null});if(session){const stamp=epoch();const request=this.request;const [user]=await hydrateAvatars([session.user]);if(stamp===epoch()&&this.visible&&request===this.request)this.setData({account:user});}},
  onHide(){this.visible=false;this.request++;this.setData({busy:false,password:'',newPassword:'',recoveryCode:'',secret:''});},
  onUnload(){this.onHide();this.unsubscribe?.();},
  valid(stamp:number,request:number){assertEpoch(stamp);if(!this.visible||request!==this.request)throw new Error('页面已离开，请重新操作');},
  input(e:any){this.setData({[e.currentTarget.dataset.field]:e.detail.value});},
  consent(e:any){this.setData({consent:e.detail.value.length>0});},
  select(e:any){this.setData({mode:e.currentTarget.dataset.mode,error:'',password:'',newPassword:'',recoveryCode:''});},
  async submit(){
    if(this.data.busy)return;
    if(!this.data.consent){this.setData({error:'请阅读并同意本页的隐私说明后继续'});return;}
    const mode=this.data.mode;
    if((mode==='bind'||mode==='register') && this.data.password.length<6){this.setData({error:'请输入至少 6 位原账号密码或新密码'});return;}
    if(mode==='bind'&&!/^1\d{10}$/.test(this.data.phone.trim())){this.setData({error:'请输入原账号手机号'});return;}
    if((mode==='reset'||mode==='phone-reset')&&(!this.data.recoveryCode||this.data.newPassword.length<6)){this.setData({error:'请填写恢复码与至少 6 位的新密码'});return;}
    this.setData({busy:true,error:''});const stamp=epoch();const request=++this.request;
    try{
      if(mode==='phone-reset'){
        await api('/auth/reset-password','POST',{phone:this.data.phone.trim(),recovery_code:this.data.recoveryCode.trim(),new_password:this.data.newPassword});
        this.valid(stamp,request);this.setData({mode:'bind',password:'',newPassword:'',recoveryCode:'',error:'密码已重置，所有旧会话已退出。请验证新密码绑定。'});return;
      }
      const code=await wxCode();this.valid(stamp,request);
      let payload:Record<string,string>={code};
      if(mode==='bind')payload={code,phone:this.data.phone.trim(),password:this.data.password};
      if(mode==='register')payload={code,password:this.data.password,display_name:this.data.displayName.trim()||'微信用户'};
      if(mode==='reset')payload={code,recovery_code:this.data.recoveryCode.trim(),new_password:this.data.newPassword};
      const result=await api<AuthResult>(`/auth/wechat/${mode==='reset'?'reset-password':mode}`,'POST',payload);this.valid(stamp,request);
      if(result.registration_required){this.setData({mode:'bind',error:'这个微信尚未关联窝账号。已有账号请验证原密码绑定；没有账号可创建新账号。'});return;}
      if(mode==='reset'){this.setData({mode:'login',newPassword:'',recoveryCode:'',error:'密码已重置，所有旧会话已退出。请重新微信登录。'});return;}
      setSession({token:result.token,user:result.user,familyId:null});this.setData({account:result.user,password:'',phone:'',recoveryCode:'',newPassword:''});
      if(result.recovery_code){this.setData({secret:result.recovery_code,expires:result.recovery_expires_at||''});}
      else wx.reLaunch({url:'/pages/home/index'});
    }catch(error){if(stamp===epoch()&&this.visible&&request===this.request)this.setData({error:error instanceof Error?error.message:'登录失败，请重试'});}
    finally{if(this.visible&&request===this.request)this.setData({busy:false,password:'',newPassword:'',recoveryCode:''});}
  },
  home(){this.setData({secret:''});wx.reLaunch({url:'/pages/home/index'});},
  async recovery(){
    if(this.data.busy)return;this.setData({busy:true,error:''});const stamp=epoch();const request=++this.request;
    try{const result=await api<{recovery_code:string;expires_at:string}>('/auth/recovery-code','POST',{password:this.data.password});this.valid(stamp,request);this.setData({secret:result.recovery_code,expires:result.expires_at||''});}
    catch(error){if(this.visible&&request===this.request&&stamp===epoch())showError(error);}
    finally{if(this.visible&&request===this.request)this.setData({busy:false,password:''});}
  },
  async logout(e:any){
    if(this.data.busy)return;
    const beforeConfirm=epoch();
    const result:any=await new Promise(resolve=>wx.showModal({title:'退出并清理本机草稿？',content:'未完成回忆的本机草稿和暂存图片会被清理，已保存的服务端回忆保留。',confirmText:'退出登录',success:resolve}));
    if(!result.confirm||!getSession()||beforeConfirm!==epoch()||!this.visible)return;
    this.setData({busy:true,error:''});const stamp=epoch();const userId=getSession()!.user.id;const request=++this.request;
    try{
      await api(e.currentTarget.dataset.all?'/auth/logout-all':'/auth/logout','POST');assertEpoch(stamp);clearSession();
      await clearMemoryDrafts(userId);
      if(this.visible&&request===this.request)this.setData({account:null,secret:'',password:'',phone:'',mode:'login'});
      wx.reLaunch({url:'/pages/login/index'});
    }catch(error){if(this.visible&&request===this.request)showError(error);}
    finally{if(this.visible&&request===this.request)this.setData({busy:false});}
  },
});
