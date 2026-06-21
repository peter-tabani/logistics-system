import 'package:flutter_test/flutter_test.dart';

import 'package:driver_app/main.dart';

void main() {
  testWidgets('shows driver login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Driver Login'), findsOneWidget);
    expect(find.text('Login'), findsOneWidget);
    expect(find.text('Test account: 0711111111 / driver123'), findsOneWidget);
  });
}
