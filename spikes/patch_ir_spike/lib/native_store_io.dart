import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// The library is bundled with the app; its path never comes from a manifest.
/// Each store owner gets a separate root descriptor and holds the inode lock
/// for the entire synchronous state transaction.
final class NativeStoreIo {
  factory NativeStoreIo.bundled(Directory root) =>
      NativeStoreIo(root, switch (Platform.operatingSystem) {
        // A packaged .so need not already belong to the process-global scope.
        'android' || 'ohos' => DynamicLibrary.open('libpatch_store_io.so'),
        'ios' => DynamicLibrary.process(),
        _ => throw UnsupportedError('bundled store requires Android/iOS/OHOS'),
      });

  NativeStoreIo(this.root, DynamicLibrary library, {this.createRoot = true})
    : _library = library,
      _open = library
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Int32),
            int Function(Pointer<Uint8>, int)
          >('psio_open_root'),
      _close = library.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'psio_close',
      ),
      _lock = library.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'psio_lock',
      ),
      _unlock = library
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'psio_unlock',
          ),
      _read = library
          .lookupFunction<
            Int32 Function(
              Int32,
              Pointer<Uint8>,
              Size,
              Pointer<Pointer<Uint8>>,
              Pointer<Size>,
            ),
            int Function(
              int,
              Pointer<Uint8>,
              int,
              Pointer<Pointer<Uint8>>,
              Pointer<Size>,
            )
          >('psio_read'),
      _replace = library
          .lookupFunction<
            Int32 Function(Int32, Pointer<Uint8>, Pointer<Uint8>, Size),
            int Function(int, Pointer<Uint8>, Pointer<Uint8>, int)
          >('psio_replace'),
      _free = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('psio_free');

  final Directory root;
  final bool createRoot;
  final DynamicLibrary _library;
  final int Function(Pointer<Uint8>, int) _open;
  final int Function(int) _close, _lock, _unlock;
  final int Function(
    int,
    Pointer<Uint8>,
    int,
    Pointer<Pointer<Uint8>>,
    Pointer<Size>,
  )
  _read;
  final int Function(int, Pointer<Uint8>, Pointer<Uint8>, int) _replace;
  final void Function(Pointer<Void>) _free;
  static final _malloc = DynamicLibrary.process()
      .lookupFunction<
        Pointer<Void> Function(Size),
        Pointer<Void> Function(int)
      >('malloc');
  int _fd = -1;
  bool _locked = false;
  bool _closed = false;

  Pointer<Void> _allocate(int size) {
    final memory = _malloc(size == 0 ? 1 : size);
    if (memory == nullptr) throw StateError('native store allocation failed');
    return memory;
  }

  Pointer<Uint8> _text(String value) {
    if (value.contains('\u0000')) throw const FormatException('NUL path');
    if (value.length > 4096) throw const FormatException('oversized path');
    final bytes = utf8.encode(value);
    if (bytes.length > 4096)
      throw const FormatException('oversized UTF-8 path');
    final memory = _allocate(bytes.length + 1).cast<Uint8>();
    memory.asTypedList(bytes.length + 1).setAll(0, [...bytes, 0]);
    return memory;
  }

  void _check(int result, String operation) {
    if (result < 0) print('HotfixNative $operation: errno=${-result}, root=${root.path}');
    if (result < 0)
      throw FileSystemException(
        'native $operation',
        root.path,
        OSError('POSIX', -result),
      );
  }

  T transaction<T>(T Function() action) {
    if (_closed || _locked)
      throw StateError('closed or reentrant native store');
    if (_fd < 0) {
      final path = _text(root.absolute.path);
      try {
        _fd = _open(path, createRoot ? 1 : 0);
      } finally {
        _free(path.cast());
      }
      _check(_fd, 'open root');
    }
    _check(_lock(_fd), 'lock');
    _locked = true;
    try {
      return action();
    } finally {
      _locked = false;
      _check(_unlock(_fd), 'unlock');
    }
  }

  void _requireLock() {
    if (!_locked || _closed)
      throw StateError('native I/O requires transaction');
  }

  Uint8List? read(String relativePath, int limit) {
    _requireLock();
    if (limit < 0 || limit > 64 * 1024 * 1024)
      throw ArgumentError('invalid read limit');
    final path = _text(relativePath);
    Pointer<Pointer<Uint8>> bytes = nullptr;
    Pointer<Size> length = nullptr;
    try {
      bytes = _allocate(sizeOf<Pointer<Uint8>>()).cast<Pointer<Uint8>>()
        ..value = nullptr;
      length = _allocate(sizeOf<Size>()).cast<Size>()..value = 0;
      final result = _read(_fd, path, limit, bytes, length);
      if (result == -2) return null; // ENOENT on all three POSIX targets.
      _check(result, 'read $relativePath');
      if (length.value > limit || bytes.value == nullptr)
        throw StateError('invalid native read result');
      // This copy is the only Dart buffer authenticated and passed to the VM;
      // there is no second path read after the pinned descriptor snapshot.
      return Uint8List.fromList(bytes.value.asTypedList(length.value));
    } finally {
      if (bytes != nullptr) _free(bytes.value.cast());
      _free(length.cast());
      _free(bytes.cast());
      _free(path.cast());
    }
  }

  Uint8List? readSource(String absolutePath, int limit) {
    final source = File(absolutePath).absolute;
    final owner = NativeStoreIo(source.parent, _library, createRoot: false);
    try {
      return owner.transaction(
        () => owner.read(source.uri.pathSegments.last, limit),
      );
    } finally {
      owner.close();
    }
  }

  void replace(String relativePath, List<int> value) {
    _requireLock();
    if (value.length > 64 * 1024 * 1024) throw ArgumentError('oversized write');
    final path = _text(relativePath);
    Pointer<Uint8> bytes = nullptr;
    try {
      bytes = _allocate(value.length).cast<Uint8>();
      bytes.asTypedList(value.length).setAll(0, value);
      _check(_replace(_fd, path, bytes, value.length), 'replace $relativePath');
    } finally {
      _free(bytes.cast());
      _free(path.cast());
    }
  }

  void close() {
    if (_locked) throw StateError('cannot close during transaction');
    if (_closed) return;
    _closed = true;
    if (_fd >= 0) {
      final fd = _fd;
      _fd = -1;
      _check(_close(fd), 'close');
    }
  }
}
