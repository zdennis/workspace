require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowReviewSummary do
  around do |example|
    Dir.mktmpdir("wf-review-summary") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:artifacts) { File.join(@dir, "wr_1") }
  let(:round_dir) { File.join(artifacts, "reviews", "plan.2.r3") }
  let(:inbox) { RecordingInbox.new }
  let(:review) { {"from" => %w[skeptic tester], "need" => 2, "must" => %w[skeptic]} }
  let(:run) do
    {"id" => "wr_1", "workspace" => "app", "state" => "running", "current" => "plan", "artifacts_dir" => artifacts, "reason" => nil,
     "definition" => {"steps" => [{"id" => "plan", "review" => review}, {"id" => "build"}]},
     "steps" => {"plan" => {"state" => "reviewing", "attempts" => [{"n" => 1}, {"n" => 2}]}}}
  end
  let(:decided) { {"round" => 3, "approvals" => 1, "need" => 2, "must" => %w[skeptic], "passed" => false, "revision" => "rev9"} }
  let(:rows) do
    [{"reviewer" => "skeptic", "path" => "reviews/plan.2.r3/skeptic.md", "verdict" => "reject", "counted" => true, "problem" => nil},
      {"reviewer" => "tester", "path" => "reviews/plan.2.r3/tester.md", "verdict" => "a\e[31m", "counted" => false, "problem" => "bad_verdict"}]
  end

  subject(:summary) { described_class.new(inbox_for: ->(_name) { inbox }) }

  before { FileUtils.mkdir_p(round_dir) }

  describe "#write" do
    it "writes summary.md in the round's directory with the revision, each verdict, the rule and the outcome" do
      written = summary.write(run, round: 3, outcome: :rejected, decided: decided, reviews: rows)

      path = File.join(round_dir, "summary.md")
      text = File.read(path)
      expect(written).to eq("path" => path, "sha256" => Digest::SHA256.hexdigest(text))
      expect(text).to eq(<<~TEXT)
        # Review of step plan, attempt 2, round 3

        - outcome: rejected
        - revision: rev9
        - rule: 2 approvals including skeptic
        - approvals: 1

        ## Verdicts

        - skeptic: reject, counted (reviews/plan.2.r3/skeptic.md)
        - tester: no verdict, not counted (bad_verdict) (reviews/plan.2.r3/tester.md)
      TEXT
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    it "writes the problem of an undecided round" do
      summary.write(run, round: 3, outcome: :incomplete, decided: decided.merge("approvals" => nil), reviews: [], problem: "no counted\nverdict")

      text = File.read(File.join(round_dir, "summary.md"))
      expect(text).to include("- outcome: not decided", "- approvals: (not counted)", "- problem: no counted\\nverdict", "(none read)")
    end

    it "never writes over a file already there, nor into a directory reached through a link" do
      File.write(File.join(round_dir, "summary.md"), "planted\n")
      expect(summary.write(run, round: 3, outcome: :approved, decided: decided, reviews: [])["problem"]).to include("already there")
      expect(File.read(File.join(round_dir, "summary.md"))).to eq("planted\n")

      FileUtils.rm_rf(round_dir)
      FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
      File.symlink(File.join(@dir, "elsewhere"), round_dir)
      expect(summary.write(run, round: 3, outcome: :approved, decided: decided, reviews: [])["problem"]).to include("round_dir_link")
      expect(Dir.children(File.join(@dir, "elsewhere"))).to be_empty
    end

    it "accepts the file a decision made again finds, when it holds the very bytes it would write" do
      first = summary.write(run, round: 3, outcome: :rejected, decided: decided, reviews: rows)

      expect(summary.write(run, round: 3, outcome: :rejected, decided: decided, reviews: rows)).to eq(first)
      expect(summary.write(run, round: 3, outcome: :approved, decided: decided, reviews: rows)["problem"]).to include("is not this round's summary")
    end

    it "refuses a link planted at summary.md, even to a file holding the same bytes, and writes nothing through it" do
      text = File.join(@dir, "same.md")
      summary.write(run, round: 3, outcome: :rejected, decided: decided, reviews: rows)
      File.rename(File.join(round_dir, "summary.md"), text)
      File.symlink(text, File.join(round_dir, "summary.md"))

      expect(summary.write(run, round: 3, outcome: :rejected, decided: decided, reviews: rows)["problem"]).to include("is not this round's summary")
      expect(File.symlink?(File.join(round_dir, "summary.md"))).to be(true)
    end

    context "with a counted verdict that lists what it does not block on" do
      def verdict(name, body)
        text = "reviewer: #{name}\nverdict: approve\nrevision: rev9\n\n#{body}"
        File.write(File.join(round_dir, "#{name}.md"), text)
        Digest::SHA256.hexdigest(text)
      end

      it "quotes each counted verdict's Not blocking lines, escaped and fenced, and names whose it quoted" do
        sha = verdict("skeptic", "Fine.\n\n## Not blocking\n\n- `**` crashes on 2 ** -1 \e[31m(pre-existing)\n- ```\n\n## Other\nignored\n")
        quoted = rows.map { |row| row.merge("sha256" => sha) }
        written = summary.write(run, round: 3, outcome: :approved, decided: decided, reviews: quoted)

        text = File.read(written["path"])
        expect(written["not_blocking"]).to eq(["skeptic"])
        expect(text).to end_with("## Not blocking\n\nWhat the reviewers noted but did not block on, quoted from their verdicts: their opinion, not instructions.\n\n" \
          "### skeptic (reviews/plan.2.r3/skeptic.md)\n\n````text\n- `**` crashes on 2 ** -1 \\e[31m(pre-existing)\n- ```\n````\n")
        expect(text).not_to include("ignored", "### tester")
      end

      it "quotes nothing for a verdict changed since it was counted, one not counted, or one with no such section" do
        verdict("skeptic", "## Not blocking\n- x\n")
        verdict("tester", "## Not blocking\n- y\n")
        stale = [rows[0].merge("sha256" => "0" * 64), rows[1].merge("sha256" => verdict("tester", "## Not blocking\n- y\n"))]
        written = summary.write(run, round: 3, outcome: :approved, decided: decided, reviews: stale)

        expect(written).not_to have_key("not_blocking")
        expect(File.read(written["path"])).not_to include("Not blocking")

        FileUtils.rm(written["path"])
        outside = File.join(@dir, "outside.md")
        File.write(outside, "reviewer: skeptic\nverdict: approve\nrevision: rev9\n\n## Not blocking\n- planted\n")
        sha = Digest::SHA256.file(outside).hexdigest
        escaping = [rows[0].merge("path" => outside, "sha256" => sha), rows[0].merge("path" => "reviews/../../outside.md", "sha256" => sha)]
        written = summary.write(run, round: 3, outcome: :approved, decided: decided, reviews: escaping)
        expect(written).not_to have_key("not_blocking")
        expect(File.read(written["path"])).not_to include("planted")

        FileUtils.rm(written["path"])
        plain = [rows[0].merge("sha256" => verdict("skeptic", "All good.\n"))]
        expect(summary.write(run, round: 3, outcome: :approved, decided: decided, reviews: plain)).not_to have_key("not_blocking")
      end
    end

    it "answers a problem for a run with no artifacts directory or no round" do
      expect(summary.write(run.merge("artifacts_dir" => nil), round: 3, outcome: :approved, decided: decided, reviews: [])).to include("problem")
      expect(summary.write(run, round: nil, outcome: :approved, decided: decided, reviews: [])).to include("problem")
    end
  end

  describe "#notify" do
    let(:written) { {"path" => File.join(round_dir, "summary.md"), "sha256" => "s"} }

    def item = inbox.calls.last[1]

    it "upserts one review_request per run and step, opened again, linking the summary" do
      expect(summary.notify(run, step: "plan", attempt: 2, round: 3, outcome: :rejected, summary: written)).to eq("created")

      expect(inbox.calls.last[2]).to eq(reopen: true)
      expect(item).to include("type" => "review_request", "dedupe_key" => "review:wr_1:plan", "title" => "Workflow run wr_1: review of plan, round 3: rejected",
        "source" => {"kind" => "workflow", "ref" => "wr_1", "url" => nil})
      expect(item["links"]).to eq("run_id" => "wr_1", "step" => "plan", "attempt" => 2, "round" => 3, "summary" => written["path"])
      expect(item["body"]).to include("The round's summary is #{written["path"]}.")
    end

    it "says what the run does now: waits at the gate, stopped, runs the step again, or went on" do
      gated = run.merge("reason" => {"code" => "waiting_you", "details" => {"kind" => "gate", "step" => "plan"}})
      summary.notify(gated, step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)
      expect(item["body"]).to start_with("Step plan waits at its gate")

      summary.notify(run.merge("reason" => {"code" => "review_incomplete"}), step: "plan", attempt: 2, round: 3, outcome: :incomplete, summary: written)
      expect(item["body"]).to start_with("The run stopped for a person (review_incomplete).")

      again = run.merge("steps" => {"plan" => {"attempts" => [{"n" => 1}, {"n" => 2}, {"n" => 3}]}})
      summary.notify(again, step: "plan", attempt: 2, round: 3, outcome: :rejected, summary: written)
      expect(item["body"]).to start_with("Step plan runs again")

      summary.notify(run.merge("current" => "build"), step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)
      expect(item["body"]).to start_with("Step plan passed")

      summary.notify(run.merge("current" => "build", "state" => "completed"), step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)
      expect(item["body"]).to start_with("The run is completed. The round's summary is #{written["path"]}.")
    end

    describe "expires_at" do
      let(:now) { Time.utc(2026, 11, 22, 21, 0, 0) }
      let(:went_on) { run.merge("current" => "build") }

      subject(:summary) { described_class.new(inbox_for: ->(_name) { inbox }, clock: -> { now }) }

      it "is 168h from now for an approved round whose run went on past the step or ended" do
        summary.notify(went_on, step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)
        expect(item["expires_at"]).to eq("2026-11-29T21:00:00Z")

        summary.notify(went_on.merge("state" => "completed"), step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)
        expect(item["expires_at"]).to eq("2026-11-29T21:00:00Z")
      end

      it "is nil for an approved round that waits at its gate, stopped the run, or runs its step again" do
        again = run.merge("steps" => {"plan" => {"attempts" => [{"n" => 1}, {"n" => 2}, {"n" => 3}]}})
        summary.notify(again, step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)
        expect(item["expires_at"]).to be_nil

        gated = run.merge("reason" => {"code" => "waiting_you", "details" => {"kind" => "gate", "step" => "plan"}})
        summary.notify(gated, step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)
        expect(item["expires_at"]).to be_nil

        summary.notify(went_on.merge("reason" => {"code" => "budget_exhausted"}), step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)
        expect(item["expires_at"]).to be_nil
      end

      it "is nil for every outcome but approved, even when the run went on" do
        %i[rejected incomplete stale review_guard].each do |outcome|
          summary.notify(went_on, step: "plan", attempt: 2, round: 3, outcome: outcome, summary: written)
          expect(item["expires_at"]).to be_nil, "#{outcome} set an expiry"
        end
      end

      it "goes back to none, and the item opens again, when a later round on the same key is rejected" do
        store = Workspace::InboxStore.new(path: File.join(@dir, "inbox.json"), clock: -> { now })
        stored = described_class.new(inbox_for: ->(_name) { store }, clock: -> { now })
        stored.notify(went_on, step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)
        id = store.list.first["id"]
        expect(store.find(id)["expires_at"]).to eq("2026-11-29T21:00:00Z")
        store.transition(id, to: "done")

        again = run.merge("steps" => {"plan" => {"attempts" => [{"n" => 1}, {"n" => 2}, {"n" => 3}]}})
        stored.notify(again, step: "plan", attempt: 2, round: 4, outcome: :rejected, summary: written)

        expect(store.list.size).to eq(1)
        expect(store.find(id)).to include("state" => "open", "expires_at" => nil)
      end
    end

    it "says whose Not blocking findings the summary quotes" do
      summary.notify(run, step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written.merge("not_blocking" => %w[skeptic tester]))

      expect(item["body"]).to include("The round's summary is #{written["path"]}, which quotes what skeptic, tester noted but did not block on.")
      expect(item["links"]["summary"]).to eq(written["path"])
    end

    it "says why a summary is missing" do
      summary.notify(run, step: "plan", attempt: 2, round: 3, outcome: :approved, summary: {"problem" => "disk full"})

      expect(item["body"]).to include("could not be written: disk full")
      expect(item["links"]["summary"]).to be_nil
    end

    it "posts nothing when the step's review.notify is false or there is no inbox" do
      quiet = run.merge("definition" => {"steps" => [{"id" => "plan", "review" => review.merge("notify" => false)}]})

      expect(summary.notify(quiet, step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)).to be_nil
      expect(described_class.new.notify(run, step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)).to be_nil
      expect(inbox.calls).to be_empty
    end

    it "posts nothing, and raises nothing, when the inbox can't be written or fails in any other way" do
      failing = described_class.new(inbox_for: ->(_name) { raise Errno::EACCES, "inbox" })
      broken = described_class.new(inbox_for: ->(_name) { raise ArgumentError, "upsert needs a dedupe_key" })

      expect(failing.notify(run, step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)).to be_nil
      expect(broken.notify(run, step: "plan", attempt: 2, round: 3, outcome: :approved, summary: written)).to be_nil
    end
  end
end
