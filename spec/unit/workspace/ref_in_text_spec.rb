require "spec_helper"

RSpec.describe Workspace::RefInText do
  def tokens(text)
    described_class.scan(text).map(&:token)
  end

  # One row per line of the T2 rules: [rule, text, tokens found].
  rules = [
    ["token: a canonical pull request URL, no tail", "see https://github.com/o/r/pull/12/files?x=1#top now", ["https://github.com/o/r/pull/12"]],
    ["token: a canonical issue URL, no trailing punctuation", "fix https://github.com/o/r/issues/7).", ["https://github.com/o/r/issues/7"]],
    ["token: the uppercase JIRA key for a bare key", "fix PROJ-1 today", ["PROJ-1"]],
    ["token: the uppercase JIRA key for an Atlassian URL", "see https://acme.atlassian.net/browse/proj-5?x=1", ["PROJ-5"]],
    ["id: a JIRA URL and the same bare key count once", "PROJ-5 https://acme.atlassian.net/browse/PROJ-5", ["PROJ-5"]],
    ["id: the same pull request in another case counts once", "https://github.com/O/R/pull/1 https://github.com/o/r/pull/1", ["https://github.com/O/R/pull/1"]],
    ["id: a pull request and an issue of one number differ", "https://github.com/o/r/pull/1 https://github.com/o/r/issues/1", ["https://github.com/o/r/pull/1", "https://github.com/o/r/issues/1"]],
    ["order: in order of appearance across kinds", "PROJ-2 then https://github.com/o/r/pull/3 then ABC-1", ["PROJ-2", "https://github.com/o/r/pull/3", "ABC-1"]],
    ["URL start: at the start of the text", "https://github.com/o/r/pull/1", ["https://github.com/o/r/pull/1"]],
    ["URL start: after whitespace, including a no-break space", "fix https://github.com/o/r/pull/1", ["https://github.com/o/r/pull/1"]],
    ["URL start: after opening punctuation", "(https://github.com/o/r/pull/1)", ["https://github.com/o/r/pull/1"]],
    ["URL start: not inside another URL", "https://evil.example/?u=https://github.com/o/r/pull/1", []],
    ["URL start: after [", "[https://github.com/o/r/pull/1]", ["https://github.com/o/r/pull/1"]],
    ["URL start: after <", "<https://github.com/o/r/pull/1>", ["https://github.com/o/r/pull/1"]],
    ["URL start: after a double quote", "\"https://github.com/o/r/pull/1\"", ["https://github.com/o/r/pull/1"]],
    ["URL start: after a single quote", "'https://github.com/o/r/pull/1'", ["https://github.com/o/r/pull/1"]],
    ["URL start: an Atlassian URL after whitespace", "see https://acme.atlassian.net/browse/PROJ-5", ["PROJ-5"]],
    ["URL start: an Atlassian URL after opening punctuation", "(https://acme.atlassian.net/browse/PROJ-5)", ["PROJ-5"]],
    ["URL start: an Atlassian URL inside another URL finds nothing", "https://evil.example/?u=https://acme.atlassian.net/browse/PROJ-5", []],
    ["number: an Atlassian number must end at a boundary", "https://acme.atlassian.net/browse/PROJ-5x", []],
    ["number: a decimal after a pull request number finds nothing", "https://github.com/o/r/pull/12.5", []],
    ["number: a decimal after an issue number finds nothing", "https://github.com/o/r/issues/12.5", []],
    ["number: leading zeros are stripped", "https://github.com/o/r/pull/012", ["https://github.com/o/r/pull/12"]],
    ["number: leading zeros and none count once", "https://github.com/o/r/pull/012 https://github.com/o/r/pull/12", ["https://github.com/o/r/pull/12"]],
    ["number: only zeros finds nothing", "https://github.com/o/r/pull/000", []],
    ["number: nine digits are allowed", "https://github.com/o/r/pull/123456789", ["https://github.com/o/r/pull/123456789"]],
    ["number: ten digits find nothing", "https://github.com/o/r/pull/1234567890", []],
    ["number: a key's ten digits find nothing", "PROJ-1234567890", []],
    ["number: an Atlassian key's ten digits find nothing", "https://acme.atlassian.net/browse/PROJ-1234567890", []],
    ["number: a key keeps its zeros", "PROJ-007", ["PROJ-007"]],
    ["repo: a dot owner finds nothing", "https://github.com/./x/pull/1", []],
    ["repo: a double-dot owner finds nothing", "https://github.com/../x/pull/1", []],
    ["repo: a dot name finds nothing", "https://github.com/o/./pull/1", []],
    ["repo: a double-dot name finds nothing", "https://github.com/o/../pull/1", []],
    ["repo: a name ending in a dot finds nothing", "https://github.com/o/r./pull/1", []],
    ["text: invalid UTF-8 is scrubbed and the rest scans", "\xff PROJ-1", ["PROJ-1"]],
    ["text: UTF-16 input is converted", "fix PROJ-1".encode("UTF-16LE"), ["PROJ-1"]],
    ["host: github.com must be the host", "https://evilgithub.com/o/r/pull/1", []],
    ["host: github.com in a path is not the host", "https://evil.example/github.com/o/r/pull/1", []],
    ["number: must end at a boundary", "https://github.com/o/r/pull/123abc", []],
    ["number: may be followed by punctuation", "https://github.com/o/r/pull/123.", ["https://github.com/o/r/pull/123"]],
    ["repo: parts hold dots, hyphens and underscores", "https://github.com/my-o.rg/re_po.js/pull/4", ["https://github.com/my-o.rg/re_po.js/pull/4"]],
    ["blanking: a key in another host's query finds nothing", "https://ci.acme.com/job?ticket=ABC-12", []],
    ["blanking: a key after a URL is still found", "https://ci.acme.com/job and ABC-12", ["ABC-12"]],
    ["bare key: followed by a period", "fix PROJ-1.", ["PROJ-1"]],
    ["bare key: in parentheses", "fix (PROJ-1)", ["PROJ-1"]],
    ["bare key: before a colon", "PROJ-1: fix it", ["PROJ-1"]],
    ["bare key: in backticks", "fix `PROJ-1`", ["PROJ-1"]],
    ["bare key: CVE ids are not keys", "CVE-2024-1234", []],
    ["bare key: not after a slash in a path", "docs/ABC-12.md", []],
    ["bare key: not after a slash in a branch", "feature/ABC-12", []],
    ["bare key: not in a browse URL of another host", "https://jira.acme.com/browse/PROJ-1", []],
    ["bare key: not after a word character", "xABC-12", []],
    ["bare key: not after a hyphen", "x-ABC-12", []],
    ["bare key: not after a dot", "v.ABC-12", []],
    ["bare key: not after =, ? or &", "a=ABC-12 ?ABC-13 &ABC-14", []],
    ["bare key: not after a hash", "#ABC-12", []],
    ["bare key: not before a hyphen", "ABC-12-fix", []],
    ["bare key: not before a dot and a word character", "ABC-12.5", []],
    ["bare key: at least two letters", "A-12", []],
    ["bare key: uppercase only", "proj-1", []],
    ["bare key: letters only, as the parser reads them", "AB2-12", []],
    ["stop list: UTF-8 is not a ticket", "use UTF-8", []],
    ["stop list: SHA-256 is not a ticket", "SHA-256", []],
    ["stop list: PR-12 is not a ticket", "PR-12", []],
    ["stop list: not applied to an Atlassian URL", "https://acme.atlassian.net/browse/PR-12", ["PR-12"]]
  ]

  describe ".scan" do
    rules.each do |rule, text, expected|
      it rule do
        expect(tokens(text)).to eq(expected)
      end
    end

    it "gives the link flag, repo and id of each kind" do
      found = described_class.scan("https://github.com/O/R/pull/1 https://github.com/o/r/issues/2 PROJ-3")

      expect(found.map(&:to_h)).to eq([
        {token: "https://github.com/O/R/pull/1", id: "github_pr:o/r#1", repo: "O/R", link: true},
        {token: "https://github.com/o/r/issues/2", id: "github_issue:o/r#2", repo: "o/r", link: true},
        {token: "PROJ-3", id: "PROJ-3", repo: nil, link: false}
      ])
    end

    it "marks an Atlassian URL as a link and a bare key as not" do
      found = described_class.scan("https://acme.atlassian.net/browse/PROJ-9 ABC-1")

      expect(found.map(&:link)).to eq([true, false])
    end

    it "keeps one hit for a key and its URL, a link, at the first mention" do
      found = described_class.scan("PROJ-12 then https://acme.atlassian.net/browse/proj-12")

      expect(found.map(&:to_h)).to eq([{token: "PROJ-12", id: "PROJ-12", repo: nil, link: true}])
    end

    it "keeps the first position when a URL comes before its key" do
      found = described_class.scan("ABC-1 https://acme.atlassian.net/browse/PROJ-2 PROJ-2")

      expect(found.map(&:token)).to eq(["ABC-1", "PROJ-2"])
      expect(found.map(&:link)).to eq([false, true])
    end

    it "finds nothing in nil or empty text" do
      expect(described_class.scan(nil)).to eq([])
      expect(described_class.scan("")).to eq([])
    end
  end

  describe ".word_key" do
    it "uppercases a key of any casing" do
      expect(described_class.word_key("proj-1")).to eq("PROJ-1")
      expect(described_class.word_key("Proj-12")).to eq("PROJ-12")
      expect(described_class.word_key("proj-007")).to eq("PROJ-007")
    end

    [
      ["a stop-list prefix", "pr-12"],
      ["another stop-list prefix", "cve-2024"],
      ["one letter", "a-1"],
      ["a digit in the prefix", "ab2-1"],
      ["a suffix after the number", "proj-1-fix"],
      ["no number", "proj-x"],
      ["ten digits", "proj-1234567890"],
      ["a plain word", "rpiv"]
    ].each do |name, word|
      it "returns nil for #{name}" do
        expect(described_class.word_key(word)).to be_nil
      end
    end
  end

  it "reads word_key on invalid UTF-8 without raising" do
    expect(described_class.word_key("\xff")).to be_nil
    expect(described_class.word_key("proj-1".encode("UTF-16LE"))).to eq("PROJ-1")
  end

  it "keeps NOT_TICKETS frozen with the planned prefixes" do
    expect(described_class::NOT_TICKETS).to be_frozen
    expect(described_class::NOT_TICKETS).to eq(%w[UTF SHA MD AES RSA ISO RFC HTTP TLS SSL GPT CVE PR ISSUE PEP IPV ES])
  end

  describe "agreement with StartRef" do
    let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
    let(:start_ref) { Workspace::StartRef.new(git: git, lineage: LineageSupport.lineage) }

    {
      "https://github.com/o/r/pull/12" => ["github_pr", "o/r#12", "pr-12"],
      "https://github.com/o/r/issues/7" => ["github_issue", "o/r#7", "issue-7"],
      "PROJ-1" => ["jira", "PROJ-1", "PROJ-1"],
      "https://acme.atlassian.net/browse/proj-5" => ["jira", "PROJ-5", "PROJ-5"]
    }.each do |text, (kind, key, branch)|
      it "reads the token found in #{text} as #{kind}" do
        found = described_class.scan("please look at #{text} soon").fetch(0)

        ref = start_ref.call(found.token, names: Workspace::StartRef::BranchNames::NONE)

        expect(ref).to have_attributes(kind: kind, key: key, branch: branch)
      end
    end
  end
end
