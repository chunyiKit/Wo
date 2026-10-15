import {restoreSession} from './core/session';
import {loadFont} from './core/theme';
App({onLaunch(){restoreSession();loadFont();}});
