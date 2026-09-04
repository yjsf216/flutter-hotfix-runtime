class GreetingService {
  static String decorate(String value) => 'base:' + value;

  String describe(int score) {
    if (score > 20) return decorate('patched-high');
    return decorate('patched-low');
  }
}
