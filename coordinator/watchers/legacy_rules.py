"""Reads a repository's legacy-deletion-ratchet rules file and applies it to added lines."""
import json
import re
import struct
import warnings

RULES_PATH = 'scripts/legacy-deletion-ratchet-rules.json'
KINDS = ('jquery', 'ujs', 'ajax', 'selectWidgets')
TEST_PATH = re.compile(r'(^|/)(spec|test|tests)/|[._-](spec|test)\.[^/]*$')
FRONTEND_EXTENSIONS = ('.js', '.mjs', '.cjs', '.jsx', '.ts', '.tsx', '.vue', '.erb', '.haml', '.hbs', '.ejs', '.coffee', '.rb')
LINE_SEARCH_LIMIT = 2000
LINE_END = r'\n\r\u2028\u2029'
JS_SPACE = r'\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff'
GROUP_NAME = re.compile(r'\(\?<([A-Za-z_][A-Za-z0-9_]*)>')
REPEAT = re.compile(r'\{\d+(,\d*)?\}')
LOOKS = ('(?:', '(?=', '(?!', '(?<=', '(?<!')


def unbounded_repeat(pattern, index):
    match = REPEAT.match(pattern, index)
    if not match:
        return False
    low, comma, high = match[0][1:-1].partition(',')
    return int(high or 99) > 1 if comma else int(low) > 1


def js_escape(pattern, index, in_class, unicode_mode, ignore_case):
    if index + 1 >= len(pattern):
        raise ValueError('trailing backslash')
    char = pattern[index + 1]
    if char in 'dDwWbtnrfv' or (char == 'B' and not in_class):
        return '\\' + char, index + 2
    if char == 's':
        return (JS_SPACE if in_class else f'[{JS_SPACE}]'), index + 2
    if char == 'S' and not in_class:
        return f'[^{JS_SPACE}]', index + 2
    if char == '0' and not pattern[index + 2:index + 3].isdigit():
        return '\\x00', index + 2
    if ignore_case and (re.fullmatch(r'x[89A-Fa-f][0-9A-Fa-f]', pattern[index + 1:index + 4])
                        or re.fullmatch(r'u(?!00[0-7])[0-9A-Fa-f]{4}', pattern[index + 1:index + 6])):
        raise ValueError('non-ASCII escape with the i flag')
    if char == 'x' and re.fullmatch(r'[0-9A-Fa-f]{2}', pattern[index + 2:index + 4]):
        return pattern[index:index + 4], index + 4
    if char == 'u' and re.fullmatch(r'[0-9A-Fa-f]{4}', pattern[index + 2:index + 6]):
        pair = re.match(r'\\u(D[89AB][0-9A-Fa-f]{2})\\u(D[C-F][0-9A-Fa-f]{2})', pattern[index:index + 12], re.I)
        if unicode_mode and pair:
            high, low = int(pair[1], 16), int(pair[2], 16)
            return f'\\U{0x10000 + ((high - 0xD800) << 10) + low - 0xDC00:08x}', index + 12
        return pattern[index:index + 6], index + 6
    if not (char.isascii() and char.isalnum()):
        if unicode_mode and char not in '^$\\.*+?()[]{}|/' + '-' * in_class:
            raise ValueError(f'invalid escape \\{char} with the u flag')
        return re.escape(char), index + 2
    raise ValueError(f'unsupported escape \\{char}')


