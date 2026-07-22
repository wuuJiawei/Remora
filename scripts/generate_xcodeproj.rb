#!/usr/bin/env ruby

require 'fileutils'
require 'digest'
require 'json'
require 'pathname'
require 'xcodeproj'

ROOT = Pathname.new(__dir__).join('..').realpath
PROJECT_PATH = ROOT.join('Remora.xcodeproj')
PACKAGE_RESOLVED_PATH = PROJECT_PATH.join('project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
DEPLOYMENT_TARGET = '14.0'
SWIFTTERM_URL = 'https://github.com/wuuJiawei/SwiftTerm'
SWIFTTERM_REVISION = '4f632d1c60be15ad70152b006cb8679fc81c764f'
NATIVE_SOURCE_MANIFEST = JSON.parse(ROOT.join('Vendor/NativeSSH/SOURCES.json').read)

def stable_uuid_keys(project)
  phase_owners = {}
  configuration_list_owners = {
    project.root_object.build_configuration_list => 'project',
  }
  product_dependency_owners = {}
  target_dependency_owners = {}
  proxy_owners = {}

  project.targets.each do |target|
    target.build_phases.each do |phase|
      phase_owners[phase] = "target:#{target.name}/phase:#{phase.isa}"
    end
    configuration_list_owners[target.build_configuration_list] = "target:#{target.name}"
    target.package_product_dependencies.each do |dependency|
      product_dependency_owners[dependency] = "target:#{target.name}"
    end
    target.dependencies.each do |dependency|
      owner = "target:#{target.name}/dependency:#{dependency.display_name}"
      target_dependency_owners[dependency] = owner
      proxy_owners[dependency.target_proxy] = owner if dependency.target_proxy
    end
  end

  configuration_owners = {}
  configuration_list_owners.each do |configuration_list, owner|
    configuration_list.build_configurations.each do |configuration|
      configuration_owners[configuration] = owner
    end
  end

  build_file_owners = {}
  phase_owners.each do |phase, owner|
    phase.files.each do |build_file|
      build_file_owners[build_file] = owner
    end
  end

  keys = {}
  key_for = lambda do |object|
    return keys.fetch(object) if keys.key?(object)

    key = case object.isa
          when 'PBXProject'
            "project:#{object.display_name}"
          when 'PBXNativeTarget'
            "target:#{object.name}"
          when 'PBXGroup', 'PBXVariantGroup'
            "#{object.isa}:#{object.hierarchy_path}"
          when 'PBXFileReference'
            "file:#{object.hierarchy_path}:#{object.path}:#{object.source_tree}"
          when 'PBXSourcesBuildPhase', 'PBXHeadersBuildPhase',
               'PBXFrameworksBuildPhase', 'PBXResourcesBuildPhase'
            phase_owners.fetch(object)
          when 'PBXBuildFile'
            reference = object.file_ref || object.product_ref
            settings = object.settings ? JSON.generate(object.settings.sort.to_h) : ''
            "#{build_file_owners.fetch(object)}/build:#{key_for.call(reference)}:#{settings}"
          when 'XCConfigurationList'
            "#{configuration_list_owners.fetch(object)}/configuration-list"
          when 'XCBuildConfiguration'
            "#{configuration_owners.fetch(object)}/configuration:#{object.name}"
          when 'PBXTargetDependency'
            target_dependency_owners.fetch(object)
          when 'PBXContainerItemProxy'
            "#{proxy_owners.fetch(object)}/proxy"
          when 'XCRemoteSwiftPackageReference'
            "package:#{object.repositoryURL}"
          when 'XCSwiftPackageProductDependency'
            "#{product_dependency_owners.fetch(object)}/package-product:#{object.product_name}"
          else
            raise "Missing stable UUID identity for #{object.isa} (#{object.display_name})"
          end

    keys[object] = key
  end

  project.objects.each { |object| key_for.call(object) }
  duplicates = keys.group_by { |_object, key| key }.select { |_key, entries| entries.length > 1 }
  unless duplicates.empty?
    details = duplicates.map { |key, entries| "#{key}: #{entries.map { |object, _| object.isa }.join(', ')}" }
    raise "Duplicate stable UUID identities:\n#{details.join("\n")}"
  end
  keys
end

def stable_uuid_map(project)
  stable_uuid_keys(project).to_h { |object, key| [key, object.uuid] }
end

def apply_stable_uuids(project, previous_uuids)
  keys = stable_uuid_keys(project)
  objects_by_old_uuid = project.objects_by_uuid.dup
  assigned_uuids = {}

  keys.each do |object, key|
    uuid = previous_uuids[key] || Digest::MD5.hexdigest("Remora/#{key}").upcase
    raise "Duplicate stable UUID #{uuid} for #{key}" if assigned_uuids.key?(uuid)

    assigned_uuids[uuid] = object
  end

  uuid_attributes = [:remote_global_id_string, :container_portal, :target_proxy]
  reference_fixups = project.objects.each_with_object([]) do |object, fixups|
    uuid_attributes.each do |attribute|
      next unless object.respond_to?(attribute)

      referenced_object = objects_by_old_uuid[object.send(attribute)]
      fixups << [object, attribute, referenced_object] if referenced_object
    end
  end

  target_attributes = project.root_object.attributes['TargetAttributes'] || {}
  target_attribute_fixups = target_attributes.each_with_object([]) do |(target_uuid, attributes), fixups|
    target = objects_by_old_uuid[target_uuid]
    next unless target

    test_target = objects_by_old_uuid[attributes['TestTargetID']]
    fixups << [target, attributes, test_target]
  end

  keys.each do |object, key|
    uuid = previous_uuids[key] || Digest::MD5.hexdigest("Remora/#{key}").upcase
    object.instance_variable_set(:@uuid, uuid)
  end
  reference_fixups.each do |object, attribute, referenced_object|
    object.send("#{attribute}=", referenced_object.uuid)
  end
  unless target_attribute_fixups.empty?
    project.root_object.attributes['TargetAttributes'] = target_attribute_fixups.to_h do |target, attributes, test_target|
      updated_attributes = attributes.dup
      updated_attributes['TestTargetID'] = test_target.uuid if test_target
      [target.uuid, updated_attributes]
    end
  end

  project.instance_variable_set(:@objects_by_uuid, assigned_uuids)
  project.mark_dirty!
end

def sorted_swift_files(path, relative_to:)
  Dir.glob(path.join('**/*.swift').to_s).sort.map { |file| Pathname(file).relative_path_from(relative_to).to_s }
end

def ensure_group(parent, name, path = nil)
  parent.children.find { |child| child.isa == 'PBXGroup' && child.display_name == name } ||
    parent.new_group(name, path)
end

def add_file_references(group, paths)
  paths.map do |path|
    group.new_file(path)
  end
end

def add_remote_package_dependency(project, repository_url:, revision:, product_name:, targets:)
  package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = repository_url
  package.requirement = {
    'kind' => 'revision',
    'revision' => revision,
  }
  project.root_object.package_references << package

  targets.each do |target|
    product_dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    product_dependency.package = package
    product_dependency.product_name = product_name
    target.package_product_dependencies << product_dependency

    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = product_dependency
    target.frameworks_build_phase.files << build_file
  end
end

previous_uuids = if PROJECT_PATH.exist?
                   stable_uuid_map(Xcodeproj::Project.open(PROJECT_PATH))
                 else
                   {}
                 end
package_resolved_contents = PACKAGE_RESOLVED_PATH.read if PACKAGE_RESOLVED_PATH.exist?
FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH.to_s)
project.root_object.attributes['LastSwiftUpdateCheck'] = '2600'
project.root_object.attributes['LastUpgradeCheck'] = '2600'
project.root_object.compatibility_version = 'Xcode 12.0'
project.root_object.development_region = 'en'
project.root_object.known_regions = ['en', 'zh-Hans']

