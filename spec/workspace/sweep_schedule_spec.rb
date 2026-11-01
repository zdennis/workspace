require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::SweepSchedule do
  around do |example|
    Dir.mktmpdir("sweep-schedule") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:agents_dir) { File.join(@dir, "Library", "LaunchAgents") }
  let(:plist_path) { File.join(agents_dir, "com.workspace.workflow-sweep.plist") }
  let(:program) { File.join(@dir, "a&b", "bin", "workspace") }
  let(:calls) { [] }
  let(:loaded) { [false] }
  let(:fail_step) { [] }
  let(:print_answer) { [] }
  let(:launchctl) do
    lambda do |args|
      calls << args
      next ["boom", 5] if fail_step.include?(args.first)
      case args.first
      when "print"
        next print_answer if print_answer.any?
        loaded.first ? ["ok", 0] : ["Could not find service", 1]
      when "bootstrap"
        loaded[0] = true
        ["", 0]
      when "bootout"
        loaded[0] = false
        ["", 0]
      end
    end
  end
  let(:source) { instance_double(Workspace::SkillSource, executable: program) }
  let(:tmux) { "/opt/homebrew/bin/tmux" }
  let(:ruby) { "/usr/local/ruby/bin/ruby" }
  let(:schedule) do
    described_class.new(agents_dir: agents_dir, launchctl: launchctl, source: source, ruby: ruby,
      which: ->(name) { (name == "tmux") ? tmux : nil }, uid: 501)
  end

  def mutating
    calls.map(&:first) - ["print"]
  end

  def error_of
    yield
    nil
  rescue Workspace::Error => e
    e
  end

  it "writes an escaped plist with absolute paths and a PATH holding ruby and tmux, then loads it" do
    row = schedule.install
    text = File.read(plist_path)
    expect(row).to include("outcome" => "installed")
    expect(text).to include("<string>#{ruby}</string>", "<string>#{@dir}/a&amp;b/bin/workspace</string>")
    expect(text).to include("<integer>300</integer>", "<string>/usr/local/ruby/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>")
    expect(text.lines[2].chomp).to eq(described_class::MARKER)
    expect(text.scan(File::NULL).size).to eq(2)
    expect(calls).to include(["bootstrap", "gui/501", plist_path])
  end

  it "rewrites a Cellar ruby to its opt path when that exists" do
    cellar = File.join(@dir, "brew", "Cellar", "ruby", "3.4.0", "bin", "ruby")
    opt = File.join(@dir, "brew", "opt", "ruby", "bin", "ruby")
    FileUtils.mkdir_p(File.dirname(opt))
    File.write(opt, "")
    described_class.new(agents_dir: agents_dir, launchctl: launchctl, source: source, ruby: cellar, which: ->(_) {}, uid: 501).install
    expect(File.read(plist_path)).to include("<string>#{opt}</string>").and(satisfy { |text| !text.include?("Cellar") })
  end

  it "changes nothing the second time" do
    schedule.install
    calls.clear
    expect(schedule.install).to include("outcome" => "unchanged")
    expect(mutating).to be_empty
  end

  it "removes stray temp files at install" do
    FileUtils.mkdir_p(agents_dir)
    File.write("#{plist_path}.tmp123", "x")
    schedule.install
    expect(Dir.glob("#{plist_path}.tmp*")).to be_empty
  end

  describe "a launchctl failure" do
    it "after the plist was written is retryable and a retry loads it" do
      fail_step << "bootstrap"
      error = error_of { schedule.install }
      expect(error.code).to eq("sweep_launchctl_failed")
      expect(error.details).to include("plist_written" => true, "step" => "bootstrap")
      expect(error.retry).to eq("flags" => [], "destructive" => false)
      expect(error.message).to include("gui/501")
      fail_step.clear
      expect(schedule.install).to include("outcome" => "loaded")
      expect(loaded.first).to be(true)
    end

    it "writes nothing when launchctl cannot run (the status check fails first)" do
      schedule = described_class.new(agents_dir: agents_dir, launchctl: ->(_) { raise Errno::ENOENT }, source: source, ruby: ruby, which: ->(_) {}, uid: 1)
      expect(error_of { schedule.install }.code).to eq("sweep_launchctl_failed")
      expect(File.exist?(plist_path)).to be(false)
    end

    it "is not read as 'not loaded' when the status check times out or fails oddly" do
      print_answer.replace(["timed out", nil])
      expect(error_of { schedule.install }.details).to include("step" => "print")
      expect(File.exist?(plist_path)).to be(false)
      print_answer.replace(["Bootstrap failed", 5])
      expect(error_of { schedule.uninstall }.code).to eq("sweep_launchctl_failed")
    end

    it "installing over a plist that changed, while not loaded, writes and loads" do
      schedule.install
      loaded[0] = false
      File.write(plist_path, File.read(plist_path).sub("300", "600"))
      calls.clear
      expect(schedule.install).to include("outcome" => "updated")
      expect(mutating).to eq(%w[bootstrap])
    end

    it "stops before writing when the boot-out of an update fails" do
      schedule.install
      changed = File.read(plist_path).sub("300", "600")
      File.write(plist_path, changed)
      fail_step << "bootout"
      expect(error_of { schedule.install }.details).to include("step" => "bootout")
      expect(File.read(plist_path)).to eq(changed)
    end

    it "reports a plist that cannot be written" do
      FileUtils.mkdir_p(agents_dir)
      FileUtils.chmod(0o500, agents_dir)
      error = error_of { schedule.install }
      FileUtils.chmod(0o700, agents_dir)
      expect(error.details).to include("step" => "write", "plist_written" => false) unless Process.uid.zero?
    end
  end

  it "unloads, rewrites and reloads when the plist differs" do
    schedule.install
    File.write(plist_path, File.read(plist_path).sub("300", "600"))
    calls.clear
    expect(schedule.install).to include("outcome" => "updated")
    expect(mutating).to eq(%w[bootout bootstrap])
  end

  describe "ownership" do
    def foreign(text)
      FileUtils.mkdir_p(agents_dir)
      File.write(plist_path, text)
    end

    it "leaves a plist it did not write alone" do
      foreign("<plist>mine</plist>")
      expect(error_of { schedule.install }.code).to eq("sweep_entry_foreign")
      expect(error_of { schedule.uninstall }.code).to eq("sweep_entry_foreign")
      expect(File.read(plist_path)).to eq("<plist>mine</plist>")
      expect(mutating).to be_empty
    end

    it "refuses a plist that only quotes the marker and label" do
      foreign("<!-- #{described_class::MARKER} -->\n<string>#{described_class::LABEL}</string>\n")
      expect(error_of { schedule.uninstall }.code).to eq("sweep_entry_foreign")
      expect(mutating).to be_empty
    end

    it "refuses our marker and label with another command" do
      schedule.install
      File.write(plist_path, File.read(plist_path).sub("<string>sweep</string>", "<string>nuke</string>"))
      expect(error_of { schedule.uninstall }.code).to eq("sweep_entry_foreign")
    end

    it "refuses a program that is not bin/workspace" do
      schedule.install
      File.write(plist_path, File.read(plist_path).sub("bin/workspace</string>", "bin/other</string>"))
      expect(error_of { schedule.uninstall }.code).to eq("sweep_entry_foreign")
    end

    it "refuses when the Label key holds another label" do
      schedule.install
      File.write(plist_path, File.read(plist_path).sub("<string>#{described_class::LABEL}</string>", "<string>x.y</string>"))
      expect(error_of { schedule.uninstall }.code).to eq("sweep_entry_foreign")
    end
  end

  it "passes the source's refusal through and writes nothing" do
    allow(source).to receive(:executable).and_raise(Workspace::Error.new("x", code: "sweep_source_worktree"))
    expect(error_of { schedule.install }.code).to eq("sweep_source_worktree")
    expect(File.exist?(plist_path)).to be(false)
  end

  it "does nothing under dry_run" do
    expect(schedule.install(dry_run: true)).to include("outcome" => "dry_run", "action" => "write and load")
    expect(File.exist?(plist_path)).to be(false)
    expect(mutating).to be_empty
  end

  describe "#uninstall" do
    it "boots out, deletes, and is quiet when nothing is there" do
      schedule.install
      expect(schedule.uninstall).to include("outcome" => "removed")
      expect(File.exist?(plist_path)).to be(false)
      expect(schedule.uninstall).to include("outcome" => "unchanged")
    end

    it "deletes a plist whose job is not loaded, without a boot-out" do
      schedule.install
      loaded[0] = false
      calls.clear
      expect(schedule.uninstall).to include("outcome" => "removed")
      expect(mutating).to be_empty
    end

    it "boots out a loaded job whose plist is gone" do
      schedule.install
      File.delete(plist_path)
      calls.clear
      expect(schedule.uninstall).to include("outcome" => "removed")
      expect(mutating).to eq(%w[bootout])
    end

    it "changes nothing under dry_run" do
      schedule.install
      calls.clear
      expect(schedule.uninstall(dry_run: true)).to include("outcome" => "dry_run")
      expect(File.exist?(plist_path)).to be(true)
      expect(mutating).to be_empty
    end

    it "keeps the plist when the boot-out fails, so a retry can finish" do
      schedule.install
      fail_step << "bootout"
      error = error_of { schedule.uninstall }
      expect(error.code).to eq("sweep_launchctl_failed")
      expect(error.retry).to eq("flags" => [], "destructive" => false)
      expect(File.exist?(plist_path)).to be(true)
    end
  end

  describe "#status" do
    it "reports without changing anything" do
      expect(schedule.status).to include("outcome" => "not_installed", "installed" => false, "message" => "No sweep entry is installed.")
      schedule.install
      calls.clear
      status = schedule.status
      expect(status).to include("outcome" => "installed", "ours" => true, "loaded" => true, "up_to_date" => true, "interval" => 300, "ruby" => ruby, "program" => program)
      expect(status["stale"]).to eq([ruby, program])
      expect(mutating).to be_empty
    end

    it "lists no stale paths when they exist" do
      FileUtils.mkdir_p(File.dirname(program))
      File.write(program, "")
      real_ruby = File.join(@dir, "ruby")
      File.write(real_ruby, "")
      described_class.new(agents_dir: agents_dir, launchctl: launchctl, source: source, ruby: real_ruby, which: ->(_) {}, uid: 501).install
      expect(schedule.status["stale"]).to eq([])
    end

    it "says a present plist is not loaded" do
      schedule.install
      loaded[0] = false
      expect(schedule.status).to include("loaded" => false, "message" => "The sweep entry is installed but not loaded.")
    end

    it "says a loaded job has no plist" do
      schedule.install
      File.delete(plist_path)
      expect(schedule.status).to include("outcome" => "not_installed", "installed" => false, "loaded" => true)
      expect(schedule.status["message"]).to include("still has the job loaded")
    end

    it "marks a foreign plist, and does not raise when launchctl cannot answer" do
      FileUtils.mkdir_p(agents_dir)
      File.write(plist_path, "<plist/>")
      print_answer.replace(["timed out", nil])
      expect(schedule.status).to include("ours" => false, "loaded" => nil, "up_to_date" => nil)
    end

    it "says up_to_date false when the plist differs" do
      schedule.install
      File.write(plist_path, File.read(plist_path).sub("300", "600"))
      expect(schedule.status).to include("up_to_date" => false)
    end
  end
end
