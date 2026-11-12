
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uniwear/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('catalog has no local fallback before Supabase loads', () {
    expect(catalog, isEmpty);
  });

  test('cart payload contains product, size and quantity only', () {
    final item = CartItem('college-polo', 'M', 2);
    expect(item.toJson(), {
      'productId': 'college-polo',
      'size': 'M',
      'quantity': 2,
    });
    expect(item.toJson().containsKey('price'), isFalse);
    expect(item.toJson().containsKey('unitPrice'), isFalse);
  });

  test('cart quantity is capped at ten', () async {
    SharedPreferences.setMockInitialValues({});
    catalog = [
      const UniformProduct(
        id: 'college-polo',
        name: 'College Polo',
        section: 'College',
        group: 'Male',
        image: 'college_polo.png',
        description: 'Test product',
        prices: {'M': 390},
      ),
    ];
    final store = AppStore();
    store.add(catalog.single, 'M', 10);
    expect(store.count, 10);
    store.add(catalog.single, 'M', 1);
    expect(store.count, 10);
    store.quantity(store.cart.single, 1);
    expect(store.count, 10);
    store.quantity(store.cart.single, -1);
    expect(store.total, 3510);
    store.dispose();
  });

  test('view-only product model has no orderable sizes', () {
    const peShirt = UniformProduct(
      id: 'integrated-pe-shirt',
      name: 'Integrated P.E. Shirt',
      section: 'Integrated',
      group: 'P.E.',
      image: 'pe_shirt.png',
      description: 'View-only',
      prices: {},
    );
    expect(peShirt.canOrder, isFalse);
    expect(peShirt.startingPrice, isNull);
  });

  test('money formatting uses Philippine peso', () {
    expect(money(123456), '₱123,456');
  });
}
