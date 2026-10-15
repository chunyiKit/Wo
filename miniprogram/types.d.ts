// 运行时由微信提供；本地不依赖全局安装。页面 API 在官方开发者工具中再次校验。
declare const wx: any;
declare function Page(options: any): void;
declare function Component(options: any): void;
declare function App(options: any): void;
declare function getApp<T = any>(): T;
declare const console: any;
declare function setTimeout(callback:()=>void,delay?:number):number;
declare function clearTimeout(id:number):void;
