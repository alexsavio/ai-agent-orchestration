import json
import subprocess
import unittest

from test_support import IsolatedTestCase
import legacy_rules
import watchers as w

RULES = json.loads((w.ROOT / 'fixtures/legacy-rules.json').read_text())
EXTRA = [('translated-dot', '^a.b$', ''), ('translated-dot-s', 'a.b', 's'), ('multiline', '^x|y$', 'm'),
         ('lookbehind', '(?<=@)name', ''), ('lookahead', 'name(?!:)', ''), ('space-class', '[\\s,]x', ''),
         ('not-space', 'a\\Sb', ''), ('lazy', 'a.*?b', ''), ('counted', 'a{2,3}b', ''), ('literal-brace', 'a{,2}', ''),
         ('u-surrogate-pair', '\\uD83D\\uDE00', 'u'), ('nonu-surrogate-pair', '\\uD83D\\uDE00', ''), ('u-surrogate-class', '^[\\uD83D\\uDE00]$', 'u'),
         ('ascii-escapes-i', '\\x41\\u0042', 'i'), ('escaped-backslash-i', '\\\\u00B5', 'i'),
         ('bounded-optional', '(a+){0,1}b', ''), ('bounded-one', '(a|b){1,1}x', ''), ('group-repeat', '(ab)+c', ''), ('optional-group', '(a+)?b', ''), ('alt-group', '(?:jquery|rails)-ujs?', ''), ('bounded-group', '(?:a|b){1}x', ''),
         ('u-slash', 'a\\/b', 'u'), ('u-class-dash', '[a\\-z]', 'u'), ('u-syntax', '\\(\\)\\{\\}', 'u'),
         ('astral-dot', '^.$', ''), ('astral-dot-u', '^.$', 'u'), ('astral-class', '^[\U0001F600]$', ''),
         ('astral-class-u', '^[\U0001F600]$', 'u'), ('astral-literal', '\U0001F600+', ''), ('astral-literal-u', '\U0001F600+', 'u'),
         ('class-edge', '[\\]\\[a-]x', ''), ('ascii-word', '\\w+', ''), ('word-boundary', '\\bfoo\\b', 'i')]
LINES = ['$(".menu").hide()', 'JQuery', 'x = jquery_ujs', 'link remote: true', 'remote:true', 'data-remote="1"',
         '$.ajax({})', 'ajax:error', 'select2', 'plain', '', 'a\nb', 'a\rb', 'a b', 'a b', 'a٣b',
         'aab', 'aaaab', 'a{,2}', '@name', 'name:', 'name', 'x]x', '-x', 'ab', 'a b', 'foo', 'FOO', 'fooé', 'éfoo',
         'xy', 'y', 'x', ' x', 'a,x', 'ſ', 'K', 'k', '\U0001F600', '\U0001F600\U0001F600', 'a\U0001F600']


def fixture_patterns():
    for kind, entries in RULES['patterns'].items():
        for entry in entries:
            yield entry['id'], entry['pattern'], entry['flags']
    yield 'bridge', RULES['bridgeMarker']['pattern'], ''
    yield from EXTRA


NODE = ('const cases = JSON.parse(process.argv[1]);'
        'console.log(JSON.stringify(cases.map(([, p, f, lines]) => lines.map(l => new RegExp(p, f).test(l)))))')


