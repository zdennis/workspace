RSpec.describe Workspace::Config do
  describe "default paths" do
    subject(:config) { described_class.new }

    it "returns the workspace installation directory" do
      expect(config.workspace_dir).to eq(File.expand_path("../..", __dir__))
    end

    it "returns the built-in library directory inside the installation, and honours a workspace_dir override" do
      expect(config.builtin_library_dir).to eq(File.join(File.expand_path("../..", __dir__), "lib", "library"))
      expect(described_class.new(workspace_dir: "/opt/ws").builtin_library_dir).to eq("/opt/ws/lib/library")
    end

    it "returns the run directory without creating it" do
      expect(config.run_dir).to eq(File.expand_path("~/.local/workspace/run"))
    end

    it "returns the tmuxinator config directory" do
      expect(config.tmuxinator_dir).to eq(File.expand_path("~/.config/tmuxinator"))
    end

    it "returns the state file path" do
      expect(config.state_file).to eq(File.expand_path("~/.workspace-state.json"))
    end

    it "returns the project template path" do
      expect(config.project_template_path).to eq(
        File.join(File.expand_path("~/.config/tmuxinator"), "workspace.project-template.yml")
      )
    end

    it "returns the worktree template path" do
      expect(config.worktree_template_path).to eq(
        File.join(File.expand_path("~/.config/tmuxinator"), "workspace.project-worktree-template.yml")
      )
    end

    it "returns the window-tool binary name" do
      expect(config.window_tool).to eq("window-tool")
    end
  end

  describe "custom workspace_dir" do
    it "propagates the custom directory" do
      config = described_class.new(workspace_dir: "/tmp/custom-workspace")
      expect(config.workspace_dir).to eq("/tmp/custom-workspace")
    end
  end

  describe "#config_path_for" do
    subject(:config) { described_class.new }

    it "builds the expected config file path" do
      expect(config.config_path_for("my-project")).to eq(
        File.join(File.expand_path("~/.config/tmuxinator"), "workspace.my-project.yml")
      )
    end
  end

  describe "#run_results_dir" do
    subject(:config) { described_class.new }

    it "returns the run results directory path" do
      expect(config.run_results_dir).to eq(File.expand_path("~/.workspace-runs"))
    end
  end

  describe "#run_result_path" do
    subject(:config) { described_class.new }

    it "builds the expected path for a uuid" do
      expect(config.run_result_path("abc-123")).to eq(
        File.join(File.expand_path("~/.workspace-runs"), "abc-123.json")
      )
    end
  end

  describe "#run_stdout_path" do
    subject(:config) { described_class.new }

    it "builds the expected path for a uuid" do
      expect(config.run_stdout_path("abc-123")).to eq(
        File.join(File.expand_path("~/.workspace-runs"), "abc-123.stdout")
      )
    end
  end

  describe "#run_stderr_path" do
    subject(:config) { described_class.new }

    it "builds the expected path for a uuid" do
      expect(config.run_stderr_path("abc-123")).to eq(
        File.join(File.expand_path("~/.workspace-runs"), "abc-123.stderr")
      )
    end
  end
  describe "#pipeline_state_path" do
    subject(:config) { described_class.new }

    it "puts a project's state under the XDG state directory" do
      expect(config.pipeline_state_path("myapp")).to eq(
        File.join(File.expand_path("~/.local/state"), "workspace", "myapp", "pipeline.json")
      )
    end

    it "honours XDG_STATE_HOME when it is set" do
      allow(ENV).to receive(:fetch).with("XDG_STATE_HOME", "~/.local/state").and_return("/custom/state")

      expect(config.pipeline_state_dir("myapp")).to eq("/custom/state/workspace/myapp")
    end
  end

  describe "#state_dir" do
    subject(:config) { described_class.new }

    it "defaults to ~/.local/state/workspace" do
      expect(config.state_dir).to eq(File.join(File.expand_path("~/.local/state"), "workspace"))
    end

    it "honours XDG_STATE_HOME when it is set" do
      allow(ENV).to receive(:fetch).with("XDG_STATE_HOME", "~/.local/state").and_return("/custom/state")

      expect(config.state_dir).to eq("/custom/state/workspace")
    end
  end

  describe "#lock_dir" do
    subject(:config) { described_class.new }

    it "puts lock stores under the state directory" do
      expect(config.lock_dir).to eq(File.join(config.state_dir, "locks"))
    end
  end

  describe "#workflow_runs_dir" do
    it "sits under a dotted directory of the state dir, where no workspace name can be" do
      config = described_class.new

      expect(config.workflow_runs_dir).to eq(File.join(config.state_dir, ".workflows", "runs"))
      expect(Workspace::WorkspaceLineage.name_from_path("/src/.workflows")).to eq("workflows")
    end
  end

  describe "#task_dir" do
    it "is a dotted directory under the state directory, which no workspace's state directory can be" do
      config = described_class.new

      expect(config.task_dir).to eq(File.join(config.state_dir, ".tasks"))
      expect(Workspace::WorkspaceLineage.name_from_path("/src/.tasks")).to eq("tasks")
    end
  end

  describe "length-capped agent runtime paths" do
    subject(:config) { described_class.new }

    let(:socket_dir) { Dir.mktmpdir }

    before do
      allow(config).to receive(:socket_dir).and_return(socket_dir)
    end

    after do
      FileUtils.rm_rf(socket_dir)
    end

    it "leaves a short name's socket path unhashed" do
      expect(config.agent_socket_path("myapp")).to eq(
        File.join(socket_dir, "workspace-myapp.sock")
      )
    end

    it "leaves a short name's log path unhashed" do
      expect(config.agent_log_path("myapp")).to eq(
        File.join(socket_dir, "workspace-myapp.log")
      )
    end

    it "puts the startup lock beside the socket and log" do
      expect(config.agent_lock_path("myapp")).to eq(File.join(socket_dir, "workspace-myapp.lock"))
    end

    it "caps a long name's socket path at the byte limit" do
      path = config.agent_socket_path("a" * 200)

      expect(path.bytesize).to be <= described_class::MAX_SOCKET_PATH_BYTES
      expect(path).to start_with(File.join(socket_dir, "workspace-"))
    end

    it "caps a long name's log filename component at the byte limit" do
      path = config.agent_log_path("a" * 300)

      expect(File.basename(path).bytesize).to be <= described_class::MAX_LOG_PATH_BYTES
      expect(path).to start_with(File.join(socket_dir, "workspace-"))
    end

    it "caps a long name's lock filename component at the byte limit" do
      path = config.agent_lock_path("a" * 300)

      expect(File.basename(path).bytesize).to be <= described_class::MAX_LOG_PATH_BYTES
      expect(path).to end_with(".lock")
    end

    it "keeps distinct long names on distinct socket paths" do
      long_a = "a" * 200
      long_b = "b" * 200

      expect(config.agent_socket_path(long_a)).not_to eq(config.agent_socket_path(long_b))
    end

    it "keeps distinct long names on distinct log paths" do
      long_a = "a" * 300
      long_b = "b" * 300

      expect(config.agent_log_path(long_a)).not_to eq(config.agent_log_path(long_b))
    end

    it "leaves a name at exactly the socket byte limit unhashed" do
      name_length = described_class::MAX_SOCKET_PATH_BYTES - socket_dir.bytesize -
        1 - "workspace-".bytesize - ".sock".bytesize
      name = "a" * name_length

      expect(config.agent_socket_path(name)).to eq(
        File.join(socket_dir, "workspace-#{name}.sock")
      )
    end

    it "hashes a name one byte past the socket byte limit" do
      name_length = described_class::MAX_SOCKET_PATH_BYTES - socket_dir.bytesize -
        1 - "workspace-".bytesize - ".sock".bytesize
      name = "a" * name_length + "b"

      literal = File.join(socket_dir, "workspace-#{name}.sock")
      expect(config.agent_socket_path(name)).not_to eq(literal)
      expect(config.agent_socket_path(name).bytesize).to be <= described_class::MAX_SOCKET_PATH_BYTES
    end

    it "truncates a multibyte name to a valid-encoding path that still binds" do
      name = "項目" * 60
      path = config.agent_socket_path(name)

      expect(path.bytesize).to be <= described_class::MAX_SOCKET_PATH_BYTES
      expect(path).to be_valid_encoding

      server = UNIXServer.new(path)
      begin
        expect(File.socket?(path)).to be true
      ensure
        server.close
        File.delete(path)
      end
    end

    it "raises when the socket dir is too deep for any capped socket path" do
      allow(config).to receive(:socket_dir).and_return("/" + "d" * 100)

      expect { config.agent_socket_path("myapp") }.to raise_error(
        Workspace::Error, /socket dir is too deep/
      )
    end

    it "caps only the log filename component, however deep the socket dir" do
      allow(config).to receive(:socket_dir).and_return("/" + "d" * 100)

      expect(config.agent_log_path("myapp")).to eq(
        File.join("/" + "d" * 100, "workspace-myapp.log")
      )
    end

    it "suffixes a truncated path with a deterministic hash of the name" do
      name = "a" * 200
      path = config.agent_socket_path(name)

      expect(path).to end_with("-#{Digest::SHA256.hexdigest(name)[0, 10]}.sock")
    end

    it "maps the same name to the same path across instances" do
      other = described_class.new
      allow(other).to receive(:socket_dir).and_return(socket_dir)
      name = "a" * 200

      expect(other.agent_socket_path(name)).to eq(config.agent_socket_path(name))
    end

    it "binds a real Unix server on a capped path" do
      path = config.agent_socket_path("a" * 200)
      server = UNIXServer.new(path)

      begin
        expect(File.socket?(path)).to be true
      ensure
        server.close
        File.delete(path)
      end
    end
  end

  describe "#agent_running?" do
    subject(:config) { described_class.new }

    it "returns false when no socket is listening" do
      expect(config.agent_running?("workspace-spec-not-running")).to be false
    end

    it "returns true when a socket is listening" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "w-ar.sock")
        server = UNIXServer.new(path)
        begin
          allow(config).to receive(:agent_socket_path).with("myapp").and_return(path)

          expect(config.agent_running?("myapp")).to be true
        ensure
          server.close
          File.delete(path)
        end
      end
    end

    it "returns false rather than raising when the socket path is too long" do
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/" + "a" * 200)

      expect(config.agent_running?("myapp")).to be false
    end
  end
end
