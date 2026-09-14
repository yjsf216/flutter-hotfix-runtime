import 'package:flutter/foundation.dart';
import 'order_repository.dart';
import 'pricing.dart';

class OrderModel extends ChangeNotifier {
  OrderModel(this.repository);
  final OrderRepository repository;
  Order? order;
  int quantity = 2;
  bool loading = false;
  String? error;
  int get total => order == null ? 0 : totalCents(order!.unitCents, quantity, order!.shippingCents);
  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try { order = await repository.load(); }
    on Object { error = 'Unable to load order'; }
    finally { loading = false; notifyListeners(); }
  }
  void addItem() { quantity++; notifyListeners(); }
}
