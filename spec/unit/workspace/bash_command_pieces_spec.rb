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
