# Structure-only regression; no device, signing or Engine execution.
require 'tmpdir'
require 'fileutils'
require 'xcodeproj'

Dir.mktmpdir('hotfix-ios-project-check') do |root|
  stage = File.join(root, 'stage')
  %w[Flutter.framework App.framework].each do |name|
    FileUtils.mkdir_p(File.join(stage, name))
  end
  output = File.join(root, 'HotfixRuntime.xcodeproj')
  abort 'generator failed' unless system('ruby', File.join(__dir__, 'create_project.rb'), stage, output)
  target = Xcodeproj::Project.open(output).targets.fetch(0)
  abort 'sources absent' unless target.source_build_phase.files.count == 2
  abort 'frameworks absent' unless target.copy_files_build_phases.first.files.count == 2
  target.build_configurations.each do |config|
    flags = config.build_settings.fetch('OTHER_LDFLAGS')
    abort 'FFI exports missing' unless flags.count { |f| f.start_with?('-Wl,-u,_psio_') } == 7
    abort 'wrong bundle' unless config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] == 'dev.hotfixruntime.ios-spike'
  end
  puts 'PASS: project sources, embedded frameworks and FFI symbol roots (structure only)'
end
