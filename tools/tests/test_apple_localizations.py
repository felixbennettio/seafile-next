import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import generate_apple_localizations as localization


class OriginalLocalizationTests(unittest.TestCase):
    def test_double_utf16_bom_and_escaped_original_ios_strings(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'Localizable.strings'
            file.write_text('\ufeff/* "Ignored" = "comment"; */\n"Save" = "保存";\n"Quote" = "\\\"示例\\\"\\n下一行";\n"Example" = "/*保留*/";', encoding='utf-16')
            self.assertEqual(localization.read_strings(file), {'Save': '保存', 'Quote': '"示例"\n下一行', 'Example': '/*保留*/'})

    def test_canonical_ios_locale_keeps_newer_translations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for locale, value in [('zh_CN', '旧值'), ('zh-Hans', '新值')]:
                file = root / 'ios-legacy/seafile/Supporting Files' / (locale + '.lproj/Localizable.strings')
                file.parent.mkdir(parents=True)
                file.write_text('"Save" = ' + json.dumps(value, ensure_ascii=False) + ';', encoding='utf-8')
            self.assertEqual(localization.ios_translations(root)['zh-Hans']['Save'], '新值')

    def test_ios_only_language_is_restored_and_runtime_keys_are_translated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / 'ios-legacy/seafile/Supporting Files/ar.lproj/Localizable.strings'
            file.parent.mkdir(parents=True)
            file.write_text('"Save" = "حفظ";', encoding='utf-8')
            (root / 'desktop/i18n').mkdir(parents=True)
            with patch.object(localization, 'KEYS', {'Save'}):
                localization.generate(root)
            generated = root / 'apple/Resources/ar.lproj/Localizable.strings'
            self.assertEqual(localization.read_strings(generated), {'Save': 'حفظ'})


if __name__ == '__main__':
    unittest.main()
