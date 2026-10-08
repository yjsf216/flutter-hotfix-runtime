import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import '../dynamic_aot/release_identity.dart';
import '../native_store_io.dart';
import '../signed_manifest.dart';
import '../signed_patch_loader.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main(List<String> args) async {
  final temp = Directory(
    Directory.systemTemp
        .createTempSync('hotfix-lifecycle-')
        .resolveSymbolicLinksSync(),
  );
  final signer = File.fromUri(
    Platform.script,
  ).parent.uri.resolve('signature_check.dart');
  Future<void> sign(List<String> arguments) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      signer.toFilePath(),
      ...arguments,
    ]);
    check(result.exitCode == 0, 'signer failed: ${result.stderr}');
  }

  SignedPatchLoader? owner;
  try {
    final keys = '${temp.path}/keys';
    await sign(['keygen', keys]);
    final artifact = File('${temp.path}/artifact')..writeAsBytesSync([1, 2, 3]);
    final baseline = 'c' * 64;
    for (final id in ['good', 'pending', 'crash']) {
      await sign([
        'sign',
        keys,
        artifact.path,
        '${temp.path}/$id.json',
        baseline,
        id,
      ]);
    }
    var now = DateTime.now().toUtc();
    final verifier = SignedManifestVerifier(
      baselineId: baseline,
      releaseIdentity: releaseIdentity,
      publicKeys: {
        'spike-p256-1': base64.decode(
          File('$keys/public-key.txt').readAsStringSync(),
        ),
      },
      clock: () => now,
    );
    final root = Directory('${temp.resolveSymbolicLinksSync()}/store');
    SignedPatchLoader reopen() {
      owner?.close();
      return owner = SignedPatchLoader(
        root: root,
        verifier: verifier,
        nativeIo: args.isEmpty
            ? null
            : NativeStoreIo(root, DynamicLibrary.open(args.single)),
      );
    }

    var loader = reopen();
    check(loader.stage('${temp.path}/good.json', artifact.path), 'stage good');
    var loaded = await loader.load<void>((_) async {}, restoreBaseline: () {});
    check(loaded != null && loader.markHealthy(loaded), 'commit healthy');
    check(
      loader.stage('${temp.path}/pending.json', artifact.path),
      'stage pending',
    );
    now = now.add(const Duration(days: 2));
    loader = reopen();
    check(
      !loader.stage('${temp.path}/good.json', artifact.path),
      'expired admission accepted',
    );
    loaded = await loader.load<void>((_) async {}, restoreBaseline: () {});
    check(
      loaded?.patchId == 'good' && loader.markHealthy(loaded!),
      'expired pending must fall back to expired but healthy LKG',
    );
    now = now.subtract(const Duration(days: 2));
    check(
      loader.stage('${temp.path}/crash.json', artifact.path),
      'stage crash',
    );
    // Simulate process death before its health checkpoint, retaining disk state.
    for (var boot = 0; boot < 2; boot++) {
      loader = reopen();
      loaded = await loader.load<void>((_) async {}, restoreBaseline: () {});
      check(loaded?.patchId == 'crash', 'crash retry selection');
    }
    loader = reopen();
    loaded = await loader.load<void>((_) async {}, restoreBaseline: () {});
    check(
      loaded?.patchId == 'good' && loader.markHealthy(loaded!),
      'crash loop did not recover LKG',
    );
    check(
      !loader.stage('${temp.path}/crash.json', artifact.path),
      'blacklisted patch reinstalled',
    );
    // Healthy expiry exemption must not waive byte or signature verification.
    File('${root.path}/versions/good.ir').writeAsBytesSync([9, 9, 9]);
    now = now.add(const Duration(days: 2));
    loader = reopen();
    var activated = false;
    loaded = await loader.load<void>((_) async {
      activated = true;
    }, restoreBaseline: () {});
    check(loaded == null && !activated, 'corrupt expired LKG executed');
    print(
      'PASS: strict admission, healthy expiry exemption, pending expiry fallback, bounded crash recovery, tamper rejection',
    );
  } finally {
    owner?.close();
    temp.deleteSync(recursive: true);
  }
}
