require "spec_helper"

RSpec.describe BoundaryScan do
  describe ".strip" do
    it "blanks comments, =begin blocks and string text, keeping line positions" do
      source = "# Foo\nx = \"Bar\" # Baz\n=begin\nQux\n=end\ny = 1\n"

      stripped = described_class.strip(source)

      expect(stripped.lines.size).to eq(source.lines.size)
      expect(stripped).not_to match(/Foo|Bar|Baz|Qux/)
      expect(stripped).to include("y = 1")
    end
  end

  describe ".chains" do
    it "reports a name in code but not in a comment or a string" do
      source = <<~RUBY
        # Commented
        x = "InString"
        y = 'Single'
        z = <<~TEXT
          InHeredoc
        TEXT
        Real.new
      RUBY

      expect(described_class.chains(source)).to eq([[7, "Real"]])
    end

    it "keeps code inside a string interpolation" do
      expect(described_class.chains('"a #{Inside.call} b"')).to eq([[1, "Inside"]])
    end

    it "joins a qualified name and keeps the chains apart" do
      source = "Commands::Inbox.new(Git.new)\n::Top::Name\n"

      expect(described_class.chains(source)).to eq([[1, "Commands::Inbox"], [1, "Git"], [2, "Top::Name"]])
    end
  end

  describe ".definitions" do
    it "names classes, modules and constants under their enclosing scope" do
      source = <<~RUBY
        module Workspace
          class Git
            LIMIT = 3
          end
          module Commands
            class Inbox; end
          end
        end
        class Workspace::Other; end
      RUBY

      expect(described_class.definitions(source)).to eq(%w[
        Workspace Workspace::Git Workspace::Git::LIMIT Workspace::Commands
        Workspace::Commands::Inbox Workspace::Other
      ])
    end
  end

  describe ".under?" do
    it "matches a directory by prefix and a file exactly" do
      expect(described_class.under?("lib/workspace/core/x.rb", "lib/workspace/core/")).to be(true)
      expect(described_class.under?("lib/workspace/core_x.rb", "lib/workspace/core/")).to be(false)
      expect(described_class.under?("lib/workspace/git.rb", "lib/workspace/git.rb")).to be(true)
      expect(described_class.under?("lib/workspace/git.rb.bak", "lib/workspace/git.rb")).to be(false)
    end
  end

  describe "over files" do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = dir
        example.run
      end
    end

    def write(path, text)
      full = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, text)
    end

    let(:scan) { described_class.new(@root) }

    before do
      write("lib/workspace/core/clock.rb", "module Workspace\n  module Core\n    class Clock; end\n  end\nend\n")
      write("lib/workspace/commands/inbox.rb", "module Workspace\n  module Commands\n    class Inbox; end\n  end\nend\n")
      write("lib/workspace/store.rb", <<~RUBY)
        module Workspace
          class Store
            # Commands::Inbox is not used here
            NOTE = "Commands::Inbox"
            def now = Core::Clock.new
            def other = Commands::Inbox.new
          end
        end
      RUBY
    end

    it "resolves references by qualified name and directory, per file and line" do
      refs = scan.references.map { |r| [r.file, r.line, r.constant, r.target_files] }

      expect(refs).to include(
        ["lib/workspace/store.rb", 5, "Core::Clock", ["lib/workspace/core/clock.rb"]],
        ["lib/workspace/store.rb", 6, "Commands::Inbox", ["lib/workspace/commands/inbox.rb"]]
      )
      expect(refs.map { |r| r[1] }).not_to include(3, 4)
    end

    it "filters by the directory a reference comes from" do
      expect(scan.references_from("lib/workspace/core/")).to eq([])
      expect(scan.references_from("lib/workspace/store.rb").size).to eq(2)
    end

    it "treats a comment-only or string-only mention as no reference" do
      write("lib/workspace/core/note.rb", "# Commands::Inbox\nX = \"Commands::Inbox\"\n")

      expect(scan.references_from("lib/workspace/core/note.rb")).to eq([])
    end

    it "lists a name defined in two files as ambiguous and gives it no target" do
      write("lib/workspace/a.rb", "class Twin; end\n")
      write("lib/workspace/b.rb", "class Twin; end\n")
      write("lib/workspace/user.rb", "Twin.new\n")

      expect(scan.ambiguous).to include("Twin" => ["lib/workspace/a.rb", "lib/workspace/b.rb"])
      expect(scan.references_from("lib/workspace/user.rb")).to eq([])
    end

    it "ignores a file's reference to itself" do
      expect(scan.references.select { |r| r.file == "lib/workspace/commands/inbox.rb" }).to eq([])
    end
  end

  describe ".process_literals" do
    def found(source) = BoundaryScan.process_literals(source).map { |l| [l.line, l.tool, l.form] }

    it "finds git, tmux and gh as the program of a spawn call, with or without an env Hash" do
      source = "Open3.capture3(\"git\", \"x\")\nOpen3.popen3(env, \"tmux\", *a) { }\nsystem \"gh\", \"b\"\nProcess.spawn(env, \"git\")\n"

      expect(found(source)).to eq([[1, "git", :spawn], [2, "tmux", :spawn], [3, "gh", :spawn], [4, "git", :spawn]])
    end

    it "finds an array opening with the tool, and a backtick command" do
      expect(found("x = [\"tmux\", \"a\"]\n`git status`\n")).to eq([[1, "tmux", :array], [2, "git", :backtick]])
    end

    it "finds a gh literal opening any call, but not git or tmux there" do
      expect(found("a.call(\"gh\", 1)\nb.call(\"git\", 1)\nc(\"tmux\")\n")).to eq([[1, "gh", :call]])
    end

    it "skips comments, other programs, an index, a later argument and a method named spawn" do
      source = "# system \"git\"\nOpen3.capture3(\"which\", \"git\")\nh[\"git\"]\nfoo(1, \"gh\")\ndef spawn(x) = x\nputs \"git status\"\n"

      expect(found(source)).to eq([])
    end
  end
end
