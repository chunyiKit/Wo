"""重建源码的纯Python相对import/词法/已知本地const构造核对。

不执行Dart、Flutter、SDK、浏览器或网络；不是analyze或编译替代品。
"""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


def changed_dart_files():
    tracked = subprocess.run(['git', 'diff', '--name-only', 'main', '--', '*.dart'],
                             cwd=ROOT, check=True, text=True, capture_output=True).stdout.splitlines()
    untracked = subprocess.run(['git', 'ls-files', '--others', '--exclude-standard', '--', '*.dart'],
                               cwd=ROOT, check=True, text=True, capture_output=True).stdout.splitlines()
    return sorted({ROOT / name for name in tracked + untracked if (ROOT / name).is_file()})


class DartLexicalError(AssertionError):
    pass


def lexical_code(source, label):
    """检查闭合并隐藏注释/字符串；字符串插值中的Dart表达式保留供括号核对。"""
    output = list(source)
    i = 0
    def fail(message, at=None):
        pos = i if at is None else at
        raise DartLexicalError(f'{label}:{source.count(chr(10), 0, pos) + 1}: {message}')
    def hide(start, end):
        for k in range(start, end):
            if output[k] != '\n': output[k] = ' '
    def string(raw=False):
        nonlocal i
        start = i
        quote = source[i]
        triple = source.startswith(quote * 3, i)
        terminal = quote * (3 if triple else 1)
        i += len(terminal)
        hide(start, i)
        while i < len(source):
            if source.startswith(terminal, i):
                end = i + len(terminal); hide(i, end); i = end; return
            if not triple and source[i] == '\n': fail('newline in short string')
            if not raw and source[i] == '\\':
                end = min(len(source), i + 2); hide(i, end); i = end; continue
            if not raw and source.startswith('${', i):
                hide(i, i + 2); i += 2; code(interpolation=True); continue
            hide(i, i + 1); i += 1
        fail('unterminated string', start)
    def code(interpolation=False):
        nonlocal i
        stack = []
        while i < len(source):
            if source.startswith('//', i):
                start = i; end = source.find('\n', i)
                i = len(source) if end < 0 else end
                hide(start, i); continue
            if source.startswith('/*', i):
                start = i; depth = 1; i += 2
                while i < len(source) and depth:
                    if source.startswith('/*', i): depth += 1; i += 2
                    elif source.startswith('*/', i): depth -= 1; i += 2
                    else: i += 1
                if depth: fail('unterminated block comment', start)
                hide(start, i); continue
            raw = source[i] in 'rR' and i + 1 < len(source) and source[i + 1] in "'\"" and (i == 0 or not re.match(r'\w', source[i - 1]))
            if raw:
                hide(i, i + 1); i += 1; string(raw=True); continue
            if source[i] in "'\"": string(); continue
            char = source[i]
            if char in '({[': stack.append((char, i))
            elif char in ')}]':
                if interpolation and char == '}' and not stack:
                    hide(i, i + 1); i += 1; return
                if not stack or stack[-1][0] != '({['[')}]'.index(char)]: fail('unbalanced delimiter')
                stack.pop()
            i += 1
        if stack: fail('unclosed delimiter', stack[-1][1])
        if interpolation: fail('unterminated interpolation')
    code()
    return ''.join(output)


def import_paths(path, source):
    for uri in re.findall(r"\b(?:import|export|part)\s+['\"]([^'\"]+)['\"]", source):
        if uri.startswith('dart:'): continue
        if uri.startswith('package:wo/'): yield ROOT / 'lib' / uri[len('package:wo/'):]
        elif ':' not in uri: yield (path.parent / uri).resolve()


def declared_constructors(code):
    found = {}
    for match in re.finditer(r'\bclass\s+(\w+)\b[^;{]*\{', code):
        start = match.end(); depth = 1; end = start
        while depth and end < len(code):
            if code[end] == '{': depth += 1
            elif code[end] == '}': depth -= 1
            end += 1
        name = match.group(1); region = code[start:end - 1]
        methods = {}
        pattern = r'(?:\A|[;{}\n])\s*(const\s+)?(?:factory\s+)?' + re.escape(name) + r'(?:\.(\w+))?\s*\('
        for constructor in re.finditer(pattern, region):
            # 换行的箭头函数返回调用不是构造声明；声明前必须是成员边界。
            head = constructor.group(0)
            name_at = constructor.start() + head.index(name)
            prefix = re.sub(r'(?:const|factory)\s*$', '', region[:name_at].rstrip()).rstrip()
            if prefix and prefix[-1] not in ';}':
                continue
            methods[constructor.group(2) or ''] = bool(constructor.group(1))
        if methods: found[name] = methods
    return found


class MobileSourceContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = changed_dart_files()
        cls.sources = {path: path.read_text() for path in cls.files}
        if not cls.files: raise AssertionError('No changed Dart sources found')

    def test_checker_handles_comments_interpolation_and_arrow_constructor_calls(self):
        code = lexical_code("// synthetic\nclass X { const X(); factory X.parse() =>\n X(); String x = '${{'k': 1}['k']}'; }", 'synthetic-valid')
        self.assertIn('class X', code)
        self.assertEqual(declared_constructors(code)['X'][''], True)
        self.assertEqual(declared_constructors('class Y { Y(); }')['Y'][''], False)
        for bad in ("class X { String s = 'unclosed; }", "class X { String s = 'line\nend'; }", 'class X { ] }', '/* unclosed'):
            with self.assertRaises(DartLexicalError): lexical_code(bad, 'synthetic-invalid')

    def test_changed_dart_relative_and_wo_imports_exist(self):
        missing = []
        for path, source in self.sources.items():
            for target in import_paths(path, source):
                if not target.is_file(): missing.append(f'{path.relative_to(ROOT)} -> {target}')
        self.assertFalse(missing, '\n'.join(missing))

    def test_changed_dart_lexical_boundaries_are_closed(self):
        errors = []
        for path, source in self.sources.items():
            try: lexical_code(source, str(path.relative_to(ROOT)))
            except DartLexicalError as error: errors.append(str(error))
        self.assertFalse(errors, '\n'.join(errors))

    def test_explicit_const_uses_match_known_local_constructors(self):
        errors = []
        for path, source in self.sources.items():
            scopes = {}
            for dependency in import_paths(path, source):
                if dependency.is_file():
                    scopes.update(declared_constructors(lexical_code(dependency.read_text(), str(dependency.relative_to(ROOT)))))
            code = lexical_code(source, str(path.relative_to(ROOT)))
            scopes.update(declared_constructors(code))
            for usage in re.finditer(r'\bconst\s+(\w+)(?:\.(\w+))?\s*\(', code):
                name, named = usage.group(1), usage.group(2) or ''
                if name in scopes and named in scopes[name] and not scopes[name][named]:
                    errors.append(f'{path.relative_to(ROOT)}: const {name}{"." + named if named else ""} has a known non-const local constructor')
        self.assertFalse(errors, '\n'.join(errors))

    def test_private_directory_method_matches_native_name_and_fixed_child_policy(self):
        dart = (ROOT / 'lib/local/transport/native_local.dart').read_text()
        kotlin = (ROOT / 'android/app/src/main/kotlin/io/github/chunyikit/wo/WoLocalBridge.kt').read_text()
        swift = (ROOT / 'ios/Runner/WoLocalBridge.swift').read_text()
        for source in (dart, kotlin, swift): self.assertIn('privateDirectory', source)
        self.assertIn('match.end!=name.length', dart)
        self.assertIn("path==null||!path.startsWith('/')", dart)
        self.assertIn("invokeMethod<String>('privateDirectory',{'name':name})", dart)
        self.assertIn('app.noBackupFilesDir.canonicalFile', kotlin)
        self.assertIn('directory.canonicalFile == directory.absoluteFile', kotlin)
        self.assertIn('android.system.Os.chmod(directory.path, 448)', kotlin)
        self.assertIn('directory.canonicalFile.parentFile == base', kotlin)
        self.assertIn('current.isSymbolicLink != true', swift)
        self.assertIn('FileProtectionType.complete', swift)
        self.assertIn('flags.isExcludedFromBackup = true', swift)

    def test_main_local_listener_is_removed_and_background_stop_is_requested(self):
        source = (ROOT / 'lib/main.dart').read_text()
        self.assertEqual(source.count('changes.addListener(_onLocalChanged)'), 1)
        self.assertEqual(source.count('changes.removeListener(_onLocalChanged)'), 1)
        self.assertIn('foreground(state==AppLifecycleState.resumed)', source)
        dispose = source.split('void dispose()', 1)[1].split('Widget build(', 1)[0]
        self.assertIn('foreground(false)', dispose)
        self.assertLess(dispose.index('removeListener(_onLocalChanged)'), dispose.index('widget.session.dispose()'))

    def test_local_memory_ui_does_not_render_unclassified_exception_text(self):
        names = ['local_memory_edit_page.dart', 'local_memory_media.dart', 'memory_detail_page.dart',
                 'memory_gallery_page.dart', 'memory_video_page.dart']
        for name in names:
            source = (ROOT / 'lib/features/plugins/memory' / name).read_text()
            self.assertNotRegex(source, r'Text\(\s*(?:error|exception|snapshot\.error)\.toString\(')
            self.assertNotRegex(source, r'\b(?:print|debugPrint)\s*\(')
        editor = (ROOT / 'lib/features/plugins/memory/local_memory_edit_page.dart').read_text()
        self.assertIn("error is ApiException?error.message:'无法完成本机操作，请保留草稿后重试'", editor)
        self.assertIn('changes.removeListener(_permissionChanged)', editor)
        self.assertIn("runtime.store.setPrivate(key,snapshot)", editor)

if __name__ == '__main__':
    unittest.main()
