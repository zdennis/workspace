require "tmpdir"
require "yaml"

RSpec.describe Workspace::Commands::Kill do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:git) { double("git") }
  let(:project_config) { double("project_config") }
  let(:project_settings) { double("project_settings") }
  let(:stop_command) { double("stop_command") }
  let(:project_detector) { Workspace::ProjectDetector.new(state: CLITestHelpers::FakeState.new, project_config: project_config) }
  let(:notes) { nil }
  let(:dev) { nil }
  let(:pr_status) { nil }
  let(:window_positions) { Workspace::WindowPositions.new(dir: File.join(tmpdir, "positions")) }

  subject(:command) do
    described_class.new(
      git: git,
      project_config: project_config,
      project_settings: project_settings,
      stop_command: stop_command,
      project_detector: project_detector,
      window_positions: window_positions,
      notes: notes,
      dev: dev,
      pr_status: pr_status,
      output: output,
      input: input
    )
  end

  after { FileUtils.remove_entry(tmpdir) }

  let(:config_path) { File.join(tmpdir, "workspace.myproject.worktree-PROJ-123.yml") }

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
        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => "/path/to/worktree"))
      end

      it "raises error when not a worktree project" do
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(false)

        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /does not appear to be a worktree project/
        )
      end

      it "suggests workspace stop for non-worktree projects" do
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(false)

        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /workspace stop/
        )
      end

      context "with valid worktree" do
        before do
          allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
          allow(git).to receive(:unsaved_work).with("/path/to/worktree").and_return(nil)
        end

        context "when the notes directory is inside the worktree and holds files" do
          let(:notes) { double("notes") }
          let(:held) { {"dir" => "/path/to/worktree/tmp/workspace-notes", "files" => 3} }
          let(:sentence) { "The notes directory /path/to/worktree/tmp/workspace-notes holds 3 files and is inside the worktree; removing the worktree deletes them." }

          before do
            allow(notes).to receive(:files_inside_worktree).with(name: "myproject.worktree-PROJ-123").and_return(held)
            allow(git).to receive(:remove_worktree)
            allow(stop_command).to receive(:call).and_return([])
            allow(project_config).to receive(:remove)
            allow(project_settings).to receive(:remove)
          end

          it "says so before it asks to remove, and keeps the answer for the caller" do
            input.puts "n"
            input.rewind

            command.call("myproject.worktree-PROJ-123")

            expect(output.string.index("Warning: #{sentence}")).to be < output.string.index("[y/N]")
            expect(output.string).to include("Warning: #{sentence}")
            expect(command.notes_inside_worktree).to eq(held)
            expect(described_class.notes_sentence(held)).to eq(sentence)
          end

          it "says it with force too, and prints nothing in quiet mode" do
            command.call("myproject.worktree-PROJ-123", force: true, quiet: true)

            expect(output.string).to eq("")
            expect(command.notes_inside_worktree).to eq(held)
          end

          it "speaks of one file in the singular" do
            allow(notes).to receive(:files_inside_worktree).and_return("dir" => "/n", "files" => 1)

            command.call("myproject.worktree-PROJ-123", force: true)

            expect(output.string).to include("holds 1 file and is")
          end

          it "forgets the answer on the next call" do
            command.call("myproject.worktree-PROJ-123", force: true)
            allow(notes).to receive(:files_inside_worktree).and_return(nil)
            command.call("myproject.worktree-PROJ-123", force: true)

            expect(command.notes_inside_worktree).to be_nil
          end
        end

        context "with delete_branch: true" do
          let(:order) { [] }
          let(:name) { "myproject.worktree-PROJ-123" }
          let(:marked) { true }
          let(:deletion) { [true, ""] }

          before do
            allow(git).to receive(:remove_worktree) { order << :remove }
            allow(stop_command).to receive(:call).and_return([])
            allow(project_config).to receive(:remove)
            allow(project_settings).to receive(:remove)
            allow(git).to receive(:worktree_branch).with("/path/to/worktree").and_return("PROJ-123")
            allow(git).to receive(:common_dir_from_files).with("/path/to/worktree").and_return("/repos/main.git")
            allow(git).to receive(:workspace_created_branch?).with("/repos/main.git", "PROJ-123").and_return(marked)
            allow(git).to receive(:delete_branch) { |*_args, **_kw|
              order << :delete
              deletion
            }
          end

          it "deletes a branch start made, after the worktree is removed, from the main checkout" do
            command.call(name, force: true, delete_branch: true)

            expect(git).to have_received(:delete_branch).with("/repos/main.git", "PROJ-123", force: true)
            expect(order).to eq([:remove, :delete])
            expect(output.string).to include("Deleted branch PROJ-123")
            expect(command.branch_result).to eq("name" => "PROJ-123", "deleted" => true, "kept_reason" => nil)
          end

          it "uses -d without force" do
            input.puts "y"
            input.rewind

            command.call(name, delete_branch: true)

            expect(git).to have_received(:delete_branch).with("/repos/main.git", "PROJ-123", force: false)
          end

          context "when start did not make the branch" do
            let(:marked) { false }

            it "keeps it" do
              command.call(name, force: true, delete_branch: true)

              expect(git).not_to have_received(:delete_branch)
              expect(output.string).to include("Kept branch PROJ-123 (it existed before start)")
              expect(command.branch_result).to eq("name" => "PROJ-123", "deleted" => false, "kept_reason" => "existed_before_start")
            end
          end

          context "when -d refuses an unmerged branch" do
            let(:deletion) { [false, "error: The branch 'PROJ-123' is not fully merged."] }

            it "warns, keeps the branch and still kills" do
              expect(command.call(name, force: true, delete_branch: true)).to eq(name)

              expect(output.string).to include("Warning: kept branch PROJ-123: not fully merged. Delete it with: git branch -D PROJ-123")
              expect(command.branch_result["kept_reason"]).to eq("not_merged")
              expect(stop_command).to have_received(:call)
            end
          end

          context "when git fails for another reason" do
            let(:deletion) { [false, "fatal: boom\n"] }

            it "reports an error and still kills" do
              expect(command.call(name, force: true, delete_branch: true)).to eq(name)

              expect(output.string).to include("Warning: kept branch PROJ-123: git could not delete it: fatal: boom")
              expect(command.branch_result).to eq("name" => "PROJ-123", "deleted" => false, "kept_reason" => "error")
            end
          end

          context "with delete_remote: true" do
            let(:pr_status) { double("pr_status", call: {"available" => true, "found" => false}) }
            let(:has_remotes) { true }
            let(:upstream) { ["origin", "refs/heads/PROJ-123"] }
            let(:remote_delete) { [:deleted, ""] }

            before do
              allow(git).to receive(:remotes?).with("/path/to/worktree").and_return(has_remotes)
              allow(git).to receive(:upstream_config).with("/path/to/worktree", "PROJ-123").and_return(upstream)
              allow(git).to receive(:unsaved_work).and_return(nil)
              allow(git).to receive(:delete_remote_branch) { |*_args|
                order << :delete_remote
                remote_delete
              }
            end

            def kill_remote(**opts)
              command.call(name, delete_branch: true, delete_remote: true, confirm: false, **opts)
            end

            it "deletes the upstream branch after the local delete" do
              kill_remote

              expect(git).to have_received(:delete_remote_branch).with("/repos/main.git", "origin", "PROJ-123")
              expect(order).to eq([:remove, :delete, :delete_remote])
              expect(output.string).to include("Deleted remote branch origin/PROJ-123")
              expect(command.remote_branch_result).to eq("name" => "PROJ-123", "remote" => "origin", "deleted" => true, "kept_reason" => nil)
            end

            it "uses the upstream's own branch name" do
              allow(git).to receive(:upstream_config).and_return(["origin", "refs/heads/other/name"])

              kill_remote

              expect(git).to have_received(:delete_remote_branch).with("/repos/main.git", "origin", "other/name")
            end

            it "makes no remote calls by default" do
              command.call(name, force: true, delete_branch: true)

              expect(pr_status).not_to have_received(:call)
              expect(git).not_to have_received(:delete_remote_branch)
              expect(command.remote_branch_result).to be_nil
            end

            context "with an open pull request" do
              let(:pr_status) { double("pr_status", call: {"available" => true, "found" => true, "state" => "OPEN", "number" => 7, "url" => "https://x/pull/7"}) }

              it "refuses before the prompt, with nothing removed" do
                expect { command.call(name, delete_branch: true, delete_remote: true) }.to raise_error(Workspace::Error) { |e|
                  expect(e.code).to eq("open_pull_request")
                  expect(e.details).to eq("branch" => "PROJ-123", "number" => 7, "url" => "https://x/pull/7")
                  expect(e.retry).to eq("flags" => ["--force"], "destructive" => true)
                }

                expect(git).not_to have_received(:remove_worktree)
                expect(output.string).not_to include("Remove worktree")
              end

              it "is skipped by force" do
                kill_remote(force: true)

                expect(pr_status).not_to have_received(:call)
                expect(git).to have_received(:delete_remote_branch)
              end
            end

            context "with a pull request status that cannot be read" do
              let(:pr_status) { double("pr_status", call: {"available" => false, "reason" => "error", "detail" => "boom"}) }

              it "refuses" do
                expect { kill_remote }.to raise_error(Workspace::Error) { |e|
                  expect(e.code).to eq("pull_request_status_unknown")
                  expect(e.details).to eq("branch" => "PROJ-123", "reason" => "error", "detail" => "boom")
                  expect(e.retry).to eq("flags" => ["--force"], "destructive" => true)
                }
                expect(git).not_to have_received(:remove_worktree)
              end
            end

            it "keeps the remote branch of a missing checkout without asking, force or not" do
              allow(project_config).to receive(:remove)

              [false, true].each do |force|
                expect(kill_remote(missing_ok: true, force: force)).to eq(name)
                expect(command.remote_branch_result).to include("deleted" => false, "kept_reason" => "checkout_missing")
              end

              expect(pr_status).not_to have_received(:call)
              expect(git).not_to have_received(:delete_remote_branch)
              expect(output.string).to include("Kept remote branch: the checkout was already gone")
            end

            it "has no pull request answer to read without a pr_status" do
              cmd = described_class.new(git: git, project_config: project_config, project_settings: project_settings,
                stop_command: stop_command, project_detector: project_detector, output: output, input: input)

              expect { cmd.call(name, delete_branch: true, delete_remote: true, confirm: false) }.to raise_error(Workspace::Error) { |e|
                expect(e.code).to eq("pull_request_status_unknown")
                expect(e.details).to eq("branch" => "PROJ-123", "reason" => "unavailable")
              }
            end

            ["MERGED", "CLOSED"].each do |state|
              it "goes on when the pull request is #{state}" do
                allow(pr_status).to receive(:call).and_return({"available" => true, "found" => true, "state" => state, "number" => 7, "url" => "u"})

                kill_remote

                expect(git).to have_received(:delete_remote_branch)
              end
            end

            it "goes on when there is no pull request" do
              kill_remote

              expect(git).to have_received(:delete_remote_branch)
            end

            context "without a remote" do
              let(:has_remotes) { false }

              it "warns and keeps going" do
                expect(kill_remote).to eq(name)

                expect(output.string).to include("Warning: kept remote branch PROJ-123: the repository has no remote")
                expect(command.remote_branch_result["kept_reason"]).to eq("no_remote")
                expect(git).not_to have_received(:delete_remote_branch)
              end
            end

            context "without an upstream" do
              let(:upstream) { nil }

              it "warns and keeps going" do
                expect(kill_remote).to eq(name)

                expect(output.string).to include("Warning: kept remote branch PROJ-123: it has no upstream")
                expect(command.remote_branch_result["kept_reason"]).to eq("no_upstream")
                expect(git).not_to have_received(:delete_remote_branch)
              end
            end

            context "when the push fails" do
              let(:remote_delete) { [:error, "remote: denied\n"] }

              it "warns and still kills" do
                expect(kill_remote).to eq(name)

                expect(output.string).to include("Warning: could not delete remote branch origin/PROJ-123: remote: denied")
                expect(command.remote_branch_result).to include("deleted" => false, "kept_reason" => "error")
              end
            end

            context "when the push times out" do
              let(:remote_delete) { [:timeout, ""] }

              it "warns and still kills" do
                expect(kill_remote).to eq(name)

                expect(output.string).to include("Warning: could not delete remote branch origin/PROJ-123: the remote did not answer in time")
                expect(command.remote_branch_result["kept_reason"]).to eq("timeout")
              end
            end

            context "when the remote no longer has the branch" do
              let(:remote_delete) { [:not_found, "remote ref does not exist"] }

              it "says so without a warning" do
                kill_remote

                expect(output.string).to include("Remote branch origin/PROJ-123 was already gone (nothing to delete)")
                expect(output.string).not_to include("Warning: could not delete remote")
                expect(command.remote_branch_result).to include("deleted" => false, "kept_reason" => "not_found")
              end
            end
          end

          it "makes no branch git calls by default" do
            command.call(name, force: true)

            expect(git).not_to have_received(:worktree_branch)
            expect(git).not_to have_received(:workspace_created_branch?)
            expect(git).not_to have_received(:delete_branch)
            expect(command.branch_result).to be_nil
          end

          it "forgets the result on the next call" do
            command.call(name, force: true, delete_branch: true)
            command.call(name, force: true)

            expect(command.branch_result).to be_nil
          end

          it "keeps the branch and says so when the checkout is already gone" do
            command.call(name, force: true, delete_branch: true, missing_ok: true)

            expect(git).not_to have_received(:delete_branch)
            expect(output.string).to include("Kept branch: the checkout was already gone")
            expect(command.branch_result).to eq("name" => nil, "deleted" => false, "kept_reason" => "checkout_missing")
          end

          it "names the branch from the task record when the checkout is gone" do
            task_store = double("task_store", active_for: {"branch" => "PROJ-123"}, archive: nil)
            cmd = described_class.new(git: git, project_config: project_config, project_settings: project_settings,
              stop_command: stop_command, project_detector: project_detector, task_store: task_store, output: output, input: input)

            cmd.call(name, force: true, delete_branch: true, missing_ok: true)

            expect(output.string).to include("Kept branch PROJ-123: the checkout was already gone")
            expect(cmd.branch_result).to eq("name" => "PROJ-123", "deleted" => false, "kept_reason" => "checkout_missing")
          end

          it "keeps the branch when HEAD is detached" do
            allow(git).to receive(:worktree_branch).with("/path/to/worktree").and_return(nil)

            command.call(name, force: true, delete_branch: true)

            expect(git).not_to have_received(:delete_branch)
            expect(output.string).to include("Kept branch: the worktree's HEAD is detached")
            expect(command.branch_result).to eq("name" => nil, "deleted" => false, "kept_reason" => "detached_head")
          end

          it "warns and keeps the branch when the git directory cannot be read" do
            allow(git).to receive(:common_dir_from_files).and_return(nil)

            expect(command.call(name, force: true, delete_branch: true)).to eq(name)

            expect(git).not_to have_received(:delete_branch)
            expect(output.string).to include("Warning: could not find the repository of branch PROJ-123")
            expect(command.branch_result).to eq("name" => "PROJ-123", "deleted" => false, "kept_reason" => "error")
          end
        end

        context "with a dev command wired" do
          let(:dev) { double("dev") }
          let(:order) { [] }

          before do
            allow(git).to receive(:remove_worktree) { order << :remove }
            allow(stop_command).to receive(:call).and_return([])
            allow(project_config).to receive(:remove)
            allow(project_settings).to receive(:remove)
          end

          it "stops the dev environment the worktree holds before it removes the worktree" do
            allow(dev).to receive(:down_when_held).with(working_dir: "/path/to/worktree") {
              order << :dev_down
              {exit_code: 0, stopped: true}
            }

            command.call("myproject.worktree-PROJ-123", force: true)

            expect(order).to eq([:dev_down, :remove])
            expect(command.dev_stopped).to be(true)
          end

          it "reports no stop when the worktree holds nothing, and forgets an earlier stop" do
            allow(dev).to receive(:down_when_held).and_return({exit_code: 0, stopped: true}, {exit_code: 0, stopped: false})
            command.call("myproject.worktree-PROJ-123", force: true)
            command.call("myproject.worktree-PROJ-123", force: true)

            expect(command.dev_stopped).to be(false)
            expect(output.string).not_to include("dev environment")
          end

          it "warns and still removes the worktree when the environment could not be stopped" do
            allow(dev).to receive(:down_when_held).and_return({exit_code: 1, stopped: false})

            command.call("myproject.worktree-PROJ-123", force: true)

            expect(output.string).to include("Warning: the dev environment could not be stopped; it is still running")
            expect(order).to eq([:remove])
            expect(command.dev_stopped).to be(false)
          end

          it "does not touch the dev environment when it is cancelled at the prompt" do
            input.puts "n"
            input.rewind
            expect(dev).not_to receive(:down_when_held)

            command.call("myproject.worktree-PROJ-123")
          end

          it "does not ask when the checkout is already gone" do
            expect(dev).not_to receive(:down_when_held)

            command.call("myproject.worktree-PROJ-123", force: true, missing_ok: true)

            expect(command.dev_stopped).to be(false)
          end
        end

        it "has nothing to say about notes when none are wired or none are inside" do
          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", force: true)

          expect(command.notes_inside_worktree).to be_nil
          expect(output.string).not_to include("notes")
        end

        it "cancels when user declines confirmation" do
          input.puts "n"
          input.rewind

          command.call("myproject.worktree-PROJ-123")

          expect(output.string).to include("Cancelled")
          expect(stop_command).not_to have_received(:call) if stop_command.respond_to?(:have_received)
        end

        context "when input is off" do
          let(:input) { Workspace::PromptInput.new(StringIO.new("y\n"), no_input: true) }

          it "refuses with confirmation_required and offers --force" do
            expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(Workspace::Error) { |e|
              expect(e.code).to eq("confirmation_required")
              expect(e.details).to eq({"prompt" => "Remove worktree and kill session? [y/N]"})
              expect(e.retry).to eq({"flags" => ["--force"], "destructive" => true})
            }
            expect(output.string).not_to include("[y/N]")
          end
        end

        it "cancels on empty input" do
          input.puts ""
          input.rewind

          command.call("myproject.worktree-PROJ-123")

          expect(output.string).to include("Cancelled")
        end

        it "removes worktree, kills session, and cleans up config on confirmation" do
          input.puts "y"
          input.rewind

          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return(["myproject.worktree-PROJ-123"])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123")

          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: false)
          expect(stop_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], quiet: false, warn_inactive: true, save_position: false)
          expect(project_config).to have_received(:remove).with("myproject.worktree-PROJ-123", quiet: false)
          expect(project_settings).to have_received(:remove).with("myproject.worktree-PROJ-123")
          expect(output.string).to include("Killing session...")
        end

        it "deletes the saved window position and does not ask stop to save a new one" do
          window_positions.write("myproject.worktree-PROJ-123", {x: 1, y: 2, width: 3, height: 4})
          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", force: true)

          expect(window_positions.read("myproject.worktree-PROJ-123")).to be_nil
          expect(stop_command).to have_received(:call).with(anything, hash_including(save_position: false))
        end

        it "removes worktree before killing session" do
          input.puts "y"
          input.rewind

          order = []
          allow(git).to receive(:remove_worktree) { order << :remove_worktree }
          allow(stop_command).to receive(:call) {
            order << :kill
            []
          }
          allow(project_config).to receive(:remove) { order << :remove_config }
          allow(project_settings).to receive(:remove) { order << :remove_settings }

          command.call("myproject.worktree-PROJ-123")

          expect(order).to eq([:remove_worktree, :remove_config, :remove_settings, :kill])
        end

        it "skips confirmation with force flag" do
          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", force: true)

          expect(output.string).not_to include("[y/N]")
          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: true)
          expect(output.string).to include("Killing session")
        end

        it "with confirm: false, skips the prompt but still has git re-check before removing" do
          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", confirm: false)

          expect(output.string).not_to include("[y/N]")
          expect(git).to have_received(:unsaved_work).with("/path/to/worktree")
          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: false)
        end

        it "with quiet: true, prints nothing and asks Stop to be quiet too" do
          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", force: true, quiet: true)

          expect(output.string).to eq("")
          expect(project_config).to have_received(:remove).with("myproject.worktree-PROJ-123", quiet: true)
          expect(stop_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], quiet: true, warn_inactive: true, save_position: false)
        end

        it "yields the project after removing the worktree and before removing config or stopping" do
          order = []
          allow(git).to receive(:remove_worktree) { order << :remove_worktree }
          allow(stop_command).to receive(:call) { order << :stop }
          allow(project_config).to receive(:remove) { order << :remove_config }
          allow(project_settings).to receive(:remove) { order << :remove_settings }

          command.call("myproject.worktree-PROJ-123", force: true) { |p| order << [:yield, p] }

          expect(order).to eq([:remove_worktree, [:yield, "myproject.worktree-PROJ-123"], :remove_config, :remove_settings, :stop])
        end

        it "refuses, touching nothing else, when git's re-check finds unsaved work at removal time" do
          input.puts "y"
          input.rewind
          unsaved = {changed_files: 1, unpushed_commits: 0, branch: "feature/x"}
          allow(git).to receive(:remove_worktree).and_raise(Workspace::UnsavedWorkError.new("x", unsaved: unsaved))
          expect(project_config).not_to receive(:remove)
          expect(stop_command).not_to receive(:call)

          expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
            Workspace::UnsavedWorkError, /1 changed file\(s\) and 0 unpushed commit\(s\) on feature\/x.*--force/m
          )
        end

        it "passes force to remove_worktree" do
          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", force: true)

          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: true)
        end

        it "ignores missing_ok while the checkout exists" do
          allow(File).to receive(:directory?).and_call_original
          allow(File).to receive(:directory?).with("/path/to/worktree").and_return(true)
          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", confirm: false, missing_ok: true)

          expect(git).to have_received(:unsaved_work)
          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: false)
        end
      end

      context "when the checkout directory is gone" do
        let(:order) { [] }

        before do
          allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(false)
          allow(stop_command).to receive(:call) { order << :stop }
          allow(project_config).to receive(:remove) { order << :remove_config }
          allow(project_settings).to receive(:remove) { order << :remove_settings }
        end

        it "still raises without missing_ok" do
          expect { command.call("myproject.worktree-PROJ-123", confirm: false) }.to raise_error(Workspace::Error, /does not appear to be a worktree project/)
          expect(order).to be_empty
        end

        it "with missing_ok, skips the worktree removal and unsaved check but removes everything else" do
          expect(git).not_to receive(:remove_worktree)
          expect(git).not_to receive(:unsaved_work)

          result = command.call("myproject.worktree-PROJ-123", confirm: false, missing_ok: true) { |p| order << [:yield, p] }

          expect(result).to eq("myproject.worktree-PROJ-123")
          expect(order).to eq([[:yield, "myproject.worktree-PROJ-123"], :remove_config, :remove_settings, :stop])
          expect(output.string).to include("Checkout already gone; skipping worktree removal.")
        end
      end
    end

    context "with marker file auto-detection" do
      it "detects project from .workspace-project in current directory" do
        marker_dir = File.join(tmpdir, "worktree-dir")
        Dir.mkdir(marker_dir)
        File.write(File.join(marker_dir, ".workspace-project"), "myproject.worktree-PROJ-123")

        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => "/path/to/worktree"))
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
        allow(git).to receive(:unsaved_work).with("/path/to/worktree").and_return(nil)
        allow(git).to receive(:remove_worktree)
        allow(stop_command).to receive(:call).and_return([])
        allow(project_config).to receive(:remove)
        allow(project_settings).to receive(:remove)

        cmd = described_class.new(
          git: git, project_config: project_config, project_settings: project_settings,
          stop_command: stop_command, project_detector: project_detector, output: output, input: input
        )
        cmd.call(nil, force: true, working_dir: marker_dir)

        expect(stop_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], quiet: false, warn_inactive: true, save_position: false)
        expect(output.string).to include("Killing session...")
      end

      it "walks up directories to find .workspace-project" do
        marker_dir = File.join(tmpdir, "worktree-dir")
        sub_dir = File.join(marker_dir, "src", "lib")
        FileUtils.mkdir_p(sub_dir)
        File.write(File.join(marker_dir, ".workspace-project"), "myproject.worktree-PROJ-123")

        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => "/path/to/worktree"))
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
        allow(git).to receive(:unsaved_work).with("/path/to/worktree").and_return(nil)
        allow(git).to receive(:remove_worktree)
        allow(stop_command).to receive(:call).and_return([])
        allow(project_config).to receive(:remove)
        allow(project_settings).to receive(:remove)

        cmd = described_class.new(
          git: git, project_config: project_config, project_settings: project_settings,
          stop_command: stop_command, project_detector: project_detector, output: output, input: input
        )
        cmd.call(nil, force: true, working_dir: sub_dir)

        expect(stop_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], quiet: false, warn_inactive: true, save_position: false)
      end

      it "kills the active workspace whose root holds the directory when there is no marker" do
        state = CLITestHelpers::FakeState.new
        state["myproject.worktree-PROJ-123"] = {}
        allow(project_config).to receive(:project_root_for).with("myproject.worktree-PROJ-123").and_return(tmpdir)
        detector = Workspace::ProjectDetector.new(state: state, project_config: project_config)
        sub_dir = File.join(tmpdir, "src").tap { |dir| Dir.mkdir(dir) }

        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => "/path/to/worktree"))
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
        allow(git).to receive(:remove_worktree)
        allow(stop_command).to receive(:call).and_return([])
        allow(project_config).to receive(:remove)
        allow(project_settings).to receive(:remove)

        cmd = described_class.new(
          git: git, project_config: project_config, project_settings: project_settings,
          stop_command: stop_command, project_detector: detector, output: output, input: input
        )
        cmd.call(nil, force: true, working_dir: sub_dir)

        expect(stop_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], quiet: false, warn_inactive: true, save_position: false)
      end

      it "raises not_in_workspace when no workspace holds the directory and no project is given" do
        cmd = described_class.new(
          git: git, project_config: project_config, project_settings: project_settings,
          stop_command: stop_command, project_detector: project_detector, output: output, input: input
        )

        expect { cmd.call(nil, working_dir: tmpdir) }.to raise_error(Workspace::Error, /No workspace found for/) { |e|
          expect(e.code).to eq("not_in_workspace")
        }
      end
    end

    context "with unsaved work" do
      before do
        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => "/path/to/worktree"))
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
      end

      it "refuses to remove a dirty or unpushed worktree before touching anything" do
        allow(git).to receive(:unsaved_work).with("/path/to/worktree")
          .and_return(changed_files: 2, unpushed_commits: 1, branch: "feature/x")
        expect(git).not_to receive(:remove_worktree)
        expect(stop_command).not_to receive(:call)

        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /2 changed file\(s\) and 1 unpushed commit\(s\) on feature\/x/
        )
      end

      it "refuses when git cannot answer" do
        allow(git).to receive(:unsaved_work).with("/path/to/worktree").and_return(:unknown)
        expect(git).not_to receive(:remove_worktree)

        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /git couldn't answer/
        )
      end

      it "mentions --force as the way out" do
        allow(git).to receive(:unsaved_work).with("/path/to/worktree")
          .and_return(changed_files: 2, unpushed_commits: 1, branch: "feature/x")

        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /--force/
        )
      end

      it "proceeds without checking when --force is given" do
        allow(git).to receive(:unsaved_work).with("/path/to/worktree")
          .and_return(changed_files: 2, unpushed_commits: 1, branch: "feature/x")
        allow(git).to receive(:remove_worktree)
        allow(stop_command).to receive(:call).and_return([])
        allow(project_config).to receive(:remove)
        allow(project_settings).to receive(:remove)

        command.call("myproject.worktree-PROJ-123", force: true)

        expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: true)
      end
    end

    context "with corrupt config" do
      before do
        File.write(config_path, "{{invalid yaml")
      end

      it "raises a friendly error" do
        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /Corrupt config file/
        )
      end
    end

    context "with a config containing a disallowed YAML class" do
      before do
        File.write(config_path, "root: !ruby/object {}\n")
      end

      it "raises a friendly error instead of Psych::DisallowedClass" do
        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /Corrupt config file/
        )
      end
    end
  end

  describe "recording worktree_finished" do
    let(:event_log) { CLITestHelpers::FakeEventLog.new }
    let(:name) { "myproject.worktree-PROJ-123" }

    subject(:command) do
      described_class.new(git: git, project_config: project_config, project_settings: project_settings,
        stop_command: stop_command, project_detector: project_detector, event_log: event_log, output: output, input: input)
    end

    before do
      File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => "/path/to/worktree"))
      allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
      allow(git).to receive(:unsaved_work).and_return(nil)
      allow(git).to receive(:remove_worktree)
      allow(stop_command).to receive(:call).and_return([])
      allow(project_config).to receive(:remove)
      allow(project_settings).to receive(:remove)
    end

    it "records the outcome under the workspace once the worktree is removed, with no path" do
      command.call(name, confirm: false)

      expect(event_log.events).to eq([{"type" => "worktree_finished", "project" => name, "data" => {"workspace" => name, "outcome" => "abandoned"}}])
    end

    it "records the event only after the worktree, config and settings are removed, and before the session stops" do
      order = []
      allow(git).to receive(:remove_worktree) { order << :worktree }
      allow(project_config).to receive(:remove) { order << :config }
      allow(project_settings).to receive(:remove) { order << :settings }
      allow(stop_command).to receive(:call) {
        order << :stop
        []
      }
      allow(event_log).to receive(:record).and_wrap_original { |m, **kw|
        order << :event
        m.call(**kw)
      }

      command.call(name, confirm: false)

      expect(order).to eq(%i[worktree config settings event stop])
    end

    it "records discarded for a forced kill and the caller's outcome otherwise" do
      command.call(name, force: true)
      command.call(name, confirm: false, outcome: "merged")

      expect(event_log.events.map { |e| e["data"]["outcome"] }).to eq(%w[discarded merged])
    end

    it "records nothing when the user cancels" do
      input.puts "n"
      input.rewind

      command.call(name)

      expect(event_log.events).to be_empty
    end

    it "records nothing when git refuses to remove the worktree" do
      allow(git).to receive(:remove_worktree).and_raise(Workspace::UnsavedWorkError.new("x", unsaved: {changed_files: 1, unpushed_commits: 0, branch: "b"}))

      expect { command.call(name, confirm: false) }.to raise_error(Workspace::UnsavedWorkError)

      expect(event_log.events).to be_empty
    end

    it "still removes the config and stops the session when the log can't be written" do
      broken = described_class.new(git: git, project_config: project_config, project_settings: project_settings,
        stop_command: stop_command, project_detector: project_detector,
        event_log: CLITestHelpers.unwritable_event_log(tmpdir), output: output, input: input)

      expect(broken.call(name, force: true)).to eq(name)

      expect(project_config).to have_received(:remove)
      expect(stop_command).to have_received(:call)
    end
  end
