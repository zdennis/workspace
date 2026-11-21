require "spec_helper"

RSpec.describe Workspace::BashCommandPieces do
  subject(:splitter) { described_class.new }

  describe "#pieces" do
    it "cuts at unquoted separators" do
      expect(splitter.pieces("cd x && git push; ls | wc\nfoo & bar || baz")).to eq(
        ["cd x", "git push", "ls", "wc", "foo", "bar", "baz"]
      )
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
