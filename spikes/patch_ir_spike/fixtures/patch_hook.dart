bool Function(String functionId)? isPatched;
Object? Function(String functionId, Object? receiver, List<Object?> arguments)?
dispatch;
Function? Function(String functionId)? lookup;

@pragma('vm:never-inline')
void hotfixNeverInlineTemplate() {}

bool hotfixHasPatch(String functionId) => isPatched?.call(functionId) ?? false;

Object? hotfixInvoke(
  String functionId,
  Object? receiver,
  List<Object?> arguments,
) => dispatch!(functionId, receiver, arguments);

Function? hotfixLookup(String functionId) => lookup?.call(functionId);
