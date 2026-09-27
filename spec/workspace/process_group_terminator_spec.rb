require "spec_helper"

RSpec.describe Workspace::ProcessGroupTerminator do
  describe "a group this user may not signal" do
    let(:kill) { ->(_signal, _target) { raise Errno::EPERM } }
    let(:terminator) { described_class.new(own_pgid: 1, kill: kill) }

    def stub_ps(stdout)
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with({"LC_ALL" => "C"}, "ps", "-axo", "pid=,pgid=,stat=,user=", pgroup: true)
        .and_return([stdout, "", status])
    end

    it "names an owner whose user name contains spaces in full" do
      stub_ps("  4242  4242 S    John Q Smith\n  4243  4242 R+   root\n  5000  5000 S    other\n")

      expect { terminator.terminate(4242, stop_timeout: 0) }
        .to raise_error(Workspace::Error, /owned by John Q Smith, root: /)
    end

    it "ignores zombie members and other groups when naming owners" do
      stub_ps("  4242  4242 Z    ghost user\n  4243  4242 S    alice\n  5000  5000 S    bob\n")

      expect { terminator.terminate(4242, stop_timeout: 0) }
        .to raise_error(Workspace::Error, /owned by alice: /)
    end
  end
end
