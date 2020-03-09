Pod::HooksManager.register('cocoapods-rome', :pre_install) do |installer_context, user_options|
  swift_fallback_version = user_options.fetch('swift_fallback_version', nil)

  # ensure we compile dynamically & don't integrate
  podfile = installer_context.podfile
  podfile.use_frameworks!
  podfile.install!(
    'cocoapods',
    podfile.installation_method.last.merge(:integrate_targets => false)
  )

  # if swift_fallback_version
  #   add_swift_fallback_version(installer_context, swift_fallback_version)
  # end
end

# Fixes 'Unable to determine Swift version' for some pods that do not define a swift version
def add_swift_fallback_version(installer_context, version)
  installer_context.pod_targets.select(&:uses_swift?).each do |target|
    target.root_spec.swift_versions << swift_fallback_version if target.root_spec.swift_versions.empty?

    # fix crash in target_validator.rb:119 (undefined method `empty?' for nil:NilClass)
    target.instance_variable_set(:@swift_version, swift_fallback_version) unless target.swift_version
  end
end
