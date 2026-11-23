# Idempotently adds the ShareExtension target to Runner.xcodeproj and the shared
# CaptureInbox.swift to both targets. Run from fils/mobile/ios:  ruby scripts/add_share_extension.rb
require 'xcodeproj'

project = Xcodeproj::Project.open('Runner.xcodeproj')
runner = project.targets.find { |t| t.name == 'Runner' }
runner_group = project.main_group['Runner']

# CaptureInbox.swift in Runner
inbox_ref = runner_group.files.find { |f| f.path == 'CaptureInbox.swift' } || runner_group.new_file('CaptureInbox.swift')
runner.source_build_phase.add_file_reference(inbox_ref, true) unless runner.source_build_phase.files_references.include?(inbox_ref)
%w[CaptureChannels.swift HeadlessCapture.swift].each do |f|
  ref = runner_group.files.find { |x| x.path == f } || runner_group.new_file(f)
  runner.source_build_phase.add_file_reference(ref, true) unless runner.source_build_phase.files_references.include?(ref)
end
ent_ref = runner_group.files.find { |f| f.path == 'Runner.entitlements' } || runner_group.new_file('Runner.entitlements')

ext = project.targets.find { |t| t.name == 'ShareExtension' }
unless ext
  ext = project.new_target(:app_extension, 'ShareExtension', :ios, '16.0', nil, :swift)
  group = project.main_group.find_subpath('ShareExtension', true)
  group.set_source_tree('<group>')
  group.set_path('ShareExtension')
  vc = group.new_file('ShareViewController.swift')
  group.new_file('Info.plist')
  group.new_file('ShareExtension.entitlements')
  ext.source_build_phase.add_file_reference(vc, true)
  ext.source_build_phase.add_file_reference(inbox_ref, true)
  ext.build_configurations.each do |c|
    s = c.build_settings
    s['PRODUCT_BUNDLE_IDENTIFIER'] = 'kw.fils.fils.ShareExtension'
    s['INFOPLIST_FILE'] = 'ShareExtension/Info.plist'
    s['CODE_SIGN_ENTITLEMENTS'] = 'ShareExtension/ShareExtension.entitlements'
    s['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
    s['SWIFT_VERSION'] = '5.0'
    s['TARGETED_DEVICE_FAMILY'] = '1,2'
    s['SKIP_INSTALL'] = 'YES'
    s['PRODUCT_NAME'] = '$(TARGET_NAME)'
    s['GENERATE_INFOPLIST_FILE'] = 'NO'
    s['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
    s['MARKETING_VERSION'] = '$(FLUTTER_BUILD_NAME)'
    s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
    s['CODE_SIGN_STYLE'] = 'Automatic'
  end
  # Flutter's Profile configuration mirrors Release for the extension.
  unless ext.build_configurations.any? { |c| c.name == 'Profile' }
    release = ext.build_configurations.find { |c| c.name == 'Release' }
    profile = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
    profile.name = 'Profile'
    profile.build_settings = release.build_settings.dup
    ext.build_configuration_list.build_configurations << profile
  end
  runner.add_dependency(ext)
  embed = runner.new_copy_files_build_phase('Embed App Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
  bf = embed.add_file_reference(ext.product_reference, true)
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  # Place the embed phase before Flutter's script phases to avoid a build cycle.
  phases = runner.build_phases
  phases.delete(embed)
  idx = phases.index { |p| p.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) } || phases.length
  phases.insert(idx, embed)
end
# The extension needs Flutter's build name/number (versions must match the app's).
# Idempotent: applied to existing projects too.
ext_group = project.main_group['ShareExtension']
xc_ref = ext_group.files.find { |f| f.path == 'ShareExtension.xcconfig' } || ext_group.new_file('ShareExtension.xcconfig')
ext.build_configurations.each { |c| c.base_configuration_reference = xc_ref }
project.save
puts "ShareExtension target present: #{project.targets.map(&:name).inspect}"
