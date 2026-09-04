import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../patch_store.dart';

void check(bool value) {
  if (!value) throw StateError('patch store check failed');
}

void main() {
  final root = Directory.systemTemp.createTempSync('patch-store-check-');
  try {
    final store = PatchStore(root);
    final p1 = Uint8List.fromList(utf8.encode('patch-one'));
    final p2 = Uint8List.fromList(utf8.encode('patch-two'));
    check(!store.install('../escape', p1, sha256.convert(p1).toString()));
    check(!store.install('p1', p1, sha256.convert(p2).toString()));

    check(store.install('p1', p1, sha256.convert(p1).toString()));
    check(store.beginBoot() == 'p1');
    check(store.markHealthy('p1'));

    check(store.install('p2', p2, sha256.convert(p2).toString()));
    check(store.beginBoot() == 'p2');
    check(store.beginBoot() == 'p2');
    check(store.beginBoot() == 'p1');
    check(store.markHealthy('p1'));

    final p3 = Uint8List.fromList(utf8.encode('patch-three'));
    check(store.install('p3', p3, sha256.convert(p3).toString()));
    File('${root.path}/versions/p3.ir').writeAsStringSync('disk-tamper');
    check(store.beginBoot() == 'p1');
    check(store.markHealthy('p1'));

    store.withdraw('p1');
    check(store.beginBoot() == PatchStore.bundled);

    File('${root.path}/state.json').writeAsStringSync('{corrupt');
    check(store.beginBoot() == PatchStore.bundled);
    print(
      'PASS: SHA-256 + atomic files + pending boot + LKG + blacklist + withdrawal',
    );
    print('PASS: invalid path/digest/state and disk tamper -> safe fallback');
  } finally {
    root.deleteSync(recursive: true);
  }
}
