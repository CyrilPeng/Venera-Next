import 'package:flutter_qjs/flutter_qjs.dart';

class OwnedJsReference extends JSRef {
  OwnedJsReference({this.failure});
  final Object? failure;
  int destroys = 0;
  @override
  void destroy() {
    destroys++;
    if (failure != null) throw failure!;
  }
}

class OwnedJsCallback extends JSInvokable {
  OwnedJsCallback(this.action);
  final Object? Function(List<dynamic>) action;
  int calls = 0;
  int destroys = 0;
  @override
  dynamic invoke(List args, [dynamic thisVal]) {
    calls++;
    return action(List<dynamic>.from(args));
  }

  @override
  void destroy() => destroys++;
}
