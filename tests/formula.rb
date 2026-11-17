# Run with `brew ruby tests/formula.rb`: use Homebrew's real install DSL, but only in a temp tree.
# No tap, fetch, dependency installation, or mutation of the Homebrew prefix.
require "tmpdir"
require "fileutils"
require "open3"

module NoTapInstallation
  def install(*)
    raise "This test must not install taps"
  end
end
Tap.prepend(NoTapInstallation)

root = Pathname.new(__dir__).parent
load root/"Formula/rex-agents.rb"
# Bypass Formula's metadata resolver (which auto-taps core). The install method needs only
# destination paths, supplied below; all filesystem DSL operations are Homebrew's own.
formula = RexAgents.allocate
Dir.mktmpdir("rex-agents-formula") do |dir|
  tmp = Pathname.new(dir)
  stage = tmp/"source"
  stage.mkpath
  %w[bin rex-agents examples setup.sh install.sh].each { |name| FileUtils.cp_r(root/name, stage/name) }
  formula.define_singleton_method(:libexec) { tmp/"Cellar/1/libexec" }
  formula.define_singleton_method(:bin) { tmp/"Cellar/1/bin" }
  formula.define_singleton_method(:opt_libexec) { tmp/"opt/rex-agents/libexec" }
  formula.opt_libexec.parent.parent.mkpath
  FileUtils.ln_s(tmp/"Cellar/1", formula.opt_libexec.parent)
  Dir.chdir(stage) { formula.install }
  raise "Lua module missing" unless (formula.libexec/"rex-agents/core.lua").file?
  wrapper = (formula.bin/"rex-agents").read
  raise "No stable root in wrapper" unless wrapper.include?(formula.opt_libexec.to_s)
  output, status = Open3.capture2e((formula.bin/"rex-agents").to_s, "setup", "--help")
  raise output unless status.success? && output.include?("Usage: rex-agents setup")
  puts "ok - actual formula install DSL, libexec layout, stable opt wrapper, setup entrypoint"
end
