require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::ProjectGroups do
  include FakeCheckouts

  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }

  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  let(:config) do
    dir = File.join(@root, "groups")
    Struct.new(:groups_dir) do
      def group_path(slug) = File.join(groups_dir, "#{slug}.yml")
    end.new(dir)
  end

  subject(:groups) { described_class.new(config: config, git: git) }

  def repo(name) = make_main_checkout(File.join(@root, name))

  describe "#create" do
    it "writes <slug>.yml and returns an empty group" do
      group = groups.create("My Shop!")

      expect(group.id).to eq("group:my-shop")
      expect(group.name).to eq("My Shop!")
      expect(group.repositories).to eq([])
      expect(File.exist?(File.join(config.groups_dir, "my-shop.yml"))).to be true
    end

    it "refuses a second group with the same slug" do
      groups.create("Billing")

      expect { groups.create("billing") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("group_exists") }
    end

    it "refuses names that make no slug or an over-long one" do
      ["", "!!!", "a" * 65, "bad\nname"].each do |name|
        expect { groups.create(name) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_group_name") }
      end
    end

    it "leaves no temp files behind" do
      groups.create("Billing")

      expect(Dir.children(config.groups_dir).sort).to eq([".lock", "billing.yml"])
    end
  end

  describe "#add" do
    before { groups.create("Billing") }

    it "keys the repository by its git common dir and accepts a worktree path" do
      main = repo("api")
      worktree = make_linked_worktree(main, File.join(main, ".worktrees", "login"))

      group, repository, added = groups.add("billing", worktree)

      expect(added).to be true
      expect(repository.id).to eq(File.join(main, ".git"))
      expect(repository.path).to eq(main)
      expect(repository.name).to eq("api")
      expect(repository.exists).to be true
      expect(group.repositories.map(&:id)).to eq([File.join(main, ".git")])
    end

    it "finds the group by id, slug or name" do
      repo("api")
      repo("web")

      groups.add("group:billing", File.join(@root, "api"))
      groups.add("BILLING", File.join(@root, "web"))

      expect(groups.find("billing").repositories.map(&:name)).to eq(%w[api web])
    end

    it "does nothing when the repository is already in that group" do
      repo("api")
      groups.add("billing", File.join(@root, "api"))

      group, _repository, added = groups.add("billing", File.join(@root, "api"))

      expect(added).to be false
      expect(group.repositories.size).to eq(1)
    end

    it "refuses a repository that is in another group" do
      repo("api")
      groups.create("Other")
      groups.add("billing", File.join(@root, "api"))

      expect { groups.add("other", File.join(@root, "api")) }.to raise_error(Workspace::Error) do |e|
        expect(e.code).to eq("repository_in_group")
        expect(e.details).to include("group" => "group:billing")
      end
      expect(groups.find("other").repositories).to eq([])
    end

    it "refuses an unknown group, a missing directory and a directory outside git" do
      repo("api")
      FileUtils.mkdir_p(File.join(@root, "plain"))

      expect { groups.add("nope", File.join(@root, "api")) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_group") }
      expect { groups.add("billing", File.join(@root, "gone")) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_a_directory") }
      expect { groups.add("billing", File.join(@root, "plain")) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_a_repository") }
    end
  end

  describe "#all and #group_for_project" do
    it "reads a repository whose directory is gone as exists: false" do
      main = repo("api")
      groups.create("Billing")
      groups.add("billing", main)
      FileUtils.rm_rf(main)

      repository = groups.find("billing").repositories.first

      expect(repository.exists).to be false
      expect(repository.id).to eq(File.join(main, ".git"))
    end

    it "looks a group up by project id" do
      main = repo("api")
      groups.create("Billing")
      groups.add("billing", main)

      expect(groups.group_for_project(File.join(main, ".git")).id).to eq("group:billing")
      expect(groups.group_for_project(File.join(@root, "x", ".git"))).to be_nil
    end

    it "skips a file that can't be parsed and lists the rest sorted by slug" do
      groups.create("Zed")
      groups.create("Alpha")
      File.write(File.join(config.groups_dir, "bad.yml"), "name: [unclosed")

      expect(groups.all.map(&:slug)).to eq(%w[alpha zed])
    end

    it "refuses an add while a group file can't be read" do
      groups.create("Alpha")
      File.write(File.join(config.groups_dir, "bad.yml"), "name: [unclosed")

      expect { groups.add("alpha", repo("api")) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("config_parse") }
    end

    it "accepts a hand-written repository entry that is just a directory" do
      main = repo("api")
      groups.create("Billing")
      File.write(File.join(config.groups_dir, "billing.yml"), YAML.dump("name" => "Billing", "repositories" => [main]))

      expect(groups.find("billing").repositories.map(&:id)).to eq([File.join(main, ".git")])
    end

    it "is empty with no groups directory" do
      expect(groups.all).to eq([])
    end
  end

  describe "#groups_by_project_id" do
    it "maps each grouped repository id to its group" do
      api = repo("api")
      web = repo("web")
      groups.create("Billing")
      groups.create("Shop")
      groups.add("billing", api)
      groups.add("shop", web)

      map = groups.groups_by_project_id

      expect(map.transform_values(&:id)).to eq(File.join(api, ".git") => "group:billing", File.join(web, ".git") => "group:shop")
    end

    it "is empty with no groups" do
      expect(groups.groups_by_project_id).to eq({})
    end
  end

  describe "#unreadable" do
    it "names group files that are not YAML or not a mapping, with a message" do
      groups.create("Billing")
      File.write(File.join(@root, "groups", "bad.yml"), "name: [unclosed\n")
      File.write(File.join(@root, "groups", "list.yml"), "- a\n")

      result = groups.unreadable

      expect(result.map { |w| w["path"] }).to eq([File.join(@root, "groups", "bad.yml"), File.join(@root, "groups", "list.yml")])
      expect(result.last["message"]).to eq("not a mapping")
      expect(result.first["message"]).not_to be_empty
    end

    it "is empty when every file reads" do
      groups.create("Billing")

      expect(groups.unreadable).to eq([])
    end
  end

  describe ".group_id?" do
    it "recognizes the prefix" do
      expect(described_class.group_id?("group:billing")).to be true
      expect(described_class.group_id?("/src/api/.git")).to be false
      expect(described_class.group_id?(nil)).to be false
    end
  end
end
