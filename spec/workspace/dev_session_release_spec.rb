require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe Workspace::DevSessionRelease do
  let(:tmpdir) { Dir.mktmpdir("ws-dev-session-release") }
  let(:lock_dir) { File.join(tmpdir, "locks") }
  let(:config) { instance_double(Workspace::Config, lock_dir: lock_dir, state_dir: File.join(tmpdir, "state")) }
  let(:spawned) { [] }
  let(:spawner) { ->(argv, cwd, log) { spawned << [argv, cwd, log] } }
  let(:release) { described_class.new(config: config, executable: "/ws/bin/workspace", spawner: spawner) }

  after { FileUtils.remove_entry(tmpdir) }

  def write_locks(namespace, data)
    FileUtils.mkdir_p(File.join(lock_dir, namespace))
    File.write(File.join(lock_dir, namespace, "locks.json"), JSON.generate(data))
  end

  def devenv_started_by(session)
    {"devenv" => {"holder" => {"kind" => "process", "pid" => 5, "started_by" => {"session_id" => session, "pane" => "%1"}}, "queue" => []}}
  end

  it "starts a detached `dev __release` in the session's directory when a lock names the session" do
    write_locks("repo-a", devenv_started_by("sess-1"))

    expect(release.call(session_id: "sess-1", cwd: tmpdir, reason: "prompt_input_exit")).to be(true)

    expect(spawned).to eq([[[RbConfig.ruby, "/ws/bin/workspace", "dev", "__release", "sess-1"], tmpdir, File.join(tmpdir, "state", "dev-release.log")]])
  end

  it "finds the session in any namespace" do
    write_locks("repo-a", devenv_started_by("sess-9"))
    write_locks("repo-b", devenv_started_by("sess-1"))

    expect(release.call(session_id: "sess-1", cwd: tmpdir, reason: "logout")).to be(true)
  end

  it "never releases on a clear, even when a lock names the session" do
    write_locks("repo-a", devenv_started_by("sess-1"))

    expect(release.call(session_id: "sess-1", cwd: tmpdir, reason: "clear")).to be(false)
    expect(spawned).to be_empty
  end

  describe "a recovery stop" do
    let(:marker) { Workspace::RecoveryStopMarker.new(state_dir: File.join(tmpdir, "state")) }

    before { write_locks("repo-a", devenv_started_by("sess-1")) }

    it "starts no release while the session is marked, and one again once cleared" do
      marker.mark("sess-1")
      expect(release.call(session_id: "sess-1", cwd: tmpdir, reason: "prompt_input_exit")).to be(false)
      expect(spawned).to be_empty

      marker.clear("sess-1")
      expect(release.call(session_id: "sess-1", cwd: tmpdir, reason: "prompt_input_exit")).to be(true)
    end

    it "releases when the marker is stale" do
      marker.mark("sess-1")
      old = Time.now - Workspace::RecoveryStopMarker::MAX_AGE - 5
      File.utime(old, old, File.join(tmpdir, "state", "agent-recovery", "stopping", "sess-1"))

      expect(release.call(session_id: "sess-1", cwd: tmpdir, reason: "logout")).to be(true)
    end

    it "marks only the one session" do
      marker.mark("sess-2")

      expect(release.call(session_id: "sess-1", cwd: tmpdir, reason: "logout")).to be(true)
    end

    it "still never releases on a clear" do
      expect(release.call(session_id: "sess-1", cwd: tmpdir, reason: "clear")).to be(false)
    end
  end

  it "starts nothing when no lock names
 the session, there is no lock directory, or there is no session id" do
    expect(release.call(session_id: "sess-1", cwd: tmpdir, reason: "logout")).to be(false)

    write_locks("repo-a", devenv_started_by("sess-9"))
    expect(release.call(session_id: "sess-1", cwd: tmpdir, reason: "logout")).to be(false)
    expect(release.call(session_id: nil, cwd: tmpdir, reason: "logout")).to be(false)
    expect(release.call(session_id: "", cwd: tmpdir, reason: "logout")).to be(false)
    expect(spawned).to be_empty
  end

  it "uses the current directory when the session's own is gone" do
    write_locks("repo-a", devenv_started_by("sess-1"))

    release.call(session_id: "sess-1", cwd: File.join(tmpdir, "gone"), reason: "logout")

    expect(spawned.first[1]).to eq(Dir.pwd)
  end

  it "skips an unreadable lock file without raising" do
    FileUtils.mkdir_p(File.join(lock_dir, "repo-a", "locks.json"))
    write_locks("repo-b", devenv_started_by("sess-1"))

    expect(release.call(session_id: "sess-1", cwd: tmpdir, reason: "logout")).to be(true)
  end

  it "does not raise when the process cannot be started" do
    write_locks("repo-a", devenv_started_by("sess-1"))
    failing = described_class.new(config: config, executable: "/x", spawner: ->(*) { raise Errno::ENOENT })

    expect(failing.call(session_id: "sess-1", cwd: tmpdir, reason: "logout")).to be(false)
  end
end
