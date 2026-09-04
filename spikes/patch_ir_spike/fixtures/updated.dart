class GreetingService {
  static String decorate(String value) => 'base:' + value;
  static String suffix(String value) => value + '!';

  String describe(int score) {
    if (score > 20) return suffix(decorate('patched-high'));
    return suffix(decorate('patched-low'));
  }
}
