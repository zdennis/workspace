require "spec_helper"

RSpec.describe Workspace::BashCommandPieces do
  subject(:splitter) { described_class.new }

  describe "#pieces" do
    it "cuts at unquoted separators" do
      expect(splitter.pieces("cd x && git push; ls | wc\nfoo & bar || baz")).to eq(
        ["cd x", "git push", "ls", "wc", "foo", "bar", "baz"]
      )
    end

    it "does not cut at the & of a redirection" do
      expect(splitter.pieces("git status 2>&1")).to eq(["git status 2>&1"])
      expect(splitter.pieces("git status &> /dev/null; ls")).to eq(["git status &> /dev/null", "ls"])
      expect(splitter.pieces("a && b & c")).to eq(%w[a b c])
    end

    it "cuts at the & after an escaped redirection character" do
      expect(splitter.pieces("git status \\>&rm -rf ~")).to eq(["git status \\>", "rm -rf ~"])
      expect(splitter.pieces("git status \\<&rm -rf ~")).to eq(["git status \\<", "rm -rf ~"])
      expect(splitter.pieces("a &&>b")).to eq(["a", ">b"])
    end

    it "does not start a comment after an escaped blank" do
      expect(splitter.pieces("git status \\ #;rm -rf ~")).to eq(["git status \\ #", "rm -rf ~"])
      expect(splitter.pieces("git status \\\t#;rm x")).to eq(["git status \\\t#", "rm x"])
      expect(splitter.pieces("git status # ;rm x")).to eq(["git status"])
    end

    it "drops a line continuation and starts a comment from the character before it" do
      expect(splitter.pieces("git status \\\n#\\\nrm -rf ~")).to eq(["git status", "rm -rf ~"])
      expect(splitter.pieces("git status \\\n#x\\\nrm x")).to eq(["git status", "rm x"])
      expect(splitter.pieces("git status\\\n#x;rm x")).to eq(["git status#x", "rm x"])
      expect(splitter.pieces("git status \\\n  --short")).to eq(["git status --short"])
      expect(splitter.pieces("echo \"a\\\nb\"")).to eq(['echo "ab"'])
      expect(splitter.pieces("echo 'a\\\nb'")).to eq(["echo 'a\\\nb'"])
    end

    it "keeps a quoted separator inside its piece" do
      expect(splitter.pieces('git commit -m "a; git push"')).to eq(['git commit -m "a; git push"'])
    end

    it "cuts the inside of a substitution" do
      expect(splitter.pieces("echo $(git push)")).to include("git push")
    end

    it "skips here-document bodies" do
      expect(splitter.pieces("cat <<EOF\ngit push\nEOF\nls")).to eq(["cat <<EOF", "ls"])
    end

    it "strips assignments, wrappers, their options and a program path" do
      expect(splitter.pieces("FOO=1 sudo -u me /usr/bin/git -C dir push")).to eq(["git push", "/usr/bin/git push"])
    end

    it "strips gh global options" do
      expect(splitter.pieces("gh -R o/r pr comment")).to eq(["gh pr comment"])
    end

    it "folds blanks outside quotes" do
      expect(splitter.pieces("git   status")).to eq(["git status"])
    end

    it "limits a piece to MAX_PIECE characters" do
      expect(splitter.pieces("echo " + "a" * 5000).first.size).to eq(described_class::MAX_PIECE)
    end
  end

  describe "#raw_pieces" do
    it "keeps each piece as written, trimmed" do
      expect(splitter.raw_pieces("  FOO=1 sudo git push && /usr/bin/git -C d pull ")).to eq(
        ["FOO=1 sudo git push", "/usr/bin/git -C d pull"]
      )
    end

    it "keeps an escaped quote inside an ANSI-C string" do
      expect(splitter.raw_pieces(%q(echo $'\''; git push))).to eq([%q(echo $'\''), "git push"])
    end

    it "keeps quotes and drops empty pieces" do
      expect(splitter.raw_pieces('echo "a; b";;')).to eq(['echo "a; b"'])
    end
  end

  describe "#substitution?" do
    ["echo $(id)", %q(echo $'\''), "echo ${x//'/>f}", "echo \"${x}\"", "echo `id`", "diff <(a) b", "tee >(a)", 'echo "$(id)"', "echo '`id`'"].each do |command|
      it "is true for #{command}" do
        expect(splitter.substitution?(command)).to be true
      end
    end

    it "is false for a plain command" do
      expect(splitter.substitution?("git status && ls")).to be false
    end
  end

  describe "#unquoted_pieces" do
    it "removes quotes and resolves escapes, then strips wrappers" do
      expect(splitter.unquoted_pieces('"rm" -rf /')).to eq(["rm -rf /"])
      expect(splitter.unquoted_pieces("r''m -rf /")).to eq(["rm -rf /"])
      expect(splitter.unquoted_pieces('\rm -rf /')).to eq(["rm -rf /"])
      expect(splitter.unquoted_pieces('sudo "rm" -rf /')).to eq(["rm -rf /"])
      expect(splitter.unquoted_pieces("echo $'a\\'b'")).to eq(["echo a'b"])
    end
  end

  describe "more wrappers" do
    [
      ["builtin rm -rf /", "rm -rf /"], ["nice rm x", "rm x"], ["nice -n 5 rm x", "rm x"], ["nice -n5 rm x", "rm x"],
      ["ionice -c3 rm x", "rm x"], ["ionice -c 3 -n 2 rm x", "rm x"], ["timeout 5 rm x", "rm x"],
      ["timeout -s KILL 5 rm x", "rm x"], ["timeout -k 1 -s TERM 5s rm x", "rm x"], ["stdbuf -o0 rm x", "rm x"],
      ["stdbuf -i L -o 0 rm x", "rm x"], ["doas -u me rm x", "rm x"], ["caffeinate -t 5 rm x", "rm x"],
      ["chroot / rm x", "rm x"], ["arch -arm64 rm x", "rm x"], ["watch -n 2 rm x", "rm x"],
      ["exec -a name rm x", "rm x"], ["xargs rm -rf", "rm -rf"], ["xargs -I{} rm {}", "rm {}"],
      ["xargs -I {} -n 1 -P 4 rm {}", "rm {}"], ["xargs -0 -d x -s 5 -L 1 -E z rm", "rm"]
    ].each do |command, stripped|
      it "strips the wrapper of #{command}" do
        expect(splitter.pieces(command)).to eq([stripped])
      end
    end
  end

  describe "wrapper options" do
    [
      ["time -o out rm x", "rm x"], ["/usr/bin/time -o x rm -rf /", "rm -rf /"], ["/usr/bin/time -f %e rm x", "rm x"],
      ["time --output out --format %e rm x", "rm x"], ["time --output=out rm x", "rm x"], ["time -ofile rm x", "rm x"],
      ["time -o x git push", "git push"], ["stdbuf --output L rm x", "rm x"], ["stdbuf --input=L rm x", "rm x"],
      ["sudo -E -H -u me rm x", "rm x"], ["sudo --user me rm x", "rm x"], ["sudo --user=me rm x", "rm x"],
      ["nice -5 rm x", "rm x"], ["env -i -u HOME rm x", "rm x"], ["xargs -0 -t rm", "rm"], ["xargs -tr rm", "rm"]
    ].each do |command, stripped|
      it "skips the options of #{command}" do
        expect(splitter.pieces(command)).to eq([stripped])
        expect(splitter.opaque?(command)).to be false
      end
    end

    ["time --bogus rm x", "sudo -Z rm x", "nice -q rm x", "timeout --wat 5 rm x", "xargs -Y rm", "env --wat rm x",
      "stdbuf -z rm x"].each do |command|
      it "is opaque for the unknown option in #{command}" do
        expect(splitter.opaque?(command)).to be true
      end
    end

    it "still shows the command after an unknown option" do
      expect(splitter.pieces("time --bogus rm -rf /")).to eq(["rm -rf /"])
    end

    it "does not unwrap an unknown option for allow matching" do
      expect(splitter.unwrapped("time -o git rm x")).to eq("rm x")
    end
  end

  describe "#unwrapped" do
    it "drops only harmless wrappers" do
      expect(splitter.unwrapped("timeout 5 git status")).to eq("git status")
      expect(splitter.unwrapped("nice -n 5 time git status")).to eq("git status")
      expect(splitter.unwrapped("sudo git status")).to eq("sudo git status")
      expect(splitter.unwrapped("FOO=1 git status")).to eq("FOO=1 git status")
      expect(splitter.unwrapped("git status")).to eq("git status")
    end
  end

  describe "#opaque? for hidden commands" do
    [
      "env -S 'rm -rf /'", "env -Srm", "env --split-string=x", "-- rm -rf /", "trap 'rm x' EXIT", "alias x=rm",
      "git -c alias.p=push p", "git -calias.p=push p", "git -c alias.p='!rm x' p", "git --config-env alias.p=V p",
      "git --config-env=alias.p=V p", "git -c ALIAS.p=x p", "perl -e 'x'", "perl -ne x", "python3 -c x", "python -c x",
      "python3.12 -c x", "ruby -e x", "ruby -rjson -e x", "node -e x", "node --eval x", "osascript -e x", "script -c x",
      "su -c x", "sudo su -c x", "awk '{}'", "gawk x", "nawk x", "bash -o pipefail -c x", "coproc rm x"
    ].each do |command|
      it "is true for #{command}" do
        expect(splitter.opaque?(command)).to be true
      end
    end

    ["timeout 5 git status", "nice -n 5 git status", "xargs -n 1 echo", "git -c core.x=y status", "ruby script.rb",
      "python3 script.py", "perl script.pl", "node app.js", "git log --oneline", "git config alias.p push"].each do |command|
      it "is false for #{command}" do
        expect(splitter.opaque?(command)).to be false
      end
    end
  end

  describe "#opaque?" do
    [
      '"rm" -rf /', "r''m x", '\rm x', "eval rm x", 'bash -c "rm x"', "sh -lc 'x'", "sudo bash -c x", "{ rm x; }",
      "if true; then rm x; fi", "while x; do y; done", "source f", ". f", "! x", "x=1 eval y", "$x y", "r?m x", "[[ a ]]"
    ].each do |command|
      it "is true for #{command}" do
        expect(splitter.opaque?(command)).to be true
      end
    end

    ["git status", "git status --short", "git log --format='%h %s'", 'git commit -m "fix: x"', "bash script.sh",
      "ls | wc -l", "echo \"a b\"", "FOO=1 git status", "git status 2>&1"].each do |command|
      it "is false for #{command}" do
        expect(splitter.opaque?(command)).to be false
      end
    end
  end

  describe "#redirect?" do
    [
      "git status > ~/.zshrc", "git diff >> x", "cmd 2>x", "cmd &>x", "cmd &>>x", "cmd < file", "cmd >| x",
      "cmd <> x", "cmd >&x", "cat <<EOF", "cat <<-EOF", "cat <<< hi", "cmd >/dev/null2", "cmd > /dev/null/x",
      "cmd >", %q(echo $'\'' >f), "echo hi >'x y'"
    ].each do |command|
      it "is true for #{command}" do
        expect(splitter.redirect?(command)).to be true
      end
    end

    ["git status \\ # > ~/.zshrc", "git status \\\t# > x"].each do |command|
      it "is true for an escaped blank before # in #{command.inspect}" do
        expect(splitter.redirect?(command)).to be true
      end
    end

    it "sees a redirect after a comment-looking # that a continuation hides" do
      expect(splitter.redirect?("git status\\\n# > x")).to be true
      expect(splitter.redirect?("git status \\\n# > x")).to be false
      expect(splitter.redirect?("git status \\\n#\\\n> x")).to be true
    end

    [
      "cmd 2>&1", "cmd >/dev/null 2>&1", "echo \"a > b\"", "echo 'x<y'", "cmd >&2", "cmd <&0", "cmd 2>&-",
      "cmd 2>/dev/null", "cmd </dev/null", "git status", "echo a\\>b", "ls # > x", "diff <(a) <(b)"
    ].each do |command|
      it "is false for #{command}" do
        expect(splitter.redirect?(command)).to be false
      end
    end
  end
end
