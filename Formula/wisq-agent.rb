# Homebrew formula, served straight from this repository as a tap:
#
#   brew tap maxlestage/wisq https://github.com/maxlestage/wisq.git
#   brew install --head maxlestage/wisq/wisq-agent    # from master, today
#   brew install maxlestage/wisq/wisq-agent           # from the v0.1.0 tag, once pushed
#   brew services start wisq-agent                    # launchd/systemd service
#
# The stable URL is a git tag rather than a tarball so no sha256 needs
# updating per release — bump the tag here when cutting one.
class WisqAgent < Formula
  desc "Host daemon that lets wisq on iPhone power VMs on and connect to them"
  homepage "https://github.com/maxlestage/wisq"
  url "https://github.com/maxlestage/wisq.git", tag: "v0.1.0"
  license "Apache-2.0"
  head "https://github.com/maxlestage/wisq.git", branch: "master"

  depends_on xcode: ["15.0", :build] if OS.mac?
  on_linux do
    depends_on "swift" => :build
  end

  def install
    # --disable-sandbox: SwiftPM's own sandbox cannot nest inside Homebrew's.
    system "swift", "build", "-c", "release", "--product", "wisq-agent",
           "--disable-sandbox"
    bin.install ".build/release/wisq-agent"
  end

  service do
    run [opt_bin/"wisq-agent"]
    keep_alive true
    log_path var/"log/wisq-agent.log"
    error_log_path var/"log/wisq-agent.log"
  end

  test do
    assert_match "wisq-agent", shell_output("#{bin}/wisq-agent --help")
  end
end
