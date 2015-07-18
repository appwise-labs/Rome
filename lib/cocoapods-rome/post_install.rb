CONFIGURATION = "Release"
DEVICE = "iphoneos"
SIMULATOR = "iphonesimulator"

def xcodebuild(sandbox, target, sdk='macosx')
  Pod::Executable.execute_command 'xcodebuild', %W(-project #{sandbox.project_path.basename} -scheme #{target} -configuration #{CONFIGURATION} -sdk #{sdk}), true
end

Pod::HooksManager.register('cocoapods-rome', :post_install) do |installer_context|
  sandbox_root = Pathname(installer_context.sandbox_root)
  sandbox = Pod::Sandbox.new(sandbox_root)

  build_dir = sandbox_root.parent + 'build'
  destination = sandbox_root.parent + 'Rome'

  Pod::UI.puts 'Building frameworks'

  build_dir.rmtree if build_dir.directory?
  Dir.chdir(sandbox.project_path.dirname) do
    targets = installer_context.umbrella_targets.select { |t| t.specs.any? }
    targets.each do |target|
      target_label = target.cocoapods_target_label
      if target.platform_name == :ios
        xcodebuild(sandbox, target_label, DEVICE)
        xcodebuild(sandbox, target_label, SIMULATOR)

        spec_names = target.specs.map { |spec| spec.root.name }
        spec_names.uniq.each do |root_name|
          executable_path = "#{build_dir}/#{root_name}"
          device_lib = "#{build_dir}/#{CONFIGURATION}-#{DEVICE}/#{target_label}/#{root_name}.framework/#{root_name}"
          device_framework_lib = File.dirname(device_lib)
          simulator_lib = "#{build_dir}/#{CONFIGURATION}-#{SIMULATOR}/#{target_label}/#{root_name}.framework/#{root_name}"

          `lipo -create -output #{executable_path} #{device_lib} #{simulator_lib}`

          FileUtils.mv executable_path, device_lib
          FileUtils.mv device_framework_lib, build_dir
        end
      else
        xcodebuild(sandbox, target_label)
      end
    end
  end

  raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?

  frameworks = Pathname.glob("#{build_dir}/*.framework").reject { |f| f.to_s =~ /Pods*\.framework/ }

  Pod::UI.puts "Built #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)}"
  Pod::UI.puts "Copying frameworks to `#{destination.relative_path_from Pathname.pwd}`"

  destination.rmtree if destination.directory?

  installer_context.umbrella_targets.each do |umbrella|
    umbrella.specs.each do |spec|
      consumer = spec.consumer(umbrella.platform_name)
      file_accessor = Pod::Sandbox::FileAccessor.new(installer_context.sandbox_root, consumer)
      frameworks += file_accessor.vendored_libraries
      frameworks += file_accessor.vendored_frameworks
    end
  end

  frameworks.each do |framework|
    FileUtils.mkdir_p destination
    FileUtils.cp_r framework, destination, :remove_destination => true
  end
  build_dir.rmtree if build_dir.directory?
end