def translate_regex(pattern, flags=''):
    """Python regex with the same matches as the JavaScript `pattern`, or ValueError."""
    if set(flags) - set('imsu') or len(set(flags)) != len(flags):
        raise ValueError(f'unsupported flags {flags!r}')
    if 'i' in flags and not pattern.isascii():
        raise ValueError('non-ASCII text with the i flag')
    multiline, dotall, unicode_mode, ignore_case = 'm' in flags, 's' in flags, 'u' in flags, 'i' in flags
    out, index, repeated = [], 0, [False]
    while index < len(pattern):
        char = pattern[index]
        if char == '\\':
            text, index = js_escape(pattern, index, False, unicode_mode, ignore_case)
            out.append(text)
        elif char == '[':
            index += 1
            negated = pattern[index:index + 1] == '^'
            index += negated
            if pattern[index:index + 1] == ']':
                raise ValueError('empty character class')
            body = []
            while index < len(pattern) and pattern[index] != ']':
                if pattern[index] == '\\':
                    text, index = js_escape(pattern, index, True, unicode_mode, ignore_case)
                else:
                    text = '\\' + pattern[index] if pattern[index] in '[&~|' else pattern[index]
                    index += 1
                body.append(text)
            if index >= len(pattern):
                raise ValueError('unterminated character class')
            out.append('[' + ('^' if negated else '') + ''.join(body) + ']')
            index += 1
        elif char == '(':
            repeated.append(False)
            named = GROUP_NAME.match(pattern, index)
            if pattern[index + 1:index + 2] != '?':
                out.append('(')
                index += 1
            elif named:
                out.append(f'(?P<{named[1]}>')
                index = named.end()
            elif pattern.startswith(LOOKS, index):
                size = 4 if pattern.startswith('(?<', index) else 3
                out.append(pattern[index:index + size])
                index += size
            else:
                raise ValueError('unsupported group syntax')
        elif char == '|':
            repeated[-1] = True
            out.append(char)
            index += 1
        elif char == ')':
            inner = repeated.pop() if len(repeated) > 1 else False
            out.append(char)
            index += 1
            again = pattern[index:index + 1] in ('*', '+') or unbounded_repeat(pattern, index)
            if inner and again:
                raise ValueError('quantified group containing a quantifier or alternation')
            repeated[-1] = repeated[-1] or inner or again
        elif char == '.':
            out.append('(?s:.)' if dotall else f'[^{LINE_END}]')
            index += 1
        elif char == '^':
            out.append(f'(?<![^{LINE_END}])' if multiline else '^')
            index += 1
        elif char == '$':
            out.append(f'(?![^{LINE_END}])' if multiline else r'\Z')
            index += 1
        elif char in '*+?{':
            repeat = REPEAT.match(pattern, index) if char == '{' else None
            if char == '{' and not repeat:
                if unicode_mode:
                    raise ValueError('lone { with the u flag')
                out.append(r'\{')
                index += 1
                continue
            end = repeat.end() if repeat else index + 1
            repeated[-1] = True
            out.append(pattern[index:end])
            if pattern[end:end + 1] == '?':
                out.append('?')
                end += 1
            if pattern[end:end + 1] in ('+', '*', '?', '{'):
                raise ValueError('unsupported repeat syntax')
            index = end
        elif char in '}]' and unicode_mode:
            raise ValueError(f'lone {char} with the u flag')
        elif char == '}':
            out.append(r'\}')
            index += 1
        else:
            out.append(char)
            index += 1
    return ''.join(out)


def utf16_units(text):
    raw = text.encode('utf-16-le', 'surrogatepass')
    return ''.join(chr(unit) for unit in struct.unpack(f'<{len(raw) // 2}H', raw))


class JsRegex:
    """Searches like a JavaScript RegExp: UTF-16 code units unless the u flag is set."""

    def __init__(self, compiled, units):
        self.compiled, self.units = compiled, units

    def search(self, text):
        text = text[:LINE_SEARCH_LIMIT]
        return self.compiled.search(utf16_units(text) if self.units else text)


def compile_js(pattern, flags=''):
    if not isinstance(pattern, str) or not isinstance(flags, str):
        raise ValueError('pattern and flags must be strings')
    if 'i' in flags and 'u' in flags:
        raise ValueError('flags i and u together')
    units = 'u' not in flags
    translated = translate_regex(utf16_units(pattern) if units else pattern, flags)
    try:
        with warnings.catch_warnings():
            warnings.simplefilter('error')
            return JsRegex(re.compile(translated, re.ASCII | (re.IGNORECASE if 'i' in flags else 0)), units)
    except (re.error, Warning, RecursionError, OverflowError) as error:
        raise ValueError(f'not expressible in Python: {error}') from error


def glob_body(glob):
    out, index = [], 0
    while index < len(glob):
        if glob.startswith('**/', index):
            out.append('(?:.*/)?')
            index += 3
        elif glob.startswith('**', index):
            out.append('.*')
            index += 2
        elif glob[index] == '*':
            out.append('[^/]*')
            index += 1
        elif glob[index] == '?':
            out.append('[^/]')
            index += 1
        elif glob[index] == '{':
            end = glob.find('}', index)
            if end < 0 or '{' in glob[index + 1:end]:
                raise ValueError(f'bad brace group in {glob!r}')
            out.append('(?:' + '|'.join(glob_body(part) for part in glob[index + 1:end].split(',')) + ')')
            index = end + 1
        else:
            out.append(re.escape(glob[index]))
            index += 1
    return ''.join(out)


