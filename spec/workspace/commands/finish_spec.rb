require "tmpdir"
require "yaml"
require "json"

RSpec.describe Workspace::Commands::Finish do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:git) { double("git") }
  let(:project_config) { double("project_config") }
  let(:kill_command) { double("kill_command") }
  let(:project_detector) { Workspace::ProjectDetector.new(state: CLITestHelpers::FakeState.new, project_config: project_config) }

  subject(:command) do
    described_class.new(
      git: git,
      project_config: project_config,
      kill_command: kill_command,
      project_detector: project_detector,
      output: output,
      error_output: error_output,
      input: input
    )
  end

  after { FileUtils.remove_entry(tmpdir) }

  let(:config_path) { File.join(tmpdir, "workspace.myproject.worktree-PROJ-123.yml") }
  let(:worktree_path) { "/path/to/worktree" }

  before do
    allow(project_config).to receive(:config_path_for)
      .with("myproject.worktree-PROJ-123")
      .and_return(config_path)
  end

  describe "#call" do
    it "raises error when config not found" do
      expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
        Workspace::Error, /No config found/
      )
    end

    context "with existing config" do
      before do
        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => worktree_path))
      end

      it "raises error when not a worktree project" do
        allow(git).to receive(:worktree_exists?).with(worktree_path).and_return(false)

        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /does not appear to be a worktree project/
        )
      end

      context "with a valid worktree" do
        before do
          allow(git).to receive(:worktree_exists?).with(worktree_path).and_return(true)
        end

        it "raises when there are changed tracked files" do
          allow(git).to receive(:changed_files_count).with(worktree_path).and_return(3)
          expect(kill_command).not_to receive(:call)

          expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
            Workspace::Error, /3 changed file\(s\)/
          )
        end

        it "raises when git cannot check status" do
          allow(git).to receive(:changed_files_count).with(worktree_path).and_return(nil)

          expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
            Workspace::Error, /couldn't read its status/
          )
        end

        context "when clean" do
          before do
            allow(git).to receive(:changed_files_count).with(worktree_path).and_return(0)
            allow(git).to receive(:worktree_branch).with(worktree_path).and_return("feature/x")
          end

          it "tells the user to check out a branch when HEAD is detached" do
            allow(git).to receive(:worktree_branch).with(worktree_path).and_return(nil)
            expect(kill_command).not_to receive(:call)

            expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
              Workspace::Error, /detached HEAD.*Check out a branch first/m
            )
          end

          it "raises when the branch has no upstream, with a push hint" do
            allow(git).to receive(:upstream_branch).with(worktree_path).and_return(nil)
            expect(kill_command).not_to receive(:call)

            expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
              Workspace::Error, /push -u origin feature\/x/
            )
          end

          context "with an upstream" do
            before do
              allow(git).to receive(:upstream_branch).with(worktree_path).and_return("origin/feature/x")
            end

            it "raises when ahead of the upstream" do
              allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(2)
              expect(kill_command).not_to receive(:call)

              expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
                Workspace::Error, /2 commit\(s\) ahead of origin\/feature\/x/
              )
            end

            it "raises when git cannot compare with the upstream" do
              allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(nil)

              expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
                Workspace::Error, /couldn't compare/
              )
            end

            it "reports unsaved work Kill finds at removal time without suggesting --force" do
              allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(0)
              unsaved = {changed_files: 1, unpushed_commits: 0, branch: "feature/x"}
              allow(kill_command).to receive(:call)
                .and_raise(Workspace::UnsavedWorkError.new("rerun with --force", unsaved: unsaved))

              expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(Workspace::Error) { |e|
                expect(e.message).to include("1 changed file(s) and 0 unpushed commit(s) on feature/x")
                expect(e.message).not_to include("--force")
              }
            end

            it "passes quiet: true to Kill under --json" do
              allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(0)
              expect(kill_command).to receive(:call).with("myproject.worktree-PROJ-123", confirm: false, quiet: true, working_dir: tmpdir)

              command.call("myproject.worktree-PROJ-123", json: true, working_dir: tmpdir)
            end

            it "reuses Kill for cleanup when clean and pushed" do
              allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(0)
              expect(kill_command).to receive(:call).with("myproject.worktree-PROJ-123", confirm: false, quiet: false, working_dir: tmpdir)

              result = command.call("myproject.worktree-PROJ-123", working_dir: tmpdir)
              expect(result).to eq("myproject.worktree-PROJ-123")
            end

            it "has no override to skip the clean/pushed check" do
              expect(command.method(:call).parameters.map(&:last)).not_to include(:discard_unpushed)
            end

            context "with --pr" do
              before do
                allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(0)
                allow(kill_command).to receive(:call)
              end

              it "skips PR creation with a note when gh is missing" do
                allow(Open3).to receive(:capture3).with("which", "gh").and_return(["", "", instance_double(Process::Status, success?: false)])

                command.call("myproject.worktree-PROJ-123", pr: true, working_dir: tmpdir)

                expect(output.string).to include("gh is not installed")
                expect(kill_command).to have_received(:call)
              end

              it "reuses an existing PR without creating a new one" do
                allow(Open3).to receive(:capture3).with("which", "gh").and_return(["/usr/bin/gh", "", instance_double(Process::Status, success?: true)])
                allow(git).to receive(:worktree_branch).with(worktree_path).and_return("feature/x")
                allow(Open3).to receive(:capture3).with("gh", "pr", "view", "feature/x", "--json", "url", chdir: worktree_path)
                  .and_return([JSON.generate({"url" => "https://github.com/org/repo/pull/1"}), "", instance_double(Process::Status, success?: true)])

                command.call("myproject.worktree-PROJ-123", pr: true, working_dir: tmpdir)

                expect(output.string).to include("https://github.com/org/repo/pull/1")
                expect(kill_command).to have_received(:call)
              end

              it "creates a PR when none exists" do
                allow(Open3).to receive(:capture3).with("which", "gh").and_return(["/usr/bin/gh", "", instance_double(Process::Status, success?: true)])
                allow(git).to receive(:worktree_branch).with(worktree_path).and_return("feature/x")
                allow(Open3).to receive(:capture3).with("gh", "pr", "view", "feature/x", "--json", "url", chdir: worktree_path)
                  .and_return(["", "no pr found", instance_double(Process::Status, success?: false)])
                allow(Open3).to receive(:capture3).with("gh", "pr", "create", "--fill", chdir: worktree_path)
                  .and_return(["https://github.com/org/repo/pull/2", "", instance_double(Process::Status, success?: true)])

                command.call("myproject.worktree-PROJ-123", pr: true, working_dir: tmpdir)

                expect(output.string).to include("https://github.com/org/repo/pull/2")
                expect(kill_command).to have_received(:call)
              end

              it "raises and does not clean up when gh pr create fails" do
                allow(Open3).to receive(:capture3).with("which", "gh").and_return(["/usr/bin/gh", "", instance_double(Process::Status, success?: true)])
                allow(git).to receive(:worktree_branch).with(worktree_path).and_return("feature/x")
                allow(Open3).to receive(:capture3).with("gh", "pr", "view", "feature/x", "--json", "url", chdir: worktree_path)
                  .and_return(["", "no pr found", instance_double(Process::Status, success?: false)])
                allow(Open3).to receive(:capture3).with("gh", "pr", "create", "--fill", chdir: worktree_path)
                  .and_return(["", "gh: not authenticated", instance_double(Process::Status, success?: false)])

                expect { command.call("myproject.worktree-PROJ-123", pr: true, working_dir: tmpdir) }.to raise_error(
                  Workspace::Error, /not authenticated/
                )
                expect(kill_command).not_to have_received(:call)
              end
            end
          end
        end
      end
    end

    context "with marker file auto-detection" do
      it "detects project from .workspace-project in current directory" do
        marker_dir = File.join(tmpdir, "worktree-dir")
        Dir.mkdir(marker_dir)
        File.write(File.join(marker_dir, ".workspace-project"), "myproject.worktree-PROJ-123")

        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => worktree_path))
        allow(git).to receive(:worktree_exists?).with(worktree_path).and_return(true)
        allow(git).to receive(:changed_files_count).with(worktree_path).and_return(0)
        allow(git).to receive(:worktree_branch).with(worktree_path).and_return("main")
        allow(git).to receive(:upstream_branch).with(worktree_path).and_return("origin/main")
        allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(0)
        allow(kill_command).to receive(:call)

        command.call(nil, working_dir: marker_dir)

        expect(kill_command).to have_received(:call).with("myproject.worktree-PROJ-123", confirm: false, quiet: false, working_dir: marker_dir)
      end

      it "raises error when no marker file found and no project given" do
        expect { command.call(nil, working_dir: tmpdir) }.to raise_error(
          Workspace::Error, /No project specified/
        )
      end
    end

    context "with corrupt config" do
      before { File.write(config_path, "{{invalid yaml") }

      it "raises a friendly error" do
        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /Corrupt config file/
        )
      end
    end

    context "with a config containing a disallowed YAML class" do
      before { File.write(config_path, "root: !ruby/object {}\n") }

      it "raises a friendly error instead of Psych::DisallowedClass" do
        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /Corrupt config file/
        )
      end
    end

    context "with --json" do
      before do
        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => worktree_path))
        allow(git).to receive(:worktree_exists?).with(worktree_path).and_return(true)
      end

      it "emits a success envelope on stdout and exit_code 0" do
        allow(git).to receive(:changed_files_count).with(worktree_path).and_return(0)
        allow(git).to receive(:worktree_branch).with(worktree_path).and_return("main")
        allow(git).to receive(:upstream_branch).with(worktree_path).and_return("origin/main")
        allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(0)
        allow(kill_command).to receive(:call)

        result = command.call("myproject.worktree-PROJ-123", json: true, working_dir: tmpdir)

        expect(result).to eq({exit_code: 0})
        parsed = JSON.parse(output.string)
        expect(parsed).to eq({"schema_version" => 1, "project" => "myproject.worktree-PROJ-123"})
      end

      it "emits an error envelope on stdout and exit_code 1, without raising" do
        allow(git).to receive(:changed_files_count).with(worktree_path).and_return(1)

        result = command.call("myproject.worktree-PROJ-123", json: true, working_dir: tmpdir)

        expect(result).to eq({exit_code: 1})
        parsed = JSON.parse(output.string)
        expect(parsed["schema_version"]).to eq(1)
        expect(parsed["error"]).to match(/changed file\(s\)/)
      end
    end
  end
end
