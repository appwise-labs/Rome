require 'fourflusher'
require 'yaml'

PLATFORMS = { 'iphonesimulator' => 'iOS',
              'appletvsimulator' => 'tvOS',
              'watchsimulator' => 'watchOS' }

def build_for_iosish_platform(sandbox, build_dir, destination_dir, target, device, simulator, configuration, static=true)
  deployment_target = target.platform_deployment_target
  target_label = target.cocoapods_target_label

  spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq
  spec_names.each do |root_name, module_name|
    framework_name = "#{module_name}.framework"

    # skip if possible
    next if skip_build?(build_dir, destination_dir, sandbox.project_path, root_name, module_name)

    # build multiple archs
    frameworks_path = []
    frameworks_path << xcodebuild(sandbox, build_dir, root_name, module_name, device, deployment_target, configuration)
    frameworks_path << xcodebuild(sandbox, build_dir, root_name, module_name, simulator, deployment_target, configuration)

    # lipo them together
    lipo(build_dir, frameworks_path)
  end
end

def xcodebuild(sandbox, build_dir, target, module_name, sdk='macosx', deployment_target=nil, configuration)
  args = %W(-project #{sandbox.project_path.realdirpath} -scheme #{target} -configuration #{configuration} -sdk #{sdk})
  platform = PLATFORMS[sdk]
  args += Fourflusher::SimControl.new.destination(:oldest, platform, deployment_target) unless platform.nil?

  Pod::UI.puts "Building '#{target}' for #{sdk}..."
  Pod::Executable.execute_command 'xcodebuild', args, true

  return "#{build_dir}/#{configuration}-#{sdk}/#{target}/#{module_name}.framework"
end

def lipo(build_dir, frameworks_path)
  module_name = File.basename(frameworks_path.first, '.framework')
  libs = frameworks_path
    .map { |f| "#{f}/#{module_name}" }
    .select { |f| File.file?(f) }

  return unless libs.count >= 2

  fatlib = "#{build_dir}/#{module_name}"
  args = %W(-create -output #{fatlib}) + libs
  Pod::Executable.execute_command 'lipo', args, true

  result_path = "#{build_dir}/#{File.basename(frameworks_path.first)}"
  FileUtils.mv frameworks_path.first, result_path, :force => true
  FileUtils.mv fatlib, "#{result_path}/#{module_name}", :force => true
end

def skip_build?(build_dir, destination_dir, project_path, target, module_name)
  framework_name = "#{module_name}.framework"

  File.directory?("#{build_dir}/#{framework_name}") ||
    File.directory?("#{destination_dir}/#{framework_name}") ||
    !native_target?(project_path, target)
end

def native_target?(project_path, target_name)
  project = Xcodeproj::Project.open(project_path)
  target = project.targets.find { |t| t.name == target_name }
  return target.is_a?(Xcodeproj::Project::Object::PBXNativeTarget)
end

def enable_debug_information(project_path, configuration)
  project = Xcodeproj::Project.open(project_path)
  project.targets.each do |target|
    config = target.build_configurations.find { |config| config.name.eql? configuration }
    config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
    config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'
  end
  project.save
end

def static?(project_path, configuration)
  project = Xcodeproj::Project.open(project_path)
  target = project.targets.find { |t| t.name =~ /^Pods/ }
  return target.product_type == "com.apple.product-type.library.static"
end

def copy_dsym_files(dsym_destination, configuration)
  platforms = ['iphoneos', 'iphonesimulator']
  platforms.each do |platform|
    dsym = Pathname.glob("build/#{configuration}-#{platform}/**/*.dSYM")
    dsym.each do |dsym|
      destination = dsym_destination + platform
      FileUtils.mkdir_p destination
      FileUtils.cp_r dsym, destination, :remove_destination => true
    end
  end
end

# To fix integration of interface builder with pre-compiled pods,
# we need to add all swift files to the public headers
def set_swift_files_as_public(installer)
  Pod::UI.puts "Fixing interface builder integration"

  installer.pods_project.targets.each do |target|
    next unless target.respond_to?(:product_type)
    next unless target.product_type == 'com.apple.product-type.framework'

    target.source_build_phase.files_references.each do |file|
      next unless File.extname(file.path) == '.swift'

      buildFile = target.headers_build_phase.add_file_reference(file)
      buildFile.settings = { 'ATTRIBUTES' => ['Public']}
    end
  end

  installer.pods_project.save
end

# Force enable bitcode for projects
def set_bitcode_generation(installer)
  Pod::UI.puts "Enforcing bitcode generation"

  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['BITCODE_GENERATION_MODE'] = 'bitcode'
    end
  end

  installer.pods_project.save
end

# Cleanup but keep `all-product-headers.yaml` files (otherwise lldb/debug is broken)
def cleanup(build_dir)
  build_dir = Pathname(build_dir)
  tmp_build_dir = Pathname('.temp-build')

  # copy over files we need to keep
  if File.directory?(build_dir)
    build_dir.glob("**/all-product-headers.yaml").each do |file|
      intermediate = Pathname(file).relative_path_from(build_dir).dirname
      destination_dir = tmp_build_dir + intermediate

      FileUtils.mkdir_p(destination_dir)
      FileUtils.mv(file, destination_dir)
    end

    build_dir.rmtree if build_dir.directory?
    FileUtils.mv(tmp_build_dir, build_dir)
  end
end

# Fixes Xcode 12 duplicate architectures (arm64 in simulator builds)
def exclude_simulator_archs(installer)
  Pod::UI.puts "Fixing Xcode 12 duplicate architectures"

  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['EXCLUDED_ARCHS[sdk=*simulator*]'] = 'arm64 arm64e armv7 armv7s armv6 armv8'
    end
  end

  installer.pods_project.save
end

def cache_podslockfile(parent)
  new_podfile_lock = File.join(parent, "Podfile.lock")
  cached_podfile_lock = File.join(parent, "Pods", "Rome-Podfile.lock")

  if File.file?(new_podfile_lock)
    Pod::UI.puts "Caching new Podfile.lock"
    FileUtils.copy_file(new_podfile_lock, cached_podfile_lock)
  else
    Pod::UI.puts "Deleting cached Podfile.lock"
    FileUtils.remove_file(cached_podfile_lock, true)
  end
end

def nuke_frameworks_if_needed(installer_context, parent)
  podfile_lock = File.join(parent, 'Podfile.lock')
  cached_podfile_lock = File.join(parent, 'Pods', 'Rome-Podfile.lock')
  rome_dir = File.join(parent, 'Rome')
  
  # if first run (no cache), make sure we nuke partials
  if !File.file?(cached_podfile_lock)
    Pod::UI.puts "No cached lockfile, nuking frameworks".yellow
    FileUtils.remove_dir(File.join(parent, 'build'), true)
    FileUtils.remove_dir(File.join(parent, 'dSYM'), true)
    FileUtils.remove_dir(rome_dir, true)
    return
  end

  # return early if identical
  return unless File.file?(podfile_lock) and File.file?(cached_podfile_lock)
  if FileUtils.identical?(podfile_lock, cached_podfile_lock)
    Pod::UI.puts 'Podfile.lock did not change, leaving frameworks as is'
    return
  end

  Pod::UI.puts 'Podfile.lock did change, deleting updated frameworks'.yellow
  contents_old = YAML.load_file(cached_podfile_lock)
  contents_new = YAML.load_file(podfile_lock)
  spec_modules = installer_context.umbrella_targets.map { |t|
    t.specs.map { |spec| [spec.root.name, spec.root.module_name] }
  }.flatten(1).uniq.to_h

  # collect changed specs (changed checksum, checkout or deleted pod)
  changed = contents_new.fetch('SPEC CHECKSUMS', {}).select { |k,v| v != contents_old.fetch('SPEC CHECKSUMS', {})[k] }.keys.to_set
  changed.merge(contents_new.fetch('CHECKOUT OPTIONS', {}).select { |k,v| v != contents_old.fetch('CHECKOUT OPTIONS', {})[k] }.keys)
  changed.merge((contents_old.fetch('SPEC CHECKSUMS', {}).keys - contents_new.fetch('SPEC CHECKSUMS', {}).keys).to_set)

  # collect affected frameworks (and filter out subspecs)
  affected = changed
  loop do
    items = contents_new.fetch('PODS', []).select { |s|
      s.is_a?(Hash) && s.values.flatten.any? { |ss| affected.include? ss.split.first }
    }.map { |s| s.keys.first.split.first }

    break if affected.superset? (affected + items)
    affected.merge(items)
  end
  affected = affected & contents_new.fetch('SPEC CHECKSUMS', {}).keys

  # delete affected frameworks
  Pod::UI.puts "Affected frameworks: #{affected.sort.join(', ')}"
  affected.each do |pod|
    name = spec_modules[pod] || pod.gsub(/^([0-9])/, '_\1').gsub(/[^a-zA-Z0-9_]/, '_')
    path = "#{rome_dir}/#{name}.framework"
    
    if File.directory?(path)
      FileUtils.remove_dir(path, true)
    else
      Pod::UI.puts "Error: could not delete #{path}, it does not exist!".red
    end
  end
end

Pod::HooksManager.register('cocoapods-rome', :post_install) do |installer_context, user_options|
  enable_dsym = user_options.fetch('dsym', true)
  configuration = user_options.fetch('configuration', 'Debug')
  fix_interface_builder = user_options.fetch('fix_interface_builder', false)
  force_bitcode = user_options.fetch('force_bitcode', false)

  exclude_simulator_archs(installer_context) if %x(xcodebuild -version).include? 'Xcode 12'
  set_swift_files_as_public(installer_context) if fix_interface_builder
  set_bitcode_generation(installer_context) if force_bitcode
  if user_options["pre_compile"]
    user_options["pre_compile"].call(installer_context)
  end

  sandbox_root = Pathname(installer_context.sandbox_root)
  sandbox = Pod::Sandbox.new(sandbox_root)

  is_static = static?(sandbox.project_path, configuration)
  enable_debug_information(sandbox.project_path, configuration) if enable_dsym

  build_dir = sandbox_root.parent + 'build'
  destination = sandbox_root.parent + 'Rome'

  nuke_frameworks_if_needed(installer_context, sandbox_root.parent)

  fw_type = is_static ? "static" : "dynamic"
  Pod::UI.puts "Building #{fw_type} frameworks"

  targets = installer_context.umbrella_targets.select { |t| t.specs.any? }
  targets.each do |target|
    case target.platform_name
    when :ios then build_for_iosish_platform(sandbox, build_dir, destination, target, 'iphoneos', 'iphonesimulator', configuration, is_static)
    when :osx then xcodebuild(sandbox, target.cocoapods_target_label, configuration)
    when :tvos then build_for_iosish_platform(sandbox, build_dir, destination, target, 'appletvos', 'appletvsimulator', configuration, is_static)
    when :watchos then build_for_iosish_platform(sandbox, build_dir, destination, target, 'watchos', 'watchsimulator', configuration, is_static)
    else raise "Unknown platform '#{target.platform_name}'" end
  end

  # Make sure the device target overwrites anything in the simulator build, otherwise iTunesConnect
  # can get upset about Info.plist containing references to the simulator SDK
  frameworks = Pathname.glob("build/*/*/*.framework").reject { |f| f.to_s =~ /Pods[^.]+\.framework/ }
  frameworks += Pathname.glob("build/*.framework").reject { |f| f.to_s =~ /Pods[^.]+\.framework/ }
  resources = []

  Pod::UI.puts "Built #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)}"

  installer_context.umbrella_targets.each do |umbrella|
    umbrella.specs.each do |spec|
      consumer = spec.consumer(umbrella.platform_name)
      file_accessor = Pod::Sandbox::FileAccessor.new(sandbox.pod_dir(spec.root.name), consumer)
      frameworks += file_accessor.vendored_libraries
      frameworks += file_accessor.vendored_frameworks
      resources += file_accessor.resources
    end
  end
  frameworks.uniq!
  resources.uniq!

  Pod::UI.puts "Copying #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)} " \
    "to `#{destination.relative_path_from Pathname.pwd}`"

  FileUtils.mkdir_p destination
  (frameworks + resources).each do |file|
    FileUtils.cp_r file, destination, :remove_destination => true
  end

  copy_dsym_files(sandbox_root.parent + 'dSYM', configuration) if enable_dsym

  cache_podslockfile(sandbox_root.parent)
  cleanup(build_dir)

  if user_options["post_compile"]
    user_options["post_compile"].call(installer_context)
  end
end
