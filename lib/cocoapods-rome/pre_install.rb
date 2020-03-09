Pod::HooksManager.register('cocoapods-rome', :pre_install) do |installer_context|
  # ensure we compile dynamically & don't integrate
  podfile = installer_context.podfile
  podfile.use_frameworks!
  podfile.install!(
    'cocoapods',
    podfile.installation_method.last.merge(:integrate_targets => false)
  )
end