project.build_configurations.each do |config|
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  config.build_settings['MARKETING_VERSION'] = '0.18.0'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '15'
  config.build_settings['SWIFT_VERSION'] = '6.0'
  config.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
  config.build_settings['CODE_SIGN_IDENTITY'] = ''
end

sources_group = ensure_group(project.main_group, 'Sources', 'Sources')
vendor_group = ensure_group(project.main_group, 'Vendor', 'Vendor')
resources_group = ensure_group(project.main_group, 'Resources', 'Resources')
scripts_group = ensure_group(project.main_group, 'scripts', 'scripts')
scripts_group.new_file('scripts/package_macos.sh')

native_group = ensure_group(sources_group, 'RemoraSSHNative', 'RemoraSSHNative')
native_ssh_vendor_group = ensure_group(vendor_group, 'NativeSSH', 'NativeSSH')
mbedcrypto_group = ensure_group(native_ssh_vendor_group, 'mbedtls', 'mbedtls')
libssh2_group = ensure_group(native_ssh_vendor_group, 'libssh2', 'libssh2')
core_group = ensure_group(sources_group, 'RemoraCore', 'RemoraCore')
terminal_group = ensure_group(sources_group, 'RemoraTerminal', 'RemoraTerminal')
app_group = ensure_group(sources_group, 'RemoraApp', 'RemoraApp')
app_resources_group = ensure_group(app_group, 'Resources', 'Resources')

