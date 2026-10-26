# Edits only Runner's build graph, preserving native/plugin files and signing.
require 'xcodeproj'
abort 'usage: ios_integrate.rb PROJECT NATIVE_C TEAM [--preserve-settings]' unless ARGV.length == 3 || ARGV.length == 4 && ARGV[3] == '--preserve-settings'
path, native, team = ARGV.take(3)
abort 'invalid team' unless team.match?(/\A[A-Z0-9]{10}\z/)
project = Xcodeproj::Project.open(path)
target = project.targets.find { |item| item.name == 'Runner' }
abort 'missing Runner target' unless target
reference = project.files.find { |file| file.real_path.to_s == File.expand_path(native) } ||
  project.main_group.new_file(File.expand_path(native))
reference.path = File.expand_path(native)
reference.source_tree = '<absolute>'
unless target.source_build_phase.files.any? { |file| file.file_ref == reference }
  target.source_build_phase.add_file_reference(reference)
end
target.build_configurations.each do |config|
  old = config.build_settings['OTHER_LDFLAGS']
  flags = old.is_a?(Array) ? old : (old ? [old] : ['$(inherited)'])
  config.build_settings['OTHER_LDFLAGS'] = (flags + ['-Wl,-export_dynamic'] +
    %w[open_root close lock unlock read replace free set_app_base].map { |s| "-Wl,-u,_psio_#{s}" }).uniq
  original_plist = config.build_settings['INFOPLIST_FILE']
  if original_plist && original_plist != '$(HOTFIX_RUNNER_INFO_PLIST)'
    config.build_settings['HOTFIX_RUNNER_INFO_PLIST'] = original_plist
    config.build_settings['INFOPLIST_FILE'] = '$(HOTFIX_RUNNER_INFO_PLIST)'
  end
  unless ARGV[3] == '--preserve-settings'
    config.build_settings['DEVELOPMENT_TEAM'] = team
    config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
    config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  end
end
project.save
