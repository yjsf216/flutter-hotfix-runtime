class Order {
  const Order(this.unitCents, this.shippingCents);
  final int unitCents;
  final int shippingCents;
}

class OrderRepository {
  OrderRepository({Future<Order> Function()? fetch}) : _fetch = fetch ?? _demoOrder;
  final Future<Order> Function() _fetch;
  Future<Order> load() => _fetch();
  // Deterministic asynchronous data source, not a real commerce backend.
  static Future<Order> _demoOrder() async => const Order(1000, 200);
}
