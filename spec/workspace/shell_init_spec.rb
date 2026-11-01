require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::ShellInit do
  def find_shell(name)
    ENV["PATH"].split(File::PATH_SEPARATOR).map { |d| File.join(d, name) }.find { |p| File.executable?(p) }
  end

  shell_commands = {
    "zsh -f" => ->(finder) { (z = finder.call("zsh")) && [z, "-f"] },
    "bash --norc --noprofile" => ->(finder) { (b = finder.call("bash")) && [b, "--norc", "--noprofile"] },
    "/bin/bash" => ->(_) { File.executable?("/bin/bash") ? ["/bin/bash"] : nil }
  }

  let(:sandbox) { Dir.mktmpdir("shell-init") }
  let(:bin_dir) { File.join(sandbox, "bin") }
  let(:work_dir) { File.join(sandbox, "work") }
  let(:argv_file) { File.join(sandbox, "argv") }

  before do
    FileUtils.mkdir_p([bin_dir, work_dir])
    fake = File.join(bin_dir, "workspace")
    File.write(fake, <<~'SH')
      #!/bin/sh
      if [ "$1" = workflow ] && [ "$2" = show ]; then
        [ -n "${WF_SHOW:-}" ] && cat "$WF_SHOW"
        exit 0
      fi
      : >> "$WF_OUT"
      for a in "$@"; do printf '%s\0' "$a" >> "$WF_OUT"; done
      exit "${FAKE_STATUS:-0}"
    SH
    File.chmod(0o755, fake)
  end

  after { FileUtils.remove_entry(sandbox) }

  def argv
    return nil unless File.exist?(argv_file)
    File.binread(argv_file).split("\0", -1)[0...-1]
  end

  # Loads the printed text with eval, then runs +line+ with +args+ as "$@".
  def run_shell(command, shell_name, line, args = [], prefix: "", env: {}, interactive: false, stdin: "")
    text = Workspace::ShellInit.text(shell_name)
    script = "#{prefix}\neval \"$WF_TEXT\"\n#{line}"
    cmd = command + (interactive ? ["-i"] : []) + ["-c", script, "sh", *args]
    environment = {"PATH" => "#{bin_dir}:#{ENV["PATH"]}", "WF_TEXT" => text, "WF_OUT" => argv_file, "HOME" => sandbox}.merge(env)
    Open3.capture3(environment, *cmd, chdir: work_dir, unsetenv_others: false, stdin_data: stdin)
  end

  shell_commands.each do |label, resolver|
    context "under #{label}" do
      let(:command) { resolver.call(method(:find_shell)) }
      let(:shell_name) { label.start_with?("zsh") ? "zsh" : "bash" }

      before { skip "#{label} is not installed" unless command }

      def wf(*args, **opts)
        run_shell(command, shell_name, 'wf "$@"', args, **opts)
      end

      it "loads silently, with an alias on wf set first" do
        prefix = (shell_name == "bash") ? "shopt -s expand_aliases\nalias wf=x" : "alias wf=x"
        out, err, status = run_shell(command, shell_name, ":", prefix: prefix)
        expect([out, err, status.exitstatus]).to eq(["", "", 0])
      end

      it "starts the default workflow on one word as a ref" do
        _, _, status = wf("feature-x")
        expect(status.exitstatus).to eq(0)
        expect(argv).to eq(%w[workflow start -- rpiv feature-x])
      end

      it "takes the id from -w" do
        wf("-w", "explore", "feature-x")
        expect(argv).to eq(%w[workflow start -- explore feature-x])
      end

      it "takes the default id from WORKSPACE_WF_DEFAULT" do
        wf("feature-x", env: {"WORKSPACE_WF_DEFAULT" => "investigate"})
        expect(argv).to eq(%w[workflow start -- investigate feature-x])
      end

      it "sends several words as one prompt joined by spaces" do
        wf("fix", "the", "thing")
        expect(argv).to eq(["workflow", "start", "--prompt", "fix the thing", "--", "rpiv"])
      end

      it "sends one quoted string with whitespace as a prompt, newline intact" do
        wf("fix the\nthing")
        expect(argv).to eq(["workflow", "start", "--prompt", "fix the\nthing", "--", "rpiv"])
      end

      it "puts --dry-run before the other arguments" do
        wf("--dry-run", "fix the thing")
        expect(argv).to eq(["workflow", "start", "--dry-run", "--prompt", "fix the thing", "--", "rpiv"])
        File.delete(argv_file)
        wf("--dry-run", "feature-x")
        expect(argv).to eq(%w[workflow start --dry-run -- rpiv feature-x])
      end

      it "takes text that starts with a dash after --" do
        wf("--", "-x")
        expect(argv).to eq(%w[workflow start -- rpiv -x])
      end

      it "treats a --dry-run after -- as text, not a dry run" do
        wf("--", "--dry-run", "fix")
        expect(argv).to eq(["workflow", "start", "--prompt", "--dry-run fix", "--", "rpiv"])
      end

      it "passes a quoted #123 as a ref" do
        wf("#123")
        expect(argv).to eq(%w[workflow start -- rpiv #123])
      end

      it "stops reading options at the first word that is not one" do
        wf("fix", "-w", "foo")
        expect(argv).to eq(["workflow", "start", "--prompt", "fix -w foo", "--", "rpiv"])
      end

      it "refuses no words, an empty word, a -w without a value and an unknown option" do
        [[], [""], ["-w"], ["-w", ""], ["-w", "x"], ["--bogus", "x"], ["-x"]].each do |args|
          File.delete(argv_file) if File.exist?(argv_file)
          _, err, status = wf(*args)
          expect(status.exitstatus).to eq(1), "args #{args.inspect}"
          expect(err).not_to be_empty
          expect(argv).to be_nil, "args #{args.inspect}"
        end
      end

      it "points an unknown option at --" do
        _, err, _ = wf("--bogus", "x")
        expect(err).to include("--")
      end

      it "prints help on stdout and exits 0" do
        out, _, status = wf("--help")
        expect(status.exitstatus).to eq(0)
        expect(out).to start_with("Usage: wf")
        expect(argv).to be_nil
      end

      it "passes the exit status of workspace through" do
        _, _, status = wf("feature-x", env: {"FAKE_STATUS" => "7"})
        expect(status.exitstatus).to eq(7)
        _, _, status = wf("fix the thing", env: {"FAKE_STATUS" => "3"})
        expect(status.exitstatus).to eq(3)
      end

      it "hands hostile words to argv byte for byte and runs nothing" do
        hostile = ["$(touch canary)", "`touch canary`", "x; touch canary", "a'b\"c", "*", "$HOME \\n"]
        hostile.each do |word|
          wf(word)
          expected = word.match?(/\s/) ? ["workflow", "start", "--prompt", word, "--", "rpiv"] : ["workflow", "start", "--", "rpiv", word]
          expect(argv).to eq(expected), word
          File.delete(argv_file)
          wf("say", word)
          expect(argv).to eq(["workflow", "start", "--prompt", "say #{word}", "--", "rpiv"]), word
          File.delete(argv_file)
        end
        expect(File.exist?(File.join(work_dir, "canary"))).to be(false)
      end

      describe "wfp" do
        let(:fzf_dir) { File.join(sandbox, "fzfbin") }
        let(:canary) { File.join(work_dir, "canary") }

        def write_exe(dir, name, body)
          FileUtils.mkdir_p(dir)
          path = File.join(dir, name)
          File.write(path, "#!/bin/sh\n#{body}\n")
          File.chmod(0o755, path)
        end

        before do
          File.write(File.join(sandbox, "show"), "rpiv  built-in\nexplore  built-in\nbad  INVALID: broken\nNo workflows.\n")
          write_exe(fzf_dir, "fzf", <<~'SH')
            n=$(cat "$WF_DIR/count" 2>/dev/null || echo 0)
            n=$((n + 1))
            echo "$n" > "$WF_DIR/count"
            for a in "$@"; do printf '%s\0' "$a"; done > "$WF_DIR/fzf.args.$n"
            if [ "${FZF_NOREAD:-}" = 1 ]; then exec <&-; else cat > "$WF_DIR/fzf.in.$n"; fi
            [ -f "$WF_DIR/fzf.out.$n" ] && cat "$WF_DIR/fzf.out.$n"
            exit "$(cat "$WF_DIR/fzf.rc.$n" 2>/dev/null || echo 0)"
          SH
          system("git", "init", "-q", "-b", "main", work_dir) || raise("git init")
          system("git", "-C", work_dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i") || raise("commit")
          system("git", "-C", work_dir, "branch", "feature-x")
        end

        def fzf_plays(*plays)
          plays.each_with_index do |(out, rc), i|
            File.write(File.join(sandbox, "fzf.out.#{i + 1}"), out) if out
            File.write(File.join(sandbox, "fzf.rc.#{i + 1}"), rc.to_s)
          end
        end

        def fzf_args(n)
          File.binread(File.join(sandbox, "fzf.args.#{n}")).split("\0")
        end

        def fzf_input(n)
          File.read(File.join(sandbox, "fzf.in.#{n}"))
        end

        def wfp_run(fzf: true, stdin: "", env: {}, prefix: "")
          path = [bin_dir, (fzf ? fzf_dir : nil), "/usr/bin", "/bin"].compact.join(":")
          run_shell(command, shell_name, "wfp", [], prefix: prefix, stdin: stdin,
            env: {"PATH" => path, "WF_SHOW" => File.join(sandbox, "show"), "WF_DIR" => sandbox}.merge(env))
        end

        it "starts the picked branch on the picked workflow when Enter is pressed" do
          fzf_plays(["explore\n", 0], ["\nfeature-x\n", 0])
          _, _, status = wfp_run
          expect(status.exitstatus).to eq(0)
          expect(argv).to eq(%w[workflow start -- explore feature-x])
          expect(fzf_input(1)).to eq("rpiv\nexplore\n")
          expect(fzf_input(2).lines).to include("feature-x\n", "main\n")
        end

        it "starts a picked pull request by its number alone" do
          fzf_plays(["rpiv\n", 0], ["12\n#12\tFix the thing\n", 0])
          wfp_run
          expect(argv).to eq(%w[workflow start -- rpiv #12])
        end

        it "uses the typed text on Alt-Enter, which prints the query once" do
          fzf_plays(["rpiv\n", 0], ["fix the thing\n", 0])
          wfp_run
          expect(argv).to eq(["workflow", "start", "--prompt", "fix the thing", "--", "rpiv"])
        end

        it "uses the typed text when nothing matches (exit 1)" do
          fzf_plays(["rpiv\n", 0], ["brand new\n", 1])
          wfp_run
          expect(argv).to eq(["workflow", "start", "--prompt", "brand new", "--", "rpiv"])
        end

        it "starts nothing and exits 130 on Esc in either picker" do
          fzf_plays([nil, 130])
          _, _, status = wfp_run
          expect([status.exitstatus, argv]).to eq([130, nil])
          FileUtils.rm_f(Dir[File.join(sandbox, "{count,fzf.*}")])
          fzf_plays(["rpiv\n", 0], [nil, 130])
          _, _, status = wfp_run
          expect([status.exitstatus, argv]).to eq([130, nil])
        end

        it "starts nothing on fzf exit 2, exit 1 from the id picker and Alt-Enter on an empty query" do
          [[[nil, 2]], [[nil, 1]], [["rpiv\n", 0], [nil, 2]], [["rpiv\n", 0], ["", 0]], [["rpiv\n", 0], ["", 1]]].each do |plays|
            FileUtils.rm_f(Dir[File.join(sandbox, "{count,fzf.*}")])
            fzf_plays(*plays)
            _, _, status = wfp_run
            expect(status.exitstatus).to eq(1), plays.inspect
            expect(argv).to be_nil
          end
        end

        it "says why when fzf leaves nothing to start" do
          {
            [[nil, 1]] => "wfp: no workflow picked; nothing started\n",
            [[nil, 2]] => "wfp: no workflow picked; nothing started\n",
            [["rpiv\n", 0], [nil, 2]] => "wfp: fzf failed (exit 2); nothing started\n"
          }.each do |plays, message|
            FileUtils.rm_f(Dir[File.join(sandbox, "{count,fzf.*}")])
            fzf_plays(*plays)
            _, err, = wfp_run
            expect(err).to eq(message), plays.inspect
          end
        end

        it "uses the typed text when the ref picker exits 1 under a person's errexit" do
          fzf_plays(["rpiv\n", 0], ["my words\n", 1])
          _, _, status = wfp_run(prefix: "set -e")
          expect(status.exitstatus).to eq(0)
          expect(argv).to eq(%w[workflow start --prompt] + ["my words", "--", "rpiv"])
        end

        it "passes --no-preview and --no-multi to both pickers and Alt-Enter to the ref picker" do
          fzf_plays(["rpiv\n", 0], ["feature-x\n", 0])
          wfp_run
          expect(fzf_args(1)).to include("--no-preview", "--no-multi")
          expect(fzf_args(2)).to include("--no-preview", "--no-multi", "--print-query", "--bind=alt-enter:print-query")
        end

        it "says so and starts nothing when there are no workflows" do
          File.write(File.join(sandbox, "show"), "No workflows.\n")
          _, err, status = wfp_run
          expect([status.exitstatus, argv]).to eq([1, nil])
          expect(err).to include("no workflows")
        end

        it "takes only the first field of hostile lines and runs nothing" do
          write_exe(bin_dir, "gh", %q{printf '#9\t$(touch canary)\n`touch canary`\t;x\n'})
          fzf_plays(["rpiv\t$(touch canary)\n", 0], ["\n#9\t$(touch canary)\n", 0])
          wfp_run
          expect(argv).to eq(%w[workflow start -- rpiv #9])
          fzf_plays(["rpiv\n", 0], ["\n$(touch canary)\t`touch canary`\n", 0])
          File.delete(argv_file)
          FileUtils.rm_f(File.join(sandbox, "count"))
          wfp_run
          expect(argv).to eq(["workflow", "start", "--prompt", "$(touch canary)", "--", "rpiv"])
          expect(File.exist?(canary)).to be(false)
        end

        it "treats hostile typed text as text" do
          fzf_plays(["rpiv\n", 0], ["x; touch canary $(touch canary)\n", 0])
          wfp_run
          expect(argv).to eq(["workflow", "start", "--prompt", "x; touch canary $(touch canary)", "--", "rpiv"])
          expect(File.exist?(canary)).to be(false)
        end

        it "offers the pull requests the gh stub lists after the branches" do
          write_exe(bin_dir, "gh", "printf '#12\\tFix\\n'")
          fzf_plays(["rpiv\n", 0], ["feature-x\n", 0])
          wfp_run
          expect(fzf_input(2).lines).to end_with("#12\tFix\n")
        end

        it "returns well under the limit when gh is fast" do
          write_exe(bin_dir, "gh", "printf '#12\\tFix\\n'")
          fzf_plays(["rpiv\n", 0], ["feature-x\n", 0])
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          wfp_run
          expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
        end

        it "gives up on a slow gh at the limit and still offers the branches" do
          write_exe(bin_dir, "gh", "exec sleep 30")
          fzf_plays(["rpiv\n", 0], ["feature-x\n", 0])
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          wfp_run
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          expect(elapsed).to be_between(4, 9)
          expect(fzf_input(2).lines).to include("feature-x\n")
          expect(argv).to eq(%w[workflow start -- rpiv feature-x])
        end

        it "does not wait out a slow gh when Esc is pressed" do
          write_exe(bin_dir, "gh", "exec sleep 30")
          fzf_plays(["rpiv\n", 0], [nil, 130])
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          _, _, status = wfp_run(env: {"FZF_NOREAD" => "1"}, prefix: "set -o pipefail")
          expect(status.exitstatus).to eq(130)
          expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
        end

        unless label.start_with?("zsh")
          it "survives set -o posix and a person's pipefail in the ref picker" do
            fzf_plays(["rpiv\n", 0], ["\nfeature-x\n", 0])
            _, err, status = wfp_run(prefix: "set -o posix\nset -o pipefail")
            expect([status.exitstatus, err]).to eq([0, ""])
            expect(argv).to eq(%w[workflow start -- rpiv feature-x])
          end
        end

        it "says so when the ref picker returns an empty ref, and stays silent on Esc" do
          fzf_plays(["rpiv\n", 0], ["", 0])
          _, err, status = wfp_run
          expect([status.exitstatus, err]).to eq([1, "wfp: no ref or text given; nothing started\n"])
          FileUtils.rm_f(Dir[File.join(sandbox, "{count,fzf.*}")])
          fzf_plays(["rpiv\n", 0], [nil, 130])
          _, err, status = wfp_run
          expect([status.exitstatus, err]).to eq([130, ""])
        end

        it "is not changed by an alias on sed, awk or grep set before the eval" do
          prefix = (shell_name == "bash") ? "shopt -s expand_aliases\n" : ""
          prefix += "alias sed=false awk=false grep=false git=false gh=false sleep=false kill=false"
          fzf_plays(["rpiv\n", 0], ["feature-x\n", 0])
          wfp_run(prefix: prefix)
          expect(argv).to eq(%w[workflow start -- rpiv feature-x])
          expect(fzf_input(1)).to eq("rpiv\nexplore\n")
          FileUtils.rm_f(Dir[File.join(sandbox, "{count,fzf.*}")])
          File.delete(argv_file)
          _, _, status = wfp_run(fzf: false, stdin: "2\nfeature-x\n", prefix: prefix)
          expect([status.exitstatus, argv]).to eq([0, %w[workflow start -- explore feature-x]])
        end

        context "without fzf" do
          it "lists the workflows and starts the one numbered, on the typed ref" do
            out, _, status = wfp_run(fzf: false, stdin: "2\nfeature-x\n")
            expect(status.exitstatus).to eq(0)
            expect(out).to include("1) rpiv\n2) explore\n")
            expect(argv).to eq(%w[workflow start -- explore feature-x])
          end

          it "sends typed text with whitespace as a prompt" do
            wfp_run(fzf: false, stdin: "1\nfix the thing\n")
            expect(argv).to eq(["workflow", "start", "--prompt", "fix the thing", "--", "rpiv"])
          end

          it "starts nothing for 0, a number too large, text, an empty answer or end of input" do
            ["0\nx\n", "3\nx\n", "99999999999999999999\nx\n", "abc\nx\n", "1;2\nx\n", "\nx\n", "", "1\n", "1\n\n"].each do |input|
              _, _, status = wfp_run(fzf: false, stdin: input)
              expect(status.exitstatus).to eq(1), input.inspect
              expect(argv).to be_nil, input.inspect
            end
          end

          it "says so when the number is empty" do
            _, err, status = wfp_run(fzf: false, stdin: "\nx\n")
            expect([status.exitstatus, err]).to eq([1, "wfp: no number given; nothing started\n"])
          end

          it "says so when the ref is empty" do
            _, err, status = wfp_run(fzf: false, stdin: "1\n\n")
            expect([status.exitstatus, err]).to eq([1, "wfp: no ref or text given; nothing started\n"])
          end

          it "asks for a ref, text or a pull request number" do
            out, = wfp_run(fzf: false, stdin: "1\nfeature-x\n")
            expect(out).to include("Ref or text (branch, '#12', or words): ")
          end

          it "runs nothing for a hostile number or ref" do
            wfp_run(fzf: false, stdin: "$(touch canary)\nx\n")
            wfp_run(fzf: false, stdin: "1\n$(touch canary)\n")
            expect(argv).to eq(["workflow", "start", "--prompt", "$(touch canary)", "--", "rpiv"])
            expect(File.exist?(canary)).to be(false)
          end
        end
      end
    end
  end

  context "under an interactive zsh" do
    before { skip "zsh is not installed" unless find_shell("zsh") }

    it "loads silently" do
      out, _err, status = run_shell([find_shell("zsh"), "-f"], "zsh", ":", interactive: true)
      expect([out, status.exitstatus]).to eq(["", 0])
    end
  end

  context "under zsh with sh_word_split, ksh_arrays and no_unset" do
    before { skip "zsh is not installed" unless find_shell("zsh") }

    it "gives the same argv" do
      prefix = "setopt sh_word_split ksh_arrays no_unset"
      run_shell([find_shell("zsh"), "-f"], "zsh", 'wf --dry-run -w explore "$@"', ["fix", "the thing"], prefix: prefix)
      expect(argv).to eq(["workflow", "start", "--dry-run", "--prompt", "fix the thing", "--", "explore"])
      File.delete(argv_file)
      run_shell([find_shell("zsh"), "-f"], "zsh", 'wf "$@"', ["feature-x"], prefix: prefix)
      expect(argv).to eq(%w[workflow start -- rpiv feature-x])
    end
  end

  describe ".text" do
    %w[zsh bash].each do |shell|
      it "holds no eval, no compgen -W and no name() { for #{shell}" do
        text = described_class.text(shell)
        expect(text).not_to match(/eval/)
        expect(text).not_to include("compgen -W")
        expect(text).not_to include("() {")
      end
    end

    it "refuses another shell" do
      expect { described_class.text("fish") }.to raise_error(ArgumentError)
    end
  end

  describe "completion" do
    let(:ids_file) { File.join(sandbox, "ids") }
    let(:subcommands) { Workspace::CLI::SUBCOMMANDS }
    let(:verbs) { Workspace::CLI::WORKFLOW_SUBCOMMANDS - ["advance"] }
    let(:id_env) { {"WF_SHOW" => ids_file} }

    before do
      File.write(ids_file, <<~IDS)
        rpiv      preset
        explore   preset
        $(touch canary)  preset
        bad;id    preset
        broken    INVALID: nope
      IDS
    end

    # Runs one Tab in bash: +words+ with the cursor on the last one.
    def bash_tab(words)
      bash = find_shell("bash") or skip "bash is not installed"
      list = words.map { |w| "'#{w}'" }.join(" ")
      line = "COMP_WORDS=(#{list}); COMP_CWORD=#{words.size - 1}; _workspace_complete; printf '%s\\n' \"${COMPREPLY[@]}\""
      out, err, status = run_shell([bash, "--norc", "--noprofile"], "bash", line, env: id_env)
      expect(status.exitstatus).to eq(0), err
      out.split("\n")
    end

    # Runs one Tab in zsh with compadd and _files stubbed.
    def zsh_tab(words)
      zsh = find_shell("zsh") or skip "zsh is not installed"
      list = words.map { |w| "'#{w}'" }.join(" ")
      line = <<~SH + "words=(#{list}); CURRENT=#{words.size}; PREFIX='#{words.last}'; _workspace_complete; print -r -- \"rc=$?\"\n"
        function compadd { local w; for w in "${(@P)2}"; do [[ $w == ${PREFIX}* ]] && print -r -- "add $w"; done; return 0 }
        function _files { print -r -- files; return 1 }
      SH
      out, err, status = run_shell([zsh, "-f"], "zsh", line, env: id_env)
      expect(status.exitstatus).to eq(0), err
      out.split("\n")
    end

    it "prints word lists equal to the CLI's subcommands and workflow verbs minus advance" do
      zsh_text = described_class.text("zsh")
      bash_text = described_class.text("bash")
      expect(zsh_text).to include("wf_list=(#{subcommands.join(" ")})", "wf_list=(#{verbs.join(" ")})")
      expect(bash_text).to include(%(wf_list="#{subcommands.join(" ")}"), %(wf_list="#{verbs.join(" ")}"))
    end

    context "in bash" do
      it "offers every subcommand after workspace" do
        expect(bash_tab(["workspace", ""])).to eq(subcommands)
      end

      it "narrows by prefix" do
        expect(bash_tab(["workspace", "wor"])).to eq(%w[workflow])
        expect(bash_tab(%w[workspace workflow st])).to eq(%w[start status stats])
      end

      it "offers the workflow verbs" do
        expect(bash_tab(["workspace", "workflow", ""])).to eq(verbs)
      end

      it "offers only valid ids after workflow start, and runs nothing for an odd one" do
        expect(bash_tab(["workspace", "workflow", "start", ""])).to eq(%w[rpiv explore])
        expect(bash_tab(["workspace", "workflow", "show", "ex"])).to eq(%w[explore])
        expect(File.exist?(File.join(work_dir, "canary"))).to be(false)
      end

      it "offers nothing for other words, so the default file completion applies" do
        expect(bash_tab(["workspace", "workflow", "advance", ""])).to eq([])
        expect(bash_tab(["workspace", "dir", ""])).to eq([])
        expect(bash_tab(["wf", ""])).to eq([])
        expect(bash_tab(["wf", "fix", ""])).to eq([])
      end

      it "offers ids after wf -w" do
        expect(bash_tab(["wf", "-w", ""])).to eq(%w[rpiv explore])
        expect(bash_tab(["wf", "-w", "e"])).to eq(%w[explore])
      end

      it "registers with complete -o default and leaves a person's set -e alone" do
        bash = find_shell("bash") or skip "bash is not installed"
        out, err, status = run_shell([bash, "--norc", "--noprofile"], "bash", "complete -p workspace wf; COMP_WORDS=(wf x); COMP_CWORD=1; _workspace_complete; echo alive", prefix: "set -e")
        expect(status.exitstatus).to eq(0), err
        expect(out).to include("complete -o default -F _workspace_complete workspace", "alive")
      end
    end

    context "in zsh" do
      it "offers every subcommand after workspace" do
        expect(zsh_tab(["workspace", ""])).to eq(subcommands.map { |w| "add #{w}" } + ["rc=0"])
      end

      it "narrows by prefix and offers the workflow verbs" do
        expect(zsh_tab(%w[workspace workflow st])).to eq(["add start", "add status", "add stats", "rc=0"])
        expect(zsh_tab(["workspace", "workflow", ""])).to eq(verbs.map { |w| "add #{w}" } + ["rc=0"])
      end

      it "offers only valid ids after workflow start, and runs nothing for an odd one" do
        expect(zsh_tab(["workspace", "workflow", "start", ""])).to eq(["add rpiv", "add explore", "rc=0"])
        expect(File.exist?(File.join(work_dir, "canary"))).to be(false)
      end

      it "falls back to files elsewhere" do
        expect(zsh_tab(["workspace", "workflow", "advance", ""])).to eq(["files", "rc=0"])
        expect(zsh_tab(["workspace", "dir", ""])).to eq(["files", "rc=0"])
        expect(zsh_tab(["wf", ""])).to eq(["files", "rc=0"])
        expect(zsh_tab(["wf", "fix", ""])).to eq(["files", "rc=0"])
      end

      it "offers ids after wf -w" do
        expect(zsh_tab(["wf", "-w", ""])).to eq(["add rpiv", "add explore", "rc=0"])
      end

      it "loads with no compinit: no output, status 0, nothing registered" do
        zsh = find_shell("zsh") or skip "zsh is not installed"
        out, err, status = run_shell([zsh, "-f"], "zsh", "print -r -- ${+functions[compdef]}")
        expect([out, err, status.exitstatus]).to eq(["0\n", "", 0])
      end

      it "loads silently and registers under ksh_arrays and the other options a person may set" do
        zsh = find_shell("zsh") or skip "zsh is not installed"
        out, err, status = run_shell([zsh, "-f"], "zsh", "print -r -- done", prefix: "setopt ksh_arrays sh_word_split no_unset\nfunction compdef { print -r -- \"compdef $*\" }")
        expect([out, err, status.exitstatus]).to eq(["compdef _workspace_complete workspace wf\ndone\n", "", 0])
      end

      it "registers through compdef when it exists, and survives set -e" do
        zsh = find_shell("zsh") or skip "zsh is not installed"
        out, err, status = run_shell([zsh, "-f"], "zsh", "print -r -- done", prefix: "set -e\nfunction compdef { print -r -- \"compdef $*\" }")
        expect(status.exitstatus).to eq(0), err
        expect(out).to eq("compdef _workspace_complete workspace wf\ndone\n")
      end
    end
  end

  describe "workspace shell-init" do
    %w[zsh bash].each do |shell|
      it "prints the #{shell} text" do
        out, err, status = Open3.capture3(File.expand_path("../../bin/workspace", __dir__), "shell-init", shell)
        expect(status.exitstatus).to eq(0), err
        expect(out).to eq(described_class.text(shell))
      end
    end

    it "refuses no argument, an unknown shell and two arguments" do
      [[], ["fish"], %w[zsh bash]].each do |args|
        _, err, status = Open3.capture3(File.expand_path("../../bin/workspace", __dir__), "shell-init", *args)
        expect(status.exitstatus).to eq(1)
        expect(err).to include("Usage: workspace shell-init zsh|bash")
      end
    end
  end
end
