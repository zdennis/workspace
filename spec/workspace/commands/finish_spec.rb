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
    allow(git).to receive(:base_ref).and_return(nil)
    allow(kill_command).to receive(:notes_inside_worktree).and_return(nil)
    allow(kill_command).to receive(:dev_stopped).and_return(false)
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
              expect(kill_command).to receive(:call).with("myproject.worktree-PROJ-123", confirm: false, quiet: true, working_dir: tmpdir, outcome: "pushed")

              command.call("myproject.worktree-PROJ-123", json: true, working_dir: tmpdir)
            end

            it "reuses Kill for cleanup when clean and pushed" do
              allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(0)
              expect(kill_command).to receive(:call).with("myproject.worktree-PROJ-123", confirm: false, quiet: false, working_dir: tmpdir, outcome: "pushed")

              result = command.call("myproject.worktree-PROJ-123", working_dir: tmpdir)
              expect(result).to eq("myproject.worktree-PROJ-123")
            end

            context "when deciding between pushed and merged" do
              before do
                allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(0)
                allow(kill_command).to receive(:call)
              end

              it "reports merged when HEAD is an ancestor of origin/<default>" do
                allow(git).to receive(:base_ref).with(worktree_path).and_return("origin/main")
                allow(git).to receive(:ancestor?).with(worktree_path, "HEAD", "origin/main").and_return(true)

                command.call("myproject.worktree-PROJ-123", json: true, working_dir: tmpdir)

                expect(kill_command).to have_received(:call).with(anything, hash_including(outcome: "merged"))
                expect(JSON.parse(output.string)["outcome"]).to eq("merged")
              end

              it "reports pushed when HEAD is not on origin/<default>" do
                allow(git).to receive(:base_ref).with(worktree_path).and_return("origin/main")
                allow(git).to receive(:ancestor?).with(worktree_path, "HEAD", "origin/main").and_return(false)

                command.call("myproject.worktree-PROJ-123", json: true, working_dir: tmpdir)

                expect(kill_command).to have_received(:call).with(anything, hash_including(outcome: "pushed"))
                expect(JSON.parse(output.string)["outcome"]).to eq("pushed")
              end

              it "reports pushed, without asking git, when only a local default branch exists" do
                allow(git).to receive(:base_ref).with(worktree_path).and_return("main")
                expect(git).not_to receive(:ancestor?)

                command.call("myproject.worktree-PROJ-123", json: true, working_dir: tmpdir)

                expect(kill_command).to have_received(:call).with(anything, hash_including(outcome: "pushed"))
              end
            end

            it "has no override to skip the clean/pushed check" do
              expect(command.method(:call).parameters.map(&:last)).not_to include(:discard_unpushed)
            end

            context "with --pr" do
              let(:pr_status) { instance_double(Workspace::PullRequestStatus, call: {"available" => true, "found" => false}) }
              let(:runner_calls) { [] }
              let(:runner_reply) { ["https://github.com/org/repo/pull/2\n", "", true] }
              let(:pull_request) do
                reply = runner_reply
                calls = runner_calls
                Workspace::Commands::PullRequest.new(
                  git: git, project_config: project_config, project_detector: project_detector, output: output, status: pr_status,
                  runner: ->(argv, chdir:, timeout:) {
                    calls << [argv, chdir]
                    raise Errno::ENOENT if reply.first == :missing
                    reply
                  }
                )
              end

              subject(:command) do
                described_class.new(git: git, project_config: project_config, kill_command: kill_command, project_detector: project_detector,
                  pull_request: pull_request, output: output, error_output: error_output, input: input)
              end

              before do
                allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(0)
                allow(kill_command).to receive(:call)
              end

              it "skips PR creation with a note when gh is missing" do
                allow(pr_status).to receive(:call).and_return({"available" => false, "reason" => "gh_missing"})

                command.call("myproject.worktree-PROJ-123", pr: true, working_dir: tmpdir)

                expect(output.string).to include("gh is not installed")
                expect(kill_command).to have_received(:call)
              end

              it "reuses an existing PR without creating a new one" do
                allow(pr_status).to receive(:call).with(worktree_path)
                  .and_return({"available" => true, "found" => true, "number" => 1, "url" => "https://github.com/org/repo/pull/1"})

                command.call("myproject.worktree-PROJ-123", pr: true, working_dir: tmpdir)

                expect(output.string).to include("PR already exists: https://github.com/org/repo/pull/1")
                expect(runner_calls).to be_empty
                expect(kill_command).to have_received(:call)
              end

              it "keeps the outcome pushed and reports the PR url under --json" do
                command.call("myproject.worktree-PROJ-123", pr: true, json: true, working_dir: tmpdir)

                doc = JSON.parse(output.string)
                expect(doc).to include("outcome" => "pushed", "pr_url" => "https://github.com/org/repo/pull/2")
                expect(kill_command).to have_received(:call).with(anything, hash_including(outcome: "pushed"))
              end

              it "creates a PR when none exists, without pushing" do
                command.call("myproject.worktree-PROJ-123", pr: true, working_dir: tmpdir)

                expect(output.string).to include("https://github.com/org/repo/pull/2")
                expect(runner_calls).to eq([[%w[gh pr create --fill], worktree_path]])
                expect(kill_command).to have_received(:call)
              end

              it "raises and does not clean up when gh pr create fails" do
                allow(pr_status).to receive(:call).and_return({"available" => false, "reason" => "error", "detail" => "x"})
                runner_reply.replace(["", "boom", false])

                expect { command.call("myproject.worktree-PROJ-123", pr: true, working_dir: tmpdir) }.to raise_error(
                  Workspace::Error, /Could not open a PR for 'myproject.worktree-PROJ-123': boom/
                )
                expect(kill_command).not_to have_received(:call)
              end

              it "raises with gh's own words and does not clean up when gh is not logged in" do
                runner_reply.replace(["", "gh: not authenticated\nrun gh auth login", false])

                expect { command.call("myproject.worktree-PROJ-123", pr: true, working_dir: tmpdir) }.to raise_error(
                  Workspace::Error, /Could not open a PR for 'myproject.worktree-PROJ-123': gh: not authenticated/
                )
                expect(kill_command).not_to have_received(:call)
              end

              it "skips with a note when gh vanishes between the lookup and the create" do
                allow(pr_status).to receive(:call).and_return({"available" => false, "reason" => "timeout"})
                runner_reply.replace([:missing])

                command.call("myproject.worktree-PROJ-123", pr: true, working_dir: tmpdir)

                expect(output.string).to include("gh is not installed; skipping PR creation.")
                expect(kill_command).to have_received(:call)
              end

              it "raises other errors from the pull request step as they are" do
                allow(pr_status).to receive(:call).and_return({"available" => true, "found" => false})
                allow(pull_request).to receive(:find_or_create).and_raise(Workspace::Error, "something else")

                expect { command.call("myproject.worktree-PROJ-123", pr: true, working_dir: tmpdir) }.to raise_error(Workspace::Error, "something else")
              end

              it "reports pr_url in --json for a created PR" do
                command.call("myproject.worktree-PROJ-123", pr: true, json: true, working_dir: tmpdir)

                expect(JSON.parse(output.string)).to include("pr_url" => "https://github.com/org/repo/pull/2")
              end

              it "reports pr_url in --json for an existing PR" do
                allow(pr_status).to receive(:call)
                  .and_return({"available" => true, "found" => true, "number" => 1, "url" => "https://github.com/org/repo/pull/1"})

                command.call("myproject.worktree-PROJ-123", pr: true, json: true, working_dir: tmpdir)

                expect(JSON.parse(output.string)).to include("pr_url" => "https://github.com/org/repo/pull/1")
              end

              it "reports a null pr_url in --json when gh is missing" do
                allow(pr_status).to receive(:call).and_return({"available" => false, "reason" => "gh_missing"})

                command.call("myproject.worktree-PROJ-123", pr: true, json: true, working_dir: tmpdir)

                expect(JSON.parse(output.string)).to include("pr_url" => nil)
              end

              it "reports a null pr_url in --json without --pr" do
                command.call("myproject.worktree-PROJ-123", json: true, working_dir: tmpdir)

                expect(JSON.parse(output.string)).to include("pr_url" => nil)
                expect(runner_calls).to be_empty
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

        expect(kill_command).to have_received(:call).with("myproject.worktree-PROJ-123", confirm: false, quiet: false, working_dir: marker_dir, outcome: "pushed")
      end

      it "finishes the active workspace whose root holds the directory when there is no marker" do
        state = CLITestHelpers::FakeState.new
        state["myproject.worktree-PROJ-123"] = {}
        allow(project_config).to receive(:project_root_for).with("myproject.worktree-PROJ-123").and_return(tmpdir)
        detector = Workspace::ProjectDetector.new(state: state, project_config: project_config)
        finish = described_class.new(git: git, project_config: project_config, kill_command: kill_command, project_detector: detector, output: output, error_output: error_output, input: input)
        sub_dir = File.join(tmpdir, "src").tap { |dir| Dir.mkdir(dir) }

        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => worktree_path))
        allow(git).to receive(:worktree_exists?).with(worktree_path).and_return(true)
        allow(git).to receive(:changed_files_count).with(worktree_path).and_return(0)
        allow(git).to receive(:worktree_branch).with(worktree_path).and_return("main")
        allow(git).to receive(:upstream_branch).with(worktree_path).and_return("origin/main")
        allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(0)
        allow(kill_command).to receive(:call)

        finish.call(nil, working_dir: sub_dir)

        expect(kill_command).to have_received(:call).with("myproject.worktree-PROJ-123", confirm: false, quiet: false, working_dir: sub_dir, outcome: "pushed")
      end

      it "raises not_in_workspace when no workspace holds the directory and no project is given" do
        expect { command.call(nil, working_dir: tmpdir) }.to raise_error(Workspace::Error, /No workspace found for/) { |e|
          expect(e.code).to eq("not_in_workspace")
        }
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
        expect(parsed).to eq({"schema_version" => 1, "ok" => true, "project" => "myproject.worktree-PROJ-123", "outcome" => "pushed", "pr_url" => nil})
      end

      context "when kill stopped the worktree's dev environment" do
        before do
          allow(git).to receive(:changed_files_count).with(worktree_path).and_return(0)
          allow(git).to receive(:worktree_branch).with(worktree_path).and_return("main")
          allow(git).to receive(:upstream_branch).with(worktree_path).and_return("origin/main")
          allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(0)
          allow(kill_command).to receive(:call)
          allow(kill_command).to receive(:dev_stopped).and_return(true)
        end

        it "leaves dev_stopped out when kill stopped nothing" do
          allow(kill_command).to receive(:dev_stopped).and_return(false)

          command.call("myproject.worktree-PROJ-123", json: true, working_dir: tmpdir)

          expect(JSON.parse(output.string)).not_to have_key("dev_stopped")
        end

        it "adds dev_stopped: true at the top level" do
          command.call("myproject.worktree-PROJ-123", json: true, working_dir: tmpdir)

          expect(JSON.parse(output.string)).to eq({"schema_version" => 1, "ok" => true, "project" => "myproject.worktree-PROJ-123", "outcome" => "pushed", "pr_url" => nil, "dev_stopped" => true})
        end
      end

      context "when the notes directory was inside the worktree and held files" do
        let(:held) { {"dir" => "#{worktree_path}/tmp/workspace-notes", "files" => 3} }

        before do
          allow(git).to receive(:changed_files_count).with(worktree_path).and_return(0)
          allow(git).to receive(:worktree_branch).with(worktree_path).and_return("main")
          allow(git).to receive(:upstream_branch).with(worktree_path).and_return("origin/main")
          allow(git).to receive(:commits_ahead_of_upstream).with(worktree_path).and_return(0)
          allow(kill_command).to receive(:call)
          allow(kill_command).to receive(:notes_inside_worktree).and_return(held)
        end

        it "adds notes_inside_worktree and a sentence in warnings, and the exit code stays 0" do
          result = command.call("myproject.worktree-PROJ-123", json: true, working_dir: tmpdir)

          expect(result).to eq({exit_code: 0})
          parsed = JSON.parse(output.string)
          expect(parsed["notes_inside_worktree"]).to eq(held)
          expect(parsed["warnings"]).to eq([Workspace::Commands::Kill.notes_sentence(held)])
          expect(parsed).to include("ok" => true, "project" => "myproject.worktree-PROJ-123")
        end

        it "leaves the plain-text output to Kill, which says it before removing" do
          command.call("myproject.worktree-PROJ-123", working_dir: tmpdir)

          expect(output.string).not_to include("notes")
        end
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
