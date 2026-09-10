# Generates only the native host. Never invokes Flutter or recompiles frozen Dart.
require 'xcodeproj'

abort 'usage: ruby create_project.rb STAGE OUTPUT.xcodeproj' unless ARGV.length == 2
stage, output = ARGV.map { |path| File.expand_path(path) }
abort 'output already exists' if File.exist?(output)
%w[Flutter.framework App.framework].each do |name|
  abort "missing #{name}" unless File.directory?(File.join(stage, name))
end
project = Xcodeproj::Project.new(output)
target = project.new_target(:application, 'HotfixRuntime', :ios, '15.0')
target.add_file_references([
  project.main_group.new_file(File.join(__dir__, 'main.m')),
  project.main_group.new_file(File.expand_path('../../native/patch_store_io.c', __dir__))
])
embed = target.new_copy_files_build_phase('Embed Frameworks')
embed.dst_subfolder_spec = '10'
%w[Flutter App].each do |name|
  reference = project.frameworks_group.new_file(File.join(stage, "#{name}.framework"))
  target.frameworks_build_phase.add_file_reference(reference) if name == 'Flutter'
  embed.add_file_reference(reference).settings = {
    'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy]
  }
end
target.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'dev.hotfixruntime.ios-spike',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES',
    'INFOPLIST_KEY_CFBundleDisplayName' => 'Hotfix Runtime',
    'CURRENT_PROJECT_VERSION' => '1',
    'MARKETING_VERSION' => '1.0',
    'CLANG_ENABLE_OBJC_ARC' => 'YES',
    'ARCHS' => 'arm64',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'FRAMEWORK_SEARCH_PATHS' => ['$(inherited)', stage],
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
    'GCC_PREPROCESSOR_DEFINITIONS' => ['$(inherited)', 'HOTFIX_DEVICE_TEST=1'],
    'OTHER_LDFLAGS' => ['$(inherited)', '-Wl,-export_dynamic'] +
      %w[open_root close lock unlock read replace free].map { |s| "-Wl,-u,_psio_#{s}" },
    'CODE_SIGN_STYLE' => 'Automatic'
  })
end
project.save
puts output
