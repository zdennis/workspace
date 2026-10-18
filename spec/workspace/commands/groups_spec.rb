require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

RSpec.describe Workspace::Commands::Groups do
  include FakeCheckouts

  let(:output) { StringIO.new }

  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  let(:config) do
    Struct.new(:groups_dir) do
      def group_path(slug) = File.join(groups_dir, "#{slug}.yml")
    end.new(File.join(@root, "groups"))
  end

  let(:store) { Workspace::ProjectGroups.new(config: config, git: Workspace::Git.new(output: StringIO.new, input: StringIO.new)) }

  subject(:command) { described_class.new(groups: store, output: output) }

  def json = JSON.parse(output.string.lines.last)

  describe "#create" do
    it "prints the group in text" do
      expect(command.create(name: "Billing")).to eq({exit_code: 0})
      expect(output.string).to include("Created group Billing (group:billing)")
    end

    it "prints one document with --json" do
      command.create(name: "Billing", json: true)

      expect(json).to include("schema_version" => 1, "ok" => true, "action" => "create")
      expect(json["group"]).to include("id" => "group:billing", "name" => "Billing", "repositories" => [])
    end

    it "prints a coded error document with --json and exits 1" do
      command.create(name: "Billing")
      output.truncate(0)
      output.rewind

      expect(command.create(name: "billing", json: true)).to eq({exit_code: 1})
      expect(json).to include("ok" => false, "code" => "group_exists")
    end

    it "raises without --json" do
      command.create(name: "Billing")

      expect { command.create(name: "billing") }.to raise_error(Workspace::Error, /already exists/)
    end
  end

  describe "#add" do
    before do
      make_main_checkout(File.join(@root, "api"))
      command.create(name: "Billing")
      output.truncate(0)
      output.rewind
    end

    it "reports the outcome and the repository in JSON" do
      command.add(group: "billing", path: File.join(@root, "api"), json: true)

      expect(json).to include("action" => "add", "outcome" => "added")
      expect(json["repository"]).to eq("id" => File.join(@root, "api", ".git"), "name" => "api", "path" => File.join(@root, "api"), "exists" => true)
      expect(json["group"]["repositories"].size).to eq(1)
    end

    it "says already_member the second time" do
      command.add(group: "billing", path: File.join(@root, "api"))
      command.add(group: "billing", path: File.join(@root, "api"), json: true)

      expect(output.string).to include("Added group:billing: api")
      expect(json["outcome"]).to eq("already_member")
    end

    it "refuses a repository of another group with its code" do
      command.create(name: "Other")
      command.add(group: "billing", path: File.join(@root, "api"))
      output.truncate(0)
      output.rewind

      expect(command.add(group: "other", path: File.join(@root, "api"), json: true)).to eq({exit_code: 1})
      expect(json).to include("ok" => false, "code" => "repository_in_group")
    end
  end

  describe "#list" do
    it "says there are no groups" do
      command.list

      expect(output.string).to include("No groups")
    end

    it "prints a table with the number of missing repositories" do
      main = make_main_checkout(File.join(@root, "api"))
      command.create(name: "Billing")
      command.add(group: "billing", path: main)
      FileUtils.rm_rf(main)
      output.truncate(0)
      output.rewind

      command.list

      expect(output.string).to match(/GROUP\s+NAME\s+REPOSITORIES\s+MEMBERS\s+NOTE/)
      expect(output.string).to match(/group:billing\s+Billing\s+1\s+api\s+\(1 missing\)/)
    end

    it "prints every group with --json" do
      command.create(name: "Billing")
      command.create(name: "Admin")
      output.truncate(0)
      output.rewind

      command.list(json: true)

      expect(json["groups"].map { |g| g["id"] }).to eq(%w[group:admin group:billing])
    end
  end
end
