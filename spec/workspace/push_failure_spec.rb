require "spec_helper"

RSpec.describe Workspace::PushFailure do
  samples_by_code = {
    "no_remote" => [
      "fatal: 'origin' does not appear to be a git repository\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n",
      "fatal: No configured push destination.\nEither specify the URL from the command-line or configure a remote repository using\n",
      "fatal: No such remote: 'origin'\n",
      "remote: Repository not found.\nfatal: repository 'https://github.com/acme/gone.git/' not found\n",
      "fatal: unable to access 'https://example.com/acme/api.git/': The requested URL returned error: 404\n"
    ],
    "push_auth_failed" => [
      "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n",
      "remote: Permission to acme/api.git denied to octocat.\nfatal: unable to access 'https://github.com/acme/api.git/': The requested URL returned error: 403\n",
      "fatal: Authentication failed for 'https://github.com/acme/api.git/'\n",
      "Host key verification failed.\nfatal: Could not read from remote repository.\n",
      "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\nHost key verification failed.\n",
      "remote: GitLab: You are not allowed to push code to this project.\nfatal: unable to access 'https://gitlab.com/a/b.git/': The requested URL returned error: 403\n",
      "remote: HTTP Basic: Access denied\nfatal: Authentication failed for 'https://gitlab.com/a/b.git/'\n",
      "fatal: unable to access 'https://proxy.corp/': Received HTTP code 407 from proxy after CONNECT\n",
      "fatal: unable to access 'https://x/': Proxy Authentication Required\n",
      "LFS: Authorization error: https://github.com/acme/api.git/info/lfs/objects/batch\nerror: failed to push some refs to 'github.com:acme/api.git'\n",
      "fatal: Git credentials for 'https://github.com' not found.\n",
      "To github.com:acme/api.git\n ! [remote rejected] main -> main (refusing to allow an OAuth App to create or update workflow `.github/workflows/ci.yml` without `workflow` scope)\n",
      "fatal: unable to access 'https://github.com/a/b.git/': The requested URL returned error: 401\n",
      "LFS: Client error https://x/info/lfs/objects/batch: 401\nerror: failed to push some refs to 'x'\n",
      "LFS: Client error https://x/info/lfs/objects/batch: 403\nerror: failed to push some refs to 'x'\n"
    ],
    "protected_branch" => [
      "remote: error: GH006: Protected branch update failed for refs/heads/main.\nTo github.com:acme/api.git\n ! [remote rejected] main -> main (protected branch hook declined)\n",
      "remote: error: GH013: Repository rule violations found for refs/heads/main.\n",
      "remote: GitLab: You are not allowed to push code to protected branches on this project.\n",
      "remote: error: Branch 'main' is protected from force push\n"
    ],
    "push_rejected" => [
      "To github.com:acme/api.git\n ! [rejected]        feature/x -> feature/x (non-fast-forward)\nerror: failed to push some refs\n",
      " ! [rejected]        feature/x -> feature/x (fetch first)\n",
      " ! [rejected]        feature/x -> feature/x (stale info)\n",
      "To x\n ! [rejected]        main -> main (non-fast-forward)\nhint: Updates were rejected because the tip of your current branch is behind\n",
      "To x\n ! [rejected]        main -> main (fetch first)\nhint: Updates were rejected because the remote contains work that you do\n",
      "To x\n ! [remote rejected] main -> main (non-fast-forward)\n"
    ],
    "push_network" => [
      "fatal: unable to access 'https://github.com/acme/api.git/': Could not resolve host: github.com\n",
      "ssh: connect to host github.com port 22: Operation timed out\nfatal: Could not read from remote repository.\n",
      "fatal: unable to access 'https://github.com/acme/api.git/': Failed to connect to github.com port 443 after 75003 ms: Couldn't connect to server\n",
      "error: RPC failed; HTTP 502 curl 22 The requested URL returned error: 502\nfatal: the remote end hung up unexpectedly\n",
      "error: RPC failed; curl 56 OpenSSL SSL_read: Connection reset by peer, errno 54\nfatal: the remote end hung up unexpectedly\n",
      "fatal: unable to access 'https://github.com/a/b.git/': The requested URL returned error: 429\n",
      "error: RPC failed; HTTP 503 curl 22 The requested URL returned error: 503\n",
      "kex_exchange_identification: Connection closed by remote host\nConnection closed by 140.82.112.4 port 22\nfatal: Could not read from remote repository.\n",
      "fatal: unable to access 'https://x/': Could not resolve proxy: proxy.corp\n",
      "fatal: unable to access 'https://x/': Failed to connect to proxy.corp port 3128 after 5 ms: Connection refused\n",
      "error: cannot lock ref 'refs/heads/main': is at 1111 but expected 2222\n! [remote rejected] main -> main (failed to update ref)\n",
      "send-pack: unexpected disconnect while reading sideband packet\nfatal: the remote end hung up unexpectedly\n",
      "pack-objects: unexpected disconnect\nerror: failed to push some refs to 'github.com:acme/api.git'\n",
      "Connection to github.com closed by remote host.\nfatal: Could not read from remote repository.\n",
      "fatal: unable to access 'https://x/': The requested URL returned error: 408\n",
      "fatal: the remote end hung up unexpectedly\n",
      "client_loop: send disconnect: Broken pipe\nfatal: Could not read from remote repository.\n"
    ],
    "push_failed" => [
      "error: RPC failed; HTTP 413 curl 22 The requested URL returned error: 413\nfatal: the remote end hung up unexpectedly\n",
      "remote: error: GH001: Large files detected. You may want to try Git Large File Storage.\nTo github.com:acme/api.git\n ! [remote rejected] main -> main (pre-receive hook declined)\n",
      "remote: commit message must start with a ticket key\nTo x\n ! [remote rejected] main -> main (pre-receive hook declined)\n",
      "remote: Rejected: your IP is blocked\nfatal: unable to access 'https://x/'\n",
      "To x\n ! [remote rejected] main -> main (failed to update ref)\nerror: failed to push some refs\n",
      "To x\n ! [remote rejected] main -> main (refusing to update checked out branch: refs/heads/main)\n",
      "husky - pre-push hook: 2 tests rejected by the linter\nerror: failed to push some refs to 'x'\n",
      "fatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n",
      "fatal: Konnte nicht vom Remote-Repository lesen.\n",
      "error: something git has never said before\nhint: really\n",
      "",
      "\xFF\xFEerror: \xC3\x28 broken bytes\n".b
    ]
  }.freeze

  samples_by_code.each do |code, samples|
    samples.each_with_index do |stderr, i|
      it "classifies #{code} sample #{i + 1}" do
        expect(described_class.classify(stderr)).to eq(code)
        expect(Workspace::ErrorCodes.known?(code)).to be true
      end
    end
  end

  it "does not let text from a local pre-push hook pick the code" do
    stderr = "pre-push: connection refused by the test database, push rejected\nerror: failed to push some refs to 'x'\n"

    expect(described_class.classify(stderr)).to eq("push_failed")
  end

  it "gives push_failed for nil stderr" do
    expect(described_class.error("b", nil)).to have_attributes(code: "push_failed", retry: nil)
  end

  it "puts the stderr and permanent: true in a push_failed error" do
    error = described_class.error("feature/x", "error: something git has never said before\nhint: really\n")

    expect(error.details).to include("branch" => "feature/x", "detail" => "error: something git has never said before", "permanent" => true)
    expect(error.details["stderr"]).to include("hint: really")
    expect(error.retry).to be_nil
  end

  it "prefers the fatal, error or remote line for the detail" do
    error = described_class.error("b", "To x\nremote: nope\n")

    expect(error.details["detail"]).to eq("remote: nope")
  end

  it "survives invalid UTF-8" do
    error = described_class.error("b", "fatal: bad \xFF bytes\n".b)

    expect(error.details["detail"]).to be_a(String)
    expect(error.details["detail"]).to be_valid_encoding
  end

  it "marks only push_network as temporary, and gives it the retry hint" do
    samples_by_code.each do |code, list|
      error = described_class.error("b", list.first)
      expect(error.details["permanent"]).to be(code != "push_network")
      expect(error.retry).to((code == "push_network") ? eq("flags" => [], "destructive" => false) : be_nil)
    end
  end

  it "registers every code" do
    expect(described_class::CODES - Workspace::ErrorCodes::REGISTRY.keys).to eq([])
  end

  describe "a push that runs past its limit" do
    let(:argvs) { [] }
    let(:git) do
      Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: ->(argv, chdir:, timeout:, env: {}) {
        argvs << [argv, env]
        raise Timeout::Error
      })
    end

    it "is push_timeout: not permanent, state unknown, no retry hint" do
      expect { git.push("/tmp", "feature/x") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("push_timeout")
        expect(e.details).to include("branch" => "feature/x", "seconds" => 120, "permanent" => false, "state_unknown" => true)
        expect(e.retry).to be_nil
        expect(e.message).to include("120 seconds", "ls-remote")
      }
    end

    it "runs git push in English" do
      expect { git.push("/tmp", "feature/x") }.to raise_error(Workspace::Error)

      expect(argvs.first).to eq([%w[git push origin feature/x], {"LC_ALL" => "C", "LANGUAGE" => "C"}])
    end
  end

  describe "the --json envelope" do
    it "has no retry and permanent: true for a permanent failure" do
      doc = Workspace::JsonEnvelope.from_exception(1, described_class.error("feature/x", "git@github.com: Permission denied (publickey).\n"))

      expect(doc).to include("ok" => false, "code" => "push_auth_failed")
      expect(doc["details"]).to include("permanent" => true)
      expect(doc).not_to have_key("retry")
    end

    it "says to retry the same command for a temporary failure" do
      doc = Workspace::JsonEnvelope.from_exception(1, described_class.error("feature/x", "fatal: Could not resolve host: github.com\n"))

      expect(doc).to include("ok" => false, "code" => "push_network", "retry" => {"flags" => [], "destructive" => false})
      expect(doc["details"]).to include("permanent" => false)
    end

    it "has no plain retry for a timeout" do
      doc = Workspace::JsonEnvelope.from_exception(1, described_class.timeout_error("feature/x", 120))

      expect(doc).to include("code" => "push_timeout")
      expect(doc["details"]).to include("permanent" => false, "state_unknown" => true)
      expect(doc).not_to have_key("retry")
    end
  end
end
