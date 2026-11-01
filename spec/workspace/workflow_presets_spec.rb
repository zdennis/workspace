require "spec_helper"
require "tmpdir"

RSpec.describe "the shipped workflow presets" do
  let(:config) { Workspace::Config.new }
  let(:dir) { Dir.mktmpdir }
  let(:catalog) { Workspace::WorkflowCatalog.new(config: config) }
  let(:ids) { Dir[File.join(config.builtin_workflows_dir, "*.yml")].map { |path| File.basename(path, ".yml") }.sort }

  before { allow(config).to receive(:workflows_dir).and_return(File.join(dir, "none")) }
  after { FileUtils.remove_entry(dir) }

  it "parses every file in lib/workflows" do
    expect(ids).to include("rpiv", "rpiv-auto-approve", "pr-feedback", "investigate", "explore")
    ids.each { |id| expect(catalog.find(id).source).to eq("builtin") }
  end

  it "ties every inbox_item proof to a key its step's prompt posts with --reopen" do
    ids.each do |id|
      catalog.find(id).to_h["steps"].each do |step|
        Array(step["require"]).filter_map { |entry| entry["inbox_item"] }.each do |key|
          prompt = step["prompt"].gsub(/\s+/, " ")
          expect(prompt).to include("--dedupe-key #{key}"), "#{id}/#{step["id"]} never posts #{key}"
          expect(prompt).to match(/--dedupe-key #{Regexp.escape(key)}[^`]*--reopen|--reopen[^`]*--dedupe-key #{Regexp.escape(key)}/), "#{id}/#{step["id"]} posts #{key} without --reopen"
        end
      end
    end
  end

  it "proves the inbox item of exactly the steps that post one on every successful path" do
    expected = {
      "explore" => %w[survey report],
      "pr-feedback" => %w[triage fix],
      "investigate" => %w[diagnose fix],
      "rpiv" => [],
      "rpiv-auto-approve" => []
    }
    expect(expected.keys.sort).to eq(ids)
    expected.each do |id, step_ids|
      proven = catalog.find(id).to_h["steps"].select { |step| Array(step["require"]).any? { |entry| entry.key?("inbox_item") } }
      expect(proven.map { |step| step["id"] }).to eq(step_ids), id
    end
  end

  describe "rpiv and rpiv-auto-approve" do
    %w[rpiv rpiv-auto-approve].each do |id|
      it "#{id} requires a commit and a done plan to implement, and a passing lint to verify" do
        steps = catalog.find(id).to_h["steps"]
        by_id = ->(name) { steps.find { |step| step["id"] == name } }

        expect(by_id.call("implement")["require"]).to eq([{"commits" => 1}, {"plan_status" => "done"}])
        expect(by_id.call("verify")["require"]).to eq([{"command" => "lint", "optional" => true}])
        expect(by_id.call("implement")["prompt"]).to include("then set the plan's\n`status: done`")
      end
    end

    it "makes the lint proof optional, so a project without a lint command still runs" do
      %w[rpiv rpiv-auto-approve].each do |id|
        verify = catalog.find(id).to_h["steps"].find { |step| step["id"] == "verify" }
        expect(verify["require"]).to eq([{"command" => "lint", "optional" => true}])
        expect(verify["prompt"]).to include("lint command, when it has one, must pass")
      end
    end

    it "tells implement never to amend or rebase, and to commit empty when nothing needs changing" do
      %w[rpiv rpiv-auto-approve].each do |id|
        implement = catalog.find(id).to_h["steps"].find { |step| step["id"] == "implement" }
        expect(implement["prompt"].gsub(/\s+/, " ")).to include("never amend or rebase").and include("git commit --allow-empty -m '<why>'")
      end
    end
  end

  describe "explore" do
    let(:steps) { catalog.find("explore").to_h["steps"] }

    it "keys the report's item apart from the survey's, which the report closes" do
      survey, report = steps.map { |step| [step["prompt"].gsub(/\s+/, " "), step["require"].first["inbox_item"]] }
      expect(survey.last).not_to eq(report.last)
      expect(report.first).to include("workspace inbox done --dedupe-key #{survey.last}").and include("--dedupe-key #{report.last} --reopen")
    end
  end
end
