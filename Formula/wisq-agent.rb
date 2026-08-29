# Homebrew formula, served straight from this repository as a tap:
#
#   brew tap maxlestage/wisq https://github.com/maxlestage/wisq.git
#   brew install --head maxlestage/wisq/wisq-agent    # from master, today
#   brew install maxlestage/wisq/wisq-agent           # from the latest tag
#   brew services start wisq-agent                    # launchd/systemd service
#
# The stable URL is a git tag rather than a tarball so no sha256 needs
# updating per release — the tag below is the only thing to bump when cutting
# one, and `site/tests/version-agreement.test.ts` fails until it is. That test
# exists because this line had already drifted out of the procedure: the
# `release: 0.2.0` commit bumped it, a later commit wrote `v0.3.0` before that
# version existed, and the `release: 0.3.0` commit then touched every other
# file and not this one. It says the right thing today by coincidence.
class WisqAgent < Formula
  desc "Host daemon that lets wisq on iPhone power VMs on and connect to them"
  homepage "https://github.com/maxlestage/wisq"
  url "https://github.com/maxlestage/wisq.git", tag: "v0.3.0"
  # No licence line: none has been chosen for this project yet, and Homebrew
  # treats this field as a statement of what the user may do with the code.
  # Declaring one here would grant rights nobody decided to grant.
  head "https://github.com/maxlestage/wisq.git", branch: "master"

  # The daemon is Rust with no dependencies, so this is the whole build.
  depends_on "rust" => :build

  def install
    system "cargo", "install", *std_cargo_args(path: "crates/wisq-agent")
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