mbedcrypto_target = project.new_target(:static_library, 'RemoraMbedCrypto', :osx, DEPLOYMENT_TARGET)
libssh2_target = project.new_target(:static_library, 'RemoraLibSSH2', :osx, DEPLOYMENT_TARGET)
native_target = project.new_target(:static_library, 'RemoraSSHNative', :osx, DEPLOYMENT_TARGET)
core_target = project.new_target(:static_library, 'RemoraCore', :osx, DEPLOYMENT_TARGET)
terminal_target = project.new_target(:static_library, 'RemoraTerminal', :osx, DEPLOYMENT_TARGET)
app_target = project.new_target(:application, 'Remora', :osx, DEPLOYMENT_TARGET)

[mbedcrypto_target, libssh2_target, native_target, core_target, terminal_target, app_target].each do |target|
  target.build_configurations.each do |config|
    config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
    config.build_settings['SWIFT_VERSION'] = '6.0'
    config.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
    config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
    config.build_settings['CODE_SIGN_IDENTITY'] = ''
  end
end

[mbedcrypto_target, libssh2_target, native_target, core_target, terminal_target].each do |target|
  target.build_configurations.each do |config|
    config.build_settings['DEFINES_MODULE'] = 'YES'
    config.build_settings['SKIP_INSTALL'] = 'YES'
    config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  end
end

mbedcrypto_target.build_configurations.each do |config|
  config.build_settings['GCC_C_LANGUAGE_STANDARD'] = 'gnu17'
  config.build_settings['HEADER_SEARCH_PATHS'] = [
    '$(SRCROOT)/Vendor/NativeSSH/mbedtls/include',
    '$(SRCROOT)/Vendor/NativeSSH/mbedtls/library',
    '$(SRCROOT)/Vendor/NativeSSH/mbedtls/3rdparty/everest/include',
    '$(SRCROOT)/Vendor/NativeSSH/mbedtls/3rdparty/everest/include/everest',
    '$(SRCROOT)/Vendor/NativeSSH/mbedtls/3rdparty/everest/include/everest/kremlib',
  ]
end

libssh2_target.build_configurations.each do |config|
  config.build_settings['GCC_C_LANGUAGE_STANDARD'] = 'gnu17'
  config.build_settings['HEADER_SEARCH_PATHS'] = [
    '$(SRCROOT)/Vendor/NativeSSH/libssh2/include',
    '$(SRCROOT)/Vendor/NativeSSH/libssh2/src',
    '$(SRCROOT)/Vendor/NativeSSH/mbedtls/include',
  ]
  config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = [
    '$(inherited)',
    'HAVE_CONFIG_H',
    'LIBSSH2_MBEDTLS',
  ]
end

native_target.build_configurations.each do |config|
  config.build_settings['GCC_C_LANGUAGE_STANDARD'] = 'gnu17'
  config.build_settings['HEADER_SEARCH_PATHS'] = [
    '$(SRCROOT)/Sources/RemoraSSHNative/include',
    '$(SRCROOT)/Vendor/NativeSSH/libssh2/include',
  ]
  config.build_settings['MODULEMAP_FILE'] = '$(SRCROOT)/Sources/RemoraSSHNative/include/module.modulemap'
  config.build_settings['PRODUCT_MODULE_NAME'] = 'RemoraSSHNative'
end

[core_target, terminal_target, app_target].each do |swift_target|
  swift_target.build_configurations.each do |config|
    config.build_settings['SWIFT_INCLUDE_PATHS'] = '$(SRCROOT)/Sources/RemoraSSHNative/include'
  end
end

app_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = 'Remora'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'io.github.wuujiawei.remora'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'Remora'
  config.build_settings['INFOPLIST_KEY_CFBundleName'] = 'Remora'
  config.build_settings['INFOPLIST_KEY_CFBundleExecutable'] = '$(EXECUTABLE_NAME)'
  config.build_settings['INFOPLIST_KEY_LSApplicationCategoryType'] = 'public.app-category.developer-tools'
  config.build_settings['INFOPLIST_KEY_NSHighResolutionCapable'] = 'YES'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/../Frameworks'
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  config.build_settings['ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS'] = 'NO'
end

