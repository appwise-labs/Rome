# cocoapods-rome

Rome makes it easy to build a list of frameworks for consumption outside of
Xcode, e.g. for a Swift script.

## Installation

```bash
$ gem install cocoapods-rome
```

## Important

In the examples below the target 'caesar' could either be an existing target of a project managed by cocapods for which you'd like to run a swift script **or** it could be fictitious, for example if you wish to run this on a standalone Podfile and get the frameworks you need for adding to your xcode project manually.

## Usage 

Write a simple Podfile, like this:

### MacOS

```ruby
platform :osx, '10.10'

plugin 'cocoapods-rome'

target 'caesar' do
  pod 'Alamofire'
end
```

### iOS 

```ruby
platform :ios, '8.0'

plugin 'cocoapods-rome',
  :pre_compile => Proc.new { |installer|
    installer.pods_project.targets.each do |target|
      target.build_configurations.each do |config|
        config.build_settings['SWIFT_VERSION'] = '4.0'
      end
    end

    installer.pods_project.save
  },
  :dsym => false,
  :configuration => 'Release'

target 'caesar' do
  pod 'Alamofire'
end
```

then run this:

```bash
pod install
```

and you will end up with dynamic frameworks:

```
$ tree Rome/
Rome/
└── Alamofire.framework
```

## Advanced Usage

### dSYMs

For your production builds, when you want dSYMs created and stored:

```ruby
platform :osx, '10.10'

plugin 'cocoapods-rome',
  :dsym => true,
  :configuration => 'Release'

target 'caesar' do
  pod 'Alamofire'
end
```

Resulting in:

```
$ tree dSYM/
dSYM/
├── iphoneos
│   └── Alamofire.framework.dSYM
│       └── Contents
│           ├── Info.plist
│           └── Resources
│               └── DWARF
│                   └── Alamofire
└── iphonesimulator
    └── Alamofire.framework.dSYM
        └── Contents
            ├── Info.plist
            └── Resources
                └── DWARF
                    └── Alamofire
```

### Fix Interface Builder integration

If you use interface builder, you may want to set the `fix_interface_builder` flag. This will ensure swift files are marked as public headers, so that interface builder correctly shows `@IBInspectable`s & `@IBDesignable`s.

```ruby
platform :osx, '10.10'

plugin 'cocoapods-rome',
  :fix_interface_builder => true

target 'caesar' do
  pod 'Alamofire'
end
```

### Bitcode generation

You can set the `force_bitcode` option to `true` to ensure all dependencies are compiled with bitcode enabled.

```ruby
platform :osx, '10.10'

plugin 'cocoapods-rome',
  :force_bitcode => true

target 'caesar' do
  pod 'Alamofire'
end
```

## Hooks

The plugin allows you to provides hooks that will be called during the installation process.

### `pre_compile`

This hook allows you to make any last changes to the generated Xcode project before the compilation of frameworks begins.

It receives the `Pod::Installer` as its only argument.

### `post_compile`

This hook allows you to run code after the compilation of the frameworks finished and they have been moved to the `Rome` folder.

It receives the `Pod::Installer` as its only argument.

#### Example

Customising the Swift version of all pods

```ruby
platform :osx, '10.10'

plugin 'cocoapods-rome', 
    :pre_compile => Proc.new { |installer|
        installer.pods_project.targets.each do |target|
            target.build_configurations.each do |config|
                config.build_settings['SWIFT_VERSION'] = '4.0'
            end
        end

        installer.pods_project.save
    },
    :post_compile => Proc.new { |installer|
        puts "Rome finished building all the frameworks"
    }

target 'caesar' do
    pod 'Alamofire'
end
```