end

RSpec.describe Workspace::Commands::Kill, "task archiving" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:project_config) { double("project_config", remove: nil) }
  let(:git) { double("git", worktree_exists?: true, unsaved_work: nil, remove_worktree: nil) }
  let(:stop_command) { double("stop_command", call: []) }
  let(:task_store) { double("task_store", archive: nil) }
  let(:name) { "myproject.worktree-PROJ-123" }
  let(:config_path) { File.join(tmpdir, "workspace.#{name}.yml") }

  subject(:command) do
    described_class.new(git: git, project_config: project_config, project_settings: double("settings", remove: nil),
      stop_command: stop_command, project_detector: double("detector"), task_store: task_store,
      output: StringIO.new, input: StringIO.new)
  end

  before do
    File.write(config_path, YAML.dump("root" => "/path/to/worktree"))
    allow(project_config).to receive(:config_path_for).with(name).and_return(config_path)
  end

  after { FileUtils.remove_entry(tmpdir) }

  it "ends the project's workflow runs once the worktree is removed, before the session stops, and says which" do
    order = []
    out = StringIO.new
    runs = double("workflow_runs")
    allow(runs).to receive(:workspace_killed) do |workspace|
      order << [:runs, workspace]
      {"cancelled" => %w[wr_1 wr_2], "failed" => ["wr_3"]}
    end
    allow(git).to receive(:remove_worktree) { order << :remove }
    allow(stop_command).to receive(:call) { order << :stop }
    with_runs = described_class.new(git: git, project_config: project_config, project_settings: double("settings", remove: nil),
      stop_command: stop_command, project_detector: double("detector"), workflow_runs: runs, output: out, input: StringIO.new)

    with_runs.call(name, confirm: false)

    expect(order).to eq([:remove, [:runs, name], :stop])
    expect(out.string).to include("Cancelled workflow run wr_1.\nCancelled workflow run wr_2.\n" \
      "Warning: workflow run wr_3 could not be ended (its run file may be malformed). If it holds a lock, free it with `workspace lock clear NAME`.\n")
  end

  it "ends no run when the kill is refused for unsaved work" do
    runs = double("workflow_runs", workspace_killed: {"cancelled" => [], "failed" => []})
    allow(git).to receive(:unsaved_work).and_return(changed_files: 1, unpushed_commits: 0, branch: "x")
    with_runs = described_class.new(git: git, project_config: project_config, project_settings: double("settings", remove: nil),
      stop_command: stop_command, project_detector: double("detector"), workflow_runs: runs, output: StringIO.new, input: StringIO.new)

    expect { with_runs.call(name, confirm: false) }.to raise_error(Workspace::UnsavedWorkError)
    expect(runs).not_to have_received(:workspace_killed)
  end

  it "archives the task as abandoned after removing the worktree" do
    order = []
    allow(git).to receive(:remove_worktree) { order << :remove }
    allow(task_store).to receive(:archive) { order << :archive }

    command.call(name, confirm: false)

    expect(task_store).to have_received(:archive).with(name, outcome: "abandoned")
    expect(order).to eq([:remove, :archive])
  end

  it "archives the task as discarded under --force" do
    command.call(name, force: true)

    expect(task_store).to have_received(:archive).with(name, outcome: "discarded")
  end

  it "archives with the outcome the caller gives" do
    command.call(name, confirm: false, outcome: "merged")

    expect(task_store).to have_received(:archive).with(name, outcome: "merged")
  end

  it "keeps the task when the worktree can't be removed" do
    allow(git).to receive(:remove_worktree).and_raise(Workspace::UnsavedWorkError.new("x", unsaved: :unknown))

    expect { command.call(name, confirm: false) }.to raise_error(Workspace::UnsavedWorkError)
    expect(task_store).not_to have_received(:archive)
  end

  it "still removes the config, settings and session, with a warning, when the task can't be archived" do
    out = StringIO.new
    command = described_class.new(git: git, project_config: project_config, project_settings: (settings = double("settings", remove: nil)),
      stop_command: stop_command, project_detector: double("detector"), task_store: task_store, output: out, input: StringIO.new)
    allow(task_store).to receive(:archive).and_raise(Workspace::Error, "Could not access task store at /x")

    expect(command.call(name, confirm: false)).to eq(name)

    expect(out.string).to include("Warning: could not archive the task for #{name}: Could not access task store at /x")
    expect(project_config).to have_received(:remove).with(name, quiet: false)
    expect(settings).to have_received(:remove).with(name)
    expect(stop_command).to have_received(:call)
  end

  it "keeps the task when the user cancels" do
    command = described_class.new(git: git, project_config: project_config, project_settings: double("settings"),
      stop_command: stop_command, project_detector: double("detector"), task_store: task_store,
      output: StringIO.new, input: StringIO.new("n\n"))

    command.call(name)

    expect(task_store).not_to have_received(:archive)
  end
end
