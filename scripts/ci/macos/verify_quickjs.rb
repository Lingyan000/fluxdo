# frozen_string_literal: true

require 'open3'
require 'rubygems/version'

# 对真实库做回归检查，不改二进制版本标记，也不修改插件缓存。
def run!(*args)
  output, status = Open3.capture2e(*args)
  raise "命令失败：#{args.join(' ')}\n#{output}" unless status.success?
  output
end

library = File.realpath(ARGV.fetch(0))
required_arches = ARGV.drop(1)
required_arches = %w[arm64 x86_64] if required_arches.empty?
arches = run!('xcrun', 'lipo', '-archs', library).split
required_arches.each do |arch|
  raise "缺少 #{arch}：#{arches}" unless arches.include?(arch)
  metadata = run!('xcrun', 'vtool', '-arch', arch, '-show-build', library)
  # Intel 旧部署目标使用 LC_VERSION_MIN_MACOSX，不能只查 minos。
  minimum = metadata[/\bminos\s+([\d.]+)/, 1]
  minimum ||= metadata[/LC_VERSION_MIN_MACOSX.*?\bversion\s+([\d.]+)/m, 1]
  raise "无法识别 #{arch} 最低系统：#{metadata}" unless minimum
  raise "#{arch} 要求 macOS #{minimum}" if Gem::Version.new(minimum) > Gem::Version.new('12.0')
  symbols = run!('xcrun', 'nm', '-arch', arch, '-gU', library)
  %w[JSEvalWrapper JS_NewRuntimeDartBridge JS_NewContextDartBridge].each do |symbol|
    raise "#{arch} 缺少 #{symbol}" unless symbols.match?(/\b_#{symbol}\s*$/)
  end
  puts "#{arch}：最低 macOS #{minimum}，桥接符号齐全"
end
