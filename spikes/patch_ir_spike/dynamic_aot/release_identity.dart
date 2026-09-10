// Embedded by the release build; host is a test harness, not a shipping target.
const baselineId = 'dbc3-host-baseline-v1';
const releaseIdentity = <String, Object?>{
  'appId': String.fromEnvironment('HOTFIX_APP_ID', defaultValue: 'dev.hotfixruntime.fixture'),
  'platform': String.fromEnvironment('HOTFIX_PLATFORM', defaultValue: 'host'),
  'abi': 'arm64',
  'release': '1.0.0+1',
  'flutterRevision': '00b0c91f06209d9e4a41f71b7a512d6eb3b9c694',
  'dartVersion': '3.11.5',
  'engineRevision': '42d3d75a56efe1a2e9902f52dc8006099c45d937',
  'flavor': 'production',
  'channel': 'stable',
  'buildParametersSha256':
      'd4ca340739925e8f4a854a9c4ed6069cc9f687c900a6c3eb509fa070cad0fbb4',
};
