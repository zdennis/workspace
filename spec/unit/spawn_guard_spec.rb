require "spec_helper"
require "open3"

RSpec.describe SpawnGuard do
  it "runs unit examples under an active token" do
    expect(Fiber[:spawn_guard]).to have_attributes(tier: :unit, active: true)
  end

  it "blocks a spawn before the process starts" do
    marker = File.join(Dir.mktmpdir, "ran")

    expect { system("touch", marker) }.to raise_error(SpawnGuard::Violation)
    expect(File.exist?(marker)).to be(false)
  ensure
    Fiber[:spawn_guard].violations.clear
  end

  it "records a spawn that the code under test rescues" do
    begin
      `true`
    rescue Exception # standard:disable Lint/RescueException
      nil
    end

    expect(Fiber[:spawn_guard].violations).to contain_exactly(a_string_starting_with("` \"true\""))
  ensure
    Fiber[:spawn_guard].violations.clear
  end

  it "records a spawn from a thread the example starts" do
    Thread.new do
      Open3.capture2("true")
    rescue SpawnGuard::Violation
      nil
    end.join

    expect(Fiber[:spawn_guard].violations).to contain_exactly(a_string_starting_with("spawn \"true\""))
  ensure
    Fiber[:spawn_guard].violations.clear
  end

  it "covers explicit receivers such as Kernel.exec and Process.spawn" do
    expect { Kernel.exec("true") }.to raise_error(SpawnGuard::Violation)
    expect { Process.spawn("true") }.to raise_error(SpawnGuard::Violation)
    expect { IO.popen(["true"]) }.to raise_error(SpawnGuard::Violation)
    expect { PTY.getpty("true") }.to raise_error(SpawnGuard::Violation)
    expect(Fiber[:spawn_guard].violations.size).to eq(4)
  ensure
    Fiber[:spawn_guard].violations.clear
  end

  it "lets a stubbed Open3 through without recording it" do
    allow(Open3).to receive(:capture3).and_return(["", "", nil])

    Open3.capture3("git", "status")

    expect(Fiber[:spawn_guard].violations).to be_empty
  end

  it "lets a spawn through once the token is inactive" do
    token = SpawnGuard::Token.new(:unit, [], false)
    previous = Fiber[:spawn_guard]
    Fiber[:spawn_guard] = token

    expect(system("true")).to be(true)
    expect(token.violations).to be_empty
  ensure
    Fiber[:spawn_guard] = previous
  end

  describe ".guard" do
    let(:fake_example) do
      Struct.new(:metadata, :body) do
        def run = body.call
      end
    end

    it "fails a unit example whose code rescued the violation" do
      example = fake_example.new({type: :unit}, -> {
        begin
          system("true")
        rescue Exception # standard:disable Lint/RescueException
          nil
        end
      })

      expect { SpawnGuard.guard(example) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /unit specs may not start a process.*system "true"/m)
    end

    it "points the failure at the caller, not at the standard library" do
      example = fake_example.new({type: :integration}, -> {
        begin
          Open3.capture2("true")
        rescue SpawnGuard::Violation
          nil
        end
      })

      expect { SpawnGuard.guard(example) }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /spawn_guard_spec\.rb/)
    end

    it "puts the outer token back afterwards" do
      outer = Fiber[:spawn_guard]

      SpawnGuard.guard(fake_example.new({type: :unit}, -> {}))

      expect(Fiber[:spawn_guard]).to be(outer)
    end
  end

  describe ".check!" do
    it "fails the example when the token holds a violation" do
      token = SpawnGuard::Token.new(:integration, ["system \"git status\" (x.rb:1)"], false)

      expect { SpawnGuard.check!(token) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /integration specs may not start a process.*git status/m)
    end

    it "passes when the token holds none" do
      expect { SpawnGuard.check!(SpawnGuard::Token.new(:unit, [], false)) }.not_to raise_error
    end
  end

  describe "a group typed system inside a unit file", type: :system do
    it "may spawn" do
      expect(Fiber[:spawn_guard]).to be_nil
      expect(system("true")).to be(true)
    end
  end
end
