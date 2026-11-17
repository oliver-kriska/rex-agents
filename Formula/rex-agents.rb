class RexAgents < Formula
  desc "Restore coding agents and project layouts after a Rex restart"
  homepage "https://github.com/oliver-kriska/rex-agents"
  url "https://github.com/oliver-kriska/rex-agents/archive/refs/tags/v0.1.0.tar.gz"
  # RELEASE BLOCKER: replace with the downloaded v0.1.0 tarball's SHA-256 before stable installation.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/oliver-kriska/rex-agents.git", branch: "main"

  depends_on "fzf"
  depends_on :macos

  def install
    libexec.install "bin", "rex-agents", "examples", "setup.sh", "install.sh"
    (bin/"rex-agents").write_env_script libexec/"bin/rex-agents",
                                      REX_AGENTS_STABLE_ROOT: opt_libexec
  end

  def caveats
    <<~EOS
      Install Rex separately, then run from a Rex pane:
        rex-agents setup --dry-run
        rex-agents setup
      Reload Rex config to activate Command-Shift-B. Hub integration is off by default.
      Before uninstalling the formula, run: rex-agents setup --uninstall
      Setup links use the stable opt path and survive brew upgrade.
    EOS
  end

  test do
    assert_match "Usage: rex-agents setup", shell_output("#{bin}/rex-agents setup --help")
  end
end
