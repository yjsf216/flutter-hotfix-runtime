class GreetingService {
  final int version = 2;

  static String decorate(String value) => 'base:' + value;

  String describe(int score) {
    if (score > 10) return decorate('high');
    return decorate('low');
  }
}