def compile_glob(glob):
    if not isinstance(glob, str) or not glob:
        raise ValueError('glob must be a non-empty string')
    return re.compile(glob_body(glob + '**' if glob.endswith('/') else glob))


def compile_extension(extension):
    if not isinstance(extension, str) or not extension:
        raise ValueError('extension must be a non-empty string')
    return extension


def string_list(raw, key, convert):
    value = raw.get(key, [])
    if not isinstance(value, list):
        raise ValueError(f'{key} must be a list')
    return [convert(item) for item in value]


class Rules:
    def __init__(self, raw):
        if not isinstance(raw, dict) or type(raw.get('version')) is not int or raw['version'] != 1:
            raise ValueError('rules file must be an object with version 1')
        self.legacy_paths = string_list(raw, 'legacyPaths', compile_glob)
        self.scanned = string_list(raw, 'scannedPaths', compile_glob)
        self.exempt = string_list(raw, 'selfExempt', compile_glob)
        self.extensions = string_list(raw, 'legacyExtensions', compile_extension)
        bridge = raw.get('bridgeMarker')
        self.bridge, self.bridge_lines = None, 0
        if bridge is not None:
            lines = bridge.get('fileLevelLines') if isinstance(bridge, dict) else None
            if not isinstance(lines, int) or isinstance(lines, bool) or lines < 1:
                raise ValueError('bridgeMarker needs a pattern and a positive fileLevelLines')
            self.bridge = self.compiled('bridgeMarker', bridge.get('pattern'), bridge.get('flags', ''))
            if self.bridge.search(''):
                raise ValueError('bridgeMarker must not match the empty string')
            self.bridge_lines = lines
        groups = raw.get('patterns')
        if not isinstance(groups, dict) or set(groups) - set(KINDS):
            raise ValueError('patterns must be an object keyed by ' + ', '.join(KINDS))
        self.patterns = []
        for kind, entries in groups.items():
            if not isinstance(entries, list):
                raise ValueError(f'patterns.{kind} must be a list')
            for entry in entries:
                if not isinstance(entry, dict) or not isinstance(entry.get('id'), str) or not entry['id']:
                    raise ValueError(f'patterns.{kind} entries need an id')
                self.patterns.append(self.compiled(entry['id'], entry.get('pattern'), entry.get('flags', '')))

        if not self.patterns:
            raise ValueError('patterns must contain at least one pattern')

    @staticmethod
    def compiled(name, pattern, flags):
        try:
            return compile_js(pattern, flags)
        except ValueError as error:
            raise ValueError(f'pattern {name}: {error}') from error

    def exempted(self, path):
        return any(glob.fullmatch(path) for glob in self.exempt)

    def in_legacy_path(self, path):
        return any(glob.fullmatch(path) for glob in self.legacy_paths)

    def classify(self, path, text):
        if '.js.erb' in self.extensions and path.endswith('.js.erb'):
            return 'JSERB'
        if path.endswith(tuple(self.extensions)):
            return 'LEGACY'
        scanned = path.endswith(FRONTEND_EXTENSIONS) and (
            not self.scanned or any(glob.fullmatch(path) for glob in self.scanned))
        legacy = self.in_legacy_path(path)
        if scanned and any(pattern.search(text) for pattern in self.patterns):
            if TEST_PATH.search(path):
                return 'TEST'
            return 'LEGACY' if legacy else 'JQUERY'
        return 'LEGACY' if legacy else None

    def bridge_files(self, lines):
        if not self.bridge:
            return set()
        return {path for path, number, text, _ in lines
                if number <= self.bridge_lines and not self.exempted(path) and self.bridge.search(text)}

    def scan(self, lines, bridged=None):
        files, hits = self.bridge_files(lines), []
        for path, _, text, added in lines:
            if not added or self.exempted(path):
                continue
            if path in files or (self.bridge and self.bridge.search(text)):
                if bridged is not None:
                    bridged.append((path, text))
            elif kind := self.classify(path, text):
                hits.append((kind, path, text))
        return hits


def reject_constant(name):
    raise ValueError(f'{name} is not JSON')


def parse_rules(text):
    try:
        return Rules(json.loads(text, parse_constant=reject_constant))
    except json.JSONDecodeError as error:
        raise ValueError(f'rules file is not JSON: {error}') from error
    except RecursionError as error:
        raise ValueError('rules file is nested too deeply') from error
