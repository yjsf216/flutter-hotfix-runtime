bool Function(String functionId)? isPatched;
Object? Function(String functionId, Object? receiver, List<Object?> arguments)?
dispatch;

@pragma('vm:never-inline')
void hotfixNeverInlineTemplate() {}

bool hotfixHasPatch(String functionId) => isPatched?.call(functionId) ?? false;

Object? hotfixInvoke(
  String functionId,
  Object? receiver,
  List<Object?> arguments,
) => dispatch!(functionId, receiver, arguments);
