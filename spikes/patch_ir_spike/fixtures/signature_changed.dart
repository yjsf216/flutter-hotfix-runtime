class GreetingService {
  static String decorate(String value) => 'base:' + value;

  String describe(num score) {
    if (score > 10) return decorate('high');
    return decorate('low');
  }
}