class TranslatorTests(IsolatedTestCase):
    def test_node_and_python_agree_on_every_pattern(self):
        cases = [(name, pattern, flags, LINES) for name, pattern, flags in fixture_patterns()]
        result = subprocess.run(['node', '-e', NODE, json.dumps(cases)], capture_output=True, text=True, check=True)
        expected = json.loads(result.stdout)
        self.assertEqual(len(expected), len(cases))
        for (name, pattern, flags, lines), js in zip(cases, expected):
            compiled = legacy_rules.compile_js(pattern, flags)
            self.assertEqual([bool(compiled.search(line)) for line in lines], js, name)
        self.assertTrue(any(any(row) for row in expected))

    def test_unsupported_syntax_is_rejected(self):
        for pattern, flags in [('(?<=a|bc)x', ''), ('(?<name>a)\\k<name>', ''), ('\\p{L}', 'u'), ('a', 'g'), ('a', 'y'),
                               ('a', 'd'), ('a', 'ii'), ('(a)\\1', ''), ('(?i)a', ''), ('(?P<n>a)', ''), ('a++', ''),
                               ('a*+', ''), ('\\u{1F600}', 'u'), ('[]', ''), ('[^]', ''), ('\\cJ', ''), ('\\A', ''),
                               ('é', 'i'), ('[', ''), ('a\\', ''), ('(?#c)', ''), ('(?>a)', ''), ('[\\S]', ''),
                               ('(?<n>a)(?<n>b)', ''), ('[+--]', ''), ('k', 'iu'), ('(a+)+$', ''), ('(a|a)*', ''), ('(a*)*b', ''), ('((a)+)+', ''), ('(\\w+\\s?)+x', ''), ('(?:a|b){2,}', ''), ('(a+){2,5}', ''), ('^(a?){1000}a{1000}$', ''), ('(a{1,3})+', ''), ('((ab)?c)*', ''), ('(a+){1,}$', ''), ('(a|aa){1,}$', ''), ('(a+){0,}b', ''), ('\\u00B5', 'i'), ('\\xB5', 'i'), ('\\u212A', 'i'), ('\\-', 'u'), ('a{,2}', 'u'), ('a{', 'u'), ('a}', 'u'), ('a]', 'u'), ('\\_', 'u')]:
            with self.assertRaises(ValueError, msg=f'{pattern!r} {flags!r}'):
                legacy_rules.compile_js(pattern, flags)

    def test_accepted_flags_and_groups(self):
        self.assertTrue(legacy_rules.compile_js('(?<n>a)b', 'ims').search('AB'))
        self.assertFalse(legacy_rules.compile_js('^a$', '').search('a\n'))

    def test_rules_file_validation(self):
        bad = [None, [], dict(RULES, version=2), dict(RULES, version=True), dict(RULES, version=1.0), dict(RULES, version='1'), {k: v for k, v in RULES.items() if k != 'version'},
               dict(RULES, patterns=[]), dict(RULES, patterns=dict(other=[])),
               dict(RULES, patterns=dict(jquery=[dict(id='', pattern='a')])),
               dict(RULES, patterns=dict(jquery=[dict(id='x', pattern='a', flags='g')])),
               dict(RULES, bridgeMarker=dict(pattern='a', fileLevelLines=0)), dict(RULES, legacyPaths='x'),
               dict(RULES, scannedPaths=['{a']), dict(RULES, selfExempt=['']), dict(RULES, legacyExtensions=['']),
               dict(RULES, legacyExtensions=[1]), dict(RULES, legacyExtensions='.coffee')]
        for raw in bad:
            with self.assertRaises(ValueError, msg=repr(raw)):
                legacy_rules.Rules(raw)
        with self.assertRaises(ValueError):
            legacy_rules.parse_rules('{not json')
        for constant in ('NaN', 'Infinity', '-Infinity'):
            with self.assertRaisesRegex(ValueError, 'is not JSON'):
                legacy_rules.parse_rules(json.dumps(RULES).replace('"jQuery call"', constant))
        with self.assertRaisesRegex(ValueError, 'pattern x:'):
            legacy_rules.Rules(dict(RULES, patterns=dict(jquery=[dict(id='x', pattern='(?<=a|bc)')])))

    def test_empty_matching_bridges_are_rejected(self):
        for pattern in ('', 'x*', '(?:)'):
            with self.assertRaisesRegex(ValueError, 'empty string'):
                legacy_rules.Rules(dict(RULES, bridgeMarker=dict(pattern=pattern, fileLevelLines=5)))

    def test_empty_pattern_sets_are_rejected(self):
        for patterns in ({}, dict(jquery=[])):
            with self.assertRaisesRegex(ValueError, 'at least one'):
                legacy_rules.Rules(dict(RULES, patterns=patterns))

    def test_extension_order_does_not_change_the_bucket(self):
        for extensions in ([".erb", ".js.erb"], [".js.erb", ".erb"]):
            rules = legacy_rules.Rules(dict(RULES, legacyExtensions=extensions))
            self.assertEqual(rules.classify('app/a.js.erb', 'x'), 'JSERB')
            self.assertEqual(rules.classify('app/a.erb', 'x'), 'LEGACY')

    def test_long_lines_are_searched_up_to_a_limit(self):
        regex = legacy_rules.compile_js('needle', '')
        self.assertTrue(regex.search('x' * (legacy_rules.LINE_SEARCH_LIMIT - 6) + 'needle'))
        self.assertFalse(regex.search('x' * legacy_rules.LINE_SEARCH_LIMIT + 'needle'))

    def test_deeply_nested_rules_are_a_value_error(self):
        with self.assertRaisesRegex(ValueError, 'nested too deeply'):
            legacy_rules.parse_rules('[' * 200000)

    def test_globs(self):
        match = lambda glob, path: bool(legacy_rules.compile_glob(glob).fullmatch(path))
        self.assertTrue(match('app/**', 'app/a/b.rb'))
        self.assertTrue(match('app/**/x.rb', 'app/x.rb'))
        self.assertTrue(match('app/**/x.rb', 'app/a/b/x.rb'))
        self.assertTrue(match('app/*.rb', 'app/x.rb'))
        self.assertFalse(match('app/*.rb', 'app/a/x.rb'))
        self.assertTrue(match('app/', 'app/a/x.rb'))
        self.assertTrue(match('a/{b,c}/x?.rb', 'a/c/x1.rb'))
        self.assertFalse(match('a/{b,c}/x?.rb', 'a/d/x1.rb'))
        self.assertFalse(match('app/x.rb', 'app/xarb'))


if __name__ == '__main__':
    unittest.main()
