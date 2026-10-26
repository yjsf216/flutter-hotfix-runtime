"""Small archive integrity checks; no signing, devices or SDK builds."""
import hashlib
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

import ios_release as ios


class IOSReleaseCheck(unittest.TestCase):
    def test_macho_sections_ignore_signature_but_detect_code_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'App'
            data = bytearray(192)
            struct.pack_into('<IIIIIIII', data, 0, 0xfeedfacf, 0x100000c, 0, 6, 1, 152, 0, 0)
            struct.pack_into('<II', data, 32, 0x19, 152)
            struct.pack_into('<I', data, 32 + 64, 1)
            data[104:110] = b'__text'
            data[120:126] = b'__TEXT'
            struct.pack_into('<QI', data, 104 + 40, 4, 184)
            data[184:188] = b'code'
            file.write_bytes(data)
            original = ios.sections(file)
            data[-1] = 1  # unrelated bytes, analogous to signature data
            file.write_bytes(data)
            self.assertEqual(ios.sections(file), original)
            data[184] ^= 1
            file.write_bytes(data)
            self.assertNotEqual(ios.sections(file), original)
            struct.pack_into('<I', data, 0, 0)
            file.write_bytes(data)
            with self.assertRaises(ValueError):
                ios.sections(file)

    def test_ipa_integrity_is_required_before_patch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / 'app.ipa'
            name = 'Payload/Runner.app/Info.plist'
            with zipfile.ZipFile(ipa, 'w') as bundle:
                bundle.writestr(name, b'identity')
            receipt = {'ipaSha256': ios.digest(ipa), 'files': {name: hashlib.sha256(b'identity').hexdigest()}}
            ios.verify(root, receipt)
            receipt['files'][name] = '0' * 64
            with self.assertRaisesRegex(ValueError, 'content changed'):
                ios.verify(root, receipt)
            receipt['ipaSha256'] = '0' * 64
            with self.assertRaisesRegex(ValueError, 'modified'):
                ios.verify(root, receipt)


if __name__ == '__main__':
    unittest.main()
