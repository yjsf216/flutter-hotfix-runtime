import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'order_model.dart';
import 'order_repository.dart';

class OrderView extends StatelessWidget {
  const OrderView({super.key, required this.model, this.amountKey});
  final OrderModel model;
  final Key? amountKey;
  @override
  Widget build(BuildContext context) => MaterialApp(home: Scaffold(
    appBar: AppBar(title: const Text('Order hotfix example')),
    body: Center(child: ListenableBuilder(listenable: model, builder: (context, _) =>
      Column(mainAxisSize: MainAxisSize.min, children: [
        if (model.loading) const CircularProgressIndicator(),
        if (model.error != null) Text(model.error!),
        Text('Quantity: ${model.quantity}'),
        Text('Total cents: ${model.total}', key: amountKey),
        ElevatedButton(onPressed: model.loading ? null : model.load, child: const Text('Load order')),
        ElevatedButton(onPressed: model.order == null ? null : model.addItem, child: const Text('Add item')),
      ]))),
  ));
}

@Preview(name: 'Order baseline', size: Size(390, 700))
Widget orderPreview() => OrderView(model: OrderModel(OrderRepository())..order = const Order(1000, 200));
