bool Function(String functionId)? isPatched;
Object? Function(String functionId, Object? receiver, List<Object?> arguments)?
dispatch;

bool hotfixHasPatch(String functionId) => isPatched?.call(functionId) ?? false;

Object? hotfixInvoke(
  String functionId,
  Object? receiver,
  List<Object?> arguments,
) => dispatch!(functionId, receiver, arguments);
