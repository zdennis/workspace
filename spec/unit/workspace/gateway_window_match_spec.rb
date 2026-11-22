require "spec_helper"

RSpec.describe Workspace::GatewayWindowMatch do
  let(:launches) { ["tmux -CC attach -t =foo:", "tmuxinator start foo --attach"] }
  let(:shells) { ["-zsh"] }
  let(:prompt) { "zach@host ~ % " }
  let(:menu) do
    <<~MENU
      ** tmux mode started **

      Command Menu
      ----------------------------
      esc    Detach cleanly.
        X    Force-quit tmux mode.
        L    Toggle logging.
        C    Run tmux command.
    MENU
  end
  let(:chain) { "tmux -CC attach -t =foo: || tmux has-session -t =foo: 2>/dev/null || tmuxinator start foo --attach" }

  def screen(head, tail = "Detached\n\n#{prompt}\n")
    "#{head}\n#{menu}\n#{tail}"
  end

  def match(contents, launch_commands: launches, tty_commands: shells)
    described_class.match?(contents: contents, launch_commands: launch_commands, tty_commands: tty_commands)
  end

  it "matches the chained launch line" do
    expect(match(screen("#{prompt}#{chain}"))).to be true
  end

  it "matches a plain tmuxinator launch line" do
    expect(match(screen("#{prompt}tmuxinator start foo --attach"), launch_commands: ["tmuxinator start foo --attach"])).to be true
  end

  it "matches a launch command wrapped across lines" do
    expect(match(screen("#{prompt}tmux -CC attach -t =\nfoo: || true"))).to be true
  end

  it "matches a launch command at the end of its line" do
    expect(match(screen("#{prompt}tmuxinator start foo --attach\n"), launch_commands: ["tmuxinator start foo --attach"])).to be true
  end

  it "does not match another session's name" do
    expect(match(screen("#{prompt}tmux -CC attach -t =bar:"))).to be false
  end

  it "does not match foo against foo-2" do
    expect(match(screen("#{prompt}tmux -CC attach -t =foo-2:\n#{prompt}tmuxinator start foo-2 --attach"))).to be false
    expect(match(screen("#{prompt}tmuxinator start foo-2 --attach"), launch_commands: ["tmuxinator start foo --attach"])).to be false
  end

  it "does not match a launch command that runs on into more text" do
    expect(match(screen("#{prompt}tmuxinator start foo --attach-x"), launch_commands: ["tmuxinator start foo --attach"])).to be false
    expect(match(screen("#{prompt}tmuxinator start foo --attach=1"), launch_commands: ["tmuxinator start foo --attach"])).to be false
  end

  it "does not match a launch command with no prompt before it" do
    expect(match(screen("tmuxinator start foo --attach"), launch_commands: ["tmuxinator start foo --attach"])).to be false
  end

  it "does not match text typed after the prompt" do
    expect(match(screen("#{prompt}#{chain}", "Detached\n\n#{prompt}ls\n"))).to be false
  end

  it "does not match a draft that itself ends in a prompt character" do
    ["echo hi >", "echo 100%", "ls $", "cat f #"].each do |draft|
      expect(match(screen("#{prompt}#{chain}", "Detached\n\n#{prompt}#{draft}\n"))).to be(false), draft
    end
  end

  it "does not match a prompt that differs from the one the launch was typed at" do
    expect(match(screen("#{prompt}#{chain}", "Detached\n\nother@host /tmp % \n"))).to be false
  end

  it "does not match a command run after Detached" do
    expect(match(screen("#{prompt}#{chain}", "Detached\n\n#{prompt}ls\nfile\n#{prompt}\n"))).to be false
  end

  it "does not match without Detached" do
    expect(match(screen("#{prompt}#{chain}", "#{prompt}\n"))).to be false
  end

  it "does not match a menu still attached" do
    expect(match(screen("#{prompt}#{chain}", ""))).to be false
  end

  it "does not match the menu phrases without the Command Menu heading and key lines" do
    loose = "#{prompt}#{chain}\nDetach cleanly Force-quit tmux mode\nToggle logging\nRun tmux command\nDetached\n\n#{prompt}\n"
    expect(match(loose)).to be false
    no_heading = "#{prompt}#{chain}\n#{menu.sub("Command Menu\n", "")}\nDetached\n\n#{prompt}\n"
    expect(match(no_heading)).to be false
  end

  it "does not match when a non-shell runs on the tty" do
    expect(match(screen("#{prompt}#{chain}"), tty_commands: ["-zsh", "vim"])).to be false
    expect(match(screen("#{prompt}#{chain}"), tty_commands: ["tmux"])).to be false
  end

  it "does not match nil or empty tty commands" do
    expect(match(screen("#{prompt}#{chain}"), tty_commands: nil)).to be false
    expect(match(screen("#{prompt}#{chain}"), tty_commands: [])).to be false
  end

  it "accepts -zsh and /bin/zsh" do
    expect(match(screen("#{prompt}#{chain}"), tty_commands: ["/bin/zsh"])).to be true
    expect(match(screen("#{prompt}#{chain}"), tty_commands: ["-zsh", "login"])).to be true
  end

  it "does not match nil or empty contents" do
    expect(match(nil)).to be false
    expect(match("")).to be false
  end

  it "does not match empty launch commands" do
    expect(match(screen("#{prompt}#{chain}"), launch_commands: [])).to be false
    expect(match(screen("#{prompt}#{chain}"), launch_commands: nil)).to be false
  end

  it "uses the last menu on screen" do
    expect(match("#{screen("#{prompt}#{chain}", "Detached\n")}\n#{screen("#{prompt}#{chain}")}")).to be true
  end
end
