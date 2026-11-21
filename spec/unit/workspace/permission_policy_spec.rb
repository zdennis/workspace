require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::PermissionPolicy do
  def rule(tool, action, pattern = nil)
    {tool: tool, pattern: pattern, action: action}.compact
  end

  def layer(rules, source: "project", default: nil)
    {source: source, rules: rules, default: default}
  end

  def decide(layers, tool, input = {}, cwd: "/work")
    described_class.new(layers: layers).decide(tool_name: tool, tool_input: input, cwd: cwd)
  end

  def bash(layers, command)
    decide(layers, "Bash", {"command" => command})
  end

  describe "actions and the default ladder" do
    it "returns each action with the rule that decided it" do
      layers = [layer([rule("Bash", "allow", "ls*"), rule("Bash", "ask", "git*"), rule("Bash", "deny", "rm*")])]
      expect(bash(layers, "ls -l")).to eq(action: "allow", rule: "project:rules[0]")
      expect(bash(layers, "git push")).to eq(action: "ask", rule: "project:rules[1]")
      expect(bash(layers, "rm x")).to eq(action: "deny", rule: "project:rules[2]")
    end

    it "asks with no rule and no default" do
      expect(bash([layer([])], "ls")[:action]).to eq("ask")
    end

    it "uses the most restrictive default among the layers that set one" do
      layers = [layer([], source: "global", default: "allow"), layer([], source: "project"),
        layer([], source: "worktree", default: "deny")]
      expect(bash(layers, "ls")).to eq(action: "deny", rule: "worktree:default")
      expect(bash(layers.first(2), "ls")).to eq(action: "allow", rule: "global:default")
    end

    it "names run rules as permissions" do
      expect(bash([layer([rule("Bash", "deny")], source: "run")], "ls")[:rule]).to eq("run:permissions[0]")
    end
  end

  describe "precedence" do
    it "lets deny beat ask beat allow across layers and within one" do
      allow_all = layer([rule("Bash", "allow")], source: "global")
      ask = layer([rule("Bash", "ask")], source: "project")
      deny = layer([rule("Bash", "deny")], source: "worktree")
      expect(bash([allow_all, ask], "ls")).to eq(action: "ask", rule: "project:rules[0]")
      expect(bash([allow_all, ask, deny], "ls")).to eq(action: "deny", rule: "worktree:rules[0]")
      expect(bash([layer([rule("Bash", "allow"), rule("Bash", "deny")])], "ls")[:action]).to eq("deny")
    end

    it "names the first match of the winning action in layer then list order" do
      layers = [layer([rule("Bash", "deny", "x*"), rule("Bash", "deny", "r*")], source: "global"),
        layer([rule("Bash", "deny", "rm*")])]
      expect(bash(layers, "rm x")).to eq(action: "deny", rule: "global:rules[1]")
    end
  end

  describe "tool globs" do
    it "matches mcp__* against every MCP tool and a plain name exactly" do
      layers = [layer([rule("mcp__*", "deny")])]
      expect(decide(layers, "mcp__github__create")[:action]).to eq("deny")
      expect(decide(layers, "Bash")[:action]).to eq("ask")
      expect(decide([layer([rule("Bash", "allow")])], "Bashful")[:action]).to eq("ask")
    end

    it "never matches a pattern on a tool with no subject" do
      layers = [layer([rule("apply_patch", "deny", "*"), rule("mcp__*", "deny", "*")])]
      expect(decide(layers, "apply_patch", {"command" => "x"})[:action]).to eq("ask")
      expect(decide(layers, "mcp__a__b", {})[:action]).to eq("ask")
    end
  end

  describe "Bash pieces" do
    let(:allow_git_status) { [layer([rule("Bash", "allow", "git status*")])] }

    it "does not allow a chained command with an unmatched piece" do
      expect(bash(allow_git_status, "git status && rm -rf ~")[:action]).to eq("ask")
      expect(bash(allow_git_status, "git status && git status -s")[:action]).to eq("allow")
    end

    it "denies when any piece matches a deny rule, including wrapped ones" do
      layers = [layer([rule("Bash", "deny", "git push*")])]
      expect(bash(layers, "cd x && git push")[:action]).to eq("deny")
      expect(bash(layers, "sudo git -C x push")[:action]).to eq("deny")
    end

    it "does not allow by pattern a command with a substitution" do
      layers = [layer([rule("Bash", "allow", "echo*")], default: "allow")]
      expect(bash(layers, "echo $(curl x)")[:action]).to eq("ask")
      expect(bash(layers, "echo ${HOME}")[:action]).to eq("ask")
    end

    it "denies a substitution when a deny rule matches or the default is deny" do
      expect(bash([layer([rule("Bash", "deny", "curl*")])], "echo $(curl x)")[:action]).to eq("deny")
      expect(bash([layer([], default: "deny")], "echo $(ls)")[:action]).to eq("deny")
    end

    it "does not allow a redirect to a file, even with default allow" do
      layers = [layer([rule("Bash", "allow", "git status*"), rule("Bash", "allow", "git diff*")], default: "allow")]
      expect(bash(layers, "git status > ~/.zshrc")[:action]).to eq("ask")
      expect(bash(layers, "git diff >> ~/.ssh/authorized_keys")[:action]).to eq("ask")
    end

    it "allows fd duplication and a redirect to /dev/null" do
      expect(bash(allow_git_status, "git status 2>&1")[:action]).to eq("allow")
      expect(bash(allow_git_status, "git status >/dev/null")[:action]).to eq("allow")
    end

    it "still allows an unpatterned Bash allow for a substitution or redirect" do
      layers = [layer([rule("Bash", "allow")])]
      expect(bash(layers, "echo $(ls) > x")[:action]).to eq("allow")
    end

    it "matches no pattern, without raising, when the command is not a String" do
      layers = [layer([rule("Bash", "allow", "git*"), rule("Bash", "deny", "*")])]
      expect(decide(layers, "Bash", {"command" => %w[git status]})[:action]).to eq("ask")
      expect(decide(layers, "Bash", {})[:action]).to eq("ask")
      expect(decide(layers, "Bash", nil)[:action]).to eq("ask")
      expect(decide([layer([rule("Bash", "deny")])], "Bash", {"command" => %w[ls]})[:action]).to eq("deny")
    end

    it "lets * cross / and leading dots" do
      expect(bash([layer([rule("Bash", "allow", "cat *")])], "cat /a/.b/c")[:action]).to eq("allow")
    end
  end

  describe "path tools" do
    it "keeps * inside one directory and lets **/ span directories" do
      layers = [layer([rule("Write", "allow", "/work/src/*.rb")])]
      expect(decide(layers, "Write", {"file_path" => "/work/src/a.rb"})[:action]).to eq("allow")
      expect(decide(layers, "Write", {"file_path" => "/work/src/sub/a.rb"})[:action]).to eq("ask")
      deep = [layer([rule("Write", "allow", "/work/**/*.rb")])]
      expect(decide(deep, "Write", {"file_path" => "/work/src/sub/a.rb"})[:action]).to eq("allow")
    end

    it "matches a dotfile" do
      layers = [layer([rule("Read", "deny", "/work/*")])]
      expect(decide(layers, "Read", {"file_path" => "/work/.env"})[:action]).to eq("deny")
    end

    it "expands a relative path against cwd and normalizes .." do
      layers = [layer([rule("Edit", "deny", "/work/secret/*")])]
      expect(decide(layers, "Edit", {"file_path" => "../secret/k"}, cwd: "/work/src")[:action]).to eq("deny")
      expect(decide(layers, "Edit", {"file_path" => "a/../../secret/k"}, cwd: "/work/src")[:action]).to eq("deny")
    end

    it "expands ~ in a pattern" do
      layers = [layer([rule("Write", "deny", "~/.ssh/*")])]
      expect(decide(layers, "Write", {"file_path" => File.expand_path("~/.ssh/config")})[:action]).to eq("deny")
    end

    it "reads notebook_path for NotebookEdit" do
      layers = [layer([rule("NotebookEdit", "deny", "/work/*.ipynb")])]
      expect(decide(layers, "NotebookEdit", {"notebook_path" => "/work/a.ipynb"})[:action]).to eq("deny")
    end

    it "does not match a pattern when the path is missing or not a String" do
      layers = [layer([rule("Write", "deny", "*"), rule("Write", "allow", "*")])]
      expect(decide(layers, "Write", {})[:action]).to eq("ask")
      expect(decide(layers, "Write", {"file_path" => ["/a"]})[:action]).to eq("ask")
      expect(decide([layer([rule("Write", "deny")])], "Write", {})[:action]).to eq("deny")
    end

    context "with symlinks" do
      around do |example|
        Dir.mktmpdir do |dir|
          @root = File.realpath(dir)
          FileUtils.mkdir_p(File.join(@root, "allowed"))
          FileUtils.mkdir_p(File.join(@root, "outside"))
          File.write(File.join(@root, "outside", "file"), "x")
          File.write(File.join(@root, "allowed", "plain"), "x")
          File.symlink(File.join(@root, "outside", "file"), File.join(@root, "allowed", "link"))
          File.symlink(File.join(@root, "outside"), File.join(@root, "allowed", "dirlink"))
          File.symlink(File.join(@root, "outside", "missing"), File.join(@root, "allowed", "dangling"))
          example.run
        end
      end

      let(:allow_tree) { [layer([rule("Write", "allow", "#{@root}/allowed/*")])] }

      it "allows a plain file in the allowed tree" do
        expect(decide(allow_tree, "Write", {"file_path" => "#{@root}/allowed/plain"})[:action]).to eq("allow")
        expect(decide(allow_tree, "Write", {"file_path" => "#{@root}/allowed/new"})[:action]).to eq("allow")
      end

      it "does not allow a link that points outside the tree" do
        expect(decide(allow_tree, "Write", {"file_path" => "#{@root}/allowed/link"})[:action]).to eq("ask")
        expect(decide(allow_tree, "Write", {"file_path" => "#{@root}/allowed/dirlink/new"})[:action]).to eq("ask")
        expect(decide(allow_tree, "Write", {"file_path" => "#{@root}/allowed/dangling"})[:action]).to eq("ask")
      end

      it "denies a link to a denied file" do
        layers = allow_tree + [layer([rule("Write", "deny", "#{@root}/outside/*")])]
        expect(decide(layers, "Write", {"file_path" => "#{@root}/allowed/link"})[:action]).to eq("deny")
        expect(decide(layers, "Write", {"file_path" => "#{@root}/allowed/dangling"})[:action]).to eq("deny")
      end

      it "asks when a symlink loop cannot be resolved" do
        File.symlink("#{@root}/allowed/loop2", "#{@root}/allowed/loop1")
        File.symlink("#{@root}/allowed/loop1", "#{@root}/allowed/loop2")
        expect(decide(allow_tree, "Write", {"file_path" => "#{@root}/allowed/loop1"})[:action]).to eq("ask")
      end
    end
  end

  describe "review findings" do
    it "does not allow a command that backgrounds after an escaped redirection character" do
      layers = [layer([rule("Bash", "allow", "git status*"), rule("Bash", "deny", "rm *")])]
      expect(bash(layers, "git status \\>&rm -rf ~")[:action]).to eq("deny")
      expect(bash(layers, "git status \\<&rm -rf ~")[:action]).to eq("deny")
    end

    it "does not treat # after an escaped blank as a comment" do
      layers = [layer([rule("Bash", "allow", "git status*"), rule("Bash", "deny", "rm *")], default: "allow")]
      expect(bash(layers, "git status \\ #;rm -rf ~")[:action]).to eq("deny")
      expect(bash(layers, "git status \\\t#;rm x")[:action]).to eq("deny")
      expect(bash(layers, "git status \\ # > ~/.zshrc")[:action]).to eq("ask")
    end

    it "handles line continuations around a #" do
      layers = [layer([rule("Bash", "allow", "git status*"), rule("Bash", "deny", "rm *")])]
      expect(bash(layers, "git status \\\n#\\\nrm -rf ~")[:action]).to eq("deny")
      expect(bash(layers, "git status \\\n#x\\\nrm x")[:action]).to eq("deny")
      expect(bash(layers, "git status \\\n  --short")[:action]).to eq("allow")
    end

    describe "quoting, eval, shells and groups" do
      let(:layers) { [layer([rule("Bash", "deny", "rm *"), rule("Bash", "allow", "git status*")], default: "allow")] }

      [
        '"rm" -rf /', "r''m -rf /", '\rm -rf /', "eval rm -rf /", 'bash -c "rm -rf /"', "sh -lc 'rm -rf /'",
        "{ rm -rf /; }", "if true; then rm -rf /; fi", "x=rm; $x -rf /", "source ./x", ". ./x", "r?m -rf /"
      ].each do |command|
        it "is never allowed: #{command}" do
          expect(bash(layers, command)[:action]).not_to eq("allow")
          expect(bash([layer([], default: "allow")], command)[:action]).to eq("ask")
        end
      end

      it "denies the quoted and escaped forms by their unquoted text" do
        ['"rm" -rf /', "r''m -rf /", '\rm -rf /', 'sudo "rm" -rf /'].each do |command|
          expect(bash(layers, command)[:action]).to eq("deny")
        end
      end

      it "still allows ordinary commands" do
        ["git status", "git status --short", "git log --format='%h %s'", 'git commit -m "fix: x"'].each do |command|
          allow_rule = [layer([rule("Bash", "allow", "git *")], default: "ask")]
          expect(bash(allow_rule, command)[:action]).to eq("allow")
        end
        expect(bash(layers, "git status --short")[:action]).to eq("allow")
      end

      it "lets a tool-only allow still allow an opaque command" do
        expect(bash([layer([rule("Bash", "allow")])], "eval x")[:action]).to eq("allow")
      end
    end

    describe "wrappers and hidden commands under default allow" do
      let(:layers) { [layer([rule("Bash", "deny", "rm *"), rule("Bash", "deny", "git push*")], default: "allow")] }

      [
        "builtin rm -rf /", "nice rm -rf /", "nice -n 5 rm -rf /", "ionice -c3 rm -rf /", "timeout 5 rm -rf /",
        "timeout -s KILL 5 rm -rf /", "exec -a x rm -rf /", "xargs rm -rf", "echo / | xargs -I{} rm -rf {}",
        "doas rm -rf /", "stdbuf -o0 rm -rf /", "chroot / rm -rf /", "caffeinate rm -rf /", "arch -arm64 rm -rf /",
        "watch rm -rf /", "arch -d FOO rm -rf /", "watch -q 2 rm -rf /", "watch --equexit 2 rm -rf /", "env -S 'rm -rf /'", "nohup -- rm -rf /", "sudo -u root rm -rf /"
      ].each do |command|
        it "denies #{command}" do
          expect(bash(layers, command)[:action]).to eq("deny")
        end
      end

      [
        "env -Srm", "-- rm -rf /", "trap 'rm -rf /' EXIT", "alias x=rm; x -rf /", "git -c alias.p=push p",
        "git -calias.p='!rm -rf /' p", "git --config-env alias.p=V p", "perl -e 'system(\"x\")'", "python3 -c x",
        "ruby -e x", "node -e x", "osascript -e x", "script -c x", "su -c x", "awk 'BEGIN{system(\"x\")}'",
        "coproc rm -rf /"
      ].each do |command|
        it "does not allow #{command}" do
          expect(bash(layers, command)[:action]).to eq("ask")
        end
      end

      [
        "/usr/bin/time -o x rm -rf /", "/usr/bin/time -f %e rm -rf /", "time -o x git push", "time --output x git push",
        "stdbuf --output L rm -rf /"
      ].each do |command|
        it "denies #{command}" do
          expect(bash(layers, command)[:action]).to eq("deny")
        end
      end

      it "does not allow a wrapper option value read as the command" do
        allow_git = [layer([rule("Bash", "allow", "git *")], default: "ask")]
        expect(bash(allow_git, "time -o git rm -rf /")[:action]).to eq("ask")
        expect(bash([layer([rule("Bash", "allow", "git *")], default: "allow")], "time --bogus git status")[:action]).to eq("ask")
      end

      it "never allows a command after an unknown wrapper option, and denies one a deny matches" do
        expect(bash(layers, "time --bogus ls")[:action]).to eq("ask")
        expect(bash(layers, "time --bogus rm -rf /")[:action]).to eq("deny")
      end

      it "allows a harmless wrapper around an allowed command, but not sudo or env" do
        allow_status = [layer([rule("Bash", "allow", "git status*")])]
        expect(bash(allow_status, "timeout 5 git status")[:action]).to eq("allow")
        expect(bash(allow_status, "nice -n 5 git status --short")[:action]).to eq("allow")
        expect(bash(allow_status, "timeout 5 git status && rm x")[:action]).to eq("ask")
        expect(bash(allow_status, "sudo git status")[:action]).to eq("ask")
        expect(bash(allow_status, "FOO=1 git status")[:action]).to eq("ask")
      end
    end

    it "never allows a non-String command by pattern or default" do
      layers = [layer([rule("Bash", "deny", "rm *"), rule("Bash", "allow", "git*")], default: "allow")]
      expect(decide(layers, "Bash", {"command" => %w[rm -rf x]})[:action]).to eq("ask")
      expect(decide(layers, "Bash", {})[:action]).to eq("ask")
      expect(decide([layer([], default: "deny")], "Bash", {"command" => %w[ls]})[:action]).to eq("deny")
      expect(decide([layer([rule("Bash", "allow")])], "Bash", {"command" => %w[ls]})[:action]).to eq("allow")
    end

    it "reads notebook_path, not file_path, for NotebookEdit" do
      layers = [layer([rule("NotebookEdit", "deny", "/work/secret/*")])]
      input = {"file_path" => "/work/ok/a", "notebook_path" => "/work/secret/a.ipynb"}
      expect(decide(layers, "NotebookEdit", input)[:action]).to eq("deny")
      expect(decide(layers, "Write", input)[:action]).to eq("ask")
    end

    it "raises on an unknown action or default" do
      expect { bash([layer([rule("Bash", "permit")])], "ls") }.to raise_error(ArgumentError, /unknown action/)
      expect { bash([layer([], default: "maybe")], "ls") }.to raise_error(ArgumentError, /unknown default/)
    end

    it "treats ~user forms literally instead of raising" do
      layers = [layer([rule("Write", "deny", "~nobody/*"), rule("Write", "deny", "/work/~bob/*")])]
      expect(decide(layers, "Write", {"file_path" => "~nobody/x"})[:action]).to eq("ask")
      expect(decide(layers, "Write", {"file_path" => "~bob/x"}, cwd: "/work")[:action]).to eq("deny")
    end
  end

  it "accepts string-keyed rules" do
    layers = [{source: "project", rules: [{"tool" => "Bash", "pattern" => "ls*", "action" => "deny"}], default: nil}]
    expect(bash(layers, "ls")[:action]).to eq("deny")
  end

  it "takes the pieces splitter as an injected keyword" do
    pieces = instance_double(Workspace::BashCommandPieces, pieces: ["x"], raw_pieces: ["x"], unquoted_pieces: [], unwrapped: "x", substitution?: false, redirect?: false, opaque?: false)
    policy = described_class.new(layers: [layer([rule("Bash", "allow", "x")])], command_pieces: pieces)
    expect(policy.decide(tool_name: "Bash", tool_input: {"command" => "anything"}, cwd: "/")[:action]).to eq("allow")
  end
end