libssh2_target.add_dependency(mbedcrypto_target)
native_target.add_dependency(libssh2_target)
core_target.add_dependency(native_target)
terminal_target.add_dependency(core_target)
app_target.add_dependency(core_target)
app_target.add_dependency(terminal_target)

libssh2_target.frameworks_build_phase.add_file_reference(mbedcrypto_target.product_reference, true)
native_target.frameworks_build_phase.add_file_reference(libssh2_target.product_reference, true)
core_target.frameworks_build_phase.add_file_reference(native_target.product_reference, true)
terminal_target.frameworks_build_phase.add_file_reference(core_target.product_reference, true)
app_target.frameworks_build_phase.add_file_reference(core_target.product_reference, true)
app_target.frameworks_build_phase.add_file_reference(terminal_target.product_reference, true)

add_remote_package_dependency(
  project,
  repository_url: SWIFTTERM_URL,
  revision: SWIFTTERM_REVISION,
  product_name: 'SwiftTerm',
  targets: [terminal_target, app_target]
)

core_target.add_system_framework('Security')
terminal_target.add_system_frameworks(['AppKit', 'CoreText', 'QuartzCore'])
app_target.add_system_frameworks(['SwiftUI', 'AppKit'])

native_source_ref = native_group.new_file('remora_ssh.c')
native_target.source_build_phase.add_file_reference(native_source_ref, true)

add_file_references(
  mbedcrypto_group,
  NATIVE_SOURCE_MANIFEST.fetch('mbedcrypto')
).each do |file_ref|
  mbedcrypto_target.source_build_phase.add_file_reference(file_ref, true)
end

add_file_references(
  libssh2_group,
  NATIVE_SOURCE_MANIFEST.fetch('libssh2')
).each do |file_ref|
  libssh2_target.source_build_phase.add_file_reference(file_ref, true)
end

native_include_group = ensure_group(native_group, 'include', 'include')
native_header_ref = native_include_group.new_file('remora_ssh.h')
native_header_build_file = native_target.headers_build_phase.add_file_reference(native_header_ref)
native_header_build_file.settings = { 'ATTRIBUTES' => ['Public'] }
native_include_group.new_file('module.modulemap')

add_file_references(
  core_group,
  sorted_swift_files(ROOT.join('Sources/RemoraCore'), relative_to: ROOT.join('Sources/RemoraCore'))
).each do |file_ref|
  core_target.source_build_phase.add_file_reference(file_ref, true)
end

add_file_references(
  terminal_group,
  sorted_swift_files(ROOT.join('Sources/RemoraTerminal'), relative_to: ROOT.join('Sources/RemoraTerminal'))
).each do |file_ref|
  terminal_target.source_build_phase.add_file_reference(file_ref, true)
end

app_source_files = sorted_swift_files(
  ROOT.join('Sources/RemoraApp'),
  relative_to: ROOT.join('Sources/RemoraApp')
).reject { |path| path.include?('/Resources/') }
add_file_references(app_group, app_source_files).each do |file_ref|
  app_target.source_build_phase.add_file_reference(file_ref, true)
end

localizable_group = app_resources_group.new_variant_group('Localizable.strings')
localizable_group.new_file('en.lproj/Localizable.strings')
localizable_group.new_file('zh-Hans.lproj/Localizable.strings')
app_target.resources_build_phase.add_file_reference(localizable_group, true)

update_checker_group = app_resources_group.new_variant_group('UpdateChecker.strings')
update_checker_group.new_file('en.lproj/UpdateChecker.strings')
update_checker_group.new_file('zh-Hans.lproj/UpdateChecker.strings')
app_target.resources_build_phase.add_file_reference(update_checker_group, true)

asset_catalog_ref = resources_group.new_file('Assets.xcassets')
app_target.resources_build_phase.add_file_reference(asset_catalog_ref, true)

web_editor_ref = app_resources_group.new_file('WebEditor')
app_target.resources_build_phase.add_file_reference(web_editor_ref, true)

apply_stable_uuids(project, previous_uuids)

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app_target, nil, launch_target: true)
scheme.save_as(PROJECT_PATH, 'Remora', true)

project.save

if package_resolved_contents
  FileUtils.mkdir_p(PACKAGE_RESOLVED_PATH.dirname)
  PACKAGE_RESOLVED_PATH.write(package_resolved_contents)
end
