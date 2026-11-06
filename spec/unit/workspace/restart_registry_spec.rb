require "spec_helper"

RSpec.describe Workspace::RestartRegistry do
  subject(:registry) { described_class.new }

  def in_thread(&block) = Thread.new(&block).value

  it "holds a pane from the first claim until its token is released" do
    expect(registry.held?("%5")).to be(false)
    token = registry.claim_for_queue("%5")

    expect(registry.held?("%5")).to be(true)
    expect(registry.claim_for_queue("%5")).to be_nil
    expect(in_thread { registry.claim_for_recovery("%5") }).to be_nil
    expect(registry.claim_pending("%5")).to be(false)

    registry.release("%5", token)
    expect(registry.held?("%5")).to be(false)
  end

  it "releases only the claim the token names" do
    token = registry.claim_for_queue("%5")
    registry.release("%5", Object.new)
    expect(registry.held?("%5")).to be(true)
    registry.release("%5", token)
    expect(registry.held?("%5")).to be(false)
  end

  it "makes a recovery claim with the calling thread as the token" do
    thread = Thread.new do
      token = registry.claim_for_recovery("%5")
      [token, Thread.current]
    end
    token, owner = thread.value
    expect(token).to equal(owner)
  end

  it "refuses recovery claims after shut_down!, but still lets a queue claim through" do
    registry.shut_down!

    expect(in_thread { registry.claim_for_recovery("%5") }).to be_nil
    expect(registry.held?("%5")).to be(false)
    expect(registry.claim_for_queue("%6")).not_to be_nil
  end

  it "reserves a pane before its worker starts and gives the reservation up" do
    expect(registry.claim_pending("%5")).to be(true)
    expect(registry.claim_pending("%5")).to be(false)

    registry.abandon_pending("%5")
    expect(registry.held?("%5")).to be(false)
  end

  it "leaves a held pane alone when abandoning a reservation it does not hold" do
    registry.claim_for_queue("%5")
    registry.abandon_pending("%5")
    expect(registry.held?("%5")).to be(true)
  end

  it "records the worker as the claim before it can release the pane, and the worker's release frees it" do
    registry.claim_pending("%5")
    done = Queue.new
    registry.start_worker("%5") do
      registry.release("%5")
      done << true
    end

    expect(done.pop(timeout: 2)).to be(true)
    expect(registry.held?("%5")).to be(false)
  end

  it "starts workers through the injected spawn" do
    spawned = []
    spawn = lambda do |&work|
      spawned << work
      Thread.new {}
    end
    registry = described_class.new(spawn: spawn)

    registry.claim_pending("%5")
    registry.start_worker("%5") {}

    expect(spawned.size).to eq(1)
    expect(registry.held?("%5")).to be(true)
  end

  it "stop_all kills and joins every worker thread and ignores other claims" do
    started = Queue.new
    registry.claim_pending("%5")
    worker = registry.start_worker("%5") do
      started << true
      sleep
    end
    started.pop(timeout: 2)
    registry.claim_for_queue("%6")

    registry.stop_all

    expect(worker.alive?).to be(false)
    expect(registry.held?("%6")).to be(true)
  end
end
