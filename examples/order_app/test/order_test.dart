import 'package:flutter_test/flutter_test.dart';
import 'package:hotfix_order_example/order_view.dart';
import 'package:hotfix_order_example/order_model.dart';
import 'package:hotfix_order_example/order_repository.dart';
import '../fixes/pricing.dart' as fixed;

void main() {
  test('fix charges shipping once', () {
    expect(fixed.totalCents(1000, 2, 200), 2200);
    expect(fixed.totalCents(1000, 3, 200), 3200);
  });
  testWidgets('async load and quantity state expose the baseline defect', (tester) async {
    final model = OrderModel(OrderRepository());
    addTearDown(model.dispose);
    await tester.pumpWidget(OrderView(model: model));
    await tester.tap(find.text('Load order'));
    await tester.pumpAndSettle();
    expect(find.text('Total cents: 2400'), findsOneWidget);
    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();
    expect(find.text('Quantity: 3'), findsOneWidget);
    expect(find.text('Total cents: 3600'), findsOneWidget);
  });
}
