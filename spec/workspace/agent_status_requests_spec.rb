require "spec_helper"

RSpec.describe Workspace::AgentStatusRequests do
  let(:now) { [Time.utc(2026, 10, 17, 22, 0, 0)] }
  let(:ids) { %w[sr-1 sr-2 sr-3] }

  subject(:requests) { described_class.new(ttl: 600, clock: -> { now[0] }, id_generator: -> { ids.shift }) }

  it "opens one request per pane, tied to the pane's pid, expiring after the ttl" do
    outcome, request = requests.open(pane_id: "%5", pane_pid: 100)

    expect(outcome).to eq(:opened)
    expect(request.to_h).to include(id: "sr-1", pane_id: "%5", pane_pid: 100, expires_at: now[0] + 600)
  end

  it "returns the open request instead of opening a second on the same pane" do
    requests.open(pane_id: "%5", pane_pid: 100)

    outcome, request = requests.open(pane_id: "%5", pane_pid: 100)

    expect([outcome, request.id]).to eq([:open, "sr-1"])
    expect(requests.open(pane_id: "%6", pane_pid: 200).first).to eq(:opened)
  end

  it "opens a new request once the pane's last one expired" do
    requests.open(pane_id: "%5", pane_pid: 100)
    now[0] += 600

    expect(requests.open(pane_id: "%5", pane_pid: 100).map { |v| v.is_a?(Symbol) ? v : v.id }).to eq([:opened, "sr-2"])
  end

  it "accepts a reply from the pane asked, with the pid recorded" do
    requests.open(pane_id: "%5", pane_pid: 100)

    code, request = requests.claim("sr-1", pane_id: "%5", pane_pid: 100)

    expect([code, request.id]).to eq([nil, "sr-1"])
  end

  it "refuses a reply from another pane and keeps the request open for the right one" do
    requests.open(pane_id: "%5", pane_pid: 100)

    expect(requests.claim("sr-1", pane_id: "%6", pane_pid: 100).first).to eq("status_reply_wrong_pane")
    expect(requests.claim("sr-1", pane_id: "%5", pane_pid: 100).first).to be_nil
  end

  it "refuses a reply from a reused pane id whose pid differs" do
    requests.open(pane_id: "%5", pane_pid: 100)

    expect(requests.claim("sr-1", pane_id: "%5", pane_pid: 999).first).to eq("status_request_stale")
    expect(requests.claim("sr-1", pane_id: "%5", pane_pid: nil).first).to eq("status_request_stale")
  end

  it "refuses an expired request once, then forgets it" do
    requests.open(pane_id: "%5", pane_pid: 100)
    now[0] += 600

    expect(requests.claim("sr-1", pane_id: "%5", pane_pid: 100).first).to eq("status_request_expired")
    expect(requests.claim("sr-1", pane_id: "%5", pane_pid: 100).first).to eq("status_request_unknown")
  end

  it "closes a request once it is claimed, and forgets a cancelled one" do
    requests.open(pane_id: "%5", pane_pid: 100)
    requests.open(pane_id: "%6", pane_pid: 200)
    requests.claim("sr-1", pane_id: "%5", pane_pid: 100)
    requests.cancel("sr-2")

    expect(requests.claim("sr-1", pane_id: "%5", pane_pid: 100).first).to eq("status_request_unknown")
    expect(requests.claim("sr-2", pane_id: "%6", pane_pid: 200).first).to eq("status_request_unknown")
    expect(requests.open(pane_id: "%5", pane_pid: 100).first).to eq(:opened)
  end

  it "lets only one of two racing replies claim a request" do
    requests.open(pane_id: "%5", pane_pid: 100)

    codes = Array.new(8) { Thread.new { requests.claim("sr-1", pane_id: "%5", pane_pid: 100).first } }.map(&:value)

    expect(codes.count(nil)).to eq(1)
    expect(codes.compact.uniq).to eq(["status_request_unknown"])
  end

  it "reopens a claimed request, unless the pane opened another meanwhile" do
    requests.open(pane_id: "%5", pane_pid: 100)
    _, claimed = requests.claim("sr-1", pane_id: "%5", pane_pid: 100)

    requests.reopen(claimed)
    expect(requests.open(pane_id: "%5", pane_pid: 100).last.id).to eq("sr-1")

    requests.claim("sr-1", pane_id: "%5", pane_pid: 100)
    requests.open(pane_id: "%5", pane_pid: 100)
    requests.reopen(claimed)
    expect(requests.claim("sr-1", pane_id: "%5", pane_pid: 100).first).to eq("status_request_unknown")
  end

  it "opens only one request when two callers race for the same pane" do
    results = Array.new(8) { Thread.new { requests.open(pane_id: "%5", pane_pid: 100).first } }.map(&:value)

    expect(results.count(:opened)).to eq(1)
  end

  it "makes ids of the documented form by default" do
    expect(described_class.new.open(pane_id: "%5", pane_pid: 1).last.id).to match(/\Asr-\h{12}\z/)
  end
end
