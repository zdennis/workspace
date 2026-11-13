require "spec_helper"
require "tmpdir"

# Workspace::Tmux's reads of a tmuxinator config and its session-name rule, which start no process.
RSpec.describe Workspace::Tmux do
  around do |example|
    Dir.mktmpdir("tmux-session-name") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:config) { instance_double(Workspace::Config) }
  let(:tmux) { described_class.new(config: config) }

  def name_from(text)
    path = File.join(@dir, "ws.yml")
    File.write(path, text)
    allow(config).to receive(:config_path_for).with("ws").and_return(path)
    tmux.session_name_for("ws")
  end

  describe "#session_name_for" do
    it "reads the name: line as YAML, dropping quotes and a trailing comment" do
      expect(name_from("name: plain\nroot: /tmp\n")).to eq("plain")
      expect(name_from("name: \"quoted\"\n")).to eq("quoted")
      expect(name_from("name: 'single' # the session\n")).to eq("single")
      expect(name_from("name: foo # a comment\n")).to eq("foo")
      expect(name_from("name: 2024\n")).to eq("2024")
      expect(name_from("name: foo.js\n")).to eq("foo.js")
    end

    it "keeps the text after name: for a line that is not YAML on its own" do
      expect(name_from("name: \"unbalanced\n")).to eq("\"unbalanced")
      expect(name_from("name: <%= ENV['X'] %>\n")).to eq("<%= ENV['X'] %>")
    end

    it "answers the config name with no name: line or no file" do
      expect(name_from("root: /tmp\n")).to eq("ws")
      allow(config).to receive(:config_path_for).with("gone").and_return(File.join(@dir, "gone.yml"))
      expect(tmux.session_name_for("gone")).to eq("gone")
    end
  end

  describe ".stored_session_name" do
    it "turns each . and : into _, as tmux does" do
      expect(described_class.stored_session_name("foo.js")).to eq("foo_js")
      expect(described_class.stored_session_name("a:b.worktree-c")).to eq("a_b_worktree-c")
      expect(described_class.stored_session_name("plain")).to eq("plain")
    end
  end
end
