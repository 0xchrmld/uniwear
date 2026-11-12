
import 'package:flutter_test/flutter_test.dart';
import 'package:uniwear/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('missing publishable configuration never opens a fake local app',
      (tester) async {
    await tester.pumpWidget(const SupabaseSetupRequiredApp());
    await tester.pumpAndSettle();
    expect(find.text('Connect UniWear to Supabase'), findsOneWidget);
    expect(find.textContaining('SUPABASE_PUBLISHABLE_KEY'), findsOneWidget);
  });
}
