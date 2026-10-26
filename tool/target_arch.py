"""Canonical release ABI names and their Android packaging equivalents."""
ANDROID = {'arm64': ('android-arm64', 'arm64-v8a', 2, 183),
           'arm': ('android-arm', 'armeabi-v7a', 1, 40)}


def abi_for(config):
    abi = config.get('abi', 'arm64')
    if abi not in ANDROID or (config.get('platform') == 'ios' and abi != 'arm64'):
        raise ValueError('Supported targets: Android arm/arm64 and iOS arm64')
    return abi


def verify_elf(data, abi):
    _, _, elf_class, machine = ANDROID[abi]
    if (len(data) < 20 or data[:4] != b'\x7fELF' or data[4] != elf_class or data[5] != 1
            or int.from_bytes(data[18:20], 'little') != machine):
        raise ValueError('ELF architecture does not match ' + abi)
