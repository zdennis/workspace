require "spec_helper"
require "tmpdir"
require "open3"
require "stringio"
require "json"

RSpec.describe Workspace::Commands::Notes do
  around do |example|
    Dir.mktmpdir("notes-cmd") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:repo) { File.join(@dir, "api") }
  let(:linked) { File.join(@dir, "api-x") }
  let(:config_dir) { File.join(@dir, "config") }
  let(:output) { StringIO.new }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:config) { instance_double(Workspace::Config, workspace_config_dir: config_dir) }
  let(:settings) { Workspace::ProjectSettings.new(config: config) }
  let(:roots) { {"api" => repo, "api.worktree-x" => linked} }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  subject(:command) do
    described_class.new(notes_dir: Workspace::NotesDir.new(git: git, home: "/home/me"), project_config: project_config,
      config_resolver: Workspace::ConfigResolver.new(project_settings: settings), git_exclude: Workspace::GitExclude.new(git: git), output: output)
  end

  def sh(*args, dir: repo)
    out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "gc.auto=0", "-c", "maintenance.auto=false", *args)
    raise out unless status.success?
  end

  def write_config(name, text)
    path = settings.project_config_path(name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def exclude_file = File.join(repo, ".git", "info", "exclude")

  before do
    FileUtils.mkdir_p(repo)
    sh("init", "-q")
    sh("commit", "-q", "--allow-empty", "-m", "start")
    sh("worktree", "add", "-q", "-b", "feature/x", linked)
    allow(project_config).to receive(:project_root_for) { |name| roots[name] }
  end

  describe "#dir" do
    it "prints the absolute path alone, tmp/workspace-notes in the checkout by default" do
      command.dir(name: "api")

      expect(output.string).to eq("#{repo}/tmp/workspace-notes\n")
    end

    it "gives a worktree the main checkout's tmp/workspace-notes plus its branch when nothing is set" do
      command.dir(name: "api.worktree-x", json: true)

      expect(JSON.parse(output.string)).to include("dir" => "#{repo}/tmp/workspace-notes/feature-x", "source" => "default", "inside_worktree" => false)
    end

    it "gives a worktree the project's notes.dir plus its branch" do
      write_config("api", "notes:\n  dir: /tmp/my-notes\n")

      command.dir(name: "api.worktree-x")

      expect(output.string).to eq("/tmp/my-notes/feature-x\n")
    end

    it "lets the project's notes.default_dir rule win over the main checkout's directory" do
      write_config("api", "notes:\n  dir: /tmp/my-notes\n  default_dir: /notes/{workspace}\n")

      command.dir(name: "api.worktree-x")

      expect(output.string).to eq("/notes/api.worktree-x\n")
    end

    it "falls back to tmp/workspace-notes in the worktree when the main workspace has no checkout" do
      roots.delete("api")

      command.dir(name: "api.worktree-x")

      expect(output.string).to eq("#{linked}/tmp/workspace-notes\n")
    end

    it "lists a default inside the main checkout in the shared info/exclude with create" do
      command.dir(name: "api.worktree-x", create: true)

      expect(Dir.exist?("#{repo}/tmp/workspace-notes/feature-x")).to be true
      expect(File.read(exclude_file)).to include("/tmp/workspace-notes/feature-x/")
      expect(command.info(name: "api.worktree-x")).to include("excluded" => true, "inside_worktree" => false)
    end

    it "does not create anything or touch the exclude file without create" do
      command.dir(name: "api.worktree-x")

      expect(Dir.exist?(File.join(linked, "tmp"))).to be false
      expect(File.exist?(exclude_file) && File.read(exclude_file).include?("workspace-notes")).to be false
    end

    it "uses a worktree's own notes.dir" do
      write_config("api.worktree-x", "notes:\n  dir: /elsewhere/mine\n")
      write_config("api", "notes:\n  dir: /elsewhere/project\n")

      command.dir(name: "api.worktree-x", json: true)

      expect(JSON.parse(output.string)).to include("dir" => "/elsewhere/mine", "source" => "worktree", "inside_worktree" => false)
    end

    it "prefers the worktree's notes.dir over the project's, and reads notes.default_dir from the project only" do
      write_config("api.worktree-x", "notes:\n  dir: /elsewhere/mine\n  default_dir: /ignored/{workspace}\n")
      write_config("api", "notes:\n  dir: /elsewhere/project\n  default_dir: /notes/{workspace}\n")

      command.dir(name: "api.worktree-x", json: true)
      expect(JSON.parse(output.string)).to include("dir" => "/elsewhere/mine", "source" => "worktree")
    end

    it "ignores a notes.default_dir in the worktree's own file" do
      write_config("api.worktree-x", "notes:\n  default_dir: /ignored/{workspace}\n")
      write_config("api", "notes:\n  default_dir: /notes/{workspace}\n")

      command.dir(name: "api.worktree-x", json: true)
      expect(JSON.parse(output.string)).to include("dir" => "/notes/api.worktree-x", "source" => "default")
    end

    it "uses the project's notes.dir for the main checkout" do
      write_config("api", "notes:\n  dir: /elsewhere/project\n")

      command.dir(name: "api", json: true)

      expect(JSON.parse(output.string)).to include("workspace" => "api", "dir" => "/elsewhere/project", "source" => "project")
    end

    it "fills the project's notes.default_dir rule for a worktree" do
      write_config("api", "notes:\n  default_dir: /notes/{workspace}/{branch}\n")

      command.dir(name: "api.worktree-x", json: true)

      expect(JSON.parse(output.string)).to include("dir" => "/notes/api.worktree-x/feature-x", "source" => "default")
    end

    it "ignores a stored value that does not pass the key's checks, as config show does" do
      write_config("api.worktree-x", "notes:\n  dir: relative/path\n")

      command.dir(name: "api.worktree-x")

      expect(output.string).to eq("#{repo}/tmp/workspace-notes/feature-x\n")
    end

    it "prints the JSON document with the plan's fields" do
      command.dir(name: "api", json: true)

      expect(JSON.parse(output.string)).to eq(
        "schema_version" => 1, "ok" => true, "workspace" => "api",
        "dir" => "#{repo}/tmp/workspace-notes", "source" => "default",
        "exists" => false, "inside_worktree" => true, "excluded" => false
      )
    end

    it "reports a directory outside the checkout as excluded, since git never sees it" do
      write_config("api.worktree-x", "notes:\n  dir: #{@dir}/outside\n")

      command.dir(name: "api.worktree-x", json: true)

      expect(JSON.parse(output.string)).to include("inside_worktree" => false, "excluded" => true)
    end

    context "with create" do
      it "makes the directory and lists the rooted line in the common dir's info/exclude" do
        command.dir(name: "api", create: true, json: true)

        expect(JSON.parse(output.string)).to include("exists" => true, "inside_worktree" => true, "excluded" => true)
        expect(Dir.exist?("#{repo}/tmp/workspace-notes")).to be true
        expect(File.read(exclude_file).lines.map(&:chomp)).to include("/tmp/workspace-notes/")
      end

      it "keeps notes out of git status and writes no config" do
        command.dir(name: "api", create: true)
        File.write("#{repo}/tmp/workspace-notes/plan.md", "x\n")

        status, = Open3.capture2("git", "-C", linked, "status", "--porcelain")
        expect(status).to eq("")
        expect(Dir.exist?(config_dir)).to be false
      end

      it "lists the line once however often it runs" do
        2.times { command.dir(name: "api", create: true) }

        expect(File.read(exclude_file).lines.map(&:chomp).count("/tmp/workspace-notes/")).to eq(1)
      end

      it "makes a directory outside the checkout and leaves info/exclude alone" do
        write_config("api.worktree-x", "notes:\n  dir: #{@dir}/outside/notes\n")

        command.dir(name: "api.worktree-x", create: true, json: true)

        expect(Dir.exist?("#{@dir}/outside/notes")).to be true
        expect(JSON.parse(output.string)).to include("exists" => true, "inside_worktree" => false)
        expect(File.exist?(exclude_file) && File.read(exclude_file).include?("outside")).to be false
      end

      it "escapes characters git reads as a glob in the line" do
        write_config("api.worktree-x", "notes:\n  dir: #{linked}/n[1]*\n")

        command.dir(name: "api.worktree-x", create: true)

        expect(File.read(exclude_file).lines.map(&:chomp)).to include('/n\[1\]\*/')
      end

      it "raises notes_dir_unwritable naming the path when the directory can't be made" do
        FileUtils.mkdir_p(File.join(repo, "tmp"))
        File.write(File.join(repo, "tmp", "workspace-notes"), "a file\n")

        expect { command.dir(name: "api", create: true) }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("notes_dir_unwritable")
          expect(e.details).to eq("path" => "#{repo}/tmp/workspace-notes")
          expect(e.message).to include("#{repo}/tmp/workspace-notes")
        }
        expect(output.string).to eq("")
      end

      it "raises notes_dir_unwritable when the exclude line can't be written" do
        FileUtils.mkdir_p(File.dirname(exclude_file))
        FileUtils.mkdir_p(exclude_file)

        expect { command.dir(name: "api.worktree-x", create: true) }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("notes_dir_unwritable")
        }
      end
    end

    it "treats a checkout reached through a symlink as the same place" do
      link = File.join(@dir, "link-to-x")
      File.symlink(linked, link)
      roots["api.worktree-x"] = link
      write_config("api.worktree-x", "notes:\n  dir: #{linked}/tmp/workspace-notes\n")

      command.dir(name: "api.worktree-x", create: true, json: true)

      expect(JSON.parse(output.string)).to include("inside_worktree" => true, "excluded" => true)
      expect(File.read(exclude_file).lines.map(&:chomp)).to include("/tmp/workspace-notes/")
    end

    it "reports excluded false and still succeeds when create runs outside a git checkout" do
      plain = File.join(@dir, "plain")
      FileUtils.mkdir_p(plain)
      roots["plain"] = plain

      command.dir(name: "plain", create: true, json: true)

      expect(JSON.parse(output.string)).to include("exists" => true, "inside_worktree" => true, "excluded" => false)
    end

    it "fills the project's rule for the main checkout too" do
      write_config("api", "notes:\n  default_dir: /notes/{workspace}\n")

      command.dir(name: "api", json: true)

      expect(JSON.parse(output.string)).to include("dir" => "/notes/api", "source" => "default")
    end

    it "does not use the project's notes.dir as is for a worktree, only with its branch added" do
      write_config("api", "notes:\n  dir: /elsewhere/project\n")

      command.dir(name: "api.worktree-x", json: true)

      expect(JSON.parse(output.string)).to include("dir" => "/elsewhere/project/feature-x", "source" => "default")
    end

    it "reports an existing directory as existing" do
      FileUtils.mkdir_p("#{repo}/tmp/workspace-notes")

      command.dir(name: "api", json: true)

      expect(JSON.parse(output.string)).to include("exists" => true)
    end

    it "raises unknown_workspace for a name with no checkout" do
      expect { command.dir(name: "nope") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_workspace")
        expect(e.details).to eq("name" => "nope")
      }
    end

    it "raises notes_dir_unresolved when the rule needs a branch and the checkout has none" do
      write_config("api", "notes:\n  default_dir: /notes/{branch}\n")
      sh("checkout", "-q", "--detach", dir: linked)

      expect { command.dir(name: "api.worktree-x") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("notes_dir_unresolved")
        expect(e.message).to include("api.worktree-x").and include("{branch}")
      }
    end

    it "raises config_parse for a config file it can't parse" do
      write_config("api.worktree-x", "notes: [unclosed\n")

      expect { command.dir(name: "api.worktree-x") }.to raise_error(Workspace::ConfigParseError) { |e|
        expect(e.code).to eq("config_parse")
      }
    end
  end

  describe "#info" do
    it "returns the answer dir prints, as a Hash, and prints nothing" do
      expect(command.info(name: "api")).to eq(
        "workspace" => "api", "dir" => "#{repo}/tmp/workspace-notes", "source" => "default",
        "exists" => false, "inside_worktree" => true, "excluded" => false
      )
      expect(output.string).to eq("")
    end

    it "makes the directory and the exclude line with create" do
      answer = command.info(name: "api", create: true)

      expect(answer).to include("exists" => true, "excluded" => true)
      expect(File.read(exclude_file).lines.map(&:chomp)).to include("/tmp/workspace-notes/")
    end

    it "raises notes_dir_unwritable when create can't make the directory" do
      File.write("#{repo}/tmp", "a file where the directory should go")

      expect { command.info(name: "api", create: true) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("notes_dir_unwritable")
      }
    end
  end

  describe "#files_inside_worktree" do
    it "counts the files of a notes directory inside the checkout, hidden and nested ones included" do
      FileUtils.mkdir_p("#{repo}/tmp/workspace-notes/sub")
      File.write("#{repo}/tmp/workspace-notes/plan.md", "x")
      File.write("#{repo}/tmp/workspace-notes/sub/a.md", "x")
      File.write("#{repo}/tmp/workspace-notes/.hidden", "x")

      expect(command.files_inside_worktree(name: "api")).to eq("dir" => "#{repo}/tmp/workspace-notes", "files" => 3)
    end

    it "is nil when the directory is missing or holds no files" do
      expect(command.files_inside_worktree(name: "api")).to be_nil
      FileUtils.mkdir_p("#{repo}/tmp/workspace-notes/empty")
      expect(command.files_inside_worktree(name: "api")).to be_nil
    end

    it "is nil for a directory outside the checkout" do
      write_config("api.worktree-x", "notes:\n  dir: #{@dir}/outside\n")
      FileUtils.mkdir_p("#{@dir}/outside")
      File.write("#{@dir}/outside/plan.md", "x")

      expect(command.files_inside_worktree(name: "api.worktree-x")).to be_nil
    end

    it "is nil, not an error, when the workspace can't be resolved" do
      expect(command.files_inside_worktree(name: "nope")).to be_nil
    end
  end
end
